local fn, uv = vim.fn, vim.loop
local fs = require('fundo.fs')
local path = require('fundo.fs.path')
local M = {}

function M.directory(archivesDir)
    return path.join(fn.stdpath('state'), 'fundo-journal', fn.sha256(path.normalize(archivesDir)))
end

local function read(filename)
    local fd = assert(fs.openSync(filename, 'r', 384))
    local ok, data = pcall(function()
        local stat = assert(fs.fstatSync(fd))
        local contents = assert(fs.readSync(fd, stat.size, 0))
        assert(#contents == stat.size, 'incomplete recovery journal')
        return contents
    end)
    fs.closeSync(fd)
    if not ok then error(data, 0) end
    return data
end

function M.refresh(transfer)
    if not transfer.journalPath then return end
    local record = {
        version = 1, name = transfer.name, undoPath = transfer.undoPath,
        fallbackPath = transfer.fallbackPath, baselinePath = transfer.baselinePath,
        baselineOnly = transfer.baselineOnly, textOnly = transfer.textOnly,
        capturedAt = transfer.capturedAt, expectedGeneration = transfer.expectedGeneration,
        changedtick = transfer.changedtick, lastError = transfer.lastError,
        createdGenerations = transfer.createdGenerations,
        pid = uv.os_getpid(), host = uv.os_gethostname(), files = {},
    }
    for _, field in ipairs({'contents', 'undoContents'}) do
        if transfer[field] then record.files[field] = {size = #transfer[field], hash = fn.sha256(transfer[field])} end
    end
    fs.writeFileSync(path.join(transfer.journalPath, 'record'), fn.json_encode(record))
end

function M.write(transfer)
    if transfer.journalPath or not transfer.contents then return end
    local root = M.directory(path.dirname(transfer.fallbackPath))
    local directory = path.join(root, ('%d-%.0f'):format(uv.os_getpid(), uv.hrtime()))
    fs.mkdirpSync(directory, 448)
    local ok, err = pcall(function()
        for _, field in ipairs({'contents', 'undoContents'}) do
            if transfer[field] then fs.writeFileSync(path.join(directory, field), transfer[field]) end
        end
        transfer.journalPath = directory
        M.refresh(transfer)
    end)
    if not ok then
        -- Removing an empty directory cannot discard captured work. Leave any
        -- partially written data for inspection rather than assuming it is bad.
        fn.delete(directory, 'd')
        transfer.journalPath = nil
        error(err, 0)
    end
    transfer.durableAt = os.time()
end

function M.finish(transfer)
    local directories = vim.list_extend({}, transfer.supersededJournals or {})
    if transfer.journalPath then directories[#directories + 1] = transfer.journalPath end
    for _, directory in ipairs(directories) do
        assert(fn.delete(directory, 'rf') == 0, 'cannot remove committed recovery journal: ' .. directory)
        fs.syncDirectorySync(path.dirname(directory))
    end
    transfer.journalPath = nil
end

function M.list(archivesDir, includeLive)
    local result, errors = {}, {}
    local root = M.directory(archivesDir)
    local scan = uv.fs_scandir(root)
    if not scan then return result, errors end
    while true do
        local id, kind = uv.fs_scandir_next(scan)
        if not id then break end
        if kind == 'directory' then
            local directory = path.join(root, id)
            local ok, record = pcall(function()
                local value = fn.json_decode(read(path.join(directory, 'record')))
                assert(value.version == 1 and type(value.name) == 'string' and type(value.undoPath) == 'string'
                    and type(value.fallbackPath) == 'string' and path.dirname(value.fallbackPath) == archivesDir,
                    'invalid recovery journal identity')
                assert(type(value.files) == 'table' and value.files.contents, 'journal text is missing')
                for _, field in ipairs({'contents', 'undoContents'}) do
                    local expected = value.files[field]
                    if expected then
                        local contents = read(path.join(directory, field))
                        assert(#contents == expected.size and fn.sha256(contents) == expected.hash,
                            'journal checksum mismatch: ' .. field)
                        value[field] = contents
                    end
                end
                assert(value.baselineOnly or value.textOnly or type(value.undoContents) == 'string',
                    'journal undo is missing')
                value.journalPath, value.fromJournal = directory, true
                return value
            end)
            if ok then
                local alive, _, code
                if record.host == uv.os_gethostname() and type(record.pid) == 'number' then
                    alive, _, code = uv.kill(record.pid, 0)
                end
                if includeLive or (not alive and code == 'ESRCH') then result[#result + 1] = record end
            else
                errors[#errors + 1] = {path = directory, message = tostring(record)}
            end
        end
    end
    table.sort(result, function(a, b)
        if (a.capturedAt or 0) ~= (b.capturedAt or 0) then return (a.capturedAt or 0) > (b.capturedAt or 0) end
        return tonumber(a.journalPath:match('%-(%d+)$')) > tonumber(b.journalPath:match('%-(%d+)$'))
    end)
    return result, errors
end

function M.forget(archivesDir, name)
    local records = M.list(archivesDir, true)
    for _, record in ipairs(records) do
        if path.normalize(record.name) == path.normalize(name) then M.finish(record) end
    end
end

return M

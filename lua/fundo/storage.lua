local uv = vim.loop
local fn = vim.fn
local fs = require('fundo.fs')
local path = require('fundo.fs.path')

local M = {}
local directoryMode = 448
local fileMode = 384

function M.root(archivesDir)
    return path.join(archivesDir, '.generations')
end

function M.directory(fallbackPath)
    return path.join(M.root(path.dirname(fallbackPath)), fn.sha256(path.normalize(fallbackPath)))
end

local function readFile(filename)
    local fd, err = fs.openSync(filename, 'r', fileMode)
    if not fd then error(err) end
    local ok, result = pcall(function()
        local stat = assert(fs.fstatSync(fd))
        local data = assert(fs.readSync(fd, stat.size, 0))
        assert(#data == stat.size, 'incomplete generation file: ' .. filename)
        return data
    end)
    fs.closeSync(fd)
    if not ok then error(result) end
    return result
end

local function readJson(filename)
    return fn.json_decode(readFile(filename))
end

local function idValid(id)
    return type(id) == 'string' and id:match('^%d+%-%d+$') ~= nil
end

local function head(fallbackPath)
    local filename = path.join(M.directory(fallbackPath), 'current')
    if not fs.statSync(filename) then return end
    local value = readJson(filename)
    assert(type(value) == 'table' and value.version == 1 and idValid(value.current), 'invalid generation pointer')
    assert(value.previous == nil or idValid(value.previous), 'invalid previous generation')
    return value
end

function M.token(fallbackPath)
    local value = head(fallbackPath)
    return value and value.current or false
end

function M.revision(fallbackPath)
    local filename = path.join(M.directory(fallbackPath), 'current')
    return fs.statSync(filename) and fn.sha256(readFile(filename)) or false
end

function M.inspect(fallbackPath)
    local ok, value = pcall(head, fallbackPath)
    if not ok then return nil, tostring(value) end
    if not value then return nil, 'missing' end
    return {generation = value.current, previous = value.previous}
end

local function readGeneration(fallbackPath, id)
    local dir = path.join(M.directory(fallbackPath), id)
    local record = readJson(path.join(dir, 'record'))
    assert(type(record) == 'table' and record.version == 1, 'unsupported generation record')
    assert(record.fallbackPath == fallbackPath and type(record.name) == 'string'
        and type(record.undoPath) == 'string', 'generation identity mismatch')
    local result = {
        name = record.name, undoPath = record.undoPath, fallbackPath = fallbackPath,
        baselinePath = fallbackPath .. '.base', capturedAt = record.capturedAt,
        generation = id, baselineOnly = record.baselineOnly,
        snapshot_format = 'buffer-lines-v1', baseline_format = 'buffer-lines-v1',
    }
    assert(type(record.files) == 'table', 'generation files are missing')
    for _, field in ipairs({'contents', 'undoContents', 'baselineContents'}) do
        local expected = record.files[field]
        if expected then
            local data = readFile(path.join(dir, field))
            assert(type(expected) == 'table' and #data == expected.size
                and fn.sha256(data) == expected.hash, 'generation checksum mismatch: ' .. field)
            result[field] = data
        end
    end
    assert(type(result.contents) == 'string', 'generation text is missing')
    assert(result.baselineOnly == true or type(result.undoContents) == 'string', 'generation undo is missing')
    return result
end

function M.read(fallbackPath)
    local ok, value = pcall(head, fallbackPath)
    if not ok then return nil, tostring(value) end
    if not value then return nil, 'missing' end
    local loaded, result = pcall(readGeneration, fallbackPath, value.current)
    if not loaded and value.previous then
        loaded, result = pcall(readGeneration, fallbackPath, value.previous)
    end
    if not loaded then return nil, tostring(result) end
    result.expectedGeneration = value.current
    return result
end

local function release(lock)
    fs.unlinkSync(path.join(lock, 'owner'))
    fs.rmdirSync(lock)
end

local function reap(lock)
    local ownerPath = path.join(lock, 'owner')
    local ok, owner = pcall(readJson, ownerPath)
    if ok and type(owner) == 'table' and owner.host == uv.os_gethostname() and type(owner.pid) == 'number' then
        local alive, _, code = uv.kill(owner.pid, 0)
        if alive or code ~= 'ESRCH' then return end
    else
        -- A process may be between mkdir and writing its owner record.
        local stat = fs.statSync(lock)
        if fs.statSync(ownerPath) or not stat or os.time() - stat.mtime.sec < 60 then return end
    end
    local marker = path.join(lock, 'reaping')
    local fd = fs.openSync(marker, 'wx', fileMode)
    if not fd then return end
    fs.closeSync(fd)
    fs.unlinkSync(ownerPath)
    fs.unlinkSync(marker)
    fs.rmdirSync(lock)
end

local function withDirectoryLock(dir, callback)
    fs.mkdirpSync(path.dirname(dir), directoryMode)
    local lock = dir .. '.lock'
    local acquired = fs.mkdirSync(lock, directoryMode)
    if not acquired then
        reap(lock)
        acquired = fs.mkdirSync(lock, directoryMode)
    end
    assert(acquired, 'archive is busy in another process: ' .. dir)
    local ok, result = pcall(function()
        fs.writeFileSync(path.join(lock, 'owner'), fn.json_encode({pid = uv.os_getpid(), host = uv.os_gethostname()}))
        return callback()
    end)
    release(lock)
    if not ok then error(result, 0) end
    return result
end

function M.withLock(fallbackPath, callback)
    return withDirectoryLock(M.directory(fallbackPath), callback)
end

local function entries(dir)
    local result = {}
    local scan = uv.fs_scandir(dir)
    if scan then
        while true do
            local name, kind = uv.fs_scandir_next(scan)
            if not name then break end
            result[#result + 1] = {name = name, kind = kind}
        end
    end
    return result
end

local function directorySize(dir)
    local bytes = 0
    for _, item in ipairs(entries(dir)) do
        local filename = path.join(dir, item.name)
        if item.kind == 'directory' then
            bytes = bytes + directorySize(filename)
        elseif item.kind == 'file' then
            bytes = bytes + ((fs.statSync(filename) or {}).size or 0)
        end
    end
    return bytes
end

function M.size(fallbackPath)
    return directorySize(M.directory(fallbackPath))
end

local function cleanup(fallbackPath, current, previous)
    local dir = M.directory(fallbackPath)
    for _, item in ipairs(entries(dir)) do
        if item.name ~= 'current' and item.name ~= current and item.name ~= previous then
            fn.delete(path.join(dir, item.name), 'rf')
        end
    end
end

function M.publish(transfer, persist)
    return M.withLock(transfer.fallbackPath, function()
        local current = M.token(transfer.fallbackPath)
        if current and current ~= transfer.expectedGeneration then
            error('archive changed in another session; reopen the file before retrying')
        end
        local saved = transfer
        local prior, priorError = M.read(transfer.fallbackPath)
        if priorError and priorError ~= 'missing' then error(priorError) end
        if transfer.baselineOnly then
            if prior and not prior.baselineOnly then
                saved = vim.tbl_extend('force', prior, {
                    baselineContents = transfer.contents, capturedAt = transfer.capturedAt,
                })
                if not transfer.contents then saved.baselineContents = nil end
            end
        end
        if not saved.contents then
            persist()
            assert(fn.delete(M.directory(transfer.fallbackPath), 'rf') == 0, 'cannot remove disabled baseline generation')
            transfer.generation = false
            return false
        end
        local id = ('%d-%.0f'):format(uv.os_getpid(), uv.hrtime())
        local dir = path.join(M.directory(transfer.fallbackPath), id)
        fs.mkdirpSync(dir, directoryMode)
        local record = {
            version = 1, name = saved.name, undoPath = saved.undoPath,
            fallbackPath = saved.fallbackPath, baselineOnly = saved.baselineOnly == true,
            capturedAt = saved.capturedAt, files = {},
        }
        for _, field in ipairs({'contents', 'undoContents', 'baselineContents'}) do
            if saved[field] then
                local data = saved[field]
                fs.writeFileSync(path.join(dir, field), data)
                record.files[field] = {size = #data, hash = fn.sha256(data)}
            end
        end
        fs.writeFileSync(path.join(dir, 'record'), fn.json_encode(record))
        persist()
        fs.writeFileSync(path.join(M.directory(transfer.fallbackPath), 'current'), fn.json_encode({
            version = 1, current = id, previous = prior and prior.generation or nil,
        }))
        transfer.generation = id
        cleanup(transfer.fallbackPath, id, prior and prior.generation or nil)
        return id
    end)
end

function M.remove(fallbackPath)
    local dir = M.directory(fallbackPath)
    if fs.statSync(dir) then
        assert(fn.delete(dir, 'rf') == 0, 'cannot remove archive generations')
    end
end

function M.records(archivesDir)
    local result = {}
    for _, item in ipairs(entries(M.root(archivesDir))) do
        if item.kind == 'directory' and item.name:match('^[a-f0-9]+$') then
            local dir = path.join(M.root(archivesDir), item.name)
            local ok, value = pcall(function()
                local pointer = readJson(path.join(dir, 'current'))
                assert(idValid(pointer.current), 'invalid generation pointer')
                local record = readJson(path.join(dir, pointer.current, 'record'))
                assert(type(record.fallbackPath) == 'string' and M.directory(record.fallbackPath) == dir
                    and path.dirname(record.fallbackPath) == archivesDir, 'generation identity mismatch')
                return {
                    directory = dir,
                    fallbackPath = record.fallbackPath, name = record.name,
                    token = pointer.current, size = M.size(record.fallbackPath),
                    mtime = fs.statSync(path.join(dir, 'current')).mtime.sec,
                }
            end)
            if ok then
                result[#result + 1] = value
            else
                local stat = fs.statSync(dir)
                result[#result + 1] = {directory = dir, size = directorySize(dir),
                    mtime = stat and stat.mtime.sec or 0, error = tostring(value)}
            end
        end
    end
    return result
end

function M.removeInvalid(dir)
    withDirectoryLock(dir, function()
        local archivesDir = path.dirname(path.dirname(dir))
        for _, record in ipairs(M.records(archivesDir)) do
            if record.directory == dir and record.error then
                assert(fn.delete(dir, 'rf') == 0, 'cannot remove invalid generation')
            end
        end
    end)
end

function M.clean(archivesDir)
    for _, item in ipairs(entries(M.root(archivesDir))) do
        if item.kind == 'directory' and item.name:match('^[a-f0-9]+$') then
            local dir = path.join(M.root(archivesDir), item.name)
            pcall(withDirectoryLock, dir, function()
                if not fs.statSync(path.join(dir, 'current')) then
                    fn.delete(dir, 'rf')
                    return
                end
                local pointer = readJson(path.join(dir, 'current'))
                if not idValid(pointer.current) then return end
                for _, entry in ipairs(entries(dir)) do
                    if entry.name ~= 'current' and entry.name ~= pointer.current and entry.name ~= pointer.previous then
                        fn.delete(path.join(dir, entry.name), 'rf')
                    end
                end
            end)
        end
    end
end

return M

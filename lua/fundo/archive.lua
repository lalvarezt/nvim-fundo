local api = vim.api
local fn = vim.fn
local config = require('fundo.config')
local fs = require('fundo.fs')
local path = require('fundo.fs.path')
local manifest = require('fundo.manifest')
local storage = require('fundo.storage')
local undo = require('fundo.model.undo')

local M = {}

local function normalize(name)
    local value = path.normalize(fn.fnamemodify(name, ':p'))
    if value ~= path.sep and not value:match('^%a:[\\/]$') then value = value:gsub(path.sep .. '+$', '') end
    return value
end

function M.records()
    local records = {}
    local unidentified = {}
    local function add(name, fallback, undoPath)
        if name == '' then return end
        records[fallback] = {name = path.normalize(name), fallbackPath = fallback, undoPath = undoPath}
    end
    for _, filename in ipairs(fn.glob(path.join(manifest.dir(config.archives_dir), '*.json'), false, true)) do
        local fallback = path.join(config.archives_dir, path.basename(filename):sub(1, -6))
        local record = manifest.read(filename, fallback)
        if record then add(record.source.path, fallback, record.undo.path)
        else table.insert(unidentified, filename) end
    end
    for _, record in ipairs(storage.records(config.archives_dir)) do
        if record.fallbackPath then
            add(record.name, record.fallbackPath, fn.undofile(record.name))
        else
            table.insert(unidentified, record.directory)
        end
    end
    local manager = require('fundo.manager')
    for _, u in pairs(manager.undos or {}) do add(u.name, u.fallbackPath, u.undoPath) end
    for _, transfer in pairs(manager.pendingTransfers or {}) do
        add(transfer.name, transfer.fallbackPath, transfer.undoPath)
    end
    return records, unidentified
end

function M.forget(target, opts)
    opts = opts or {}
    target = target or api.nvim_buf_get_name(0)
    assert(type(target) == 'string' and target ~= '', 'forget requires a file or project path')
    target = normalize(target)
    local stat = fs.statSync(target)
    local project = opts.project == true or (stat and stat.type == 'directory') or false
    local prefix = target:sub(-1) == path.sep and target or target .. path.sep
    local records, unidentified = M.records()
    if not project then
        local undoPath = fn.undofile(target)
        if undoPath ~= '' then
            local fallback = undo.archivePath(target, undoPath, config.archives_dir)
            if fs.statSync(fallback) or fs.statSync(fallback .. '.base') or fs.statSync(manifest.path(fallback))
                or fs.statSync(storage.directory(fallback)) then
                records[fallback] = records[fallback] or {name = target, fallbackPath = fallback, undoPath = undoPath}
            end
        end
    end
    local result = {target = target, project = project, records = {}, bytes = 0, errors = {},
        unidentified = unidentified, applied = false, removed = 0}
    for _, record in pairs(records) do
        if record.name == target or (project and record.name:sub(1, #prefix) == prefix) then
            local fallback = record.fallbackPath
            record.paths = {fallback, fallback .. '.base', manifest.path(fallback)}
            record.bytes = storage.size(fallback)
            for _, filename in ipairs(record.paths) do record.bytes = record.bytes + ((fs.statSync(filename) or {}).size or 0) end
            record.token = storage.revision(fallback)
            result.bytes = result.bytes + record.bytes
            table.insert(result.records, record)
        end
    end
    table.sort(result.records, function(a, b) return a.name < b.name end)
    if not opts.apply then return result end
    local manager = require('fundo.manager')
    for _, record in ipairs(result.records) do
        local ok, err = pcall(storage.withLock, record.fallbackPath, function()
            assert(storage.revision(record.fallbackPath) == record.token, 'archive changed after removal preview')
            for _, filename in ipairs(record.paths) do
                local removed, failure, code = fs.unlinkSync(filename)
                if not removed and code ~= 'ENOENT' then error(failure) end
            end
            storage.remove(record.fallbackPath)
        end)
        if ok then
            manager:forgetName(record.name)
            result.removed = result.removed + 1
        else
            table.insert(result.errors, record.name .. ': ' .. tostring(err))
        end
    end
    result.applied = #result.errors == 0
    if result.applied then
        if project then
            manager.forgottenProjects = manager.forgottenProjects or {}
            manager.forgottenProjects[target] = true
            for name in pairs(manager.manualPaths or {}) do
                if name == target or name:sub(1, #prefix) == prefix then manager.manualPaths[name] = nil end
            end
        else
            manager:forgetName(target)
        end
    end
    return result
end

local function withScratch(record, callback)
    local bufnr = api.nvim_create_buf(false, true)
    vim.bo[bufnr].undofile = false
    local u = undo:new(bufnr, config.archives_dir)
    u.name, u.undoPath, u.fallbackPath = record.name, record.undoPath, record.fallbackPath
    u.baselinePath = record.fallbackPath .. '.base'
    local ok, result = pcall(callback, u, bufnr)
    api.nvim_buf_delete(bufnr, {force = true})
    if not ok then error(result, 0) end
    return result
end

local function sourceSnapshot(name)
    local matches = {}
    for _, record in pairs(M.records()) do
        if record.name == name then table.insert(matches, record) end
    end
    -- Legacy records without metadata can still be addressed explicitly.
    if #matches == 0 then
        local undoPath = fn.undofile(name)
        assert(undoPath ~= '', 'source has no usable undo path')
        matches[1] = {name = name, undoPath = undoPath,
            fallbackPath = undo.archivePath(name, undoPath, config.archives_dir)}
    end
    assert(#matches == 1, 'multiple archives match the old path; association is ambiguous')
    local record = matches[1]
    local committed, err = storage.read(record.fallbackPath)
    if committed then return committed end
    assert(err == 'missing', err)
    return withScratch(record, function(u, bufnr)
        if fs.statSync(record.fallbackPath) and fs.statSync(record.undoPath) then
            api.nvim_buf_set_lines(bufnr, 0, -1, false, u:readFallbackLines())
            local loaded, failure = u:loadUndo()
            assert(loaded, failure)
            return u:transferSnapshot()
        end
        local baseline = u:readBaseline()
        assert(baseline, 'no usable archive for the old path')
        return {name = name, baselineOnly = true, contents = table.concat(baseline, '\n') .. '\n'}
    end)
end

function M.associationCandidates(newPath)
    newPath = newPath or api.nvim_buf_get_name(0)
    if newPath == '' then return {} end
    newPath = normalize(newPath)
    local bufnr = fn.bufnr(newPath)
    if bufnr < 0 or not api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].modified then return {} end
    local current = fs.statSync(newPath)
    if not current or not current.ino or current.ino == 0 or not current.birthtime
        or current.birthtime.sec == 0 then return {} end
    local contents = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n'
    local candidates = {}
    for _, record in pairs(M.records()) do
        if record.name ~= newPath and not fs.statSync(record.name) then
            local metadata = manifest.read(manifest.path(record.fallbackPath), record.fallbackPath)
            local previous = metadata and metadata.source.stat
            if previous and previous.dev == current.dev and previous.ino == current.ino
                and vim.deep_equal(previous.birthtime, current.birthtime) then
                local ok, saved = pcall(sourceSnapshot, record.name)
                if ok and saved.contents == contents then table.insert(candidates, record.name) end
            end
        end
    end
    if #candidates == 1 then return candidates end
    return {}
end

function M.associate(oldPath, newPath)
    local manager = require('fundo.manager')
    assert(manager.initialized, 'Fundo must be enabled before associating history')
    assert(type(oldPath) == 'string' and oldPath ~= '', 'association requires the old path')
    oldPath = normalize(oldPath)
    newPath = newPath or api.nvim_buf_get_name(0)
    assert(type(newPath) == 'string' and newPath ~= '', 'association requires a named destination')
    newPath = normalize(newPath)
    assert(oldPath ~= newPath, 'source and destination paths must differ')
    local bufnr = fn.bufnr(newPath)
    assert(bufnr >= 0 and api.nvim_buf_is_loaded(bufnr), 'open the destination file before associating history')
    local eligibility = undo:new(bufnr, config.archives_dir):baselineEligibility()
    assert(eligibility == 'eligible' or eligibility == 'baseline-disabled' or eligibility == 'oversized',
        'destination is ineligible: ' .. eligibility)
    assert(config.filter(newPath, bufnr) == true, 'destination is excluded by filter')
    assert(vim.bo[bufnr].buftype == '', 'destination must be a regular file buffer')
    local tree = require('fundo.utils').bufCall(bufnr, fn.undotree)
    assert(#tree.entries == 0, 'destination already has undo history; both histories were kept')
    local undoPath = fn.undofile(newPath)
    assert(undoPath ~= '', 'destination has no usable undo path')
    assert(not fs.statSync(undoPath), 'destination already has a native undo file; both histories were kept')
    local fallback = undo.archivePath(newPath, undoPath, config.archives_dir)
    local current = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local currentText = table.concat(current, '\n') .. '\n'
    local existing, generationError = storage.read(fallback)
    assert(existing or generationError == 'missing', generationError)
    if existing then
        assert(existing.baselineOnly and existing.contents == currentText,
            'destination already has different archived history; both histories were kept')
    elseif fs.statSync(fallback) then
        error('destination already has a fallback archive; both histories were kept')
    elseif fs.statSync(fallback .. '.base') then
        local probe = undo:new(bufnr, config.archives_dir)
        probe.fallbackPath, probe.baselinePath = fallback, fallback .. '.base'
        local previous = probe:readBaseline()
        assert(previous and table.concat(previous, '\n') .. '\n' == currentText,
            'destination already has different baseline history; both histories were kept')
    end
    local active = manager.undos[bufnr]
    local pending = (active and (active.pendingRecovery or active.pendingTransfer)) or manager.pendingTransfers[fallback]
    assert(not pending or (pending.baselineOnly and pending.contents == currentText),
        'destination has pending history; both histories were kept')
    local token = storage.token(fallback)
    local source = sourceSnapshot(oldPath)
    local destination = {name = newPath, undoPath = undoPath, fallbackPath = fallback}
    local transfer = withScratch(destination, function(u, scratch)
        -- The initial scratch contents must not become part of destination history.
        vim.bo[scratch].undolevels = -1
        api.nvim_buf_set_lines(scratch, 0, -1, false, current)
        vim.bo[scratch].undolevels = vim.bo[bufnr].undolevels
        vim.bo[scratch].modified = false
        local loaded, reason = u:loadFallBack(source)
        assert(loaded or (source.baselineOnly and source.contents == currentText), reason or 'source history could not be loaded')
        if u:isEmpty() then
            return {baselineOnly = true, name = newPath, undoPath = undoPath, fallbackPath = fallback,
                baselinePath = fallback .. '.base', contents = currentText, capturedAt = os.time()}
        end
        return u:transferSnapshot()
    end)
    transfer.expectedGeneration = token
    transfer.rejectExistingUndo = true
    undo.completePendingTransferSync(transfer)
    if active then
        active.pendingTransfer = nil
        active:dispose()
        manager.undos[bufnr] = nil
    end
    manager.pendingTransfers[fallback] = nil
    manager.manualPaths[newPath] = true
    manager.forgotten[newPath] = nil
    local tracked = assert(manager:attach(bufnr, 'manual'), 'destination could not be attached')
    local loaded, reason = tracked:loadFallBack(transfer)
    assert(loaded or transfer.baselineOnly, reason or 'associated history could not be loaded')
    tracked.isDirty = false
    local previous = vim.split(source.contents, '\n', {plain = true})
    table.remove(previous)
    tracked:recordRecovery(previous, current, 'association')
    tracked.lastAction, tracked.lastUpdated = 'associated', os.time()
    return {source = oldPath, destination = newPath, generation = storage.token(fallback)}
end

return M

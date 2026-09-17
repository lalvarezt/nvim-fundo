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

return M

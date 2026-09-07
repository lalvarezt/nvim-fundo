local api = vim.api
local fn = vim.fn
local uv = vim.loop

local config = require('fundo.config')
local fs = require('fundo.fs')
local manifest = require('fundo.manifest')
local path = require('fundo.fs.path')
local utils = require('fundo.utils')

local M = {}

local function artifact(pathname)
    local stat = pathname ~= '' and fs.statSync(pathname) or nil
    return {
        path = pathname,
        exists = stat ~= nil,
        size = stat and stat.size or nil,
        mtime = stat and stat.mtime and stat.mtime.sec or nil,
    }
end

local function resolveTarget(target)
    local bufnr
    local name
    if type(target) == 'number' then
        bufnr = target
        local ok, value = pcall(api.nvim_buf_get_name, bufnr)
        name = ok and value or ''
    elseif type(target) == 'string' and target ~= '' then
        name = fn.fnamemodify(target, ':p')
        bufnr = fn.bufnr(name)
        if bufnr < 0 then
            bufnr = nil
        end
    else
        bufnr = api.nvim_get_current_buf()
        name = api.nvim_buf_get_name(bufnr)
    end
    return bufnr, name
end

function M.status(target)
    local manager = require('fundo.manager')
    local bufnr, name = resolveTarget(target)
    local tracked = bufnr and manager.undos and manager.undos[bufnr] or nil
    local selected = false
    local filterError
    if name ~= '' then
        local ok, value = pcall(config.filter, name, bufnr or -1)
        if ok then
            selected = value == true
        else
            filterError = tostring(value)
        end
    end

    local undoPath = name ~= '' and fn.undofile(name) or ''
    local fallbackPath = undoPath ~= ''
        and require('fundo.model.undo').archivePath(name, undoPath, config.archives_dir) or ''
    local baselinePath = fallbackPath ~= '' and fallbackPath .. '.base' or ''
    local manifestPath = fallbackPath ~= '' and manifest.path(fallbackPath) or ''
    local manifestValue, manifestError
    if manifestPath ~= '' then
        manifestValue, manifestError = manifest.read(manifestPath, fallbackPath)
    end

    local state
    if name == '' then
        state = 'unnamed'
    elseif filterError then
        state = 'filter-error'
    elseif not selected then
        state = 'filtered'
    elseif tracked and tracked.pendingTransfer then
        state = 'pending-transfer'
    elseif tracked and tracked.isDirty then
        state = 'dirty'
    elseif fs.statSync(fallbackPath) and manifestValue then
        state = 'healthy'
    elseif fs.statSync(fallbackPath) and manifestError == 'missing' then
        state = 'legacy-archive'
    elseif fs.statSync(fallbackPath) then
        state = 'invalid-manifest'
    elseif fs.statSync(baselinePath) then
        state = 'baseline-only'
    else
        state = 'no-archive'
    end

    return {
        name = name,
        bufnr = bufnr,
        selected = selected,
        filter_error = filterError,
        tracked = tracked ~= nil,
        dirty = tracked and tracked.isDirty == true or false,
        pending = tracked and tracked.pendingTransfer ~= nil or false,
        last_action = tracked and tracked.lastAction or nil,
        last_updated = tracked and tracked.lastUpdated or nil,
        state = state,
        native_undo = artifact(undoPath),
        fallback = artifact(fallbackPath),
        baseline = artifact(baselinePath),
        manifest = artifact(manifestPath),
        manifest_version = manifestValue and manifestValue.version or nil,
        manifest_error = manifestError ~= 'missing' and manifestError or nil,
    }
end

local function scanDirectory(dir)
    local result = {}
    local request = uv.fs_scandir(dir)
    if not request then
        return result
    end
    while true do
        local name, kind = uv.fs_scandir_next(request)
        if not name then
            break
        end
        if kind == 'file' then
            result[name] = fs.statSync(path.join(dir, name))
        end
    end
    return result
end

function M.doctor()
    local manager = require('fundo.manager')
    local issues = {}
    local function issue(code, message)
        table.insert(issues, {code = code, message = message})
    end

    local dirStat = fs.statSync(config.archives_dir)
    if not dirStat or dirStat.type ~= 'directory' then
        issue('archive-directory', 'archive directory is missing or is not a directory')
    elseif not utils.isWindows() and dirStat.mode % 512 ~= 448 then
        issue('archive-permissions', 'archive directory permissions are not owner-only')
    end

    local files = scanDirectory(config.archives_dir)
    local records = {}
    local totalSize = 0
    for name, stat in pairs(files) do
        totalSize = totalSize + (stat and stat.size or 0)
        if name:sub(-5) == '.base' then
            local key = name:sub(1, -6)
            records[key] = records[key] or {}
            records[key].baseline = stat
        else
            records[name] = records[name] or {}
            records[name].fallback = stat
        end
    end

    local metadataDir = manifest.dir(config.archives_dir)
    local metadataStat = fs.statSync(metadataDir)
    if metadataStat and metadataStat.type ~= 'directory' then
        issue('metadata-directory', 'metadata path is not a directory')
    elseif metadataStat and not utils.isWindows() and metadataStat.mode % 512 ~= 448 then
        issue('metadata-permissions', 'metadata directory permissions are not owner-only')
    end
    local metadataFiles = scanDirectory(metadataDir)
    for name, stat in pairs(metadataFiles) do
        totalSize = totalSize + (stat and stat.size or 0)
        if not utils.isWindows() and stat.mode % 512 ~= 384 then
            issue('manifest-permissions', 'manifest permissions are not owner-only: ' .. name)
        end
        if name:sub(-5) ~= '.json' then
            issue('metadata-file', 'unexpected metadata file: ' .. name)
        else
            local key = name:sub(1, -6)
            records[key] = records[key] or {}
            records[key].manifest = stat
        end
    end

    local legacy = 0
    local expired = 0
    local cutoff = config.retention_days and os.time() - config.retention_days * 24 * 60 * 60 or nil
    for key, record in pairs(records) do
        local fallbackPath = path.join(config.archives_dir, key)
        if record.manifest and not record.fallback and not record.baseline then
            issue('orphan-manifest', 'manifest has no fallback: ' .. key .. '.json')
        elseif record.fallback and not record.manifest then
            legacy = legacy + 1
        elseif record.manifest then
            local _, err = manifest.read(manifest.path(fallbackPath), fallbackPath)
            if err then
                issue('invalid-manifest', key .. ': ' .. err)
            end
        end
        local newest = math.max(
            record.fallback and record.fallback.mtime.sec or 0,
            record.baseline and record.baseline.mtime.sec or 0,
            record.manifest and record.manifest.mtime.sec or 0
        )
        if cutoff and newest < cutoff then
            expired = expired + 1
        end
    end

    local limitBytes = config.limit_archives_size * 1024 * 1024
    if totalSize > limitBytes then
        issue('archive-size', 'archive usage exceeds the configured limit')
    end

    return {
        ok = #issues == 0,
        archive_dir = config.archives_dir,
        size = totalSize,
        limit = limitBytes,
        records = vim.tbl_count(records),
        legacy_records = legacy,
        expired_records = expired,
        tracked_buffers = manager.undos and vim.tbl_count(manager.undos) or 0,
        pending_transfers = manager.pendingTransfers and vim.tbl_count(manager.pendingTransfers) or 0,
        issues = issues,
    }
end

local function presence(value)
    if value.path == '' then
        return 'unavailable'
    end
    if value.exists then
        return ('present (%d bytes)'):format(value.size or 0)
    end
    return 'missing'
end

function M.formatStatus(value)
    local lines = {
        'Fundo status: ' .. (value.name ~= '' and value.name or '[unnamed buffer]'),
        '  state: ' .. value.state,
        '  selected: ' .. (value.selected and 'yes' or 'no'),
        '  tracked: ' .. (value.tracked and 'yes' or 'no'),
        '  native undo: ' .. presence(value.native_undo),
        '  fallback: ' .. presence(value.fallback),
        '  baseline: ' .. presence(value.baseline),
        '  manifest: ' .. presence(value.manifest),
    }
    if value.manifest_version then
        table.insert(lines, '  manifest version: ' .. value.manifest_version)
    end
    if value.manifest_error then
        table.insert(lines, '  manifest error: ' .. value.manifest_error)
    end
    if value.filter_error then
        table.insert(lines, '  filter error: ' .. value.filter_error)
    end
    if value.last_action then
        table.insert(lines, '  last action: ' .. value.last_action)
    end
    return table.concat(lines, '\n')
end

function M.formatDoctor(value)
    local lines = {
        'Fundo doctor: ' .. (value.ok and 'OK' or 'issues found'),
        '  archive directory: ' .. value.archive_dir,
        ('  usage: %d / %d bytes'):format(value.size, value.limit),
        ('  records: %d (%d legacy, %d expired)'):format(
            value.records,
            value.legacy_records,
            value.expired_records
        ),
        ('  tracked buffers: %d; pending transfers: %d'):format(value.tracked_buffers, value.pending_transfers),
    }
    if #value.issues == 0 then
        table.insert(lines, '  issues: none')
    else
        table.insert(lines, '  issues:')
        for _, current in ipairs(value.issues) do
            table.insert(lines, ('    - %s: %s'):format(current.code, current.message))
        end
    end
    return table.concat(lines, '\n')
end

return M

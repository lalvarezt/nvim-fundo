local api = vim.api
local fn = vim.fn
local uv = vim.loop

local event = require('fundo.lib.event')
local disposable = require('fundo.lib.disposable')
local promise = require('promise')
local utils = require('fundo.utils')
local undo = require('fundo.model.undo')
local async = require('async')
local await = async.wait
local config = require('fundo.config')
local fs = require('fundo.fs')
local log = require('fundo.lib.log')
local path = require('fundo.fs.path')
local mutex = require('fundo.lib.mutex')

local archiveDirMode = 448 -- 0o700

---@class FundoManager
---@field initialized boolean
---@field undos table<number, FundoUndo>
---@field lastScannedtime number
---@field mutex FundoMutex
---@field disposables FundoDisposable[]
local Manager = {}

local function bufferName(bufnr)
    local ok, name = pcall(api.nvim_buf_get_name, bufnr)
    return ok and name or ''
end

local function logBufferEvent(name, bufnr)
    local bufName = bufferName(bufnr)
    if bufName == '' then
        log.trace('event ' .. name .. ':', bufnr, bufName)
    else
        log.debug('event ' .. name .. ':', bufnr, bufName)
    end
end

function Manager:detach(bufnr)
    local u = self.undos[bufnr]
    if u then
        log.debug('detaching buffer:', bufnr, bufferName(bufnr))
        local ok, err = pcall(function()
            u:transferSync()
        end)
        if not ok then
            pcall(log.warn, 'failed to transfer undo archive for buffer', bufnr, err)
            if u.pendingTransfer then
                self.pendingTransfers[u.pendingTransfer.fallbackPath] = u.pendingTransfer
                u:dispose()
                self.undos[bufnr] = nil
            end
            return false, err
        end
        u:dispose()
        self.undos[bufnr] = nil
        log.debug('detached buffer:', bufnr)
    else
        log.trace('detach skipped; buffer is not attached:', bufnr, bufferName(bufnr))
    end
    return true
end

function Manager:attach(bufnr)
    if not self.undos[bufnr] then
        local u = undo:new(bufnr, self.archivesDir)
        if u:attach() then
            self.undos[bufnr] = u
            log.debug('attached buffer:', bufnr, bufferName(bufnr))
        else
            log.trace('attach skipped:', bufnr, bufferName(bufnr))
        end
    end
    return self.undos[bufnr]
end

function Manager:listFileStats(dir, bufferSize)
    return async(function()
        local tasks = {}
        await(fs.openDirStream(dir, bufferSize, function(entries)
            if not entries then
                return
            end
            for _, entry in ipairs(entries) do
                if entry.type == 'file' then
                    local name = entry.name
                    tasks[name] = fs.stat(path.join(dir, name))
                end
            end
        end))
        return promise.all(tasks)
    end)
end

function Manager:scanArchivesDir()
    return async(function()
        log.debug('scanning archives dir:', self.archivesDir)
        local statTbl = await(self:listFileStats(self.archivesDir, 1024))
        local records = {}
        for name, stat in pairs(statTbl) do
            if name:sub(-5) == '.base' then
                local key = name:sub(1, -6)
                local record = records[key] or {name = key}
                record.baseline = {name = name, mtime = stat.mtime.sec, size = stat.size}
                record.mtime = math.max(record.mtime or 0, stat.mtime.sec)
                records[key] = record
            else
                local record = records[name] or {name = name}
                record.fallback = {name = name, mtime = stat.mtime.sec, size = stat.size}
                record.mtime = math.max(record.mtime or 0, stat.mtime.sec)
                records[name] = record
            end
        end
        local stats = vim.tbl_values(records)
        table.sort(stats, function(a, b)
            return a.mtime > b.mtime
        end)
        local size = 0
        local limit = self.limitArchivesSize * 1024 * 1024
        local tasks = {}
        local removed = 0
        local function remove(stat)
            if stat then
                local p = path.join(self.archivesDir, stat.name)
                log.debug('archive will be pruned:', p, 'size:', stat.size)
                tasks[p] = fs.unlink(p)
                removed = removed + 1
            end
        end
        for _, record in ipairs(stats) do
            if record.fallback and size + record.fallback.size <= limit then
                size = size + record.fallback.size
                if record.baseline and size + record.baseline.size <= limit then
                    size = size + record.baseline.size
                else
                    remove(record.baseline)
                end
            else
                remove(record.fallback)
                remove(record.baseline)
            end
        end
        local results = await(promise.allSettled(tasks))
        local failed = 0
        for p, result in pairs(results) do
            if result.status == 'rejected' then
                failed = failed + 1
                pcall(log.warn, 'failed to prune archive:', p, result.reason)
            end
        end
        if removed > 0 then
            log.info('archive prune completed:', 'kept_size:', size, 'limit:', limit, 'removed:', removed, 'failed:', failed)
        else
            log.debug('archive prune completed without removals:', 'kept_size:', size, 'limit:', limit)
        end
    end)
end

function Manager:syncAll(block)
    return self.mutex:use(function()
        return async(function()
            local tasks = {}
            local considered = 0
            for bufnr, u in pairs(self.undos) do
                considered = considered + 1
                if u:shouldTransfer() then
                    tasks[bufnr] = u:transfer()
                end
            end
            for key, transfer in pairs(self.pendingTransfers) do
                local pendingKey = key
                tasks['pending:' .. pendingKey] = undo.completePendingTransfer(transfer):thenCall(function(value)
                    self.pendingTransfers[pendingKey] = nil
                    return value
                end)
            end
            log.debug('syncAll started:', 'block:', block == true, 'considered:', considered, 'transfers:', vim.tbl_count(tasks))
            if vim.tbl_isempty(tasks) then
                local now = uv.hrtime()
                if not block and now - self.lastScannedtime > 60 * 60 * 1e9 then
                    await(self:scanArchivesDir())
                    self.lastScannedtime = uv.hrtime()
                end
                log.debug('syncAll completed; no buffers need transfer')
                return
            end
            local res = false
            local p = promise.allSettled(tasks):thenCall(function(value)
                res = true
                return value
            end)
            local now = uv.hrtime()
            if block then
                vim.wait(1000, function()
                    return res
                end, 30, false)
                log.debug(('syncAll wait elapsed %dms'):format((uv.hrtime() - now) / 1e6))
            end
            local results = await(p)
            local failures = {}
            for bufnr, result in pairs(results) do
                if result.status == 'rejected' then
                    local msg = ('buffer %s: %s'):format(bufnr, tostring(result.reason))
                    table.insert(failures, msg)
                    pcall(log.warn, 'failed to transfer undo archive:', msg)
                end
            end
            if #failures > 0 then
                error(table.concat(failures, '; '))
            end
            -- 60 * 60 * 1e9 ns = 1 hour
            if not block and now - self.lastScannedtime > 60 * 60 * 1e9 then
                await(self:scanArchivesDir())
                self.lastScannedtime = uv.hrtime()
            end
            log.info('syncAll completed:', 'block:', block == true, 'transfers:', vim.tbl_count(tasks), 'failures:', #failures)
            res = true
        end)
    end)
end

function Manager:syncAllSync()
    local failures = {}
    for bufnr, u in pairs(self.undos) do
        local ok, err = pcall(function()
            if u:shouldTransfer() then
                u:transferSync()
            end
        end)
        if not ok then
            if u.pendingTransfer then
                self.pendingTransfers[u.pendingTransfer.fallbackPath] = u.pendingTransfer
            else
                table.insert(failures, ('buffer %s: %s'):format(bufnr, tostring(err)))
            end
        end
    end
    for key, transfer in pairs(self.pendingTransfers) do
        local ok, err = pcall(undo.completePendingTransferSync, transfer)
        if ok then
            self.pendingTransfers[key] = nil
        else
            table.insert(failures, ('pending %s: %s'):format(key, tostring(err)))
        end
    end
    if #failures > 0 then
        pcall(log.warn, 'synchronous undo transfer failures:', table.concat(failures, '; '))
        return false, table.concat(failures, '; ')
    end
    return true
end

function Manager:initialize()
    if self.initialized then
        log.debug('initialize skipped; manager already initialized')
        return self
    end
    self.archivesDir = path.normalize(config.archives_dir)
    self.limitArchivesSize = config.limit_archives_size
    fs.mkdirpSync(self.archivesDir, archiveDirMode)
    if not utils.isWindows() then
        fs.chmodSync(self.archivesDir, archiveDirMode)
    end
    self.undos = {}
    self.pendingTransfers = self.pendingTransfers or {}
    self.lastScannedtime = uv.hrtime()
    self.mutex = mutex:new()
    self.disposables = {}
    self.initialized = true
    log.info('manager initialized:', 'archives_dir:', self.archivesDir, 'limit_mb:', self.limitArchivesSize)
    table.insert(self.disposables, disposable:create(function()
        log.debug('disposing manager:', 'attached_buffers:', vim.tbl_count(self.undos))
        for _, b in pairs(self.undos) do
            b:dispose()
        end
        self.initialized = false
        self.undos = {}
        self.pendingTransfers = {}
        self.lastScannedtime = 0
    end))
    event:on('BufReadPost', function(bufnr)
        logBufferEvent('BufReadPost', bufnr)
        local u = self:attach(bufnr)
        if u then
            u:check()
        end
    end, self.disposables)
    event:on('FileChangedShellPost', function(bufnr)
        logBufferEvent('FileChangedShellPost', bufnr)
        local u = self.undos[bufnr]
        if u then
            u:check()
        end
    end, self.disposables)
    event:on('BufWritePost', function(bufnr)
        logBufferEvent('BufWritePost', bufnr)
        local u = self.undos[bufnr]
        if u then
            u:reset(true)
        end
    end, self.disposables)
    event:on('BufWipeout', function(bufnr)
        logBufferEvent('BufWipeout', bufnr)
        self:detach(bufnr)
    end, self.disposables)
    event:on('BufUnload', function(bufnr)
        logBufferEvent('BufUnload', bufnr)
        self:detach(bufnr)
    end, self.disposables)
    event:on('CmdlineEnter', function(char)
        log.debug('event CmdlineEnter:', char)
        if char ~= ':' then
            return
        end
        promise.resolve():thenCall(function()
            if utils.mode() == 'c' and fn.getcmdtype() == ':' then
                self:syncAll()
            end
        end)
    end, self.disposables)
    event:on('VimLeave', function()
        log.debug('event VimLeave')
        self:syncAllSync()
    end, self.disposables)
    event:on('VimSuspend', function()
        log.debug('event VimSuspend')
        self:syncAllSync()
    end, self.disposables)
    event:on('TermEnter', function()
        log.debug('event TermEnter')
        self:syncAll()
    end, self.disposables)
    event:on('FocusLost', function()
        log.debug('event FocusLost')
        self:syncAll()
    end, self.disposables)
    local loaded = 0
    local attached = 0
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(bufnr) then
            loaded = loaded + 1
            local u = self:attach(bufnr)
            if u then
                attached = attached + 1
                u:check()
            end
        end
    end
    log.info('loaded buffers scanned:', 'loaded:', loaded, 'attached:', attached)
    return self
end

---
---@param bufnr number
---@return FundoUndo
function Manager:get(bufnr)
    return self.undos[bufnr]
end

function Manager:dispose()
    disposable.disposeAll(self.disposables)
    self.disposables = {}
end

return Manager

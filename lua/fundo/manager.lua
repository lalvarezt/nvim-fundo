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
local manifest = require('fundo.manifest')
local storage = require('fundo.storage')
local journal = require('fundo.journal')

local archiveDirMode = 448 -- 0o700

local function onMain(callback)
    return promise(function(resolve, reject)
        local function run()
            local ok, result = pcall(callback)
            if ok then resolve(result) else reject(result) end
        end
        if vim.in_fast_event() then vim.schedule(run) else run() end
    end)
end

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

function Manager:removeSuperseded(transfers)
    for _, transfer in ipairs(transfers or {}) do
        if self.pendingTransfers[transfer.fallbackPath] == transfer then
            self.pendingTransfers[transfer.fallbackPath] = nil
        end
    end
end

function Manager:finishCapture(u)
    self:removeSuperseded(u.resolvedTransfers)
    u.resolvedTransfers = nil
    local key = u.resolvedCapture and u.resolvedCapture.fallbackPath or u.fallbackPath
    local failure = self.captureFailures and self.captureFailures[key]
    if failure and failure == u.resolvedCapture then
        self.captureFailures[key] = nil
    end
end

function Manager:keepPending(u)
    if u.pendingTransfer then
        -- A retargeted transfer owns its predecessors until it commits.
        self:removeSuperseded(u.pendingTransfer.supersededTransfers)
        self.pendingTransfers[u.pendingTransfer.fallbackPath] = u.pendingTransfer
    end
    if u.captureFailure then self.captureFailures[u.fallbackPath] = u.captureFailure end
end

function Manager:detach(bufnr)
    local u = self.undos[bufnr]
    if u then
        log.debug('detaching buffer:', bufnr, bufferName(bufnr))
        local ok, result = pcall(u.transferSync, u)
        if ok and result then
            self.pendingTransfers[u.fallbackPath] = nil
            self:finishCapture(u)
        else
            if u.pendingTransfer and u.pendingTransfer.undoContents then
                u.pendingTransfer.recoverOnOpen = true
            end
            self:keepPending(u)
        end
        u:dispose()
        self.undos[bufnr] = nil
        if not ok then
            pcall(log.warn, 'failed to transfer undo archive for buffer', bufnr, result)
            vim.notify('Fundo could not save ' .. u.name .. ': ' .. tostring(result)
                .. '; inspect :FundoDoctor for recovery copies', vim.log.levels.WARN)
            return false, result
        end
        log.debug('detached buffer:', bufnr)
    else
        log.trace('detach skipped; buffer is not attached:', bufnr, bufferName(bufnr))
    end
    return true
end

function Manager:trackingReason(bufnr, trigger)
    local name = path.normalize(api.nvim_buf_get_name(bufnr))
    if self.manualPaths and self.manualPaths[name] then return end
    if self.forgotten and self.forgotten[name] then return 'forgotten' end
    for prefix in pairs(self.forgottenProjects or {}) do
        local directory = prefix:sub(-1) == path.sep and prefix or prefix .. path.sep
        if name == prefix or name:sub(1, #directory) == directory then return 'forgotten' end
    end
    if self.undos and self.undos[bufnr] then return end
    if config.track_on == 'open' or trigger == 'manual' or (config.track_on == 'write' and trigger == 'write') then
        return
    end
    local undoPath = fn.undofile(name)
    if undoPath ~= '' then
        local fallback = undo.archivePath(name, undoPath, self.archivesDir)
        local pending = self.pendingTransfers and self.pendingTransfers[fallback]
            or self.captureFailures and self.captureFailures[fallback]
        if pending and path.normalize(pending.name) == name then return end
        if fs.statSync(fallback) or fs.statSync(fallback .. '.base')
            or fs.statSync(path.join(storage.directory(fallback), 'current')) then return end
    end
    return config.track_on == 'write' and 'awaiting-write' or 'awaiting-manual'
end

function Manager:forgetName(name)
    name = path.normalize(name)
    self.forgotten = self.forgotten or {}
    self.forgotten[name] = true
    journal.forget(self.archivesDir, name)
    for key, failure in pairs(self.captureFailures or {}) do
        if path.normalize(failure.name) == name then self.captureFailures[key] = nil end
    end
    if self.manualPaths then self.manualPaths[name] = nil end
    for bufnr, u in pairs(self.undos or {}) do
        if path.normalize(u.name) == name then
            u.pendingTransfer = nil
            u:dispose()
            self.undos[bufnr] = nil
        end
    end
    for key, transfer in pairs(self.pendingTransfers or {}) do
        if path.normalize(transfer.name) == name then self.pendingTransfers[key] = nil end
    end
end

function Manager:attach(bufnr, trigger)
    if not self.undos[bufnr] then
        local reason = self:trackingReason(bufnr, trigger)
        if reason then
            if trigger == 'read' and (reason == 'awaiting-manual' or reason == 'awaiting-write') then
                local probe = undo:new(bufnr, self.archivesDir)
                if probe:attach() then probe:discardForeignNative() end
            end
            return
        end
        local u = undo:new(bufnr, self.archivesDir)
        if u:attach() then
            local pending = self.pendingTransfers[u.fallbackPath]
            if pending and u.generation and pending.expectedGeneration ~= u.generation then
                -- A newer session owns the pointer. Keep the stale draft for :FundoRecover.
                local saved, err = pcall(journal.write, pending)
                if not saved then
                    pcall(log.warn, 'could not preserve conflicting draft:', pending.name, err)
                    return
                end
                self.pendingTransfers[u.fallbackPath] = nil
                pending = nil
            end
            if pending and path.normalize(pending.name) == path.normalize(u.name) then
                -- The buffer may have changed while Fundo was disabled. Capture
                -- its current history before retrying the older detached copy.
                u:reset(true)
                if not vim.bo[bufnr].modified and (u:isEmpty() or pending.recoverOnOpen or pending.fromJournal) then
                    u.pendingRecovery = pending
                u.pendingNativeSequence = utils.bufCall(bufnr, fn.undotree).seq_last
                end
            end
            self.undos[bufnr] = u
            require('fundo.checkpoint').watch(u, function(ok)
                if ok then
                    self:finishCapture(u)
                    self.pendingTransfers[u.fallbackPath] = nil
                else
                    self:keepPending(u)
                end
            end)
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
                    local filename = path.join(dir, name)
                    if dir ~= self.archivesDir or fs.isNativeUndoFile(filename) == false then
                        tasks[name] = fs.stat(filename)
                    end
                end
            end
        end))
        return promise.all(tasks)
    end)
end

function Manager:scanArchivesDir()
    return async(function()
        log.debug('scanning archives dir:', self.archivesDir)
        await(onMain(function() config.checkArchiveDir(self.archivesDir) end))
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
        local metadataDir = manifest.dir(self.archivesDir)
        if fs.statSync(metadataDir) then
            local metadataStats = await(self:listFileStats(metadataDir, 1024))
            for name, stat in pairs(metadataStats) do
                if name:sub(-5) == '.json' then
                    local key = name:sub(1, -6)
                    local record = records[key] or {name = key}
                    record.manifest = {
                        path = path.join(metadataDir, name),
                        mtime = stat.mtime.sec,
                        size = stat.size,
                    }
                    record.mtime = math.max(record.mtime or 0, stat.mtime.sec)
                    records[key] = record
                end
            end
        end
        local generations = await(onMain(function() return storage.records(self.archivesDir) end))
        for _, generation in ipairs(generations) do
            local key = generation.fallbackPath and path.basename(generation.fallbackPath)
                or '@generation-' .. path.basename(generation.directory)
            local record = records[key] or {name = key, mtime = generation.mtime}
            record.generation = generation
            record.mtime = math.max(record.mtime or 0, generation.mtime)
            records[key] = record
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
                local p = stat.path or path.join(self.archivesDir, stat.name)
                log.debug('archive will be pruned:', p, 'size:', stat.size)
                tasks[p] = onMain(function()
                    config.checkArchiveDir(self.archivesDir)
                    if fs.unlinkArchiveSync(p) then removed = removed + 1 end
                end)
            end
        end
        local cutoff = self.retentionDays and os.time() - self.retentionDays * 24 * 60 * 60 or nil
        if self.prunePolicy ~= 'delete' then
            local expired = 0
            for _, record in ipairs(stats) do
                for _, artifact in ipairs({record.fallback or false, record.baseline or false,
                    record.manifest or false, record.generation or false}) do
                    if artifact then size = size + artifact.size end
                end
                if cutoff and record.mtime < cutoff then expired = expired + 1 end
            end
            self.pruningStatus = {policy = 'preserve', bytes = size, limit = limit, expired = expired}
            if size > limit or expired > 0 then
                vim.schedule(function()
                    vim.notify(('Fundo preserved recovery archives: %d bytes, limit %d, %d expired records. '
                        .. 'Inspect :FundoDoctor; prune_policy=preserve keeps saved work.'):format(size, limit, expired),
                        vim.log.levels.WARN)
                end)
            end
            log.debug('archive scan preserved records:', 'bytes:', size, 'limit:', limit, 'expired:', expired)
            return
        end
        for _, record in ipairs(stats) do
            local essentialSize = record.fallback and record.fallback.size or 0
            essentialSize = essentialSize + (record.manifest and record.manifest.size or 0)
            essentialSize = essentialSize + (record.generation and record.generation.size or 0)
            if not record.fallback then
                essentialSize = essentialSize + (record.baseline and record.baseline.size or 0)
            end
            local expired = cutoff and record.mtime < cutoff
            if not expired and size + essentialSize <= limit then
                size = size + essentialSize
                if record.fallback then
                    if record.baseline and size + record.baseline.size <= limit then
                        size = size + record.baseline.size
                    else
                        remove(record.baseline)
                    end
                end
            else
                if record.generation and record.generation.error then
                    local dir = record.generation.directory
                    tasks[dir] = onMain(function()
                        if not storage.removeInvalid(dir) then
                            vim.notify('Fundo preserved damaged generations for inspection: ' .. dir,
                                vim.log.levels.WARN)
                        end
                    end)
                elseif record.generation then
                    local fallbackPath = record.generation.fallbackPath
                    tasks[fallbackPath] = onMain(function()
                        storage.withLock(fallbackPath, function()
                            if storage.token(fallbackPath) ~= record.generation.token then return end
                            for _, artifact in ipairs({record.fallback or false, record.baseline or false, record.manifest or false}) do
                                if artifact then
                                    local target = artifact.path or path.join(self.archivesDir, artifact.name)
                                    fs.unlinkArchiveSync(target)
                                end
                            end
                            storage.remove(fallbackPath)
                            for _, u in pairs(self.undos) do
                                if u.fallbackPath == fallbackPath and u.generation == record.generation.token then
                                    u.generation = false
                                    if u.pendingTransfer and u.pendingTransfer.expectedGeneration == record.generation.token then
                                        u.pendingTransfer.expectedGeneration = false
                                    end
                                end
                            end
                            local pending = self.pendingTransfers[fallbackPath]
                            if pending and pending.expectedGeneration == record.generation.token then
                                pending.expectedGeneration = false
                            end
                        end)
                    end)
                else
                    remove(record.fallback)
                    remove(record.baseline)
                    remove(record.manifest)
                end
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

local function replay(transfer, recovering)
    local bufnr = utils.bufnrForPath(transfer.name)
    local loaded = bufnr >= 0 and api.nvim_buf_is_loaded(bufnr)
    local destination = fn.undofile(transfer.name)
    if destination == '' or destination ~= transfer.undoPath
        or (loaded and not undo:new(bufnr):canPersist())
        or (not loaded and (not vim.go.undofile or vim.go.undolevels < 0)) then
        -- A previously captured snapshot may only exist in memory after a journal outage.
        local saved, err = pcall(journal.write, transfer)
        if not saved then
            transfer.lastError = {stage = 'journal', message = tostring(err), time = os.time()}
            error(err, 0)
        end
        return false
    end
    assert(not recovering, 'pending snapshot still requires recovery into its buffer')
    undo.completePendingTransferSync(transfer)
    return true
end

function Manager:syncAll(block)
    return self.mutex:use(function()
        return async(function()
            local tasks = {}
            local activePaths = {}
            local considered = 0
            for bufnr, u in pairs(self.undos) do
                considered = considered + 1
                if u:shouldTransfer() then
                    local fallbackPath = u.fallbackPath
                    local pending = self.pendingTransfers[fallbackPath]
                    activePaths[fallbackPath] = true
                    tasks[bufnr] = u:transfer():thenCall(function(saved)
                        if saved then
                            self:finishCapture(u)
                            if self.pendingTransfers[fallbackPath] == pending then
                                self.pendingTransfers[fallbackPath] = nil
                            end
                        end
                end, function(err)
                    if self.undos[bufnr] == u then self:keepPending(u) end
                    error(err, 0)
                    end)
                    -- A changed undodir can move the active capture to a new
                    -- archive key. Its old retry still belongs to this task.
                    activePaths[u.fallbackPath] = true
                end
            end
            for key, transfer in pairs(self.pendingTransfers) do
                local pendingKey = key
                if not activePaths[key] then
                    tasks['pending:' .. pendingKey] = onMain(function()
                        if self.pendingTransfers[pendingKey] ~= transfer then return end
                        if replay(transfer) and self.pendingTransfers[pendingKey] == transfer then
                            self.pendingTransfers[pendingKey] = nil
                        end
                    end)
                end
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
            if u:transferSync() then
                self.pendingTransfers[u.fallbackPath] = nil
                self:finishCapture(u)
            end
        end)
        if not ok then
            self:keepPending(u)
            if not u.pendingTransfer or u.lastError then
                table.insert(failures, ('buffer %s: %s'):format(bufnr, tostring(err)))
            end
        end
    end
    for key, transfer in pairs(self.pendingTransfers) do
        local recovering = false
        for _, u in pairs(self.undos) do
            if u.pendingRecovery == transfer then recovering = true end
        end
        local ok, err = pcall(replay, transfer, recovering)
        if ok and not err then goto continue end
        if ok then
            self.pendingTransfers[key] = nil
            for _, u in pairs(self.undos) do
                u:finishTransfer(transfer)
            end
        else
            table.insert(failures, ('pending %s: %s'):format(key, tostring(err)))
        end
        ::continue::
    end
    if #failures > 0 then
        pcall(log.warn, 'synchronous undo transfer failures:', table.concat(failures, '; '))
        vim.notify('Fundo save failed: ' .. table.concat(failures, '; ')
            .. '; inspect :FundoDoctor for recovery copies', vim.log.levels.WARN)
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
    config.checkArchiveDir(self.archivesDir)
    self.limitArchivesSize = config.limit_archives_size
    self.retentionDays = config.retention_days
    self.prunePolicy = config.prune_policy
    self.pruningStatus = nil
    fs.mkdirpSync(self.archivesDir, archiveDirMode)
    if not utils.isWindows() then
        fs.chmodSync(self.archivesDir, archiveDirMode)
    end
    storage.clean(self.archivesDir)
    self.undos = {}
    self.forgotten = self.forgotten or {}
    self.forgottenProjects = self.forgottenProjects or {}
    self.manualPaths = self.manualPaths or {}
    self.pendingTransfers = self.pendingTransfers or {}
    self.captureFailures = self.captureFailures or {}
    local records, errors = journal.list(self.archivesDir)
    self.journalErrors = errors
    for _, record in ipairs(records) do
        local ok, token = pcall(storage.token, record.fallbackPath)
        if record.textOnly then
            self.captureFailures[record.fallbackPath] = self.captureFailures[record.fallbackPath] or record
        elseif ok and token == record.expectedGeneration and not self.pendingTransfers[record.fallbackPath] then
            self.pendingTransfers[record.fallbackPath] = record
        end
    end
    self.lastScannedtime = uv.hrtime()
    self.mutex = mutex:new()
    self.disposables = {}
    self.initialized = true
    log.info('manager initialized:', 'archives_dir:', self.archivesDir, 'limit_mb:', self.limitArchivesSize,
        'retention_days:', self.retentionDays or 'none')
    local reads = {}
    table.insert(self.disposables, disposable:create(function()
        log.debug('disposing manager:', 'attached_buffers:', vim.tbl_count(self.undos))
        for _, b in pairs(self.undos) do
            self:keepPending(b)
            b:dispose()
        end
        self.initialized = false
        self.undos = {}
        self.lastScannedtime = 0
        reads = {}
    end))
    local function afterRead(bufnr, edited)
        reads[bufnr] = nil
        local u = self:attach(bufnr)
        if u then
            u:check()
            if edited and not u.pendingRecovery and not vim.bo[bufnr].modified and not u:isEmpty() then
                -- Reloads can retain native undo. Persist the matching text.
                u:reset(true)
            end
        end
    end
    event:on('BufReadPost', function(bufnr)
        logBufferEvent('BufReadPost', bufnr)
        local read = {winid = api.nvim_get_current_win()}
        reads[bufnr] = read
        local u = self:attach(bufnr, 'read')
        if u then u:discardForeignNative() end
        -- A failed native undo read can abort before Neovim applies modelines.
        vim.schedule(function()
            if not self.initialized or not api.nvim_buf_is_loaded(bufnr) or reads[bufnr] ~= read then return end
            if vim.bo[bufnr].modeline and vim.o.modelines > 0 then
                local ran = false
                local id = api.nvim_create_autocmd('User', {
                    group = 'Fundo', pattern = 'FundoApplyModelines', once = true,
                    callback = function() ran = true end,
                })
                local ok = pcall(utils.bufCall, bufnr, function()
                    api.nvim_exec_autocmds('User', {
                        group = 'Fundo', pattern = 'FundoApplyModelines', modeline = true,
                    })
                end)
                if not ran then pcall(api.nvim_del_autocmd, id) end
                if reads[bufnr] ~= read then return end
                if not ok or not ran then
                    reads[bufnr] = nil
                    return
                end
            end
            afterRead(bufnr, true)
        end)
    end, self.disposables)
    event:on('BufNewFile', function(bufnr)
        reads[bufnr] = 'new'
    end, self.disposables)
    event:on('BufLeave', function(bufnr)
        local read = reads[bufnr]
        if type(read) == 'table' then read.defer = true end
    end, self.disposables)
    event:on('BufWinEnter', function(bufnr)
        -- Display in a different window can follow an aborted hidden read.
        local read = reads[bufnr]
        if read == 'new' or (read and not read.defer and read.winid == api.nvim_get_current_win()) then
            afterRead(bufnr, read ~= 'new')
        end
    end, self.disposables)
    event:on('FileChangedShellPost', function(bufnr)
        logBufferEvent('FileChangedShellPost', bufnr)
        afterRead(bufnr, true)
    end, self.disposables)
    event:on('BufFilePost', function(bufnr)
        local u = self.undos[bufnr]
        if u then
            self:detach(bufnr)
        end
        u = self:attach(bufnr)
        if u then u:reset(true) end
    end, self.disposables)
    event:on('BufWritePost', function(bufnr)
        logBufferEvent('BufWritePost', bufnr)
        local u = self:attach(bufnr, 'write')
        if u then
            u:reset(true)
            -- Neovim can discard the live tree on the very next reload.
            if vim.o.undoreload >= 0 and api.nvim_buf_line_count(bufnr) >= vim.o.undoreload then
                local ok, saved = pcall(u.transferSync, u)
                if ok and saved then
                    self:finishCapture(u)
                    self.pendingTransfers[u.fallbackPath] = nil
                elseif not ok then
                    self:keepPending(u)
                    vim.notify('Fundo could not archive the write: ' .. tostring(saved), vim.log.levels.WARN)
                end
            end
        end
    end, self.disposables)
    event:on('BufWipeout', function(bufnr)
        logBufferEvent('BufWipeout', bufnr)
        reads[bufnr] = nil
        self:detach(bufnr)
    end, self.disposables)
    event:on('BufUnload', function(bufnr)
        logBufferEvent('BufUnload', bufnr)
        reads[bufnr] = nil
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
            local u = self:attach(bufnr, 'read')
            if u then
                attached = attached + 1
                u:discardForeignNative()
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

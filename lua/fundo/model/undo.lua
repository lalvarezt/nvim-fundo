local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local promise = require('promise')
local path = require('fundo.fs.path')
local fs = require('fundo.fs')
local utils = require('fundo.utils')
local log = require('fundo.lib.log')
local config = require('fundo.config')
local manifest = require('fundo.manifest')
local storage = require('fundo.storage')
local journal = require('fundo.journal')

local archiveDirMode = 448 -- 0o700

local function transferError(stage, err)
    return {stage = stage, message = tostring(err), time = os.time()}
end

local function undoDisabled(bufnr)
    local levels = vim.bo[bufnr].undolevels
    if levels == -123456 then
        levels = vim.go.undolevels
    end
    return not vim.bo[bufnr].undofile or levels < 0
end

local function readSnapshot(filename)
    local lines = fn.readfile(filename, 'b')
    if lines[#lines] ~= '' then
        error('incomplete buffer snapshot: ' .. filename)
    end
    table.remove(lines)
    for i, line in ipairs(lines) do
        lines[i] = line:gsub('\n', '\0')
    end
    return lines
end

local function bufferContents(bufnr)
    return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n'
end

local function readLegacySnapshot(filename)
    local bufnr = api.nvim_create_buf(false, true)
    local ok, lines = pcall(utils.bufCall, bufnr, function()
        vim.bo[bufnr].undofile = false
        cmd('silent noautocmd keepalt 0read ' .. fn.fnameescape(filename))
        local result = api.nvim_buf_get_lines(bufnr, 0, -2, false)
        return #result == 0 and {''} or result
    end)
    api.nvim_buf_delete(bufnr, {force = true})
    if not ok then error(lines) end
    return lines
end

---@class FundoUndo
---@field dir string
---@field bufnr number
---@field attached boolean
local Undo = {}

local function logTransferDecision(self, result, reason)
    log.trace('shouldTransfer:', result, reason, 'bufnr:', self.bufnr, 'file:', self.name or '')
    return result
end

local function isLogFile(name)
    return config.logging and config.logging.path
        and name ~= ''
        and path.normalize(name) == path.normalize(config.logging.path)
end

function Undo.archivePath(name, undoPath, dir)
    local key = path.basename(undoPath)
    -- Adjacent undo files do not encode their parent directory. The .base
    -- suffix is reserved for baselines and must never name a fallback.
    if key:sub(-5) == '.base' or key == '.' .. path.basename(name) .. '.un~' then
        key = '@' .. fn.sha256(path.normalize(name))
    end
    return path.join(dir, key)
end

function Undo:new(bufnr, dir)
    local o = setmetatable({}, self)
    self.__index = self
    o.bufnr = bufnr
    o.dir = dir
    return o
end

function Undo:attach()
    if not api.nvim_buf_is_loaded(self.bufnr) then
        return false
    end
    local bt = vim.bo[self.bufnr].bt
    local name = api.nvim_buf_get_name(self.bufnr)
    if name == '' then
        return false
    end
    if path.dirname(name) == self.dir or manifest.isPath(name, self.dir)
        or name:sub(1, #storage.root(self.dir) + 1) == storage.root(self.dir) .. path.sep then
        log.debug('attach disabled undofile for archive buffer:', self.bufnr, name)
        vim.bo[self.bufnr].undofile = false
    end
    if isLogFile(name) then
        self.attached = false
        log.trace('undo attach skipped; Fundo log file:', self.bufnr, name)
        return self.attached
    end
    local filterOk, selected = pcall(config.filter, name, self.bufnr)
    if not filterOk then
        self.attached = false
        self.filterError = tostring(selected)
        pcall(log.warn, 'undo attach filter failed:', self.bufnr, name, selected)
        return self.attached
    end
    self.selected = selected == true
    if not self.selected then
        self.attached = false
        log.trace('undo attach skipped; rejected by filter:', self.bufnr, name)
        return self.attached
    end
    self.attached = (bt == '' or bt == 'acwrite') and vim.bo[self.bufnr].undofile
    if self.attached then
        self:reset()
        log.debug('undo attached:', self.bufnr, name)
    elseif bt ~= '' and bt ~= 'acwrite' then
        log.trace('undo attach skipped; unsupported buftype:', self.bufnr, name, bt)
    elseif not vim.bo[self.bufnr].undofile then
        log.trace('undo attach skipped; undofile disabled:', self.bufnr, name)
    end
    return self.attached
end

function Undo:dispose()
    log.debug('undo disposed:', self.bufnr, self.name or '')
    self.attached = false
end

---
---@param dirty? boolean
---@param bufName? string
function Undo:reset(dirty, bufName)
    if not self.attached then
        log.trace('reset skipped; undo is not attached:', self.bufnr)
        return
    end
    local name = bufName or api.nvim_buf_get_name(self.bufnr)
    if name ~= self.name then
        self.lastError = nil
        self.lastCapturedTick = nil
        self.checkedNative = false
        self.undoPath = fn.undofile(name)
        self.fallbackPath = Undo.archivePath(name, self.undoPath, self.dir)
        self.baselinePath = self.fallbackPath .. '.base'
        local ok, token = pcall(storage.token, self.fallbackPath)
        self.generation = ok and token or false
        local legacyPath = path.join(self.dir, path.basename(self.undoPath))
        if legacyPath ~= self.fallbackPath and not fs.statSync(self.fallbackPath)
            and not fs.statSync(self.baselinePath) then
            local record = manifest.read(manifest.path(legacyPath), legacyPath)
            if record and path.normalize(record.source.path) == path.normalize(name) then
                local ok, err = pcall(function()
                    if fs.statSync(legacyPath) then fs.copyFileSync(legacyPath, self.fallbackPath) end
                    if fs.statSync(legacyPath .. '.base') then
                        fs.copyFileSync(legacyPath .. '.base', self.baselinePath)
                    end
                    manifest.write({
                        name = name, undoPath = self.undoPath,
                        fallbackPath = self.fallbackPath, baselinePath = self.baselinePath,
                        snapshot_format = record.snapshot_format, baseline_format = record.baseline_format,
                    })
                end)
                if not ok then pcall(log.warn, 'failed to migrate archive:', legacyPath, err) end
            end
        end
        log.debug('undo paths reset:', 'bufnr:', self.bufnr, 'file:', name, 'undo:', self.undoPath,
            'fallback:', self.fallbackPath, 'baseline:', self.baselinePath)
    end
    self.name = name
    local wasDirty = self.isDirty
    self.isDirty = dirty and self.undoPath ~= '' and vim.bo[self.bufnr].undolevels ~= 0
    if self.isDirty or wasDirty ~= self.isDirty then
        log.debug('undo dirty state:', self.bufnr, self.name, self.isDirty == true)
    end
end

function Undo:isEmpty()
    local res = utils.bufCall(self.bufnr, function()
        return api.nvim_exec('undolist', true)
    end)
    return not res:match('^number')
end

function Undo:loadUndo(filename)
    local ok, err = utils.bufCall(self.bufnr, function()
        return pcall(cmd, 'sil rundo ' .. fn.fnameescape(filename or self.undoPath))
    end)
    if ok then
        log.debug('loaded undo file:', self.undoPath)
    else
        log.debug('failed to load undo file:', self.undoPath, err)
    end
    return ok, err
end

function Undo:saveUndo(target)
    if self.undoPath == '' then
        log.debug('saveUndo skipped; empty undo path:', self.bufnr, self.name or '')
        return false
    end
    local ok, cmdOk, cmdErr = pcall(utils.bufCall, self.bufnr, function()
        return pcall(cmd, 'sil wundo! ' .. fn.fnameescape(target or self.undoPath))
    end)
    if not ok then
        log.debug('saveUndo failed:', self.undoPath, cmdOk)
        return false, cmdOk
    end
    if cmdOk then
        log.debug('saved undo file:', self.undoPath)
    else
        log.debug('saveUndo failed:', self.undoPath, cmdErr)
    end
    return cmdOk, cmdErr
end

function Undo:baselineLimitBytes()
    return config.baseline_max_file_size * 1024 * 1024
end

function Undo:bufferSize()
    -- Includes the normalized final newline, even for 'noendofline' buffers.
    return api.nvim_buf_get_offset(self.bufnr, api.nvim_buf_line_count(self.bufnr))
end

function Undo:baselineEligibility()
    if not api.nvim_buf_is_loaded(self.bufnr) then return 'unloaded' end
    local options = vim.bo[self.bufnr]
    if api.nvim_buf_get_name(self.bufnr) == '' then return 'unnamed' end
    if options.buftype ~= '' and options.buftype ~= 'acwrite' then return 'unsupported-buffer' end
    if undoDisabled(self.bufnr) then return 'undo-disabled' end
    if not options.modifiable then return 'not-modifiable' end
    if options.modified then return 'modified' end
    local size = self:bufferSize()
    if self:baselineLimitBytes() <= 0 then return 'baseline-disabled', size end
    if size > self:baselineLimitBytes() then return 'oversized', size end
    return 'eligible', size
end

function Undo:canSaveBaseline(stat)
    local limit = self:baselineLimitBytes()
    if limit <= 0 or not stat then
        log.trace('baseline save skipped; missing stat or non-positive limit:', self.baselinePath, limit)
        return false
    end
    if stat.type and stat.type ~= 'file' then
        log.trace('baseline save skipped; source is not a file:', self.name, stat.type)
        return false
    end
    if type(stat.size) ~= 'number' or stat.size > limit then
        log.debug('baseline save skipped; source exceeds limit:', self.name, 'size:', stat.size, 'limit:', limit)
        return false
    end
    return true
end

function Undo:deleteBaseline()
    local removed, err, code = fs.unlinkSync(self.baselinePath)
    if not removed and code ~= 'ENOENT' then
        error(err)
    end
    log.debug('deleted baseline archive:', self.baselinePath)
end

function Undo:saveBaseline(snapshot)
    if not self.baselinePath or not self.name then
        log.debug('saveBaseline skipped; missing paths:', self.bufnr, self.name or '', self.baselinePath or '')
        return false
    end
    if not snapshot and self.pendingTransfer and self.pendingTransfer.baselineOnly then
        self.pendingTransfer = nil
    end
    local size = snapshot and #snapshot.contents or self:bufferSize()
    local selected = self:canSaveBaseline({type = 'file', size = size})
    local contents = selected and (snapshot and snapshot.contents or bufferContents(self.bufnr)) or nil
    local transfer = {
        baselineOnly = true, name = self.name, undoPath = self.undoPath,
        fallbackPath = self.fallbackPath, baselinePath = self.baselinePath, contents = contents,
        capturedAt = snapshot and snapshot.capturedAt or os.time(),
        expectedGeneration = snapshot and snapshot.expectedGeneration or self.generation,
    }
    local stage = 'baseline'
    local ok, err = pcall(function()
        local record = manifest.read(manifest.path(self.fallbackPath), self.fallbackPath)
        local previous = selected and record and record.baseline_format == 'buffer-lines-v1' and self:readBaseline()
        if previous and table.concat(previous, '\n') .. '\n' == contents
            and transfer.expectedGeneration
            and storage.token(self.fallbackPath) == transfer.expectedGeneration
            and not self.lastError and not (snapshot and snapshot.lastError) then
            if snapshot then snapshot.generation = self.generation end
            return
        end
        local function persist()
            if not selected then
                self:deleteBaseline()
                stage = 'manifest'
                if not fs.statSync(self.fallbackPath) then
                    manifest.remove(self.fallbackPath)
                    return
                end
            else
                fs.mkdirpSync(path.dirname(self.baselinePath), archiveDirMode)
                fs.writeFileSync(self.baselinePath, contents)
            end
            stage = 'manifest'
            manifest.write({
                name = self.name, undoPath = self.undoPath, fallbackPath = self.fallbackPath,
                baselinePath = self.baselinePath, snapshot_format = record and record.snapshot_format,
                baseline_format = selected and 'buffer-lines-v1' or nil, capturedAt = transfer.capturedAt,
            })
            stage = 'generation'
        end
        if selected or storage.token(self.fallbackPath) then
            self.generation = storage.publish(transfer, persist)
        else
            persist()
        end
        if snapshot then snapshot.generation = self.generation end
    end)
    if not ok then
        -- Publication can fail after the pointer becomes visible. Keep its
        -- revision for a retry, but require synchronization before success.
        if transfer.expectedGeneration ~= (snapshot and snapshot.expectedGeneration or self.generation) then
            self.generation = transfer.expectedGeneration
            if snapshot then snapshot.expectedGeneration = transfer.expectedGeneration end
        end
        self.lastError = transferError(stage, err)
        pcall(log.warn, 'failed to save baseline archive:', self.baselinePath, err)
        return false, err
    end
    self.lastError = nil
    if self.bufnr and api.nvim_buf_is_loaded(self.bufnr) then
        self.lastCapturedTick = snapshot and snapshot.changedtick or api.nvim_buf_get_changedtick(self.bufnr)
    end
    if selected then log.debug('saved baseline archive:', self.baselinePath) end
    return selected
end

function Undo:queueBaseline()
    if not self:canSaveBaseline({type = 'file', size = self:bufferSize()}) then
        self:saveBaseline()
        return
    end
    local snapshot = {
        baselineOnly = true,
        name = self.name,
        undoPath = self.undoPath,
        fallbackPath = self.fallbackPath,
        baselinePath = self.baselinePath,
        contents = bufferContents(self.bufnr),
        capturedAt = os.time(),
        expectedGeneration = self.generation,
        changedtick = api.nvim_buf_get_changedtick(self.bufnr),
    }
    self.pendingTransfer = snapshot
    vim.schedule(function()
        if not self.attached or self.pendingTransfer ~= snapshot then return end
        local dirty = self.isDirty
        local ok, err = pcall(Undo.completePendingTransferSync, snapshot)
        if ok then
            self:finishTransfer(snapshot)
            self.isDirty = dirty
        else
            pcall(log.warn, 'deferred baseline save failed:', self.name, err)
        end
    end)
end

local function saveBaselineSnapshot(transfer)
    local limit = config.baseline_max_file_size * 1024 * 1024
    if limit <= 0 or #transfer.contents > limit then
        Undo.deleteBaseline(transfer)
        return false
    end
    fs.mkdirpSync(path.dirname(transfer.baselinePath), archiveDirMode)
    fs.writeFileSync(transfer.baselinePath, transfer.contents)
    return true
end

function Undo.completePendingTransferSync(transfer)
    if transfer.baselineOnly then
        local writer = setmetatable(transfer, {__index = Undo})
        local _, err = writer:saveBaseline(transfer)
        if err then
            pcall(journal.write, transfer)
            error(err, 0)
        end
        journal.finish(transfer)
        return
    end
    local stage = 'journal'
    local ok, err = pcall(function()
        journal.write(transfer)
        stage = 'fallback'
        local limit = config.baseline_max_file_size * 1024 * 1024
        transfer.baselineContents = limit > 0 and #transfer.contents <= limit and transfer.contents or nil
        storage.publish(transfer, function()
            if transfer.rejectExistingUndo then
                assert(not fs.statSync(transfer.undoPath), 'destination native undo appeared during association')
            end
            fs.mkdirpSync(path.dirname(transfer.fallbackPath), archiveDirMode)
            fs.writeFileSync(transfer.fallbackPath, transfer.contents)
            stage = 'undo'
            fs.writeFileSync(transfer.undoPath, transfer.undoContents)
            stage = 'baseline'
            saveBaselineSnapshot(transfer)
            stage = 'manifest'
            manifest.write(transfer)
            stage = 'generation'
        end)
    end)
    if not ok then
        transfer.lastError = transferError(stage, err)
        pcall(journal.refresh, transfer)
        error(err, 0)
    end
    transfer.expectedGeneration = transfer.generation
    journal.refresh(transfer)
    journal.finish(transfer)
    transfer.lastError = nil
end

function Undo.completePendingTransfer(transfer)
    return promise(function(resolve, reject)
        local function run()
            local ok, err = pcall(Undo.completePendingTransferSync, transfer)
            if ok then resolve() else reject(err) end
        end
        if vim.in_fast_event and vim.in_fast_event() then
            vim.schedule(run)
        else
            run()
        end
    end)
end

function Undo:transferSnapshot()
    local bufferText = bufferContents(self.bufnr)
    local temporary = fn.tempname()
    local ok, err = self:saveUndo(temporary)
    if not ok then
        pcall(fs.unlinkSync, temporary)
        error(err or ('failed to save undo file: ' .. self.undoPath))
    end
    local fd, openErr = fs.openSync(temporary, 'r', 0)
    if not fd then
        pcall(fs.unlinkSync, temporary)
        error(openErr)
    end
    local readOk, contents = pcall(function()
        local stat, statErr = fs.fstatSync(fd)
        if not stat then
            error(statErr)
        end
        local data, readErr = fs.readSync(fd, stat.size, 0)
        if not data or #data ~= stat.size then
            error(readErr or 'incomplete undo snapshot')
        end
        return data
    end)
    local closed, closeErr = fs.closeSync(fd)
    fs.unlinkSync(temporary)
    if not readOk then
        error(contents)
    end
    if not closed then
        error(closeErr)
    end
    return {
        name = self.name,
        undoPath = self.undoPath,
        fallbackPath = self.fallbackPath,
        baselinePath = self.baselinePath,
        contents = bufferText,
        undoContents = contents,
        snapshot_format = 'buffer-lines-v1',
        baseline_format = 'buffer-lines-v1',
        capturedAt = os.time(),
        expectedGeneration = self.pendingTransfer and self.pendingTransfer.expectedGeneration or self.generation,
        changedtick = api.nvim_buf_get_changedtick(self.bufnr),
    }
end

function Undo:readBaseline()
    if not self.baselinePath or not fs.statSync(self.baselinePath) then
        log.trace('readBaseline skipped; baseline missing:', self.baselinePath or '')
        return
    end
    local record, recordErr = manifest.read(manifest.path(self.fallbackPath), self.fallbackPath)
    if recordErr and recordErr ~= 'missing' then
        pcall(log.warn, 'invalid baseline metadata:', self.baselinePath, recordErr)
        return
    end
    local normalized = record and (record.baseline_format or record.snapshot_format) == 'buffer-lines-v1'
    local ok, lines
    if normalized then
        ok, lines = pcall(readSnapshot, self.baselinePath)
    else
        ok, lines = pcall(readLegacySnapshot, self.baselinePath)
    end
    if not ok then
        pcall(log.warn, 'failed to read baseline archive:', self.baselinePath, lines)
        return
    end
    log.debug('read baseline archive:', self.baselinePath, 'lines:', #lines)
    return lines
end

function Undo:readFallbackLines()
    local record, err = manifest.read(manifest.path(self.fallbackPath), self.fallbackPath)
    if err and err ~= 'missing' then error(err) end
    if record and record.snapshot_format == 'buffer-lines-v1' then return readSnapshot(self.fallbackPath) end
    return readLegacySnapshot(self.fallbackPath)
end

function Undo:linesEqual(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

function Undo:recordRecovery(before, after, kind)
    if self:linesEqual(before, after) then return end
    local recovery = {before = before, after = after, kind = kind, time = os.time(),
        name = self.name, bufnr = self.bufnr}
    self.recovery = recovery
    vim.schedule(function()
        if not api.nvim_buf_is_valid(self.bufnr) then return end
        local ok, err = pcall(api.nvim_exec_autocmds, 'User', {
            pattern = 'FundoRecovered', modeline = false, data = vim.deepcopy(recovery),
        })
        if not ok then pcall(log.warn, 'FundoRecovered handler failed:', err) end
    end)
end

function Undo:loadBaseline(transfer)
    local baselineLines
    if transfer then
        baselineLines = vim.split(transfer.contents, '\n', {plain = true})
        table.remove(baselineLines)
    else
        baselineLines = self:readBaseline()
    end
    if not baselineLines then
        log.trace('loadBaseline skipped; no baseline:', self.baselinePath or '')
        return false
    end
    local currentLines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
    if self:linesEqual(baselineLines, currentLines) then
        log.trace('loadBaseline skipped; baseline equals current buffer:', self.baselinePath)
        return false
    end

    local preferredWinid = utils.getWinByBuf(self.bufnr)
    local view
    if utils.isWinValid(preferredWinid) then
        view = utils.saveView(preferredWinid)
    end

    local modified = vim.bo[self.bufnr].modified
    local ei = vim.o.eventignore
    vim.o.eventignore = 'all'
    local ok, err = pcall(function()
        utils.bufCall(self.bufnr, function()
            local undolevels = vim.bo[self.bufnr].undolevels
            vim.bo[self.bufnr].undolevels = -1
            local baselineOk, baselineErr =
                pcall(api.nvim_buf_set_lines, self.bufnr, 0, -1, false, baselineLines)
            vim.bo[self.bufnr].undolevels = undolevels
            if not baselineOk then
                error(baselineErr)
            end
            api.nvim_buf_set_lines(self.bufnr, 0, -1, false, currentLines)
        end)
        vim.bo[self.bufnr].modified = modified
        if view and utils.isWinValid(preferredWinid) then
            utils.restView(preferredWinid, view)
        end
    end)
    vim.o.eventignore = ei
    if not ok then
        pcall(log.warn, 'failed to load baseline archive:', self.baselinePath, err)
        pcall(api.nvim_buf_set_lines, self.bufnr, 0, -1, false, currentLines)
        vim.bo[self.bufnr].modified = modified
        if view and utils.isWinValid(preferredWinid) then
            pcall(utils.restView, preferredWinid, view)
        end
        return false
    end

    self.isDirty = true
    self:recordRecovery(baselineLines, currentLines, 'baseline')
    self.lastAction = 'recovered-baseline'
    self.lastUpdated = os.time()
    log.debug('loaded baseline archive:', self.baselinePath)
    return true
end

function Undo:loadFileAndUndo(winid, transfer)
    log.debug('loading fallback and undo:', 'fallback:', self.fallbackPath, 'undo:', self.undoPath, 'winid:', winid)
    local view
    if winid then
        view = utils.saveView(winid)
    end

    local lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
    local modified = vim.bo[self.bufnr].modified
    local ei = vim.o.eventignore
    vim.o.eventignore = 'all'
    local missingUndo = false
    local temporary
    local beforeLines, afterLines
    local ok, err = pcall(function()
        afterLines = lines
        if transfer then
            -- Recovery must not depend on publishing to an unavailable archive.
            -- writefile's binary list representation maps embedded NUL to NL.
            temporary = fn.tempname()
            local fd, openErr = fs.openSync(temporary, 'wx', 384) -- 0o600
            if not fd then error(openErr) end
            local closed, closeErr = fs.closeSync(fd)
            if not closed then error(closeErr) end
            local undoLines = vim.split(transfer.undoContents, '\n', {plain = true})
            for i, line in ipairs(undoLines) do undoLines[i] = line:gsub('%z', '\n') end
            if fn.writefile(undoLines, temporary, 'b') ~= 0 then
                error('failed to write temporary recovery undo file')
            end
            local archived = vim.split(transfer.contents, '\n', {plain = true})
            table.remove(archived)
            api.nvim_buf_set_lines(self.bufnr, 0, -1, false, archived)
        else
            local record, recordErr = manifest.read(manifest.path(self.fallbackPath), self.fallbackPath)
            if recordErr and recordErr ~= 'missing' then error(recordErr) end
            if record and record.snapshot_format == 'buffer-lines-v1' then
                local archived = readSnapshot(self.fallbackPath)
                api.nvim_buf_set_lines(self.bufnr, 0, -1, false, archived)
            else
                utils.bufCall(self.bufnr, function()
                    cmd(([[
                    keepalt sil %dread %s
                    keepj sil 1,%ddelete_
                ]]):format(#lines, fn.fnameescape(self.fallbackPath), #lines))
                end)
            end
        end
        beforeLines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
        missingUndo = not fs.statSync(temporary or self.undoPath)
        local undoOk, undoErr = self:loadUndo(temporary)
        if not undoOk then
            pcall(log.warn, 'failed to load undo file:', self.undoPath, undoErr)
            error(undoErr or ('failed to load undo file: ' .. self.undoPath))
        end
        if not self:linesEqual(beforeLines, lines) then
            api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
        end
        -- Keep subsequent edits separate from the recovered external change.
        utils.bufCall(self.bufnr, function()
            cmd('let &l:undolevels = &l:undolevels')
        end)
        vim.bo[self.bufnr].modified = modified

        if winid then
            utils.restView(winid, view)
        end
    end)
    if temporary then pcall(fs.unlinkSync, temporary) end
    if not ok then
        local restored, restoreErr = pcall(function()
            if not self:linesEqual(api.nvim_buf_get_lines(self.bufnr, 0, -1, false), lines) then
                api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
            end
            vim.bo[self.bufnr].modified = modified
        end)
        if not restored then
            -- Retain the original text even if the source buffer became unwritable.
            self.recoveryBackup = {lines = lines, error = tostring(restoreErr)}
            local backupOk, backup = pcall(function()
                local directory = path.join(fn.stdpath('state'), 'fundo-recovery')
                fs.mkdirpSync(directory, archiveDirMode)
                local filename = path.join(directory, ('%d-%.0f.txt'):format(vim.loop.os_getpid(), vim.loop.hrtime()))
                fs.writeFileSync(filename, table.concat(lines, '\n') .. '\n')
                return filename
            end)
            if backupOk then self.recoveryBackup.path = backup end
            local bufferOk, bufnr = pcall(function()
                local buffer = api.nvim_create_buf(true, true)
                api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
                vim.bo[buffer].modified = true
                return buffer
            end)
            if bufferOk then self.recoveryBackup.bufnr = bufnr end
            local message = 'Fundo recovery rollback failed for ' .. self.name .. ': ' .. tostring(restoreErr)
            if backupOk then message = message .. '; original text saved to ' .. backup end
            if bufferOk then message = message .. '; recovery buffer ' .. bufnr end
            vim.schedule(function() vim.notify(message, vim.log.levels.ERROR) end)
        end
        vim.o.eventignore = ei
        pcall(log.warn, 'failed to load fallback archive:', self.fallbackPath, err)
        if winid and view and utils.isWinValid(winid) then
            pcall(utils.restView, winid, view)
        end
        return false, missingUndo and 'missing-undo' or 'corrupt-undo'
    end
    vim.o.eventignore = ei
    log.debug('loaded fallback and undo:', 'fallback:', self.fallbackPath, 'undo:', self.undoPath)
    self:recordRecovery(beforeLines, afterLines, 'fallback')
    return true
end

function Undo:loadFallBack(transfer)
    if transfer and transfer.baselineOnly then
        return self:loadBaseline(transfer)
    end
    if not transfer and not fs.statSync(self.fallbackPath) then
        log.trace('loadFallBack skipped; fallback missing:', self.fallbackPath)
        return false, 'missing-fallback'
    end
    local loaded = false
    local reason
    local preferredWinid, winids = utils.getWinByBuf(self.bufnr)
    if preferredWinid == -1 then
        loaded, reason = self:loadFileAndUndo(nil, transfer)
    elseif winids then
        local views = {}
        for _, winid in ipairs(winids) do
            views[winid] = utils.saveView(winid)
        end
        loaded, reason = self:loadFileAndUndo(preferredWinid, transfer)
        for winid, view in pairs(views) do
            if utils.isWinValid(winid) then
                pcall(utils.restView, winid, view)
            end
        end
    else
        loaded, reason = self:loadFileAndUndo(preferredWinid, transfer)
    end
    if loaded then
        -- The buffer now contains the externally changed file with the restored
        -- undo tree. Persist that repaired pair before another external edit can
        -- make the native undo file invalid again.
        self.isDirty = self.undoPath ~= '' and vim.bo[self.bufnr].undolevels ~= 0
        self.lastAction = 'recovered-fallback'
        self.lastUpdated = os.time()
        if reason then
            log.debug('loaded fallback archive:', self.fallbackPath, 'reason:', reason)
        else
            log.debug('loaded fallback archive:', self.fallbackPath)
        end
    else
        log.debug('failed to load fallback archive:', self.fallbackPath, 'reason:', reason or '')
    end
    return loaded, reason
end

function Undo:shouldTransfer()
    if not self.attached or self.undoPath == '' then
        return logTransferDecision(self, false, self.attached and 'empty-undo-path' or 'not-attached')
    end
    if not (vim.in_fast_event and vim.in_fast_event()) and undoDisabled(self.bufnr) then
        return logTransferDecision(self, false, 'undo-disabled')
    end
    if self.lastError or self.pendingTransfer then
        return logTransferDecision(self, true, 'retry')
    end
    if self.isDirty then
        return logTransferDecision(self, true, 'dirty')
    end
    if vim.in_fast_event and vim.in_fast_event() then
        return logTransferDecision(self, true, 'check-buffer-changes-on-main-loop')
    end
    if api.nvim_buf_get_changedtick(self.bufnr) ~= self.lastCapturedTick then
        return logTransferDecision(self, true, 'buffer-changed')
    end
    if not fs.statSync(self.undoPath) then
        if type(vim.in_fast_event) == 'function' and vim.in_fast_event() then
            return logTransferDecision(self, true, 'native-undo-missing-fast-event')
        end
        return logTransferDecision(self, not self:isEmpty(), 'native-undo-missing')
    end
    if fs.statSync(self.fallbackPath) then
        local manifestPath = manifest.path(self.fallbackPath)
        local inFastEvent = type(vim.in_fast_event) == 'function' and vim.in_fast_event()
        if inFastEvent and fs.statSync(manifestPath) then
            return logTransferDecision(self, false, 'fallback-and-manifest-exist-fast-event')
        end
        local _, manifestErr = manifest.read(manifestPath, self.fallbackPath)
        if not manifestErr then
            return logTransferDecision(self, false, 'fallback-exists')
        end
        if inFastEvent then
            return logTransferDecision(self, true, 'manifest-missing-or-invalid-fast-event')
        end
        return logTransferDecision(self, not self:isEmpty(), 'manifest-missing-or-invalid')
    end
    -- If the archive is missing but Neovim successfully loaded a native undo
    -- tree, save the matching file contents. Avoid inspecting the undo list in
    -- fast-event async paths because that requires non-fast Neovim APIs.
    if type(vim.in_fast_event) == 'function' and vim.in_fast_event() then
        return logTransferDecision(self, true, 'fallback-missing-fast-event')
    end
    return logTransferDecision(self, not self:isEmpty(), 'fallback-missing')
end

function Undo:transfer()
    -- Capture and publish on one main-loop turn. Yielding between wundo and
    -- publication lets unload, rename, or another write replace half the pair.
    return promise(function(resolve, reject)
        local function run()
            local ok, err = pcall(self.transferSync, self)
            if ok then resolve() else reject(err) end
        end
        if vim.in_fast_event and vim.in_fast_event() then
            vim.schedule(run)
        else
            run()
        end
    end)
end

function Undo:transferSync()
    if not self:shouldTransfer() then
        log.debug('transferSync skipped:', self.bufnr, self.name or '')
        return
    end
    if self.pendingRecovery then
        self:check()
        if self.pendingRecovery then
            error(self.lastError and self.lastError.message or 'pending history could not be recovered', 0)
        end
    end
    if self:isEmpty() then
        local snapshot = self.pendingTransfer
        local _, err = self:saveBaseline(snapshot and snapshot.baselineOnly and snapshot or nil)
        if err then error(err, 0) end
        self.pendingTransfer = nil
        self.isDirty = false
        return
    end
    log.debug('transferSync started:', self.bufnr, self.name or '')
    local captured, transfer = pcall(self.transferSnapshot, self)
    if not captured then
        self.lastError = transferError('capture', transfer)
        error(transfer, 0)
    end
    self.lastError = nil
    if self.pendingTransfer then
        transfer.supersededJournals = vim.list_extend({}, self.pendingTransfer.supersededJournals or {})
        if self.pendingTransfer.journalPath then
            table.insert(transfer.supersededJournals, self.pendingTransfer.journalPath)
        end
    end
    self.pendingTransfer = transfer
    Undo.completePendingTransferSync(transfer)
    self:finishTransfer(transfer)
end

function Undo:finishTransfer(transfer)
    if self.pendingTransfer ~= transfer then return end
    self.pendingTransfer = nil
    self.generation = transfer.generation or self.generation
    self.lastCapturedTick = transfer.changedtick or self.lastCapturedTick
    -- Retrying an older snapshot does not resolve a newer capture failure.
    if self.lastError then return end
    self.isDirty = false
    self.lastAction = 'transferred'
    self.lastUpdated = os.time()
    log.debug('transferSync completed:', self.bufnr, transfer.name, 'fallback:', transfer.fallbackPath)
end

function Undo:check()
    if not self.attached or self.undoPath == '' then
        log.trace('check skipped:', self.bufnr, self.name or '', self.attached and 'empty-undo-path' or 'not-attached')
        return
    end
    if vim.bo[self.bufnr].modified or not vim.bo[self.bufnr].modifiable
        or undoDisabled(self.bufnr) then
        return
    end
    if self.pendingRecovery then
        if not self:isEmpty() then
            if not self.pendingRecovery.fromJournal then
                self.lastError = transferError('undo', 'pending recovery would replace newer undo history')
                return
            end
            local ok, err = pcall(function() storage.retain(self:transferSnapshot()) end)
            if not ok then self.lastError = transferError('generation', err); return end
        end
        local loaded, reason = self:loadFallBack(self.pendingRecovery)
        if not loaded then
            self.lastError = transferError('undo', reason)
            return
        end
        self.pendingTransfer = self.pendingRecovery
        self.generation = self.pendingRecovery.expectedGeneration
        self.pendingRecovery = nil
        self.checkedNative = true
        self.lastError = nil
        return
    end
    if not self:isEmpty() then
        if self.checkedNative or self.isDirty then return end
        local committed, err = storage.read(self.fallbackPath)
        if committed and not committed.baselineOnly then
            local captured, native = pcall(self.transferSnapshot, self)
            if not captured then
                self.lastError = transferError('capture', native)
                return
            end
            if native.contents ~= committed.contents or native.undoContents ~= committed.undoContents then
                local retained, id = pcall(storage.retain, native)
                if not retained then
                    self.lastError = transferError('generation', id)
                    return
                end
                self.retainedGeneration = id
                local loaded, reason = self:loadFallBack(committed)
                if not loaded then
                    self.lastError = transferError('generation', reason)
                    return
                end
            end
            self.generation = committed.expectedGeneration
        elseif err and err ~= 'missing' then
            self.lastError = transferError('generation', err)
            return
        end
        self.checkedNative = true
        return
    end
    if self.pendingTransfer and self.pendingTransfer.baselineOnly then
        local ok = pcall(Undo.completePendingTransferSync, self.pendingTransfer)
        if not ok then return end
        self:finishTransfer(self.pendingTransfer)
    end
    local committed, generationError = storage.read(self.fallbackPath)
    if committed then
        self.generation = committed.expectedGeneration
        local loaded, reason = self:loadFallBack(committed)
        if loaded then return end
        if not committed.baselineOnly then
            self.lastError = transferError('generation', reason or 'committed undo could not be loaded')
            return
        end
        self:queueBaseline()
        return
    elseif generationError ~= 'missing' then
        self.lastError = transferError('generation', generationError)
        return
    end
    local _, recordErr = manifest.read(manifest.path(self.fallbackPath), self.fallbackPath)
    if recordErr and recordErr ~= 'missing' then
        pcall(log.warn, 'invalid recovery metadata:', self.name, recordErr)
        return
    end
    log.trace('check started:', self.bufnr, self.name or '')
    local loaded, reason = self:loadFallBack()
    if loaded then
        log.debug('check completed; fallback loaded:', self.bufnr, self.name or '')
        return
    end
    if reason == 'missing-fallback' and fs.statSync(self.undoPath) then
        log.debug('check completed; native undo exists and fallback is missing:', self.bufnr, self.name or '')
        return
    end
    if self:loadBaseline() then
        self.lastAction = 'recovered-baseline'
        self.lastUpdated = os.time()
        log.debug('check completed; baseline loaded:', self.bufnr, self.name or '')
        return
    end
    self:queueBaseline()
    log.trace('check completed; baseline saved if possible:', self.bufnr, self.name or '')
end

return Undo

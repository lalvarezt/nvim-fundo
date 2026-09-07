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

local archiveDirMode = 448 -- 0o700

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
    if path.dirname(name) == self.dir or manifest.isPath(name, self.dir) then
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
        self.undoPath = fn.undofile(name)
        self.fallbackPath = Undo.archivePath(name, self.undoPath, self.dir)
        self.baselinePath = self.fallbackPath .. '.base'
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

function Undo:loadUndo()
    local ok, err = utils.bufCall(self.bufnr, function()
        return pcall(cmd, 'sil rundo ' .. fn.fnameescape(self.undoPath))
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
    if not self.baselinePath or not fs.statSync(self.baselinePath) then
        return
    end
    local ok, err = pcall(fs.unlinkSync, self.baselinePath)
    if not ok then
        pcall(log.warn, 'failed to delete baseline archive:', self.baselinePath, err)
    else
        log.debug('deleted baseline archive:', self.baselinePath)
    end
end

function Undo:saveBaseline()
    if not self.baselinePath or not self.name then
        log.debug('saveBaseline skipped; missing paths:', self.bufnr, self.name or '', self.baselinePath or '')
        return false
    end
    local contents = bufferContents(self.bufnr)
    if not self:canSaveBaseline({type = 'file', size = #contents}) then
        self:deleteBaseline()
        return false
    end
    local ok, err = pcall(function()
        fs.mkdirpSync(path.dirname(self.baselinePath), archiveDirMode)
        fs.writeFileSync(self.baselinePath, contents)
        local record = manifest.read(manifest.path(self.fallbackPath), self.fallbackPath)
        manifest.write({
            name = self.name,
            undoPath = self.undoPath,
            fallbackPath = self.fallbackPath,
            baselinePath = self.baselinePath,
            snapshot_format = record and record.snapshot_format,
            baseline_format = 'buffer-lines-v1',
        })
    end)
    if not ok then
        pcall(log.warn, 'failed to save baseline archive:', self.baselinePath, err)
        return false
    end
    log.debug('saved baseline archive:', self.baselinePath)
    return true
end

local function saveBaselineSnapshot(transfer)
    local limit = config.baseline_max_file_size * 1024 * 1024
    if limit <= 0 or #transfer.contents > limit then
        pcall(fs.unlinkSync, transfer.baselinePath)
        return false
    end
    fs.mkdirpSync(path.dirname(transfer.baselinePath), archiveDirMode)
    fs.writeFileSync(transfer.baselinePath, transfer.contents)
    return true
end

function Undo.completePendingTransferSync(transfer)
    fs.mkdirpSync(path.dirname(transfer.fallbackPath), archiveDirMode)
    fs.writeFileSync(transfer.fallbackPath, transfer.contents)
    fs.writeFileSync(transfer.undoPath, transfer.undoContents)
    saveBaselineSnapshot(transfer)
    manifest.write(transfer)
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
    local stat = fs.fstatSync(fd)
    local contents, readErr = fs.readSync(fd, stat.size, 0)
    fs.closeSync(fd)
    fs.unlinkSync(temporary)
    if not contents or #contents ~= stat.size then
        error(readErr or 'incomplete undo snapshot')
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
    }
end

function Undo:readBaseline()
    if not self.baselinePath or not fs.statSync(self.baselinePath) then
        log.trace('readBaseline skipped; baseline missing:', self.baselinePath or '')
        return
    end
    local record = manifest.read(manifest.path(self.fallbackPath), self.fallbackPath)
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

function Undo:loadBaseline()
    local baselineLines = self:readBaseline()
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
    log.debug('loaded baseline archive:', self.baselinePath)
    return true
end

function Undo:loadFileAndUndo(winid)
    log.debug('loading fallback and undo:', 'fallback:', self.fallbackPath, 'undo:', self.undoPath, 'winid:', winid)
    local view
    if winid then
        view = utils.saveView(winid)
    end

    local ei = vim.o.eventignore
    vim.o.eventignore = 'all'
    local missingUndo = false
    local ok, err = pcall(function()
        local modified = vim.bo[self.bufnr].modified
        local lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
        local record = manifest.read(manifest.path(self.fallbackPath), self.fallbackPath)
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
        missingUndo = not fs.statSync(self.undoPath)
        local undoOk, undoErr = self:loadUndo()
        if not undoOk then
            api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
            vim.bo[self.bufnr].modified = modified
            if winid then
                utils.restView(winid, view)
            end
            pcall(log.warn, 'failed to load undo file:', self.undoPath, undoErr)
            error(undoErr or ('failed to load undo file: ' .. self.undoPath))
        end
        api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
        vim.bo[self.bufnr].modified = modified

        if winid then
            utils.restView(winid, view)
        end
    end)
    vim.o.eventignore = ei
    if not ok then
        pcall(log.warn, 'failed to load fallback archive:', self.fallbackPath, err)
        if winid and view and utils.isWinValid(winid) then
            pcall(utils.restView, winid, view)
        end
        return false, missingUndo and 'missing-undo' or 'corrupt-undo'
    end
    log.debug('loaded fallback and undo:', 'fallback:', self.fallbackPath, 'undo:', self.undoPath)
    return true
end

function Undo:loadFallBack()
    if not fs.statSync(self.fallbackPath) then
        log.trace('loadFallBack skipped; fallback missing:', self.fallbackPath)
        return false, 'missing-fallback'
    end
    local loaded = false
    local reason
    local preferredWinid, winids = utils.getWinByBuf(self.bufnr)
    if preferredWinid == -1 then
        loaded, reason = self:loadFileAndUndo()
    elseif winids then
        local views = {}
        for _, winid in ipairs(winids) do
            views[winid] = utils.saveView(winid)
        end
        loaded, reason = self:loadFileAndUndo(preferredWinid)
        for winid, view in pairs(views) do
            if utils.isWinValid(winid) then
                pcall(utils.restView, winid, view)
            end
        end
    else
        loaded, reason = self:loadFileAndUndo(preferredWinid)
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
    if self.isDirty then
        return logTransferDecision(self, true, 'dirty')
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
    if self:isEmpty() then
        self:saveBaseline()
        self.isDirty = false
        return
    end
    log.debug('transferSync started:', self.bufnr, self.name or '')
    local transfer = self:transferSnapshot()
    self.pendingTransfer = transfer
    Undo.completePendingTransferSync(transfer)
    self.pendingTransfer = nil
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
    if not self:isEmpty() then
        log.trace('check skipped; undo tree is not empty:', self.bufnr, self.name or '')
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
    self:saveBaseline()
    log.trace('check completed; baseline saved if possible:', self.bufnr, self.name or '')
end

return Undo

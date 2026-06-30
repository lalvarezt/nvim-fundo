local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local async = require('async')
local await = async.wait
local promise = require('promise')
local path = require('fundo.fs.path')
local fs = require('fundo.fs')
local utils = require('fundo.utils')
local log = require('fundo.lib.log')
local config = require('fundo.config')

---@class FundoUndo
---@field dir string
---@field bufnr number
---@field attached boolean
local Undo = {}

local function logTransferDecision(self, result, reason)
    log.trace('shouldTransfer:', result, reason, 'bufnr:', self.bufnr, 'file:', self.name or '')
    return result
end

function Undo:new(bufnr, dir)
    local o = setmetatable({}, self)
    self.__index = self
    o.bufnr = bufnr
    o.dir = dir
    return o
end

function Undo:attach()
    local bt = vim.bo[self.bufnr].bt
    local name = api.nvim_buf_get_name(self.bufnr)
    if path.dirname(name) == self.dir then
        log.debug('attach disabled undofile for archive buffer:', self.bufnr, name)
        vim.bo[self.bufnr].undofile = false
    end
    self.attached = (bt == '' or bt == 'acwrite') and vim.bo[self.bufnr].undofile
    if self.attached then
        self:reset()
        log.debug('undo attached:', self.bufnr, name)
    elseif bt ~= '' and bt ~= 'acwrite' then
        log.debug('undo attach skipped; unsupported buftype:', self.bufnr, name, bt)
    elseif not vim.bo[self.bufnr].undofile then
        log.debug('undo attach skipped; undofile disabled:', self.bufnr, name)
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
        local basename = path.basename(self.undoPath)
        self.fallbackPath = path.join(self.dir, basename)
        self.baselinePath = self.fallbackPath .. '.base'
        log.debug('undo paths reset:', 'bufnr:', self.bufnr, 'file:', name, 'undo:', self.undoPath,
            'fallback:', self.fallbackPath, 'baseline:', self.baselinePath)
    end
    self.name = name
    self.isDirty = dirty and self.undoPath ~= '' and vim.bo[self.bufnr].undolevels ~= 0
    log.debug('undo dirty state:', self.bufnr, self.name, self.isDirty == true)
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

function Undo:saveUndo()
    if self.undoPath == '' then
        log.debug('saveUndo skipped; empty undo path:', self.bufnr, self.name or '')
        return false
    end
    local ok, cmdOk, cmdErr = pcall(utils.bufCall, self.bufnr, function()
        return pcall(cmd, 'sil wundo! ' .. fn.fnameescape(self.undoPath))
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

function Undo:saveUndoAsync()
    return promise(function(resolve)
        local function run()
            local ok, err = self:saveUndo()
            resolve({ok = ok, err = err})
        end
        if vim.in_fast_event and vim.in_fast_event() then
            vim.schedule(run)
        else
            run()
        end
    end)
end

function Undo:baselineLimitBytes()
    return config.limit_archives_size * 1024 * 1024
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
    local stat = fs.statSync(self.name)
    if not self:canSaveBaseline(stat) then
        self:deleteBaseline()
        return false
    end
    local ok, err = pcall(function()
        fs.mkdirpSync(path.dirname(self.baselinePath), 493)
        fs.copyFileSync(self.name, self.baselinePath)
    end)
    if not ok then
        pcall(log.warn, 'failed to save baseline archive:', self.baselinePath, err)
        return false
    end
    log.debug('saved baseline archive:', self.baselinePath)
    return true
end

function Undo:readBaseline()
    if not self.baselinePath or not fs.statSync(self.baselinePath) then
        log.debug('readBaseline skipped; baseline missing:', self.baselinePath or '')
        return
    end
    local ok, lines = pcall(fn.readfile, self.baselinePath)
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
        log.debug('loadBaseline skipped; no baseline:', self.baselinePath or '')
        return false
    end
    local currentLines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
    if self:linesEqual(baselineLines, currentLines) then
        log.debug('loadBaseline skipped; baseline equals current buffer:', self.baselinePath)
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
        utils.bufCall(self.bufnr, function()
            cmd(([[
                keepalt sil %dread %s
                keepj sil 1,%ddelete_
            ]]):format(#lines, fn.fnameescape(self.fallbackPath), #lines))
        end)
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
        log.debug('loadFallBack skipped; fallback missing:', self.fallbackPath)
        return false, 'missing-fallback'
    end
    local loaded = false
    local reason
    local preferredWinid, winids = utils.getWinByBuf(self.bufnr)
    if preferredWinid == -1 then
        loaded, reason = self:loadFileAndUndo()
    elseif winids then
        for _, winid in ipairs(winids) do
            local ok, err = self:loadFileAndUndo(winid)
            loaded = ok or loaded
            reason = ok and reason or (err or reason)
        end
    else
        loaded, reason = self:loadFileAndUndo(preferredWinid)
    end
    if loaded then
        -- The buffer now contains the externally changed file with the restored
        -- undo tree. Persist that repaired pair before another external edit can
        -- make the native undo file invalid again.
        self.isDirty = self.undoPath ~= '' and vim.bo[self.bufnr].undolevels ~= 0
        log.debug('loaded fallback archive:', self.fallbackPath, 'reason:', reason or '')
    else
        log.debug('failed to load fallback archive:', self.fallbackPath, 'reason:', reason or '')
    end
    return loaded, reason
end

function Undo:shouldTransfer()
    if not self.attached or self.undoPath == '' then
        return logTransferDecision(self, false, self.attached and 'empty-undo-path' or 'not-attached')
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
        return logTransferDecision(self, false, 'fallback-exists')
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
    return async(function()
        if not self:shouldTransfer() then
            log.debug('transfer skipped:', self.bufnr, self.name or '')
            return
        end
        log.debug('transfer started:', self.bufnr, self.name or '')
        local undo = await(self:saveUndoAsync())
        if not undo.ok then
            pcall(log.warn, 'failed to save undo file:', self.undoPath, undo.err)
            error(undo.err or ('failed to save undo file: ' .. self.undoPath))
        end
        local stat = await(fs.stat(self.name))
        if not stat then
            error('failed to stat buffer file: ' .. self.name)
        end
        fs.mkdirpSync(path.dirname(self.fallbackPath), 493)
        await(fs.copyFile(self.name, self.fallbackPath))
        self:saveBaseline()
        self.isDirty = false
        log.debug('transfer completed:', self.bufnr, self.name, 'fallback:', self.fallbackPath)
    end)
end

function Undo:transferSync()
    if not self:shouldTransfer() then
        log.debug('transferSync skipped:', self.bufnr, self.name or '')
        return
    end
    log.debug('transferSync started:', self.bufnr, self.name or '')
    local undoOk, undoErr = self:saveUndo()
    if not undoOk then
        pcall(log.warn, 'failed to save undo file:', self.undoPath, undoErr)
        error(undoErr or ('failed to save undo file: ' .. self.undoPath))
    end
    local stat = fs.statSync(self.name)
    if not stat then
        error('failed to stat buffer file: ' .. self.name)
    end
    fs.mkdirpSync(path.dirname(self.fallbackPath), 493)
    fs.copyFileSync(self.name, self.fallbackPath)
    self:saveBaseline()
    self.isDirty = false
    log.debug('transferSync completed:', self.bufnr, self.name, 'fallback:', self.fallbackPath)
end

function Undo:check()
    if not self.attached or self.undoPath == '' then
        log.debug('check skipped:', self.bufnr, self.name or '', self.attached and 'empty-undo-path' or 'not-attached')
        return
    end
    if not self:isEmpty() then
        log.debug('check skipped; undo tree is not empty:', self.bufnr, self.name or '')
        return
    end
    log.debug('check started:', self.bufnr, self.name or '')
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
        log.debug('check completed; baseline loaded:', self.bufnr, self.name or '')
        return
    end
    self:saveBaseline()
    log.debug('check completed; baseline saved if possible:', self.bufnr, self.name or '')
end

return Undo

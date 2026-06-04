local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local async = require('async')
local promise = require('promise')
local path = require('fundo.fs.path')
local fs = require('fundo.fs')
local utils = require('fundo.utils')
local log = require('fundo.lib.log')

---@class FundoUndo
---@field dir string
---@field bufnr number
---@field attached boolean
local Undo = {}

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
        vim.bo[self.bufnr].undofile = false
    end
    self.attached = (bt == '' or bt == 'acwrite') and vim.bo[self.bufnr].undofile
    if self.attached then
        self:reset()
    end
    return self.attached
end

function Undo:dispose()
    self.attached = false
end

---
---@param dirty? boolean
---@param bufName? string
function Undo:reset(dirty, bufName)
    if not self.attached then
        return
    end
    local name = bufName or api.nvim_buf_get_name(self.bufnr)
    if name ~= self.name then
        self.undoPath = fn.undofile(name)
        local basename = path.basename(self.undoPath)
        self.fallbackPath = path.join(self.dir, basename)
    end
    self.name = name
    self.isDirty = dirty and self.undoPath ~= '' and vim.bo[self.bufnr].undolevels ~= 0
end

function Undo:isEmpty()
    local res = utils.bufCall(self.bufnr, function()
        return api.nvim_exec('undolist', true)
    end)
    return not res:match('^number')
end

function Undo:loadUndo()
    return utils.bufCall(self.bufnr, function()
        return pcall(cmd, 'sil rundo ' .. fn.fnameescape(self.undoPath))
    end)
end

function Undo:saveUndo()
    if self.undoPath == '' then
        return false
    end
    local ok, cmdOk, cmdErr = pcall(utils.bufCall, self.bufnr, function()
        return pcall(cmd, 'sil wundo! ' .. fn.fnameescape(self.undoPath))
    end)
    if not ok then
        return false, cmdOk
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

function Undo:loadFileAndUndo(winid)
    local view
    if winid then
        view = utils.saveView(winid)
    end

    local ei = vim.o.eventignore
    vim.o.eventignore = 'all'
    local ok, err = pcall(function()
        local modified = vim.bo[self.bufnr].modified
        local lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
        utils.bufCall(self.bufnr, function()
            cmd(([[
                keepalt sil %dread %s
                keepj sil 1,%ddelete_
            ]]):format(#lines, fn.fnameescape(self.fallbackPath), #lines))
        end)
        local undoOk, undoErr = self:loadUndo()
        if not undoOk then
            pcall(log.warn, 'failed to load undo file:', self.undoPath, undoErr)
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
    end
    return ok
end

function Undo:loadFallBack()
    if not fs.statSync(self.fallbackPath) then
        return false
    end
    local loaded = false
    local preferredWinid, winids = utils.getWinByBuf(self.bufnr)
    if preferredWinid == -1 then
        loaded = self:loadFileAndUndo()
    elseif winids then
        for _, winid in ipairs(winids) do
            loaded = self:loadFileAndUndo(winid) or loaded
        end
    else
        loaded = self:loadFileAndUndo(preferredWinid)
    end
    if loaded then
        -- The buffer now contains the externally changed file with the restored
        -- undo tree. Persist that repaired pair before another external edit can
        -- make the native undo file invalid again.
        self.isDirty = self.undoPath ~= '' and vim.bo[self.bufnr].undolevels ~= 0
    end
    return loaded
end

function Undo:shouldTransfer()
    if not self.attached or self.undoPath == '' then
        return false
    end
    if self.isDirty or not fs.statSync(self.undoPath) then
        return true
    end
    -- If the archive is missing but Neovim successfully loaded a non-empty
    -- native undo tree, save the matching file contents. Without this, a later
    -- out-of-process edit (while Neovim is closed) leaves us with no fallback
    -- content to replay the undo file against.
    return not fs.statSync(self.fallbackPath) and not self:isEmpty()
end

function Undo:transfer()
    return async(function()
        if not self:shouldTransfer() then
            return
        end
        local undo = await(self:saveUndoAsync())
        if not undo.ok then
            pcall(log.warn, 'failed to save undo file:', self.undoPath, undo.err)
        end
        local stat = await(fs.stat(self.name))
        if stat then
            await(fs.copyFile(self.name, self.fallbackPath))
        end
        self.isDirty = false
    end)
end

function Undo:transferSync()
    if not self:shouldTransfer() then
        return
    end
    local undoOk, undoErr = self:saveUndo()
    if not undoOk then
        pcall(log.warn, 'failed to save undo file:', self.undoPath, undoErr)
    end
    local stat = fs.statSync(self.name)
    if stat then
        fs.copyFileSync(self.name, self.fallbackPath)
    end
    self.isDirty = false
end

function Undo:check()
    if not self.attached or self.undoPath == '' then
        return
    end
    if self:isEmpty() then
        self:loadFallBack()
    end
end

return Undo

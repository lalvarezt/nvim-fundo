local M = {}
local cmd = vim.cmd
local api = vim.api

local disposable = require('fundo.lib.disposable')
local manager    = require('fundo.manager')
local event      = require('fundo.lib.event')
local log        = require('fundo.lib.log')

local enabled

---@type FundoDisposable[]
local disposables = {}

local function createEvents()
    local groupId = api.nvim_create_augroup('Fundo', {})
    log.debug('created autocmd group:', groupId)
    api.nvim_create_autocmd({'BufReadPost', 'BufWritePost', 'BufWipeout', 'BufUnload', 'FileChangedShellPost'}, {
        group = groupId,
        callback = function(t) event:emit(t.event, t.buf) end
    })
    api.nvim_create_autocmd('CmdlineEnter', {
        group = groupId,
        pattern = ':',
        callback = function(t) event:emit(t.event, t.file) end
    })
    api.nvim_create_autocmd({'VimLeave', 'VimSuspend', 'TermEnter', 'FocusLost'}, {
        group = groupId,
        callback = function(t) event:emit(t.event) end
    })

    return disposable:create(function()
        log.debug('deleting autocmd group:', groupId)
        api.nvim_del_augroup_by_id(groupId)
    end)
end

local function createCommand()
    cmd([[
        com! FundoEnable lua require('fundo').enable()
        com! FundoDisable lua require('fundo').disable()
    ]])
    api.nvim_create_user_command('FundoStatus', function(opts)
        local diagnostics = require('fundo.diagnostics')
        local target = opts.args ~= '' and opts.args or nil
        print(diagnostics.formatStatus(require('fundo').status(target)))
    end, {nargs = '?', complete = 'file', force = true})
    api.nvim_create_user_command('FundoDoctor', function()
        local diagnostics = require('fundo.diagnostics')
        print(diagnostics.formatDoctor(require('fundo').doctor()))
    end, {force = true})
end

function M.enable()
    log.trace('enable requested')
    if enabled then
        log.debug('enable skipped; already enabled')
        return false
    end
    createCommand()
    local pending = {}
    local ok, err = pcall(function()
        table.insert(pending, createEvents())
        table.insert(pending, manager:initialize())
    end)
    if not ok then
        disposable.disposeAll(pending)
        disposables = {}
        error(err)
    end
    disposables = pending
    enabled = true
    log.info('enabled')
    return true
end

function M.disable()
    log.trace('disable requested')
    if not enabled then
        log.debug('disable skipped; already disabled')
        return false
    end
    manager:syncAllSync()
    disposable.disposeAll(disposables)
    enabled = false
    log.info('disabled')
    return true
end

return M

local api = vim.api
local M = {}
local nextId = 0

local function scratch(lines, name, filetype)
    local bufnr = api.nvim_create_buf(false, true)
    vim.bo[bufnr].undofile = false
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].bufhidden = 'wipe'
    api.nvim_buf_set_name(bufnr, name)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = filetype
    vim.bo[bufnr].modified = false
    vim.bo[bufnr].readonly = true
    vim.bo[bufnr].modifiable = false
    return bufnr
end

function M.show(bufnr)
    if bufnr == nil or bufnr == 0 then bufnr = api.nvim_get_current_buf() end
    assert(api.nvim_buf_is_loaded(bufnr), 'preview requires a loaded buffer')
    local recovery = require('fundo').recovery(bufnr)
    assert(recovery, 'no recovered external change for this buffer')
    local current = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local filetype = vim.bo[bufnr].filetype
    nextId = nextId + 1
    local prefix = 'fundo://preview/' .. nextId
    local originalTab = api.nvim_get_current_tabpage()
    local result = {}
    local ok, err = pcall(function()
        result.before_buffer = scratch(recovery.before, prefix .. '/previous', filetype)
        result.after_buffer = scratch(current, prefix .. '/current', filetype)
        vim.cmd('tabnew')
        result.tabpage = api.nvim_get_current_tabpage()
        result.before_window = api.nvim_get_current_win()
        api.nvim_win_set_buf(result.before_window, result.before_buffer)
        vim.cmd('diffthis')
        vim.cmd('rightbelow vsplit')
        result.after_window = api.nvim_get_current_win()
        api.nvim_win_set_buf(result.after_window, result.after_buffer)
        vim.cmd('diffthis')
    end)
    if not ok then
        if result.tabpage and api.nvim_tabpage_is_valid(result.tabpage) then
            pcall(vim.cmd, 'tabclose!')
        end
        if api.nvim_tabpage_is_valid(originalTab) then api.nvim_set_current_tabpage(originalTab) end
        for _, buffer in ipairs({result.before_buffer or false, result.after_buffer or false}) do
            if buffer and api.nvim_buf_is_valid(buffer) then pcall(api.nvim_buf_delete, buffer, {force = true}) end
        end
        error(err, 0)
    end
    return result
end

return M

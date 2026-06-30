local fn = vim.fn
local path = require('fundo.fs.path')

local M = {}
local counter = 0

local function quote(value)
    return string.format('%q', value)
end

local function shellescape(value)
    return fn.shellescape(value)
end

local repo = os.getenv('PWD') or fn.getcwd()

function M.run(opts)
    counter = counter + 1

    local script = path.join(opts.tmpdir, ('session-%d.lua'):format(counter))
    local report = opts.report or path.join(opts.tmpdir, ('session-%d-report.txt'):format(counter))
    local cache = path.join(opts.tmpdir, 'cache')
    local state = path.join(opts.tmpdir, 'state')
    local data = path.join(opts.tmpdir, 'data')

    fn.mkdir(cache, 'p')
    fn.mkdir(state, 'p')
    fn.mkdir(data, 'p')

    local lines = {
        'vim.env.XDG_CACHE_HOME = ' .. quote(cache),
        'vim.env.XDG_STATE_HOME = ' .. quote(state),
        'vim.env.XDG_DATA_HOME = ' .. quote(data),
        'vim.opt.runtimepath:prepend(' .. quote(repo) .. ')',
        'package.path = ' .. quote(repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;') .. ' .. package.path',
        'vim.o.undofile = true',
        'vim.o.undodir = ' .. quote(opts.undo_dir),
        'require("fundo").setup({',
        '    archives_dir = ' .. quote(opts.archives_dir) .. ',',
        '    limit_archives_size = 16,',
        '})',
        'FILE = ' .. quote(opts.file),
        'REPORT = ' .. quote(report),
        'function BufferText()',
        '    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|")',
        'end',
        'function EntryCount()',
        '    return #(vim.fn.undotree().entries or {})',
        'end',
        'function WriteReport(items)',
        '    vim.fn.writefile(items, REPORT)',
        'end',
    }
    for line in (opts.body .. '\n'):gmatch('([^\n]*)\n') do
        table.insert(lines, line)
    end

    fn.writefile(lines, script)

    local nvim = os.getenv('NVIM_BIN') or 'nvim'
    local cmd = table.concat({
        shellescape(nvim),
        '--clean',
        '-n',
        '--headless',
        '-u',
        shellescape(script),
    }, ' ')
    if fn.executable('timeout') == 1 then
        local timeout = os.getenv('FUNDO_CHILD_TIMEOUT') or '15s'
        cmd = 'timeout --kill-after=2s ' .. shellescape(timeout) .. ' ' .. cmd
    end
    cmd = cmd .. ' 2>&1'
    local output = fn.system(cmd)
    local code = vim.v.shell_error
    if code ~= 0 then
        error(('child Neovim session failed with exit code %d\nscript: %s\n%s'):format(code, script, output))
    end

    return {
        script = script,
        report = report,
        output = output,
        lines = fn.filereadable(report) == 1 and fn.readfile(report) or {},
    }
end

return M

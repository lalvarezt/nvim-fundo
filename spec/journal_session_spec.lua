local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('durable pending recovery.', function()
    local dir
    before_each(function()
        dir = fn.tempname()
        fn.mkdir(dir .. '/undo', 'p')
        fn.writefile({'original'}, dir .. '/source.txt')
    end)
    after_each(function() fn.delete(dir, 'rf') end)
    local function run(body)
        return session.run({tmpdir = dir, file = dir .. '/source.txt',
            archives_dir = dir .. '/archives', undo_dir = dir .. '/undo', body = body}).lines
    end

    it('recovers an unsaved edit after an archive outage and editor exit.', function()
        local first = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            assert(require('fundo.manager'):syncAllSync())
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'unsaved work'})
            local fs, config = require('fundo.fs'), require('fundo.config')
            local write = fs.writeFileSync
            fs.writeFileSync = function(target, ...)
                if target:sub(1, #config.archives_dir + 1) == config.archives_dir .. '/' then error('archive outage') end
                return write(target, ...)
            end
            local ok = require('fundo.manager'):syncAllSync()
            WriteReport({tostring(ok)})
            vim.cmd('quitall!')
        ]])
        assert.same({'false'}, first)
        local second = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local text = BufferText()
            vim.cmd('undo')
            WriteReport({text, BufferText()})
            vim.cmd('quitall!')
        ]])
        assert.same({'saved', 'unsaved work'}, second)
    end)
end)

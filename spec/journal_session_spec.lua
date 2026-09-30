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

    it('retains text and diagnostics when undo capture fails during unload.', function()
        local first = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            local manager = require('fundo.manager')
            assert(manager:syncAllSync())
            local bufnr = vim.api.nvim_get_current_buf()
            local u = manager:get(bufnr)
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'uncaptured work'})
            u.saveUndo = function() return false, 'undo capture outage' end
            vim.cmd('enew!')
            vim.cmd('bunload! ' .. bufnr)
            local records = require('fundo.journal').list(require('fundo.config').archives_dir, true)
            WriteReport({tostring(manager:get(bufnr) == nil), tostring(require('fundo').doctor().ok),
                records[1] and records[1].contents:gsub('\n$', '') or 'missing',
                require('fundo').status(FILE).last_error and 'failure retained' or 'missing error'})
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'false', 'uncaptured work', 'failure retained'}, first)
        local second = run([[
            local records = require('fundo.journal').list(require('fundo.config').archives_dir, true)
            local candidates = require('fundo').recovery_candidates(FILE)
            local id
            for _, candidate in ipairs(candidates) do if candidate.text_only then id = candidate.id end end
            local opened = require('fundo').recover(id, FILE)
            local text = table.concat(vim.api.nvim_buf_get_lines(opened.bufnr, 0, -1, false), '|')
            WriteReport({text, tostring(records[1].textOnly),
                tostring(require('fundo').doctor().ok)})
            vim.cmd('quitall!')
        ]])
        assert.same({'uncaptured work', 'true', 'false'}, second)
    end)
end)

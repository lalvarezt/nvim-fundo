local fn = vim.fn
local path = require('fundo.fs.path')
local session = dofile('spec/helper/session.lua')

describe('baseline status.', function()
    local tmpdir
    before_each(function()
        tmpdir = fn.tempname()
        fn.mkdir(path.join(tmpdir, 'undo'), 'p')
        fn.writefile({'original'}, path.join(tmpdir, 'source.txt'))
    end)
    after_each(function() fn.delete(tmpdir, 'rf') end)

    local function run(body)
        return session.run({
            tmpdir = tmpdir, archives_dir = path.join(tmpdir, 'archives'),
            undo_dir = path.join(tmpdir, 'undo'), file = path.join(tmpdir, 'source.txt'), body = body,
        }).lines
    end

    it('explains capture eligibility without changing the buffer or its history.', function()
        local lines = run([[
            local fundo, config = require('fundo'), require('fundo.config')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local results = {}
            local function report()
                table.insert(results, fundo.status().baseline.reason)
            end
            report()
            config.baseline_max_file_size = 0
            report()
            config.baseline_max_file_size = 0.000001
            report()
            config.baseline_max_file_size = 8
            vim.bo.undofile = false
            report()
            vim.bo.undofile = true
            vim.bo.undolevels = -1
            report()
            vim.bo.undolevels = 1000
            vim.bo.modifiable = false
            report()
            vim.bo.modifiable = true
            vim.bo.modified = true
            report()
            vim.bo.modified = false
            assert(BufferText() == 'original' and EntryCount() == 0)
            WriteReport(results)
            vim.cmd('quitall!')
        ]])
        assert.same({'eligible', 'baseline-disabled', 'oversized', 'undo-disabled',
            'undo-disabled', 'not-modifiable', 'modified'}, lines)
    end)

    it('reports pending and persisted capture details across sessions.', function()
        local first = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local fundo = require('fundo')
            local before = fundo.status().baseline
            assert(before.eligible and before.capture_state == 'pending')
            assert(before.limit == 8 * 1024 * 1024 and before.buffer_size == 9)
            assert(require('fundo.manager'):syncAllSync())
            local saved = fundo.status().baseline
            assert(saved.capture_state == 'saved' and saved.size == 9)
            assert(type(saved.captured_at) == 'number')
            local text = require('fundo.diagnostics').formatStatus(fundo.status())
            assert(text:find('baseline captured at:', 1, true))
            WriteReport({tostring(saved.captured_at)})
            vim.cmd('quitall!')
        ]])
        local reopened = run([[
            local status = require('fundo').status(FILE).baseline
            assert(status.reason == 'unloaded' and status.capture_state == 'saved')
            WriteReport({tostring(status.captured_at)})
            vim.cmd('quitall!')
        ]])
        assert.same(first, reopened)
    end)
end)

local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('edit checkpoints.', function()
    local dir
    before_each(function()
        dir = fn.tempname()
        fn.mkdir(dir .. '/undo', 'p')
        fn.writefile({'original'}, dir .. '/source.txt')
    end)
    after_each(function() fn.delete(dir, 'rf') end)
    local function run(body, checkpoint)
        return session.run({tmpdir = dir, file = dir .. '/source.txt', undo_dir = dir .. '/undo',
            archives_dir = dir .. '/archives', checkpoint = checkpoint or {enabled = true}, body = body}).lines
    end

    it('checkpoints ordinary API edits before exit without lifecycle events.', function()
        run([[
            vim.o.swapfile = false
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            assert(require('fundo.manager'):syncAllSync())
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'recent draft'})
            vim.wait(1500, function() return false end, 10)
            os.exit(0)
        ]])
        local result = run([[
            vim.o.swapfile = false
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            vim.cmd('undo')
            WriteReport({before, BufferText(), table.concat(vim.fn.readfile(FILE), '|')})
            vim.cmd('quitall!')
        ]])
        assert.same({'saved', 'recent draft', 'saved'}, result)
    end)

    it('bounds checkpoint delay while edits continue.', function()
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
            local published = false
            for i = 1, 30 do
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'draft ' .. i})
                vim.wait(20, function() return false end, 5)
                local capture = require('fundo.storage').read(u.fallbackPath)
                if capture and capture.contents:find('draft', 1, true) then published = true; break end
            end
            WriteReport({tostring(published), tostring(vim.bo.modified), table.concat(vim.fn.readfile(FILE), '|')})
            vim.cmd('quitall!')
        ]], {enabled = true, debounce_ms = 100, max_delay_ms = 150})
        assert.same({'true', 'true', 'original'}, result)
    end)

    it('keeps failed automatic checkpoints in the recovery journal.', function()
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            local config, fs = require('fundo.config'), require('fundo.fs')
            local write = fs.writeFileSync
            fs.writeFileSync = function(target, ...)
                if target:sub(1, #config.archives_dir + 1) == config.archives_dir .. '/' then error('archive outage') end
                return write(target, ...)
            end
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'checkpoint draft'})
            vim.wait(250, function() return false end, 10)
            local records = require('fundo.journal').list(config.archives_dir, true)
            WriteReport({records[1] and records[1].contents:gsub('\n$', '') or 'missing',
                tostring(require('fundo').status().last_error ~= nil)})
            fs.writeFileSync = write
            vim.cmd('quitall!')
        ]], {enabled = true, debounce_ms = 30, max_delay_ms = 100})
        assert.same({'checkpoint draft', 'true'}, result)
    end)

    it('cancels scheduled checkpoints when the plugin is disabled.', function()
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'before disable'})
            require('fundo').disable()
            local u = require('fundo.model.undo'):new(vim.api.nvim_get_current_buf(), require('fundo.config').archives_dir)
            local fallback = u.archivePath(FILE, vim.fn.undofile(FILE), require('fundo.config').archives_dir)
            local revision = require('fundo.storage').revision(fallback)
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'after disable'})
            vim.wait(250, function() return false end, 10)
            WriteReport({tostring(revision == require('fundo.storage').revision(fallback))})
            vim.cmd('quitall!')
        ]], {enabled = true, debounce_ms = 30, max_delay_ms = 100})
        assert.same({'true'}, result)
    end)

    it('checkpoints edits in a hidden loaded buffer.', function()
        local result = run([[
            vim.o.hidden = true
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
            vim.cmd('enew')
            vim.api.nvim_buf_set_lines(u.bufnr, 0, -1, false, {'hidden draft'})
            vim.wait(250, function() return false end, 10)
            local capture = require('fundo.storage').read(u.fallbackPath)
            WriteReport({capture.contents:gsub('\n$', ''), table.concat(vim.fn.readfile(FILE), '|')})
            vim.cmd('quitall!')
        ]], {enabled = true, debounce_ms = 30, max_delay_ms = 100})
        assert.same({'hidden draft', 'original'}, result)
    end)

    it('does not recreate explicitly forgotten records when a timer was scheduled.', function()
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'discarded draft'})
            require('fundo').forget(FILE, {apply = true})
            vim.wait(250, function() return false end, 10)
            WriteReport({tostring(#require('fundo.storage').records(require('fundo.config').archives_dir)),
                tostring(require('fundo').status().tracked)})
            vim.cmd('quitall!')
        ]], {enabled = true, debounce_ms = 30, max_delay_ms = 100})
        assert.same({'0', 'false'}, result)
    end)
end)

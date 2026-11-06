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

    for _, case in ipairs({
        {name = 'a continuous insert', keys = ' second', expected = 'original'},
        {name = 'an explicit insert undo break', keys = '<C-g>u second', expected = 'first'},
        {name = 'a separate insert', keys = '<Esc>A second', expected = 'first'},
    }) do
        it('preserves undo grouping for ' .. case.name .. ' across checkpoints.', function()
            local result = run(([=[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
                local function eventually(condition, action)
                    local start = vim.loop.hrtime()
                    local function check()
                        local ok, err = xpcall(function()
                            if condition() then action(); return end
                            assert(vim.loop.hrtime() - start < 3e9, 'input/checkpoint timed out: ' .. BufferText())
                            vim.defer_fn(check, 10)
                        end, debug.traceback)
                        if not ok then io.stderr:write(err); os.exit(1) end
                    end
                    vim.schedule(check)
                end
                local function captured(text)
                    return BufferText() == text and u.lastCapturedTick == vim.b.changedtick
                end
                vim.schedule(function() vim.api.nvim_input('gg0Cfirst') end)
                eventually(function() return captured('first') end, function()
                    assert(vim.api.nvim_get_mode().mode == 'i')
                    vim.api.nvim_input(%q)
                    eventually(function() return captured('first second') end, function()
                        assert(vim.api.nvim_get_mode().mode == 'i')
                        local beforeUndo = vim.b.changedtick
                        vim.api.nvim_input('<Esc>u')
                        eventually(function()
                            return vim.api.nvim_get_mode().mode == 'n' and vim.b.changedtick > beforeUndo
                        end, function()
                            local undone = BufferText()
                            vim.cmd('redo')
                            WriteReport({undone, BufferText(), vim.fn.readfile(FILE)[1]})
                            vim.cmd('quitall!')
                        end)
                    end)
                end)
            ]=]):format(case.keys), {enabled = true, debounce_ms = 30, max_delay_ms = 100})
            assert.same({case.expected, 'first second', 'original'}, result)
        end)
    end

    it('skips unchanged unsaved work on repeated explicit syncs and saves the next edit.', function()
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'first draft'})
            local fundo, manager = require('fundo'), require('fundo.manager')
            local u = manager:get(vim.api.nvim_get_current_buf())
            assert(vim.wait(2000, function() return u.lastCapturedTick == vim.b.changedtick end))
            local function sync()
                local finished, failure = false, nil
                fundo.sync():thenCall(function() finished = true end, function(err)
                    failure, finished = err, true
                end)
                assert(vim.wait(2000, function() return finished end))
                assert(not failure, tostring(failure))
            end
            local fs = require('fundo.fs')
            local write, writes = fs.writeFileSync, 0
            fs.writeFileSync = function(...)
                writes = writes + 1
                return write(...)
            end
            for _ = 1, 20 do sync() end
            local unchangedWrites = writes
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'next draft'})
            sync()
            fs.writeFileSync = write
            WriteReport({tostring(unchangedWrites), require('fundo.storage').read(u.fallbackPath).contents:gsub('\n$', ''),
                tostring(vim.bo.modified), vim.fn.readfile(FILE)[1]})
            vim.cmd('quitall!')
        ]], {enabled = true, debounce_ms = 30, max_delay_ms = 100})
        assert.same({'0', 'next draft', 'true', 'original'}, result)
    end)

    it('checkpoints ordinary API edits before exit without lifecycle events.', function()
        run([[
            vim.o.swapfile = false
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            assert(require('fundo.manager'):syncAllSync())
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'recent draft'})
            local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
            assert(vim.wait(5000, function() return u.lastCapturedTick == vim.b.changedtick end, 10))
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

    for _, case in ipairs({
        {name = 'normal-mode edits', edit = [[vim.cmd('normal! gg0Cnormal draft')]], text = 'normal draft'},
        {name = 'substitutions', edit = [[vim.cmd('%s/saved/substitute draft/')]], text = 'substitute draft'},
        {name = 'multiline API edits', edit = [[vim.api.nvim_buf_set_text(0, 0, 0, 0, 5, {'API α', 'draft'})]],
            text = 'API α|draft'},
        {name = 'register puts', edit = [[vim.fn.setreg('a', {'put draft'}, 'l'); vim.cmd('normal! "ap')]],
            text = 'saved|put draft'},
        {name = 'file reads', edit = [[vim.fn.writefile({'read draft'}, FILE .. '.append')
            vim.cmd('$read ' .. vim.fn.fnameescape(FILE .. '.append'))]], text = 'saved|read draft'},
        {name = 'acwrite buffers', edit = [[vim.bo.buftype = 'acwrite'
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'acwrite draft'})]], text = 'acwrite draft'},
    }) do
        it('recovers checkpoints of ' .. case.name .. ' with undo and redo after restart.', function()
            run(([=[
                vim.o.swapfile = false
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
                vim.cmd('write')
                assert(require('fundo.manager'):syncAllSync())
                vim.cmd('let &l:undolevels = &l:undolevels')
                %s
                assert(BufferText() == %q)
                local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
                assert(vim.wait(2000, function() return u.lastCapturedTick == vim.b.changedtick end, 10))
                os.exit(0)
            ]=]):format(case.edit, case.text), {enabled = true, debounce_ms = 30, max_delay_ms = 100})
            local result = run([[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                assert(BufferText() == 'saved')
                vim.cmd('undo')
                local draft = BufferText()
                vim.cmd('undo')
                assert(BufferText() == 'saved')
                vim.cmd('undo')
                assert(BufferText() == 'original')
                for _ = 1, 3 do vim.cmd('redo') end
                WriteReport({draft, BufferText(), vim.fn.readfile(FILE)[1]})
                vim.cmd('quitall!')
            ]])
            assert.same({case.text, 'saved', 'saved'}, result)
        end)
    end

    it('preserves the redo branch when a checkpoint captures an undone edit.', function()
        run([[
            vim.o.swapfile = false
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            assert(require('fundo.manager'):syncAllSync())
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'draft'})
            vim.cmd('undo')
            local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
            assert(vim.wait(2000, function() return u.lastCapturedTick == vim.b.changedtick end, 10))
            os.exit(0)
        ]], {enabled = true, debounce_ms = 30, max_delay_ms = 100})
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(BufferText() == 'saved')
            vim.cmd('redo')
            local draft = BufferText()
            vim.cmd('undo')
            vim.cmd('undo')
            WriteReport({draft, BufferText(), vim.fn.readfile(FILE)[1]})
            vim.cmd('quitall!')
        ]])
        assert.same({'draft', 'original', 'saved'}, result)
    end)

    for _, option in ipairs({
        {disable = 'noundofile', enable = 'undofile'},
        {disable = 'undolevels=-1', enable = 'undolevels=1000'},
        {disable = 'buftype=nofile', enable = 'buftype='},
    }) do
        it('pauses persistence for ' .. option.disable .. ' and resumes after it is restored.', function()
            local result = run(([=[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'first draft'})
                local manager, storage = require('fundo.manager'), require('fundo.storage')
                assert(manager:syncAllSync())
                local u = manager:get(vim.api.nvim_get_current_buf())
                local revision = storage.revision(u.fallbackPath)
                vim.cmd('setlocal %s')
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'excluded draft'})
                assert(u.checkpointTimer == nil)
                assert(manager:syncAllSync())
                assert(revision == storage.revision(u.fallbackPath))
                vim.cmd('setlocal %s')
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'resumed draft'})
                assert(vim.wait(2000, function() return u.lastCapturedTick == vim.b.changedtick end, 10))
                WriteReport({storage.read(u.fallbackPath).contents:gsub('\n$', ''), vim.fn.readfile(FILE)[1]})
                vim.cmd('quitall!')
            ]=]):format(option.disable, option.enable), {enabled = true, debounce_ms = 30, max_delay_ms = 100})
            assert.same({'resumed draft', 'original'}, result)
        end)
    end

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

    it('checkpoints edits made before the deferred opening baseline is saved.', function()
        run([[
            vim.o.swapfile = false
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
            assert(u.pendingTransfer and u.pendingTransfer.baselineOnly)
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'immediate draft'})
            assert(vim.wait(2000, function() return u.lastCapturedTick == vim.b.changedtick end, 10))
            os.exit(0)
        ]], {enabled = true, debounce_ms = 30, max_delay_ms = 100})
        local result = run([[
            vim.o.swapfile = false
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.cmd('undo')
            WriteReport({BufferText(), vim.fn.readfile(FILE)[1]})
            vim.cmd('quitall!')
        ]])
        assert.same({'immediate draft', 'original'}, result)
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
            local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
            assert(vim.wait(2000, function()
                return u.pendingTransfer and u.pendingTransfer.lastError ~= nil
            end, 10))
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
            assert(vim.wait(2000, function()
                return u.lastCapturedTick == vim.api.nvim_buf_get_changedtick(u.bufnr)
            end, 10))
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

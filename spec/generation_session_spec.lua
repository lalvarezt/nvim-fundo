local fn = vim.fn
local path = require('fundo.fs.path')
local session = dofile('spec/helper/session.lua')

describe('generation recovery across processes.', function()
    local tmpdir, file
    before_each(function()
        tmpdir = fn.tempname()
        file = path.join(tmpdir, 'source.txt')
        fn.mkdir(path.join(tmpdir, 'undo'), 'p')
        fn.writefile({'original'}, file)
    end)
    after_each(function() fn.delete(tmpdir, 'rf') end)

    local function run(body)
        return session.run({
            tmpdir = tmpdir, archives_dir = path.join(tmpdir, 'archives'),
            undo_dir = path.join(tmpdir, 'undo'), file = file, body = body,
        }).lines
    end

    it('recovers committed history after exit during publication and reclaims the dead lock.', function()
        local first = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local manager = require('fundo.manager')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'committed'})
            vim.cmd('write')
            assert(manager:syncAllSync())
            local u = manager:get(vim.api.nvim_get_current_buf())
            local pointer = require('fundo.storage').directory(u.fallbackPath) .. '/current'
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'uncommitted'})
            vim.cmd('write')
            local fs, write = require('fundo.fs'), require('fundo.fs').writeFileSync
            fs.writeFileSync = function(target, ...)
                if target == pointer then
                    WriteReport({'interrupted'})
                    os.exit(0)
                end
                return write(target, ...)
            end
            manager:syncAllSync()
            error('publication did not reach the failpoint')
        ]])
        assert.same({'interrupted'}, first)
        fn.writefile({'outside'}, file)
        local second = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local out = {BufferText()}
            vim.cmd('undo')
            table.insert(out, BufferText())
            vim.cmd('undo')
            table.insert(out, BufferText())
            vim.cmd('undo')
            table.insert(out, BufferText())
            assert(require('fundo.manager'):syncAllSync())
            WriteReport(out)
            vim.cmd('quitall!')
        ]])
        assert.same({'outside', 'uncommitted', 'committed', 'original'}, second)
    end)

    it('keeps another process newer history when an older buffer tries to sync.', function()
        local report = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local manager = require('fundo.manager')
            assert(manager:syncAllSync())
            local u = manager:get(vim.api.nvim_get_current_buf())
            local config = require('fundo.config')
            local nested = dofile('spec/helper/session.lua')
            nested.run({
                tmpdir = vim.fn.fnamemodify(FILE, ':h'), archives_dir = config.archives_dir,
                undo_dir = vim.o.undodir, file = FILE,
                body = "vim.cmd('edit ' .. vim.fn.fnameescape(FILE)); " ..
                    "vim.api.nvim_buf_set_lines(0, 0, -1, false, {'newer process'}); " ..
                    "vim.cmd('write'); vim.cmd('quitall!')",
            })
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'older buffer'})
            u:reset(true)
            local synced, err = manager:syncAllSync()
            assert(not synced and err:find('another session', 1, true))
            assert(u.pendingTransfer)
            local committed = require('fundo.storage').read(u.fallbackPath)
            WriteReport({committed.contents:gsub('\n$', ''), BufferText()})
            vim.cmd('quitall!')
        ]])
        assert.same({'newer process', 'older buffer'}, report)
    end)

    it('preserves competing native history and loads the committed same-text tree.', function()
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local manager = require('fundo.manager')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'shared'})
            vim.cmd('write')
            assert(manager:syncAllSync())
            dofile('spec/helper/session.lua').run({tmpdir = vim.fn.fnamemodify(FILE, ':h'),
                archives_dir = require('fundo.config').archives_dir, undo_dir = vim.o.undodir, file = FILE,
                report = vim.fn.fnamemodify(FILE, ':h') .. '/nested-report', body = [=[
                    vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                    for _, text in ipairs({'other session work', 'shared'}) do
                        vim.cmd('let &l:undolevels = &l:undolevels')
                        vim.api.nvim_buf_set_lines(0, 0, -1, false, {text})
                        vim.cmd('write')
                        assert(require('fundo.manager'):syncAllSync())
                    end
                    vim.cmd('quitall!')
                ]=]})
            vim.cmd('write!')
            WriteReport({tostring(manager:syncAllSync())})
            vim.cmd('quitall!')
        ]])
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.cmd('undo')
            local previous = BufferText()
            vim.cmd('redo')
            local manager = require('fundo.manager')
            assert(manager:syncAllSync())
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'later work'})
            vim.cmd('write')
            assert(manager:syncAllSync())
            local u = manager:get(vim.api.nvim_get_current_buf())
            local retained = vim.fn.glob(require('fundo.storage').directory(u.fallbackPath) .. '/*/retained', false, true)
            WriteReport({previous, tostring(#retained > 0)})
            vim.cmd('quitall!')
        ]])
        assert.same({'other session work', 'true'}, result)
    end)

    it('opens preserved undo without changing the source and repairs a missing pointer explicitly.', function()
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            local manager, fundo = require('fundo.manager'), require('fundo')
            assert(manager:syncAllSync())
            local u = manager:get(vim.api.nvim_get_current_buf())
            local committed = require('fundo.storage').read(u.fallbackPath)
            assert(require('fundo.fs').unlinkSync(require('fundo.storage').directory(u.fallbackPath) .. '/current'))
            local candidates = fundo.recovery_candidates()
            local found = false
            for _, candidate in ipairs(candidates) do if candidate.id == committed.generation then found = true end end
            local inspected = fundo.recover(committed.generation)
            vim.api.nvim_buf_call(inspected.bufnr, function() vim.cmd('undo') end)
            local old = table.concat(vim.api.nvim_buf_get_lines(inspected.bufnr, 0, -1, false), '|')
            local source = BufferText()
            local repaired = fundo.repair(committed.generation)
            WriteReport({tostring(found), tostring(inspected.undo_loaded), old, source,
                tostring(repaired == require('fundo.storage').token(u.fallbackPath)),
                table.concat(vim.fn.readfile(FILE), '|')})
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'true', 'original', 'saved', 'true', 'saved'}, result)
    end)

    it('preserves committed history when enabled on a modified buffer from an older session.', function()
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'shared'})
            vim.cmd('write')
            local manager, fundo = require('fundo.manager'), require('fundo')
            assert(manager:syncAllSync())
            dofile('spec/helper/session.lua').run({tmpdir = vim.fn.fnamemodify(FILE, ':h'),
                archives_dir = require('fundo.config').archives_dir, undo_dir = vim.o.undodir, file = FILE,
                report = vim.fn.fnamemodify(FILE, ':h') .. '/nested-report', body = [=[
                    vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                    for _, text in ipairs({'other session work', 'shared'}) do
                        vim.cmd('let &l:undolevels = &l:undolevels')
                        vim.api.nvim_buf_set_lines(0, 0, -1, false, {text})
                        vim.cmd('write')
                        assert(require('fundo.manager'):syncAllSync())
                    end
                    vim.cmd('quitall!')
                ]=]})
            local u = manager:get(vim.api.nvim_get_current_buf())
            local committed = require('fundo.storage').read(u.fallbackPath)
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'live draft'})
            fundo.disable()
            fundo.enable()
            assert(manager:syncAllSync())
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'later draft'})
            assert(manager:syncAllSync())
            local preserved = false
            for _, candidate in ipairs(fundo.recovery_candidates(FILE)) do
                if candidate.id == committed.generation then preserved = true end
            end
            local text = 'missing'
            if preserved then
                local opened = fundo.recover(committed.generation, FILE)
                vim.api.nvim_buf_call(opened.bufnr, function() vim.cmd('undo') end)
                text = table.concat(vim.api.nvim_buf_get_lines(opened.bufnr, 0, -1, false), '|')
            end
            WriteReport({tostring(preserved), text, BufferText()})
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'other session work', 'later draft'}, result)
    end)
end)

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
end)

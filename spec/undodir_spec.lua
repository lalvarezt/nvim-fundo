local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('undo directory changes.', function()
    local dir
    before_each(function()
        dir = fn.tempname()
        fn.mkdir(dir .. '/undo', 'p')
        fn.mkdir(dir .. '/new-undo', 'p')
        fn.writefile({'original'}, dir .. '/source.txt')
    end)
    after_each(function() fn.delete(dir, 'rf') end)

    it('resumes tracking after starting with an empty undodir.', function()
        local result = session.run({tmpdir = dir, file = dir .. '/source.txt', undo_dir = '',
            archives_dir = dir .. '/archives', body = [[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'draft'})
                vim.o.undodir = vim.fn.fnamemodify(FILE, ':h') .. '/new-undo'
                assert(require('fundo.manager'):syncAllSync())
                local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
                local saved = require('fundo.storage').read(u.fallbackPath)
                WriteReport({saved and saved.contents:gsub('\n$', '') or 'missing'})
                vim.cmd('quitall!')
            ]]})
        assert.same({'draft'}, result.lines)
    end)

    it('pauses saves while undodir is empty and resumes at the next destination.', function()
        local result = session.run({tmpdir = dir, file = dir .. '/source.txt', undo_dir = dir .. '/undo',
            archives_dir = dir .. '/archives', body = [[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                local manager, storage = require('fundo.manager'), require('fundo.storage')
                assert(manager:syncAllSync())
                local u = manager:get(vim.api.nvim_get_current_buf())
                local revision = storage.revision(u.fallbackPath)
                vim.o.undodir = ''
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'draft'})
                assert(manager:syncAllSync())
                assert(revision == storage.revision(u.fallbackPath))
                vim.o.undodir = '.'
                assert(manager:syncAllSync())
                WriteReport({(storage.read(u.fallbackPath).contents:gsub('\n$', ''))})
                vim.cmd('quitall!')
            ]]})
        assert.same({'draft'}, result.lines)
    end)

    for _, adjacent in ipairs({false, true}) do
        for _, deferred in ipairs({false, true}) do
            it('moves a clean baseline with adjacent=' .. tostring(adjacent) .. ' and deferred=' .. tostring(deferred), function()
                local destination = adjacent and '.' or dir .. '/new-undo'
                session.run({tmpdir = dir, file = dir .. '/source.txt', undo_dir = dir .. '/undo',
                    archives_dir = dir .. '/archives', body = ([=[
                        vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                        local manager = require('fundo.manager')
                        if not %s then assert(manager:syncAllSync()) end
                        vim.o.undodir = %q
                        local u = manager:get(vim.api.nvim_get_current_buf())
                        if %s then
                            assert(vim.wait(2000, function() return not u.pendingTransfer end))
                        else
                            assert(manager:syncAllSync())
                        end
                        assert(u.undoPath == vim.fn.undofile(FILE))
                        local manifest = require('fundo.manifest')
                        local record = assert(manifest.read(manifest.path(u.fallbackPath), u.fallbackPath))
                        assert(record.undo.path == u.undoPath, 'baseline metadata kept the old undo destination')
                        os.exit(0)
                    ]=]):format(tostring(deferred), destination, tostring(deferred))})
                fn.writefile({'external'}, dir .. '/source.txt')
                local result = session.run({tmpdir = dir, file = dir .. '/source.txt', undo_dir = destination,
                    archives_dir = dir .. '/archives', body = [[
                        vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                        vim.cmd('undo')
                        WriteReport({BufferText()})
                        vim.cmd('quitall!')
                    ]]})
                assert.same({'original'}, result.lines)
            end)
        end

        for _, variant in ipairs({{false, false}, {true, false}, {false, true}, {true, true}}) do
            local failed, asynchronous = unpack(variant)
            it(('moves active history with adjacent=%s, pending=%s, async=%s')
                :format(tostring(adjacent), tostring(failed), tostring(asynchronous)), function()
                local destination = adjacent and '.' or dir .. '/new-undo'
                session.run({tmpdir = dir, file = dir .. '/source.txt', undo_dir = dir .. '/undo',
                    archives_dir = dir .. '/archives', body = ([=[
                        vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                        vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
                        vim.cmd('write')
                        local manager = require('fundo.manager')
                        assert(manager:syncAllSync())
                        if %s then
                            vim.cmd('let &l:undolevels = &l:undolevels')
                            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'pending draft'})
                            local fs, config = require('fundo.fs'), require('fundo.config')
                            local write = fs.writeFileSync
                            fs.writeFileSync = function(target, ...)
                                if target:sub(1, #config.archives_dir) == config.archives_dir then error('outage') end
                                return write(target, ...)
                            end
                            assert(not manager:syncAllSync())
                            fs.writeFileSync = write
                        end
                        local old = vim.o.undodir
                        vim.o.undodir = %q
                        vim.fn.delete(old, 'rf')
                        vim.cmd('let &l:undolevels = &l:undolevels')
                        vim.api.nvim_buf_set_lines(0, 0, -1, false, {'latest draft'})
                        if %s then
                            local finished, failure = false, nil
                            require('fundo').sync():thenCall(function() finished = true end, function(err)
                                failure, finished = err, true
                            end)
                            assert(vim.wait(2000, function() return finished end))
                            assert(not failure, tostring(failure))
                        else
                            assert(manager:syncAllSync())
                        end
                        assert(vim.tbl_isempty(manager.pendingTransfers))
                        assert(vim.fn.filereadable(vim.fn.undofile(FILE)) == 1)
                        assert(vim.fn.isdirectory(old) == 0)
                        assert(vim.fn.readfile(FILE)[1] == 'saved')
                        os.exit(0)
                    ]=]):format(tostring(failed), destination, tostring(asynchronous))})
                fn.writefile({'external'}, dir .. '/source.txt')
                local result = session.run({tmpdir = dir, file = dir .. '/source.txt', undo_dir = destination,
                    archives_dir = dir .. '/archives', body = [[
                        vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                        assert(BufferText() == 'external')
                        vim.cmd('undo')
                        local draft = BufferText()
                        vim.cmd('redo')
                        WriteReport({draft, BufferText(), vim.fn.readfile(FILE)[1]})
                        vim.cmd('quitall!')
                    ]]})
                assert.same({'latest draft', 'external', 'external'}, result.lines)
            end)
        end
    end
end)

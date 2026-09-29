local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('lifecycle snapshot integrity.', function()
    local tmpdir
    before_each(function()
        tmpdir = fn.tempname()
        fn.mkdir(tmpdir .. '/undo', 'p')
    end)
    after_each(function() fn.delete(tmpdir, 'rf') end)

    for _, event in ipairs({'VimSuspend', 'FocusLost', 'TermEnter', 'BufUnload', 'VimLeave'}) do
        it('captures edits made after a successful transfer on ' .. event .. '.', function()
            local result = session.run({
                tmpdir = tmpdir, file = tmpdir .. '/source', undo_dir = tmpdir .. '/undo',
                archives_dir = tmpdir .. '/archives',
                body = ([=[
                    local api, fn = vim.api, vim.fn
                    fn.writefile({'original'}, FILE)
                    vim.cmd('edit ' .. fn.fnameescape(FILE))
                    api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
                    vim.cmd('write')
                    local manager, storage = require('fundo.manager'), require('fundo.storage')
                    assert(manager:syncAllSync())
                    local fallback = manager:get(api.nvim_get_current_buf()).fallbackPath
                    vim.cmd('let &l:undolevels = &l:undolevels')
                    api.nvim_buf_set_lines(0, 0, -1, false, {'unsaved work'})
                    local event = %q
                    if event == 'BufUnload' then
                        local bufnr = api.nvim_get_current_buf()
                        vim.cmd('enew!')
                        vim.cmd('bunload! ' .. bufnr)
                    elseif event == 'VimLeave' then
                        api.nvim_create_autocmd('VimLeave', {callback = function()
                            WriteReport({storage.read(fallback).contents:gsub('\n$', ''), fn.readfile(FILE)[1]})
                        end})
                        vim.cmd('quitall!')
                    else
                        api.nvim_exec_autocmds(event, {})
                        vim.wait(1000, function()
                            return storage.read(fallback).contents == 'unsaved work\n'
                        end, 10)
                    end
                    WriteReport({storage.read(fallback).contents:gsub('\n$', ''), fn.readfile(FILE)[1]})
                    vim.cmd('quitall!')
                ]=]):format(event),
            })
            assert.same({'unsaved work', 'saved'}, result.lines)
        end)
    end
end)

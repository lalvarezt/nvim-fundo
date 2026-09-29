local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('archive preservation policy.', function()
    local tmpdir
    before_each(function()
        tmpdir = fn.tempname()
        fn.mkdir(tmpdir .. '/undo', 'p')
    end)
    after_each(function() fn.delete(tmpdir, 'rf') end)

    for _, pressure in ipairs({'size', 'age', 'damaged'}) do
        it('keeps recoverable work under ' .. pressure .. ' pressure by default.', function()
            local result = session.run({
                tmpdir = tmpdir, file = tmpdir .. '/source', undo_dir = tmpdir .. '/undo',
                archives_dir = tmpdir .. '/archives',
                body = ([=[
                    local api, fn = vim.api, vim.fn
                    fn.writefile({'original'}, FILE)
                    vim.cmd('edit ' .. fn.fnameescape(FILE))
                    local manager, storage, fs = require('fundo.manager'), require('fundo.storage'), require('fundo.fs')
                    api.nvim_buf_set_lines(0, 0, -1, false, {'previous work'})
                    vim.cmd('write')
                    assert(manager:syncAllSync())
                    vim.cmd('let &l:undolevels = &l:undolevels')
                    api.nvim_buf_set_lines(0, 0, -1, false, {'current work'})
                    vim.cmd('write')
                    assert(manager:syncAllSync())
                    local u = manager:get(api.nvim_get_current_buf())
                    local pressure = %q
                    local issueCode, expected = 'archive-size', 'current work\n'
                    if pressure == 'age' then
                        manager.retentionDays = 1
                        require('fundo.config').retention_days = 1
                        local old = os.time() - 3 * 24 * 60 * 60
                        for _, p in ipairs({u.fallbackPath, u.baselinePath,
                            require('fundo.manifest').path(u.fallbackPath), storage.directory(u.fallbackPath) .. '/current'}) do
                            assert(vim.loop.fs_utime(p, old, old))
                        end
                        issueCode = 'archive-retention'
                    else
                        manager.limitArchivesSize = 0
                        require('fundo.config').limit_archives_size = 0
                        if pressure == 'damaged' then
                            local current = storage.token(u.fallbackPath)
                            fs.writeFileSync(storage.directory(u.fallbackPath) .. '/' .. current .. '/record', '{broken')
                            issueCode, expected = 'invalid-generation', 'previous work\n'
                        end
                    end
                    local finished, failure = false, nil
                    manager:scanArchivesDir():thenCall(function() finished = true end, function(e)
                        failure, finished = e, true
                    end)
                    assert(vim.wait(1000, function() return finished end))
                    assert(not failure)
                    local record = storage.read(u.fallbackPath)
                    local preserved = record and record.contents == expected or false
                    local diagnosed = false
                    for _, issue in ipairs(require('fundo').doctor().issues) do
                        if issue.code == issueCode then diagnosed = true end
                    end
                    WriteReport({tostring(preserved), tostring(diagnosed)})
                    -- Avoid publishing into the intentionally damaged record on exit.
                    manager:dispose()
                    vim.cmd('quitall!')
                ]=]):format(pressure),
            })
            assert.same({'true', 'true'}, result.lines)
        end)
    end
end)

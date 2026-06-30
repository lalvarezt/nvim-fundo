local api = vim.api
local fn = vim.fn
local uv = vim.loop
local async = require('async')
local await = async.wait
local promise = require('promise')
local manager = require('fundo.manager')
local path = require('fundo.fs.path')
local event = require('fundo.lib.event')

describe('fundo integration.', function()
    local tmpdir
    local archivesDir
    local undoDir
    local file
    local sync_all

    local function buffer_lines()
        return api.nvim_buf_get_lines(0, 0, -1, false)
    end

    local function archives()
        return fn.glob(path.join(archivesDir, '*'), false, true)
    end

    local function clear_archives()
        for _, archive in ipairs(archives()) do
            fn.delete(archive)
        end
    end

    local function fundo_autocmd_count(event_name)
        local ok, autocmds = pcall(api.nvim_get_autocmds, {
            group = 'Fundo',
            event = event_name,
        })
        if not ok then
            return 0
        end
        return #autocmds
    end

    local function assert_history_restores_to(expected, redo_expected)
        redo_expected = redo_expected or {'external', 'change'}
        local undolist = api.nvim_exec('undolist', true)
        assert(undolist:match('^number'), 'expected undo history to be available')
        vim.cmd('undo')
        assert.same(expected, buffer_lines())
        vim.cmd('redo')
        assert.same(redo_expected, buffer_lines())
    end

    local function edit_and_write(lines)
        api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.cmd('write')
    end

    local function open_file_with_history(initial, internal)
        fn.writefile(initial, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write(internal)
        sync_all()
        assert.are_not.equal(0, #archives())
    end

    local function external_write(lines)
        fn.writefile(lines, file)
    end

    local function external_append(lines)
        fn.writefile(lines, file, 'a')
    end

    sync_all = function()
        local finished = false
        local ok = true
        local err
        manager:syncAll():thenCall(function()
            finished = true
        end, function(reason)
            ok = false
            err = reason
            finished = true
        end)
        assert(vim.wait(1000, function()
            return finished
        end, 20, false), err)
        assert(ok, err)
    end

    before_each(function()
        tmpdir = fn.tempname()
        fn.mkdir(tmpdir, 'p')
        archivesDir = path.join(tmpdir, 'archives')
        undoDir = path.join(tmpdir, 'undo')
        fn.mkdir(archivesDir, 'p')
        fn.mkdir(undoDir, 'p')
        file = path.join(tmpdir, 'sample.txt')

        vim.o.undofile = true
        vim.o.undodir = undoDir
        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 16,
        })
    end)

    after_each(function()
        pcall(require('fundo').disable)
        pcall(vim.cmd, 'silent! %bwipeout!')
        fn.delete(tmpdir, 'rf')
    end)

    it('restores undo history after wipeout and external file changes.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
        vim.cmd('write')
        vim.cmd('bwipeout!')

        assert.are_not.equal(0, #archives())

        fn.writefile({'external', 'change'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.same({'external', 'change'}, buffer_lines())

        assert_history_restores_to({'one', 'two'})
    end)

    it('restores undo history after unload and external file changes.', function()
        local other = path.join(tmpdir, 'other.txt')
        fn.writefile({'one'}, file)
        fn.writefile({'placeholder'}, other)
        vim.cmd('edit ' .. fn.fnameescape(file))
        vim.bo.bufhidden = 'unload'
        api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
        vim.cmd('write')
        vim.cmd('edit ' .. fn.fnameescape(other))

        assert.are_not.equal(0, #archives())

        fn.writefile({'external', 'change'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.same({'external', 'change'}, buffer_lines())

        assert_history_restores_to({'one', 'two'})
    end)

    it('persists undo history when the native undo file is missing during unload.', function()
        local other = path.join(tmpdir, 'other.txt')
        fn.writefile({'one'}, file)
        fn.writefile({'placeholder'}, other)
        vim.cmd('edit ' .. fn.fnameescape(file))
        vim.bo.bufhidden = 'unload'
        api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        fn.delete(fn.undofile(file))
        clear_archives()

        vim.cmd('edit ' .. fn.fnameescape(other))

        assert.equal('file', fn.getftype(fn.undofile(file)))
        assert.are_not.equal(0, #archives())

        fn.writefile({'external', 'change'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.same({'external', 'change'}, buffer_lines())

        assert_history_restores_to({'one', 'two'})
    end)

    it('archives an existing clean undo tree before Neovim is closed.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
        vim.cmd('write')
        sync_all()
        clear_archives()

        local u = manager:get(api.nvim_get_current_buf())
        assert(u, 'expected fundo to track the edited buffer')
        assert(u.isDirty == false, 'expected the native undo file to already be synced')
        assert(u:shouldTransfer(), 'expected missing archive to be recreated')

        vim.cmd('bwipeout!')
        assert.are_not.equal(0, #archives())

        fn.writefile({'external', 'change'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.same({'external', 'change'}, buffer_lines())

        assert_history_restores_to({'one', 'two'})
    end)

    it('restores undo history after loaded buffer external file changes.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
        vim.cmd('write')
        sync_all()

        assert.are_not.equal(0, #archives())

        fn.writefile({'external', 'change'}, file)
        vim.cmd('checktime')
        assert.same({'external', 'change'}, buffer_lines())

        assert_history_restores_to({'one', 'two'})
    end)

    it('keeps a dirty loaded buffer unchanged when checktime sees an external overwrite.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})

        fn.writefile({'external', 'change'}, file)
        local ok, err = pcall(vim.cmd, 'checktime')

        assert(ok, err)
        assert.same({'one', 'two'}, buffer_lines())
        assert.True(vim.bo.modified)
    end)

    it('restores undo history after loaded buffer external append.', function()
        open_file_with_history({'one'}, {'one', 'two'})

        external_append({'external'})
        vim.cmd('checktime')

        assert.same({'one', 'two', 'external'}, buffer_lines())
        assert_history_restores_to({'one', 'two'}, {'one', 'two', 'external'})
    end)

    it('restores undo history after loaded buffer external truncate.', function()
        open_file_with_history({'one', 'two'}, {'one', 'two', 'three'})

        external_write({'one'})
        vim.cmd('checktime')

        assert.same({'one'}, buffer_lines())
        assert_history_restores_to({'one', 'two', 'three'}, {'one'})
    end)

    it('restores undo history for paths with spaces and shell-special characters.', function()
        file = path.join(tmpdir, 'sample with spaces [hash#].txt')
        open_file_with_history({'one'}, {'one', 'two'})

        external_write({'external', 'change'})
        vim.cmd('checktime')

        assert.same({'external', 'change'}, buffer_lines())
        assert_history_restores_to({'one', 'two'})
    end)

    it('restores undo history after multiple external edits before one checktime.', function()
        open_file_with_history({'one'}, {'one', 'two'})

        external_write({'external', 'version-a'})
        external_write({'external', 'version-b'})
        vim.cmd('checktime')

        assert.same({'external', 'version-b'}, buffer_lines())
        assert_history_restores_to({'one', 'two'}, {'external', 'version-b'})
    end)

    it('restores undo history after explicit bunload and external file changes.', function()
        local other = path.join(tmpdir, 'other.txt')

        fn.writefile({'one'}, file)
        fn.writefile({'placeholder'}, other)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'one', 'two'})
        vim.cmd('edit ' .. fn.fnameescape(other))
        vim.cmd('buffer ' .. fn.fnameescape(file))
        vim.cmd('bunload')

        assert.are_not.equal(0, #archives())

        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.same({'external', 'change'}, buffer_lines())

        assert_history_restores_to({'one', 'two'})
    end)

    it('restores undo history after bdelete and external file changes.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'one', 'two'})
        vim.cmd('bdelete')

        assert.are_not.equal(0, #archives())

        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.same({'external', 'change'}, buffer_lines())

        assert_history_restores_to({'one', 'two'})
    end)

    it('tracks the saveas path for later external changes.', function()
        local saved_as = path.join(tmpdir, 'saved-as.txt')

        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'one', 'two'})
        vim.cmd('saveas ' .. fn.fnameescape(saved_as))
        file = saved_as
        sync_all()

        external_write({'external', 'change'})
        vim.cmd('checktime')

        assert.same({'external', 'change'}, buffer_lines())
        assert_history_restores_to({'one', 'two'})
    end)

    it('syncs dirty undo state on FocusLost before an external change.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'one', 'two'})
        clear_archives()

        event:emit('FocusLost')

        assert.True(vim.wait(1000, function()
            return #archives() > 0
        end, 20, false))
        external_write({'external', 'change'})
        vim.cmd('checktime')

        assert.same({'external', 'change'}, buffer_lines())
        assert_history_restores_to({'one', 'two'})
    end)

    it('syncs dirty undo state on TermEnter.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'one', 'two'})
        clear_archives()

        event:emit('TermEnter')

        local u = manager:get(api.nvim_get_current_buf())
        assert.truthy(u)
        assert.True(vim.wait(1000, function()
            return #archives() > 0 and not u.isDirty
        end, 20, false))
        assert.False(u.isDirty)
    end)

    it('does not sync on non-colon CmdlineEnter events.', function()
        local syncAll = manager.syncAll
        local calls = 0

        manager.syncAll = function(self, ...)
            calls = calls + 1
            return syncAll(self, ...)
        end
        event:emit('CmdlineEnter', '/')
        manager.syncAll = syncAll

        assert.equal(0, calls)
    end)

    it('tracks buffers that were loaded before setup.', function()
        require('fundo').disable()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 16,
        })
        local u = manager:get(api.nvim_get_current_buf())
        assert(u, 'expected setup to attach the already-loaded file buffer')
        sync_all()

        assert.are_not.equal(0, #archives())

        fn.writefile({'external', 'change'}, file)
        vim.cmd('checktime')
        assert.same({'external', 'change'}, buffer_lines())

        assert_history_restores_to({'one', 'two'})
    end)

    describe('modification combinations.', function()
        local close_scenarios = {
            {
                name = 'wipeout',
                before_edit = function() end,
                persist = function()
                    vim.cmd('bwipeout!')
                end,
                restore = function()
                    vim.cmd('edit ' .. fn.fnameescape(file))
                end,
            },
            {
                name = 'unload',
                before_edit = function()
                    vim.bo.bufhidden = 'unload'
                end,
                persist = function()
                    local other = path.join(tmpdir, 'other.txt')
                    fn.writefile({'placeholder'}, other)
                    vim.cmd('edit ' .. fn.fnameescape(other))
                end,
                restore = function()
                    vim.cmd('edit ' .. fn.fnameescape(file))
                end,
            },
            {
                name = 'loaded-sync',
                before_edit = function() end,
                persist = sync_all,
                restore = function()
                    vim.cmd('checktime')
                end,
            },
        }

        local missing_artifact_scenarios = {
            {
                name = 'all-artifacts-present',
                mutate = function() end,
            },
            {
                name = 'native-undo-missing',
                mutate = function()
                    fn.delete(fn.undofile(file))
                end,
            },
            {
                name = 'archive-missing',
                mutate = clear_archives,
            },
            {
                name = 'native-undo-and-archive-missing',
                mutate = function()
                    fn.delete(fn.undofile(file))
                    clear_archives()
                end,
            },
        }

        for _, close_case in ipairs(close_scenarios) do
            for _, missing_case in ipairs(missing_artifact_scenarios) do
                local close_case = close_case
                local missing_case = missing_case
                it(('preserves undo after internal writes, %s, external edit, %s'):format(
                    close_case.name,
                    missing_case.name
                ), function()
                    fn.writefile({'one'}, file)
                    vim.cmd('edit ' .. fn.fnameescape(file))
                    close_case.before_edit()

                    api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
                    vim.cmd('write')
                    api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two', 'three'})
                    vim.cmd('write')

                    local u = manager:get(api.nvim_get_current_buf())
                    assert(u, 'expected fundo to track the edited buffer')
                    assert(u:shouldTransfer(), 'expected written buffer to need transfer')

                    missing_case.mutate()
                    close_case.persist()

                    assert.equal('file', fn.getftype(fn.undofile(file)))
                    assert.are_not.equal(0, #archives())

                    fn.writefile({'external', 'change'}, file)
                    close_case.restore()

                    assert.same({'external', 'change'}, buffer_lines())
                    assert_history_restores_to({'one', 'two', 'three'})
                end)
            end
        end

        it('preserves history across outside, inside, outside edits.', function()
            fn.writefile({'one'}, file)
            vim.cmd('edit ' .. fn.fnameescape(file))
            api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            sync_all()

            fn.writefile({'external', 'one'}, file)
            vim.cmd('checktime')
            assert.same({'external', 'one'}, buffer_lines())

            api.nvim_buf_set_lines(0, 0, -1, false, {'external', 'one', 'inside'})
            vim.cmd('write')
            fn.delete(fn.undofile(file))
            clear_archives()
            sync_all()

            fn.writefile({'external', 'change'}, file)
            vim.cmd('checktime')

            assert.same({'external', 'change'}, buffer_lines())
            assert_history_restores_to({'external', 'one', 'inside'})
        end)
    end)

    it('prunes the oldest archives when the size limit is exceeded.', function()
        local file_a = path.join(tmpdir, 'a.txt')
        local file_b = path.join(tmpdir, 'b.txt')

        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 0.00004,
        })

        fn.writefile({'aaaaaaaaaaaaaaaaaaaa'}, file_a)
        vim.cmd('edit ' .. fn.fnameescape(file_a))
        api.nvim_buf_set_lines(0, 0, -1, false, {'aaaaaaaaaaaaaaaaaaaa', 'updated'})
        vim.cmd('write')
        vim.cmd('bwipeout!')

        fn.writefile({'bbbbbbbbbbbbbbbbbbbb'}, file_b)
        vim.cmd('edit ' .. fn.fnameescape(file_b))
        api.nvim_buf_set_lines(0, 0, -1, false, {'bbbbbbbbbbbbbbbbbbbb', 'updated'})
        vim.cmd('write')
        vim.cmd('bwipeout!')

        local archives = fn.glob(path.join(archivesDir, '*'), false, true)
        assert.equal(4, #archives)

        for i, archive in ipairs(archives) do
            uv.fs_utime(archive, 100 * i, 100 * i)
        end

        async(function()
            await(manager:scanArchivesDir())
            done()
        end)
        assert.True(wait())

        local remaining = fn.glob(path.join(archivesDir, '*'), false, true)
        assert.equal(1, #remaining)
        assert.equal(archives[4], remaining[1])
    end)

    it('does not fail the prune scan when an archive cannot be removed.', function()
        local fs = require('fundo.fs')
        local unlink = fs.unlink
        local archive = path.join(archivesDir, 'stale')

        fn.writefile({'stale archive'}, archive)
        manager.limitArchivesSize = 0
        fs.unlink = function()
            return promise.reject('unlink failed')
        end

        async(function()
            await(manager:scanArchivesDir())
            done()
        end)
        local ok, err = wait()
        fs.unlink = unlink

        assert(ok, err)
    end)

    it('creates missing parent directories for a nested archive directory.', function()
        local fs = require('fundo.fs')
        local nestedArchivesDir = path.join(tmpdir, 'missing', 'nested', 'archives')

        require('fundo').setup({
            archives_dir = nestedArchivesDir,
            limit_archives_size = 16,
        })

        assert.equal('directory', fs.statSync(nestedArchivesDir).type)
    end)

    it('fails setup when the configured archive path is not a directory.', function()
        local invalidArchivesDir = path.join(tmpdir, 'archive-file')
        fn.writefile({'not a directory'}, invalidArchivesDir)

        local ok, err = pcall(require('fundo').setup, {
            archives_dir = invalidArchivesDir,
            limit_archives_size = 16,
        })

        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 16,
        })

        assert.False(ok)
        assert.truthy(tostring(err):match('director'))
    end)

    it('recovers cleanly after setup fails with an invalid archive path.', function()
        local invalidArchivesDir = path.join(tmpdir, 'archive-file')
        fn.writefile({'not a directory'}, invalidArchivesDir)

        local ok = pcall(require('fundo').setup, {
            archives_dir = invalidArchivesDir,
            limit_archives_size = 16,
        })

        assert.False(ok)
        assert.equal(0, fundo_autocmd_count('BufReadPost'))
        assert.equal(0, fundo_autocmd_count('FileChangedShellPost'))

        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 16,
        })

        assert.equal(1, fundo_autocmd_count('BufReadPost'))
        assert.equal(1, fundo_autocmd_count('FileChangedShellPost'))

        open_file_with_history({'one'}, {'one', 'two'})
        external_write({'external', 'change'})
        vim.cmd('checktime')

        assert.same({'external', 'change'}, buffer_lines())
        assert_history_restores_to({'one', 'two'})
    end)

    it('keeps a buffer tracked when fallback archive transfer fails during detach.', function()
        local fs = require('fundo.fs')
        local copyFileSync = fs.copyFileSync

        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        rawset(fs, 'copyFileSync', function()
            error('archive write failed')
        end)
        local ok, err = manager:detach(bufnr)
        rawset(fs, 'copyFileSync', copyFileSync)

        assert.False(ok)
        assert.truthy(tostring(err):match('archive write failed'))
        local u = manager:get(bufnr)
        assert(u, 'expected failed detach to leave the undo object available for retry')
        assert.True(u.isDirty)

        ok, err = manager:detach(bufnr)

        assert(ok, err)
        assert.falsy(manager:get(bufnr))
        vim.cmd('bwipeout!')
        fn.writefile({'external', 'change'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.same({'external', 'change'}, buffer_lines())
        assert_history_restores_to({'one', 'two'})
    end)

    it('does not update the fallback archive when saving native undo fails.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        local u = manager:get(bufnr)
        assert(u, 'expected fundo to track the edited buffer')
        clear_archives()
        u.saveUndo = function()
            return false, 'forced undo save failure'
        end

        local ok, err = pcall(function()
            u:transferSync()
        end)

        assert.False(ok)
        assert.truthy(tostring(err):match('forced undo save failure'))
        assert.True(u.isDirty)
        assert.equal(0, #archives())
    end)

    it('keeps undo dirty when fallback archive transfer fails.', function()
        local fs = require('fundo.fs')
        local copyFileSync = fs.copyFileSync

        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        local u = manager:get(bufnr)
        assert(u, 'expected fundo to track the edited buffer')
        clear_archives()
        rawset(fs, 'copyFileSync', function()
            error('forced archive copy failure')
        end)

        local ok, err = pcall(function()
            u:transferSync()
        end)
        rawset(fs, 'copyFileSync', copyFileSync)

        assert.False(ok)
        assert.truthy(tostring(err):match('forced archive copy failure'))
        assert.True(u.isDirty)
        assert.equal(0, #archives())
    end)

    it('does not treat failed fallback undo loading as a repaired tree.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')
        sync_all()

        local u = manager:get(bufnr)
        assert(u, 'expected fundo to track the edited buffer')
        assert.False(u.isDirty)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'external', 'change'})
        u.loadUndo = function()
            return false, 'forced undo load failure'
        end

        local loaded = u:loadFallBack()

        assert.False(loaded)
        assert.False(u.isDirty)
        assert.same({'external', 'change'}, buffer_lines())
    end)

    it('reports sync failures and keeps undo dirty.', function()
        local fs = require('fundo.fs')
        local copyFile = fs.copyFile

        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        local u = manager:get(bufnr)
        assert(u, 'expected fundo to track the edited buffer')
        rawset(fs, 'copyFile', function()
            return promise.reject('forced async archive copy failure')
        end)

        local finished = false
        local ok = true
        local err
        manager:syncAll():thenCall(function()
            finished = true
        end, function(reason)
            ok = false
            err = reason
            finished = true
        end)
        assert(vim.wait(1000, function()
            return finished
        end, 20, false), err)
        rawset(fs, 'copyFile', copyFile)

        assert.False(ok)
        assert.truthy(tostring(err):match('forced async archive copy failure'))
        assert.True(u.isDirty)
    end)

    it('recreates a deleted archive directory before syncing.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        fn.delete(archivesDir, 'rf')
        sync_all()

        assert.equal(1, fn.isdirectory(archivesDir))
        assert.are_not.equal(0, #archives())

        fn.writefile({'external', 'change'}, file)
        vim.cmd('checktime')
        assert.same({'external', 'change'}, buffer_lines())
        assert_history_restores_to({'one', 'two'})
    end)
end)

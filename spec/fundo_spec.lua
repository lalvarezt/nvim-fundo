local api = vim.api
local fn = vim.fn
local uv = vim.loop
local async = require('async')
local promise = require('promise')
local manager = require('fundo.manager')
local path = require('fundo.fs.path')

describe('fundo integration.', function()
    local tmpdir
    local archivesDir
    local undoDir
    local file

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

    local function assert_history_restores_to(expected)
        local undolist = api.nvim_exec('undolist', true)
        assert.truthy(undolist:match('^number'), 'expected undo history to be available')
        vim.cmd('undo')
        assert.same(expected, buffer_lines())
        vim.cmd('redo')
        assert.same({'external', 'change'}, buffer_lines())
    end

    local function sync_all()
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
        assert.True(vim.wait(1000, function()
            return finished
        end, 20, false), err)
        assert.True(ok, err)
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
                    assert.truthy(u, 'expected fundo to track the edited buffer')
                    assert.True(u:shouldTransfer(), 'expected written buffer to need transfer')

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
        assert.equal(2, #archives)

        uv.fs_utime(archives[1], 100, 100)
        uv.fs_utime(archives[2], 200, 200)

        async(function()
            await(manager:scanArchivesDir())
            done()
        end)
        assert.True(wait())

        local remaining = fn.glob(path.join(archivesDir, '*'), false, true)
        assert.equal(1, #remaining)
        assert.equal(archives[2], remaining[1])
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

        assert.True(ok, err)
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

    it('detaches a buffer even when fallback archive transfer fails.', function()
        local fs = require('fundo.fs')
        local copyFileSync = fs.copyFileSync

        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        fs.copyFileSync = function()
            error('archive write failed')
        end
        local ok, err = pcall(function()
            manager:detach(bufnr)
        end)
        fs.copyFileSync = copyFileSync

        assert.True(ok, err)
        assert.Nil(manager:get(bufnr))
    end)
end)

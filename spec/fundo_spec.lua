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

    for _, mutation in ipairs({'delete', 'rename', 'overwrite'}) do
        it('persists the buffer snapshot after an external ' .. mutation .. ' before sync.', function()
            fn.writefile({'one'}, file)
            vim.cmd('edit ' .. fn.fnameescape(file))
            edit_and_write({'one', 'two'})
            if mutation == 'delete' then
                assert.equal(0, fn.delete(file))
            elseif mutation == 'rename' then
                assert(uv.fs_rename(file, file .. '.moved'))
            else
                external_write({'outside'})
            end
            sync_all()
            vim.cmd('bwipeout!')
            external_write({'external', 'change'})
            vim.cmd('edit ' .. fn.fnameescape(file))
            assert_history_restores_to({'one', 'two'})
            vim.cmd('undo')
            vim.cmd('undo')
            assert.same({'one'}, buffer_lines())
        end)
    end

    it('tracks a newly created file through its first write.', function()
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'created'})
        assert.truthy(manager:get(api.nvim_get_current_buf()))
        sync_all()
        vim.cmd('bwipeout!')
        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert_history_restores_to({'created'})
    end)

    it('follows an explicit buffer rename before the next write.', function()
        open_file_with_history({'one'}, {'one', 'two'})
        local renamed = file .. '.renamed'
        assert(uv.fs_rename(file, renamed))
        vim.cmd('file ' .. fn.fnameescape(renamed))
        local u = manager:get(api.nvim_get_current_buf())
        assert.equal(renamed, u.name)
        sync_all()
        vim.cmd('bwipeout!')
        fn.writefile({'external', 'change'}, renamed)
        vim.cmd('edit ' .. fn.fnameescape(renamed))
        assert_history_restores_to({'one', 'two'})
    end)

    it('keeps a clean file baseline during an archive scan.', function()
        fn.writefile({'baseline'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local u = manager:get(api.nvim_get_current_buf())
        async(function()
            await(manager:scanArchivesDir())
            done()
        end)
        assert.True(wait())
        assert.equal(1, fn.filereadable(u.baselinePath))
        vim.cmd('bwipeout!')
        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert_history_restores_to({'baseline'})
    end)

    it('does not replay an older pending transfer over a newer saved buffer.', function()
        local fs = require('fundo.fs')
        local writeFileSync = fs.writeFileSync
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'two'})
        rawset(fs, 'writeFileSync', function() error('disk unavailable') end)
        vim.cmd('bwipeout!')
        rawset(fs, 'writeFileSync', writeFileSync)
        assert.equal(1, vim.tbl_count(manager.pendingTransfers))
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'three'})
        sync_all()
        vim.cmd('bwipeout!')
        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert_history_restores_to({'three'})
    end)

    for _, lines in ipairs({{'', ''}, {'utf8: é 日本語', 'tail\r'}, {'nul\0byte', ''}}) do
        it('round trips buffer text ' .. vim.inspect(lines) .. ' through fallback and baseline.', function()
            open_file_with_history({'initial'}, lines)
            local u = manager:get(api.nvim_get_current_buf())
            local undoPath = u.undoPath
            vim.cmd('bwipeout!')
            external_write({'external', 'change'})
            vim.cmd('edit ' .. fn.fnameescape(file))
            assert_history_restores_to(lines)
            vim.cmd('bwipeout!')
            fn.delete(undoPath)
            external_write({'another'})
            vim.cmd('edit ' .. fn.fnameescape(file))
            assert_history_restores_to({'external', 'change'}, {'another'})
        end)
    end

    it('leaves no synthetic undo entries after a corrupt fallback fails recovery.', function()
        open_file_with_history({'one'}, {'one', 'two'})
        local u = manager:get(api.nvim_get_current_buf())
        local fallbackPath, baselinePath = u.fallbackPath, u.baselinePath
        vim.cmd('bwipeout!')
        fn.writefile({'corrupt archive'}, fallbackPath)
        fn.delete(baselinePath)
        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.same({'external', 'change'}, buffer_lines())
        vim.cmd('undo')
        assert.same({'external', 'change'}, buffer_lines())
    end)

    it('respects undofile being disabled on an already tracked buffer.', function()
        open_file_with_history({'one'}, {'one', 'two'})
        local u = manager:get(api.nvim_get_current_buf())
        local before = fn.readfile(u.fallbackPath)
        vim.bo.undofile = false
        edit_and_write({'untracked'})
        sync_all()
        assert.same(before, fn.readfile(u.fallbackPath))
    end)

    it('does not restore a baseline over a modified buffer during setup.', function()
        fn.writefile({'baseline'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        require('fundo').disable()
        vim.bo.undolevels = -1
        api.nvim_buf_set_lines(0, 0, -1, false, {'unsaved'})
        vim.bo.undolevels = 1000
        require('fundo').enable()
        assert.same({'unsaved'}, buffer_lines())
        vim.cmd('undo')
        assert.same({'unsaved'}, buffer_lines())
        assert.True(vim.bo.modified)
    end)

    it('restores a clean UTF-16 baseline as buffer text.', function()
        fn.writefile({'placeholder'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        require('fundo').disable()
        api.nvim_buf_set_lines(0, 0, -1, false, {'日本語', 'é'})
        vim.bo.fileencoding = 'utf-16le'
        vim.bo.bomb = true
        vim.cmd('write')
        vim.cmd('bwipeout!')
        fn.delete(fn.undofile(file))
        fn.delete(archivesDir, 'rf')
        require('fundo').enable()
        vim.cmd('edit ' .. fn.fnameescape(file))
        vim.cmd('bwipeout!')
        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert_history_restores_to({'日本語', 'é'})
    end)

    it('reports a clean baseline as usable storage.', function()
        fn.writefile({'baseline'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.equal('baseline-only', require('fundo').status().state)
        assert.True(require('fundo').doctor().ok)
    end)

    it('recovers a deleted path without recreating its source file.', function()
        open_file_with_history({'one'}, {'one', 'two'})
        vim.cmd('bwipeout!')
        fn.delete(file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.same({''}, buffer_lines())
        assert_history_restores_to({'one', 'two'}, {''})
        sync_all()
        assert.equal(0, fn.filereadable(file))
    end)

    it('retries a detached snapshot after the source has disappeared.', function()
        local fs = require('fundo.fs')
        local writeFileSync = fs.writeFileSync
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'two'})
        rawset(fs, 'writeFileSync', function() error('disk unavailable') end)
        vim.cmd('bwipeout!')
        rawset(fs, 'writeFileSync', writeFileSync)
        fn.delete(file)
        sync_all()
        assert.equal(0, vim.tbl_count(manager.pendingTransfers))
        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert_history_restores_to({'two'})
    end)

    for _, mode in ipairs({'sync', 'unload', 'leave'}) do
        it('keeps a modified snapshot paired with its undo tree during ' .. mode .. '.', function()
            fn.writefile({'initial'}, file)
            vim.cmd('edit ' .. fn.fnameescape(file))
            edit_and_write({'saved'})
            api.nvim_buf_set_lines(0, 0, -1, false, {'unsaved'})
            if mode == 'sync' then
                sync_all()
            elseif mode == 'leave' then
                event:emit('VimLeave')
            else
                vim.cmd('bwipeout!')
            end
            assert.same({'saved'}, fn.readfile(file))
            vim.cmd('silent! bwipeout!')
            external_write({'external', 'change'})
            vim.cmd('edit ' .. fn.fnameescape(file))
            assert_history_restores_to({'unsaved'})
        end)
    end

    it('keeps fallback archives for files whose names end in .base.', function()
        local original = file
        fn.writefile({'original baseline'}, original)
        vim.cmd('edit ' .. fn.fnameescape(original))
        vim.cmd('bwipeout!')
        file = file .. '.base'
        open_file_with_history({'one'}, {'one', 'two'})
        async(function()
            await(manager:scanArchivesDir())
            done()
        end)
        assert.True(wait())
        vim.cmd('bwipeout!')
        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert_history_restores_to({'one', 'two'})
        vim.cmd('bwipeout!')
        fn.writefile({'changed original'}, original)
        vim.cmd('edit ' .. fn.fnameescape(original))
        assert_history_restores_to({'original baseline'}, {'changed original'})
    end)

    it('separates same-named files when undodir stores undo beside each source.', function()
        vim.o.undodir = '.'
        local otherDir = path.join(tmpdir, 'other')
        fn.mkdir(otherDir, 'p')
        local other = path.join(otherDir, 'sample.txt')
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'one', 'two'})
        sync_all()
        local firstFallback = manager:get(api.nvim_get_current_buf()).fallbackPath
        vim.cmd('bwipeout!')
        fn.writefile({'other'}, other)
        vim.cmd('edit ' .. fn.fnameescape(other))
        edit_and_write({'other', 'history'})
        sync_all()
        assert.are_not.equal(firstFallback, manager:get(api.nvim_get_current_buf()).fallbackPath)
        vim.cmd('bwipeout!')
        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert_history_restores_to({'one', 'two'})
    end)

    it('does not retain an invalid buffer after native undo persistence fails on unload.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'two'})
        local bufnr = api.nvim_get_current_buf()
        manager:get(bufnr).saveUndo = function() return false, 'disk unavailable' end
        vim.cmd('bwipeout!')
        assert.falsy(manager:get(bufnr))
        sync_all()
    end)

    it('migrates a collision-prone archive when its metadata identifies the source.', function()
        local fs = require('fundo.fs')
        local manifest = require('fundo.manifest')
        file = file .. '.base'
        open_file_with_history({'one'}, {'one', 'two'})
        local u = manager:get(api.nvim_get_current_buf())
        local fallback, baseline, undoPath = u.fallbackPath, u.baselinePath, u.undoPath
        vim.cmd('bwipeout!')
        local legacy = path.join(archivesDir, path.basename(undoPath))
        assert(uv.fs_rename(fallback, legacy))
        assert(uv.fs_rename(baseline, legacy .. '.base'))
        fs.unlinkSync(manifest.path(fallback))
        manifest.write({
            name = file, undoPath = undoPath,
            fallbackPath = legacy, baselinePath = legacy .. '.base',
            snapshot_format = 'buffer-lines-v1', baseline_format = 'buffer-lines-v1',
        })
        external_write({'external', 'change'})
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert.equal(fallback, require('fundo').status().fallback.path)
        assert_history_restores_to({'one', 'two'})
    end)

    it('keeps a failed baseline write pending until its matching snapshot is persisted.', function()
        local fs = require('fundo.fs')
        local writeFileSync = fs.writeFileSync
        open_file_with_history({'one'}, {'one', 'two'})
        local u = manager:get(api.nvim_get_current_buf())
        edit_and_write({'three'})
        rawset(fs, 'writeFileSync', function(target, ...)
            if target == u.baselinePath then error('baseline disk failure') end
            return writeFileSync(target, ...)
        end)
        local ok = pcall(u.transferSync, u)
        rawset(fs, 'writeFileSync', writeFileSync)
        assert.False(ok)
        assert.True(u.isDirty)
        assert.truthy(u.pendingTransfer)
        sync_all()
        assert.is_nil(u.pendingTransfer)
        assert.same({'three'}, fn.readfile(u.baselinePath))
    end)

    it('decodes a legacy UTF-16 baseline without metadata.', function()
        local fs = require('fundo.fs')
        fn.writefile({'external', 'change'}, file)
        local undoPath = fn.undofile(file)
        local baselinePath = path.join(archivesDir, path.basename(undoPath)) .. '.base'
        fs.writeFileSync(baselinePath, '\255\254a\0\n\0')
        vim.cmd('edit ' .. fn.fnameescape(file))
        assert_history_restores_to({'a'})
    end)

    it('archives an empty new file without requiring a native undo tree.', function()
        vim.cmd('edit ' .. fn.fnameescape(file))
        vim.cmd('write')
        sync_all()
        assert.equal('baseline-only', require('fundo').status().state)
    end)

    it('archives a renamed clean buffer without requiring a native undo tree.', function()
        fn.writefile({'clean'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local renamed = file .. '.renamed'
        assert(uv.fs_rename(file, renamed))
        vim.cmd('file ' .. fn.fnameescape(renamed))
        sync_all()
        vim.cmd('bwipeout!')
        fn.writefile({'external', 'change'}, renamed)
        vim.cmd('edit ' .. fn.fnameescape(renamed))
        assert_history_restores_to({'clean'})
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

    it('writes a versioned manifest and reports healthy status.', function()
        local manifest = require('fundo.manifest')
        local fs = require('fundo.fs')

        open_file_with_history({'one'}, {'one', 'two'})

        local fallback = path.join(archivesDir, path.basename(fn.undofile(file)))
        local manifestPath = manifest.path(fallback)
        local value, err = manifest.read(manifestPath, fallback)
        assert(value, err)
        assert.equal(1, value.version)
        assert.equal(path.normalize(file), value.source.path)
        assert.equal(path.normalize(fallback), value.fallback.path)
        assert.equal('file', fs.statSync(manifestPath).type)
        if not require('fundo.utils').isWindows() then
            assert.equal(384, fs.statSync(manifestPath).mode % 512)
        end

        local status = require('fundo').status(file)
        assert.equal('healthy', status.state)
        assert.equal(1, status.manifest_version)
        assert.True(status.fallback.exists)
        assert.True(status.manifest.exists)

        local doctor = require('fundo').doctor()
        assert.True(doctor.ok)
        assert.equal(1, doctor.records)
        assert.equal(0, doctor.legacy_records)

        local diagnostics = require('fundo.diagnostics')
        assert.equal(2, fn.exists(':FundoStatus'))
        assert.equal(2, fn.exists(':FundoDoctor'))
        assert.truthy(diagnostics.formatStatus(status):match('state: healthy'))
        assert.truthy(diagnostics.formatDoctor(doctor):match('Fundo doctor: OK'))
    end)

    it('reports corrupted manifests without changing an otherwise valid archive.', function()
        local manifest = require('fundo.manifest')

        open_file_with_history({'one'}, {'one', 'two'})
        local fallback = path.join(archivesDir, path.basename(fn.undofile(file)))
        fn.writefile({'not json'}, manifest.path(fallback))

        local status = require('fundo').status(file)
        assert.equal('invalid-manifest', status.state)
        assert.truthy(status.manifest_error)

        local doctor = require('fundo').doctor()
        assert.False(doctor.ok)
        assert.equal('invalid-manifest', doctor.issues[1].code)
        assert.equal('file', fn.getftype(fallback))
    end)

    it('uses an independent maximum size for baseline snapshots.', function()
        local manifest = require('fundo.manifest')

        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 16,
            baseline_max_file_size = 0,
        })
        open_file_with_history({'one'}, {'one', 'two'})

        local fallback = path.join(archivesDir, path.basename(fn.undofile(file)))
        local value, err = manifest.read(manifest.path(fallback), fallback)
        assert(value, err)
        assert.equal('file', fn.getftype(fallback))
        assert.equal('', fn.getftype(fallback .. '.base'))
        assert.Nil(value.baseline)
    end)

    it('does not track files rejected by the configured filter.', function()
        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 16,
            filter = function(name)
                return path.normalize(name) ~= path.normalize(file)
            end,
        })

        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        edit_and_write({'one', 'two'})

        assert.Nil(manager:get(api.nvim_get_current_buf()))
        assert.same({}, archives())
        local status = require('fundo').status(file)
        assert.equal('filtered', status.state)
        assert.False(status.selected)
    end)

    it('prunes complete records after their retention period.', function()
        local manifest = require('fundo.manifest')
        local fs = require('fundo.fs')

        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 16,
            retention_days = 1,
        })
        open_file_with_history({'one'}, {'one', 'two'})

        local fallback = path.join(archivesDir, path.basename(fn.undofile(file)))
        local recordPaths = {fallback, fallback .. '.base', manifest.path(fallback)}
        for _, recordPath in ipairs(recordPaths) do
            uv.fs_utime(recordPath, 100, 100)
        end

        async(function()
            await(manager:scanArchivesDir())
            done()
        end)
        assert.True(wait())

        for _, recordPath in ipairs(recordPaths) do
            assert.Nil(fs.statSync(recordPath))
        end
    end)

    it('prunes the oldest archive record when the size limit is exceeded.', function()
        local file_a = path.join(tmpdir, 'a.txt')
        local file_b = path.join(tmpdir, 'b.txt')
        local manifest = require('fundo.manifest')
        local fs = require('fundo.fs')

        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 16,
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

        local function touchRecord(currentFile, timestamp)
            local fallback = path.join(archivesDir, path.basename(fn.undofile(currentFile)))
            local recordPaths = {fallback, fallback .. '.base', manifest.path(fallback)}
            local size = 0
            for _, recordPath in ipairs(recordPaths) do
                local stat = fs.statSync(recordPath)
                assert(stat, 'expected record artifact: ' .. recordPath)
                size = size + stat.size
                uv.fs_utime(recordPath, timestamp, timestamp)
            end
            return fallback, recordPaths, size
        end

        local _, recordA = touchRecord(file_a, 100)
        local fallbackB, recordB, sizeB = touchRecord(file_b, 200)
        manager.limitArchivesSize = (sizeB + 1) / 1024 / 1024

        async(function()
            await(manager:scanArchivesDir())
            done()
        end)
        assert.True(wait())

        for _, recordPath in ipairs(recordA) do
            assert.Nil(fs.statSync(recordPath))
        end
        for _, recordPath in ipairs(recordB) do
            assert(fs.statSync(recordPath), 'expected newest record to be kept: ' .. fallbackB)
        end
    end)

    it('runs an overdue idle prune and retries after a scan failure.', function()
        local scanArchivesDir = manager.scanArchivesDir
        local previousScan = uv.hrtime() - 60 * 60 * 1e9 - 1
        local scans = 0
        manager.lastScannedtime = previousScan
        manager.scanArchivesDir = function()
            scans = scans + 1
            if scans == 1 then
                return promise.reject('forced scan failure')
            end
            return promise.resolve()
        end

        local function run_sync()
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
            assert(vim.wait(1000, function() return finished end, 20, false), err)
            return ok, err
        end

        local ok = run_sync()
        assert.False(ok)
        assert.equal(previousScan, manager.lastScannedtime)
        ok = run_sync()
        manager.scanArchivesDir = scanArchivesDir

        assert.True(ok)
        assert.equal(2, scans)
        assert.True(manager.lastScannedtime > previousScan)
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

    it('sets the configured archive directory to owner-only permissions.', function()
        local fs = require('fundo.fs')
        local privateArchivesDir = path.join(tmpdir, 'private-archives')

        require('fundo').setup({
            archives_dir = privateArchivesDir,
            limit_archives_size = 16,
        })

        if not require('fundo.utils').isWindows() then
            assert.equal(448, fs.statSync(privateArchivesDir).mode % 512)
        end
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

    it('retries a failed fallback transfer after the wiped buffer is invalid.', function()
        local fs = require('fundo.fs')
        local writeFileSync = fs.writeFileSync

        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        rawset(fs, 'writeFileSync', function()
            error('archive write failed')
        end)
        vim.cmd('bwipeout!')
        rawset(fs, 'writeFileSync', writeFileSync)

        assert.falsy(manager:get(bufnr))
        assert.False(api.nvim_buf_is_valid(bufnr))
        assert.equal(1, vim.tbl_count(manager.pendingTransfers))

        sync_all()

        assert.equal(0, vim.tbl_count(manager.pendingTransfers))
        assert.are_not.equal(0, #archives())
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
        local writeFileSync = fs.writeFileSync

        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        local u = manager:get(bufnr)
        assert(u, 'expected fundo to track the edited buffer')
        clear_archives()
        rawset(fs, 'writeFileSync', function()
            error('forced archive copy failure')
        end)

        local ok, err = pcall(function()
            u:transferSync()
        end)
        rawset(fs, 'writeFileSync', writeFileSync)

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

    it('replays fallback recovery once for a buffer shown in multiple windows.', function()
        open_file_with_history({'one'}, {'one', 'two'})
        local bufnr = api.nvim_get_current_buf()
        local u = manager:get(bufnr)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'external', 'change'})
        vim.cmd('vsplit')
        local winids = api.nvim_list_wins()
        api.nvim_win_set_cursor(winids[1], {1, 0})
        api.nvim_win_set_cursor(winids[2], {2, 0})
        local original = u.loadFileAndUndo
        local calls = 0
        u.loadFileAndUndo = function(self, winid)
            calls = calls + 1
            return original(self, winid)
        end

        local loaded, reason = u:loadFallBack()

        u.loadFileAndUndo = original
        assert(loaded, reason)
        assert.equal(1, calls)
        assert.same({1, 0}, api.nvim_win_get_cursor(winids[1]))
        assert.same({2, 0}, api.nvim_win_get_cursor(winids[2]))
    end)

    it('completes VimLeave synchronization before the event returns.', function()
        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local u = manager:get(api.nvim_get_current_buf())
        api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
        vim.cmd('write')
        local transferSync = u.transferSync
        local completed = false
        u.transferSync = function(self)
            transferSync(self)
            completed = true
        end

        event:emit('VimLeave')

        u.transferSync = transferSync
        assert.True(completed)
        assert.False(u.isDirty)
    end)

    it('reports sync failures and keeps undo dirty.', function()
        local fs = require('fundo.fs')
        local writeFileSync = fs.writeFileSync

        fn.writefile({'one'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {'one', 'two'})
        vim.cmd('write')

        local u = manager:get(bufnr)
        assert(u, 'expected fundo to track the edited buffer')
        rawset(fs, 'writeFileSync', function()
            error('forced async archive copy failure')
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
        rawset(fs, 'writeFileSync', writeFileSync)

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

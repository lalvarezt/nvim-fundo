local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('recovery integrity.', function()
    local tmpdir

    before_each(function()
        tmpdir = fn.tempname()
        fn.mkdir(tmpdir .. '/undo', 'p')
    end)

    after_each(function()
        fn.delete(tmpdir, 'rf')
    end)

    local function run(body)
        return session.run({
            tmpdir = tmpdir, file = tmpdir .. '/source',
            undo_dir = tmpdir .. '/undo', archives_dir = tmpdir .. '/archives',
            body = body,
        }).lines
    end

    it('captures newer edits when retrying a pointer directory sync failure.', function()
        local lines = run([[
            local api, fn = vim.api, vim.fn
            fn.writefile({'original'}, FILE)
            vim.cmd('edit ' .. fn.fnameescape(FILE))
            api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            local manager, storage, fs = require('fundo.manager'), require('fundo.storage'), require('fundo.fs')
            assert(manager:syncAllSync())
            local u = manager:get(api.nvim_get_current_buf())
            local initial, sync = storage.token(u.fallbackPath), fs.syncDirectorySync
            vim.cmd('let &l:undolevels = &l:undolevels')
            api.nvim_buf_set_lines(0, 0, -1, false, {'pending'})
            fs.syncDirectorySync = function(target)
                if target == storage.directory(u.fallbackPath) and storage.token(u.fallbackPath) ~= initial then
                    error('injected pointer directory sync failure')
                end
                return sync(target)
            end
            assert(not manager:syncAllSync())
            fs.syncDirectorySync = sync
            vim.cmd('let &l:undolevels = &l:undolevels')
            api.nvim_buf_set_lines(0, 0, -1, false, {'newer unsaved work'})
            assert(manager:syncAllSync())
            WriteReport({storage.read(u.fallbackPath).contents:gsub('\n$', ''), fn.readfile(FILE)[1]})
            vim.cmd('quitall!')
        ]])
        assert.same({'newer unsaved work', 'saved'}, lines)
    end)

    it('retries baseline publication after a pointer directory sync failure.', function()
        local lines = run([[
            local fn = vim.fn
            fn.writefile({'original'}, FILE)
            vim.cmd('edit ' .. fn.fnameescape(FILE))
            local manager, storage, fs = require('fundo.manager'), require('fundo.storage'), require('fundo.fs')
            assert(manager:syncAllSync())
            local u = manager:get(vim.api.nvim_get_current_buf())
            local initial, sync = storage.token(u.fallbackPath), fs.syncDirectorySync
            local snapshot = {
                baselineOnly = true, contents = 'new baseline\n', capturedAt = os.time(),
                expectedGeneration = initial,
            }
            fs.syncDirectorySync = function(target)
                if target == storage.directory(u.fallbackPath) and storage.token(u.fallbackPath) ~= initial then
                    error('injected baseline pointer directory sync failure')
                end
                return sync(target)
            end
            local saved = u:saveBaseline(snapshot)
            fs.syncDirectorySync = sync
            assert(not saved)
            local syncCalls = 0
            fs.syncDirectorySync = function(target)
                if target == storage.directory(u.fallbackPath) then syncCalls = syncCalls + 1 end
                return sync(target)
            end
            local retried = u:saveBaseline(snapshot)
            fs.syncDirectorySync = sync
            WriteReport({tostring(retried), tostring(u.generation == storage.token(u.fallbackPath)),
                tostring(syncCalls > 0), (storage.read(u.fallbackPath).contents:gsub('\n$', ''))})
            manager:dispose()
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'true', 'true', 'new baseline'}, lines)
    end)

    for _, stage in ipairs({'undo', 'restore', 'rollback'}) do
        it('rolls back current text after a recovery exception at ' .. stage .. '.', function()
            local lines = run(([=[
                local api, fn = vim.api, vim.fn
                fn.writefile({'original'}, FILE)
                vim.cmd('edit ' .. fn.fnameescape(FILE))
                api.nvim_buf_set_lines(0, 0, -1, false, {'archived'})
                vim.cmd('write')
                local manager = require('fundo.manager')
                assert(manager:syncAllSync())
                local u = manager:get(api.nvim_get_current_buf())
                local archived = assert(require('fundo.storage').read(u.fallbackPath))
                api.nvim_buf_set_lines(0, 0, -1, false, {'current external text'})
                vim.bo.modified = false
                local loadUndo, setLines = u.loadUndo, api.nvim_buf_set_lines
                local stage = %q
                if stage == 'undo' then
                    u.loadUndo = function() error('injected undo exception') end
                else
                    local calls = 0
                    api.nvim_buf_set_lines = function(...)
                        calls = calls + 1
                        if calls == 2 or (stage == 'rollback' and calls > 2 and select(1, ...) == u.bufnr) then
                            error('injected restoration exception')
                        end
                        return setLines(...)
                    end
                end
                local loaded = u:loadFileAndUndo(nil, archived)
                u.loadUndo, api.nvim_buf_set_lines = loadUndo, setLines
                assert(not loaded)
                assert(vim.o.eventignore ~= 'all')
                if stage == 'rollback' then
                    local backup = assert(u.recoveryBackup)
                    assert(fn.readfile(backup.path)[1] == 'current external text')
                    assert(api.nvim_buf_get_lines(backup.bufnr, 0, -1, false)[1] == 'current external text')
                    WriteReport({'current external text', fn.readfile(FILE)[1], backup.path})
                else
                    assert(not vim.bo.modified)
                    WriteReport({BufferText(), fn.readfile(FILE)[1]})
                end
                vim.cmd('quitall!')
            ]=]):format(stage))
            assert.same({'current external text', 'archived'}, {lines[1], lines[2]})
            if stage == 'rollback' then
                assert.equal(1, fn.filereadable(lines[3]))
                assert.same({'current external text'}, fn.readfile(lines[3]))
                fn.delete(lines[3])
            end
        end)
    end

    for _, scenario in ipairs({
        {blocked = false, mode = 'sync'}, {blocked = true, mode = 'sync'},
        {blocked = false, mode = 'async'}, {blocked = true, mode = 'async'},
    }) do
        it('recovers detached history with ' .. scenario.mode .. ' retry blocked=' .. tostring(scenario.blocked) .. '.', function()
            local lines = run(([=[
                local api, fn = vim.api, vim.fn
                local manager, fs = require('fundo.manager'), require('fundo.fs')
                local mode = %q
                local function sync()
                    if mode == 'sync' then return manager:syncAllSync() end
                    local finished, saved = false, false
                    require('fundo').sync():thenCall(function()
                        saved, finished = true, true
                    end, function()
                        finished = true
                    end)
                    assert(vim.wait(1000, function() return finished end))
                    return saved
                end
                fn.writefile({'one'}, FILE)
                vim.cmd('edit ' .. fn.fnameescape(FILE))
                api.nvim_buf_set_lines(0, 0, -1, false, {'two'})
                vim.cmd('write')
                assert(manager:syncAllSync())
                api.nvim_buf_set_lines(0, 0, -1, false, {'three'})
                vim.cmd('write')
                local originalWrite = fs.writeFileSync
                fs.writeFileSync = function() error('archive unavailable') end
                vim.cmd('bwipeout!')
                assert(vim.tbl_count(manager.pendingTransfers) == 1)
                if not %s then fs.writeFileSync = originalWrite end
                fn.writefile({'outside'}, FILE)
                vim.cmd('edit ' .. fn.fnameescape(FILE))
                assert(BufferText() == 'outside' and not vim.bo.modified)
                if %s then
                    assert(not sync())
                    assert(vim.tbl_count(manager.pendingTransfers) == 1)
                    assert(BufferText() == 'outside' and EntryCount() > 0)
                    fs.writeFileSync = originalWrite
                end
                assert(sync())
                assert(vim.tbl_count(manager.pendingTransfers) == 0)
                assert(fn.readfile(FILE)[1] == 'outside')
                vim.cmd('undo')
                local previous = BufferText()
                vim.cmd('undo')
                local older = BufferText()
                vim.cmd('redo')
                vim.cmd('redo')
                WriteReport({previous, older, BufferText()})
                vim.cmd('quitall!')
            ]=]):format(scenario.mode, tostring(scenario.blocked), tostring(scenario.blocked)))
            assert.same({'three', 'two', 'outside'}, lines)

            fn.writefile({'later'}, tmpdir .. '/source')
            lines = run([[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                vim.cmd('undo')
                local previous = BufferText()
                vim.cmd('undo')
                local older = BufferText()
                vim.cmd('redo')
                vim.cmd('redo')
                WriteReport({previous, older, BufferText()})
                vim.cmd('quitall!')
            ]])
            assert.same({'outside', 'three', 'later'}, lines)
        end)
    end

    for _, mode in ipairs({'sync', 'async'}) do
        for _, operation in ipairs({'write', 'modified', 'wipeout', 'file', 'saveas'}) do
            it('preserves edits during blocked recovery with ' .. mode .. ' and ' .. operation .. '.', function()
                local lines = run(([=[
                    local api, fn = vim.api, vim.fn
                    local manager, fs = require('fundo.manager'), require('fundo.fs')
                    fn.writefile({'one'}, FILE)
                    vim.cmd('edit ' .. fn.fnameescape(FILE))
                    api.nvim_buf_set_lines(0, 0, -1, false, {'two'})
                    vim.cmd('write')
                    assert(manager:syncAllSync())
                    api.nvim_buf_set_lines(0, 0, -1, false, {'three'})
                    vim.cmd('write')
                    local write = fs.writeFileSync
                    fs.writeFileSync = function() error('archive unavailable') end
                    vim.cmd('bwipeout!')
                    fn.writefile({'outside'}, FILE)
                    vim.cmd('edit ' .. fn.fnameescape(FILE))
                    api.nvim_buf_set_lines(0, 0, -1, false, {'edit1'})
                    vim.cmd('write')
                    vim.cmd('let &undolevels = &undolevels')
                    api.nvim_buf_set_lines(0, 0, -1, false, {'edit2'})
                    local operation, mode = %q, %q
                    if operation ~= 'modified' then vim.cmd('write') end
                    local target = FILE
                    if operation == 'file' or operation == 'saveas' then
                        target = FILE .. '.renamed'
                        vim.cmd(operation .. ' ' .. fn.fnameescape(target))
                    elseif operation == 'wipeout' then
                        vim.cmd('bwipeout!')
                        vim.cmd('edit ' .. fn.fnameescape(FILE))
                    end
                    fs.writeFileSync = write
                    if mode == 'sync' then
                        assert(manager:syncAllSync())
                    else
                        local done, failure
                        require('fundo').sync():thenCall(function() done = true end, function(err)
                            failure, done = err, true
                        end)
                        assert(vim.wait(1000, function() return done end))
                        assert(not failure, tostring(failure))
                    end
                    assert(vim.tbl_count(manager.pendingTransfers) == 0)
                    assert(vim.bo.modified == (operation == 'modified'))
                    assert(fn.readfile(FILE)[1] == (operation == 'modified' and 'edit1' or 'edit2'))
                    local report = {BufferText()}
                    for _ = 1, 4 do
                        vim.cmd('undo')
                        table.insert(report, BufferText())
                    end
                    for _ = 1, 4 do vim.cmd('redo') end
                    table.insert(report, BufferText())
                    WriteReport(report)
                    vim.cmd('quitall!')
                ]=]):format(operation, mode))
                assert.same({'edit2', 'edit1', 'outside', 'three', 'two', 'edit2'}, lines)

                local renamed = operation == 'file' or operation == 'saveas'
                fn.writefile({'later'}, tmpdir .. '/source' .. (renamed and '.renamed' or ''))
                lines = run(([[
                    local target = FILE .. %q
                    vim.cmd('edit ' .. vim.fn.fnameescape(target))
                    local report = {BufferText()}
                    for _ = 1, 5 do
                        vim.cmd('undo')
                        table.insert(report, BufferText())
                    end
                    WriteReport(report)
                    vim.cmd('quitall!')
                ]]):format(renamed and '.renamed' or ''))
                assert.same({'later', 'edit2', 'edit1', 'outside', 'three', 'two'}, lines)
            end)
        end
    end

    it('keeps both histories untouched when temporary recovery fails before local edits.', function()
        local lines = run([[
            local api, fn = vim.api, vim.fn
            local manager, fs = require('fundo.manager'), require('fundo.fs')
            fn.writefile({'one'}, FILE)
            vim.cmd('edit ' .. fn.fnameescape(FILE))
            api.nvim_buf_set_lines(0, 0, -1, false, {'two'})
            vim.cmd('write')
            assert(manager:syncAllSync())
            api.nvim_buf_set_lines(0, 0, -1, false, {'three'})
            vim.cmd('write')
            local write = fs.writeFileSync
            fs.writeFileSync = function() error('archive unavailable') end
            vim.cmd('bwipeout!')
            fn.writefile({'outside'}, FILE)
            local writefile = fn.writefile
            fn.writefile = function(_, _, flags)
                assert(flags == 'b')
                error('temporary storage unavailable')
            end
            vim.cmd('edit ' .. fn.fnameescape(FILE))
            fn.writefile = writefile
            assert(BufferText() == 'outside' and EntryCount() == 0)
            local pending = vim.tbl_values(manager.pendingTransfers)[1]
            assert(pending.contents == 'three\n')
            api.nvim_buf_set_lines(0, 0, -1, false, {'edit1'})
            vim.cmd('write')
            vim.cmd('let &undolevels = &undolevels')
            api.nvim_buf_set_lines(0, 0, -1, false, {'edit2'})
            vim.cmd('write')
            fs.writeFileSync = write
            assert(not manager:syncAllSync())
            assert(vim.tbl_values(manager.pendingTransfers)[1] == pending)
            local report = {BufferText()}
            vim.cmd('undo')
            table.insert(report, BufferText())
            vim.cmd('undo')
            table.insert(report, BufferText())
            WriteReport(report)
            vim.cmd('quitall!')
        ]])
        assert.same({'edit2', 'edit1', 'outside'}, lines)
    end)

    for _, corruption in ipairs({
        'malformed', 'unsupported-version', 'wrong-path',
        'unknown-baseline-format', 'unknown-snapshot-format', 'invalid-format-type',
    }) do
        it('rejects ' .. corruption .. ' legacy metadata without guessing the baseline format.', function()
            local lines = run(([=[
                local api, fn = vim.api, vim.fn
                local fs, manifest = require('fundo.fs'), require('fundo.manifest')
                fn.writefile({'original'}, FILE)
                vim.cmd('edit ' .. fn.fnameescape(FILE))
                local u = require('fundo.manager'):get(api.nvim_get_current_buf())
                local bomText = '\239\187\191text'
                api.nvim_buf_set_lines(0, 0, -1, false, {bomText})
                assert(u:saveBaseline())
                require('fundo.storage').remove(u.fallbackPath)
                u.generation = false
                assert(u:readBaseline()[1] == bomText)
                local metadata = manifest.path(u.fallbackPath)
                local record = assert(manifest.read(metadata, u.fallbackPath))
                local corruption = %q
                local invalid = '{broken'
                if corruption == 'unsupported-version' then
                    record.version = 999
                    invalid = fn.json_encode(record)
                elseif corruption == 'wrong-path' then
                    record.fallback.path = u.fallbackPath .. '.different'
                    invalid = fn.json_encode(record)
                elseif corruption == 'unknown-baseline-format' then
                    record.baseline_format = 'buffer-lines-v2'
                    invalid = fn.json_encode(record)
                elseif corruption == 'unknown-snapshot-format' then
                    record.snapshot_format = 'buffer-lines-v2'
                    invalid = fn.json_encode(record)
                elseif corruption == 'invalid-format-type' then
                    record.baseline_format = false
                    invalid = fn.json_encode(record)
                end
                fs.writeFileSync(metadata, invalid)
                local rejected = u:readBaseline() == nil
                vim.bo.undolevels = -1
                api.nvim_buf_set_lines(0, 0, -1, false, {'outside'})
                vim.bo.undolevels = 1000
                vim.bo.modified = false
                u:check()
                WriteReport({
                    tostring(rejected), BufferText(), tostring(EntryCount()),
                    tostring(fn.readfile(u.baselinePath, 'b')[1] == bomText),
                    tostring(table.concat(fn.readfile(metadata, 'b'), '\n') == invalid),
                })
                vim.cmd('quitall!')
            ]=]):format(corruption))
            assert.same({'true', 'outside', '0', 'true', 'true'}, lines)
        end)
    end
end)

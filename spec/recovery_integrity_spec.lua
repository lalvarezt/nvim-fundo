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
                    assert(BufferText() == 'outside' and EntryCount() == 0)
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

    for _, corruption in ipairs({
        'malformed', 'unsupported-version', 'wrong-path',
        'unknown-baseline-format', 'unknown-snapshot-format', 'invalid-format-type',
    }) do
        it('rejects ' .. corruption .. ' metadata without guessing the baseline format.', function()
            local lines = run(([=[
                local api, fn = vim.api, vim.fn
                local fs, manifest = require('fundo.fs'), require('fundo.manifest')
                fn.writefile({'original'}, FILE)
                vim.cmd('edit ' .. fn.fnameescape(FILE))
                local u = require('fundo.manager'):get(api.nvim_get_current_buf())
                local bomText = '\239\187\191text'
                api.nvim_buf_set_lines(0, 0, -1, false, {bomText})
                assert(u:saveBaseline())
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

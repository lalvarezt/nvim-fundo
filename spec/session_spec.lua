local fn = vim.fn
local path = require('fundo.fs.path')
local session = dofile('spec/helper/session.lua')

local function map_report(lines)
    local res = {}
    for _, line in ipairs(lines) do
        local key, value = line:match('^([^=]+)=(.*)$')
        if key then
            res[key] = value
        end
    end
    return res
end

describe('closed Neovim sessions.', function()
    local tmpdir
    local archivesDir
    local undoDir
    local file

    before_each(function()
        tmpdir = fn.tempname()
        archivesDir = path.join(tmpdir, 'archives')
        undoDir = path.join(tmpdir, 'undo')
        file = path.join(tmpdir, 'sample.txt')
        fn.mkdir(archivesDir, 'p')
        fn.mkdir(undoDir, 'p')
    end)

    after_each(function()
        fn.delete(tmpdir, 'rf')
    end)

    local function run(body, opts)
        opts = opts or {}
        return session.run({
            tmpdir = tmpdir,
            archives_dir = archivesDir,
            undo_dir = undoDir,
            file = file,
            body = body,
            limit_archives_size = opts.limit_archives_size,
        })
    end

    it('runs FundoSync and reports completion and failure in a clean process.', function()
        fn.writefile({'one'}, file)
        local report = map_report(run([[
            local notices = {}
            vim.notify = function(message, level)
                table.insert(notices, {message = message, level = level})
            end
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'unsaved'})
            local fs = require('fundo.fs')
            local original = fs.writeFileSync
            fs.writeFileSync = function() error('command write failure') end
            vim.cmd('FundoSync')
            assert(vim.wait(1000, function() return #notices == 1 end, 10))
            assert(notices[1].level == vim.log.levels.ERROR)
            assert(notices[1].message:find('command write failure', 1, true))
            local failure = require('fundo').status().last_error
            assert(failure.stage == 'fallback')
            assert(type(failure.time) == 'number')
            local statusOutput = vim.api.nvim_exec('FundoStatus', true)
            assert(statusOutput:find('last error [fallback]', 1, true))
            assert(statusOutput:find('command write failure', 1, true))
            assert(statusOutput:find('failed at:', 1, true))
            local doctorOutput = vim.api.nvim_exec('FundoDoctor', true)
            assert(doctorOutput:find('transfer-error', 1, true))
            assert(doctorOutput:find('command write failure', 1, true))
            fs.writeFileSync = original
            vim.cmd('FundoSync')
            assert(vim.wait(1000, function() return #notices == 2 end, 10))
            assert(notices[2].level == vim.log.levels.INFO)
            assert(require('fundo').status().last_error == nil)
            assert(require('fundo').doctor().ok)
            WriteReport({
                'message=' .. notices[2].message,
                'state=' .. require('fundo').status().state,
                'modified=' .. tostring(vim.bo.modified),
                'source=' .. table.concat(vim.fn.readfile(FILE), '|'),
            })
            vim.cmd('quitall!')
        ]]).lines)
        assert.equal('Fundo sync complete', report.message)
        assert.equal('healthy', report.state)
        assert.equal('true', report.modified)
        assert.equal('one', report.source)
    end)

    local function create_linear_history()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two', 'three'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])
    end

    it('preserves clean opened file contents after an external edit while closed.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.cmd('quitall')
        ]])

        fn.writefile({'external', 'change'}, file)
        local report = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            local entries_before = EntryCount()
            local ok, err = pcall(vim.cmd, 'undo')
            local undo = BufferText()
            local redo_ok, redo_err = pcall(vim.cmd, 'redo')
            WriteReport({
                'before=' .. before,
                'entries_before=' .. tostring(entries_before),
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'undo=' .. undo,
                'redo_ok=' .. tostring(redo_ok),
                'redo_err=' .. tostring(redo_err),
                'redo=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]]).lines)

        assert.equal('external|change', report.before)
        assert.equal('true', report.undo_ok)
        assert.equal('one', report.undo)
        assert.equal('true', report.redo_ok)
        assert.equal('external|change', report.redo)
        assert.is_true(tonumber(report.entries_before) >= 1)
    end)

    it('advances the baseline after repaired external changes are persisted.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.cmd('quitall')
        ]])

        fn.writefile({'two'}, file)
        local first = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            vim.cmd('undo')
            local undo = BufferText()
            vim.cmd('redo')
            WriteReport({
                'before=' .. before,
                'undo=' .. undo,
                'redo=' .. BufferText(),
            })
            vim.cmd('quitall')
        ]]).lines)
        assert.equal('two', first.before)
        assert.equal('one', first.undo)
        assert.equal('two', first.redo)

        fn.writefile({'three'}, file)
        local second = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            vim.cmd('undo')
            local undo = BufferText()
            vim.cmd('redo')
            WriteReport({
                'before=' .. before,
                'undo=' .. undo,
                'redo=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]]).lines)
        assert.equal('three', second.before)
        assert.equal('two', second.undo)
        assert.equal('three', second.redo)
    end)

    it('does not create a synthetic undo step when current contents match the baseline.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.cmd('quitall')
        ]])

        local report = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            local ok, err = pcall(vim.cmd, 'undo')
            WriteReport({
                'before=' .. before,
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'after=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]]).lines)

        assert.equal('one', report.before)
        assert.equal('one', report.after)
    end)

    it('does not create a baseline for files larger than the archive size limit.', function()
        fn.writefile({string.rep('x', 128)}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.cmd('quitall')
        ]], {limit_archives_size = 0.00004})

        assert.equal(0, #fn.glob(path.join(archivesDir, '*.base'), false, true))

        fn.writefile({'external'}, file)
        local report = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            local ok, err = pcall(vim.cmd, 'undo')
            WriteReport({
                'before=' .. before,
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'after=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]], {limit_archives_size = 0.00004}).lines)

        assert.equal('external', report.before)
        assert.equal('external', report.after)
    end)

    it('creates and uses a baseline for files within the archive size limit.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.cmd('quitall')
        ]], {limit_archives_size = 0.001})

        assert.equal(1, #fn.glob(path.join(archivesDir, '*.base'), false, true))

        fn.writefile({'two'}, file)
        local report = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            vim.cmd('undo')
            local undo = BufferText()
            vim.cmd('redo')
            WriteReport({
                'before=' .. before,
                'undo=' .. undo,
                'redo=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]], {limit_archives_size = 0.001}).lines)

        assert.equal('two', report.before)
        assert.equal('one', report.undo)
        assert.equal('two', report.redo)
    end)

    it('drops the baseline when the current file no longer fits the archive size limit.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.cmd('quitall')
        ]], {limit_archives_size = 0.00004})
        assert.equal(1, #fn.glob(path.join(archivesDir, '*.base'), false, true))

        fn.writefile({string.rep('x', 128)}, file)
        local oversized = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            vim.cmd('undo')
            local undo = BufferText()
            vim.cmd('redo')
            WriteReport({
                'before=' .. before,
                'undo=' .. undo,
                'redo=' .. BufferText(),
            })
            vim.cmd('quitall')
        ]], {limit_archives_size = 0.00004}).lines)
        assert.equal(string.rep('x', 128), oversized.before)
        assert.equal('one', oversized.undo)
        assert.equal(string.rep('x', 128), oversized.redo)
        assert.equal(0, #fn.glob(path.join(archivesDir, '*.base'), false, true))

        fn.writefile({'three'}, file)
        local report = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            local ok, err = pcall(vim.cmd, 'undo')
            WriteReport({
                'before=' .. before,
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'after=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]], {limit_archives_size = 0.00004}).lines)

        assert.equal('three', report.before)
        assert.are_not.equal('one', report.after)
    end)

    local function assert_linear_recovery(expected_before)
        local report = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local out = {'before=' .. BufferText(), 'entries_before=' .. tostring(EntryCount())}
            local ok1, err1 = pcall(vim.cmd, 'undo')
            table.insert(out, 'undo1_ok=' .. tostring(ok1))
            table.insert(out, 'undo1_err=' .. tostring(err1))
            table.insert(out, 'undo1=' .. BufferText())
            local ok2, err2 = pcall(vim.cmd, 'undo')
            table.insert(out, 'undo2_ok=' .. tostring(ok2))
            table.insert(out, 'undo2_err=' .. tostring(err2))
            table.insert(out, 'undo2=' .. BufferText())
            local ok3, err3 = pcall(vim.cmd, 'redo')
            table.insert(out, 'redo_ok=' .. tostring(ok3))
            table.insert(out, 'redo_err=' .. tostring(err3))
            table.insert(out, 'redo=' .. BufferText())
            WriteReport(out)
            vim.cmd('quitall!')
        ]]).lines)

        assert.equal(expected_before, report.before)
        assert.equal('true', report.undo1_ok)
        assert.equal('one|two|three', report.undo1)
        assert.equal('true', report.undo2_ok)
        assert.equal('one|two', report.undo2)
        assert.equal('true', report.redo_ok)
        assert.equal('one|two|three', report.redo)
        return report
    end

    it('preserves linear undo history after an external edit while closed.', function()
        create_linear_history()

        fn.writefile({'external', 'change'}, file)
        assert_linear_recovery('external|change')
    end)

    for _, reload in ipairs({'checktime', 'edit!'}) do
        it('persists native reload history after ' .. reload .. ' before a later external change.', function()
            fn.writefile({'one'}, file)
            run(([[
                vim.o.undoreload = 10000
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
                vim.cmd('write')
                require('fundo.manager'):syncAllSync()
                vim.fn.writefile({'one', 'two', 'three'}, FILE)
                vim.cmd(%q)
                assert(BufferText() == 'one|two|three')
                assert(not vim.bo.modified)
                vim.cmd('quitall!')
            ]]):format(reload))

            fn.writefile({'external', 'change'}, file)
            assert_linear_recovery('external|change')
        end)
    end

    for _, operation in ipairs({'delete', 'rename'}) do
        it('persists undo on exit after the open file is externally ' .. operation .. 'd.', function()
            fn.writefile({'one'}, file)
            run(([[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
                vim.cmd('write')
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two', 'three'})
                vim.cmd('write')
                %s
                vim.cmd('quitall!')
            ]]):format(operation == 'delete' and 'vim.fn.delete(FILE)'
                or 'assert(vim.loop.fs_rename(FILE, FILE .. ".moved"))'))
            assert.equal(0, fn.filereadable(file))
            fn.writefile({'external', 'change'}, file)
            assert_linear_recovery('external|change')
        end)
    end

    it('preserves linear undo history after an external append while closed.', function()
        create_linear_history()

        fn.writefile({'external'}, file, 'a')

        assert_linear_recovery('one|two|three|external')
    end)

    it('preserves linear undo history after an external truncate while closed.', function()
        create_linear_history()

        fn.writefile({'one'}, file)

        assert_linear_recovery('one')
    end)

    it('handles an empty-file external overwrite while closed.', function()
        create_linear_history()

        fn.writefile({}, file)

        assert_linear_recovery('')
    end)

    it('preserves linear undo history after multiple external overwrites while closed.', function()
        create_linear_history()

        fn.writefile({'external', 'version-a'}, file)
        fn.writefile({'external', 'version-b'}, file)

        assert_linear_recovery('external|version-b')
    end)

    local function create_branched_history()
        fn.writefile({'base'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'base', 'main1'})
            vim.cmd('write')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'base', 'main1', 'main2'})
            vim.cmd('write')
            vim.cmd('undo')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'base', 'branch1'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])
    end

    local function assert_branch_recovery(expected_before)
        local report = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local out = {'before=' .. BufferText(), 'entries_before=' .. tostring(EntryCount())}
            local ok1, err1 = pcall(vim.cmd, 'undo')
            table.insert(out, 'undo1_ok=' .. tostring(ok1))
            table.insert(out, 'undo1_err=' .. tostring(err1))
            table.insert(out, 'undo1=' .. BufferText())
            local ok2, err2 = pcall(vim.cmd, 'undo')
            table.insert(out, 'undo2_ok=' .. tostring(ok2))
            table.insert(out, 'undo2_err=' .. tostring(err2))
            table.insert(out, 'undo2=' .. BufferText())
            local ok3, err3 = pcall(vim.cmd, 'redo')
            table.insert(out, 'redo_ok=' .. tostring(ok3))
            table.insert(out, 'redo_err=' .. tostring(err3))
            table.insert(out, 'redo=' .. BufferText())
            table.insert(out, 'entries_after=' .. tostring(EntryCount()))
            WriteReport(out)
            vim.cmd('quitall!')
        ]]).lines)

        assert.equal(expected_before, report.before)
        assert.is_true(tonumber(report.entries_before) >= 3)
        assert.equal('true', report.undo1_ok)
        assert.equal('base|branch1', report.undo1)
        assert.equal('true', report.undo2_ok)
        assert.equal('base|main1', report.undo2)
        assert.equal('true', report.redo_ok)
        assert.equal('base|branch1', report.redo)
        assert.is_true(tonumber(report.entries_after) >= 3)
    end

    it('preserves a branched undo tree after an external edit while closed.', function()
        create_branched_history()

        fn.writefile({'external', 'change'}, file)
        assert_branch_recovery('external|change')
    end)

    it('preserves a branched undo tree after an external append while closed.', function()
        create_branched_history()

        fn.writefile({'external'}, file, 'a')

        assert_branch_recovery('base|branch1|external')
    end)

    it('preserves history across outside, inside, outside edits in separate sessions.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])

        fn.writefile({'external', 'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local ok, err = pcall(vim.cmd, 'undo')
            if not ok then
                error(err)
            end
            vim.cmd('redo')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'external', 'one', 'inside'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])

        fn.writefile({'external', 'change'}, file)
        local report = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local out = {'before=' .. BufferText(), 'entries_before=' .. tostring(EntryCount())}
            local ok, err = pcall(vim.cmd, 'undo')
            table.insert(out, 'undo_ok=' .. tostring(ok))
            table.insert(out, 'undo_err=' .. tostring(err))
            table.insert(out, 'undo=' .. BufferText())
            local redo_ok, redo_err = pcall(vim.cmd, 'redo')
            table.insert(out, 'redo_ok=' .. tostring(redo_ok))
            table.insert(out, 'redo_err=' .. tostring(redo_err))
            table.insert(out, 'redo=' .. BufferText())
            table.insert(out, 'entries_after=' .. tostring(EntryCount()))
            WriteReport(out)
            vim.cmd('quitall!')
        ]]).lines)

        assert.equal('external|change', report.before)
        assert.equal('true', report.undo_ok)
        assert.equal('external|one|inside', report.undo)
        assert.equal('true', report.redo_ok)
        assert.equal('external|change', report.redo)
        assert.is_true(tonumber(report.entries_before) >= 2)
        assert.is_true(tonumber(report.entries_after) >= 2)
    end)

    it('handles missing or corrupted recovery artifacts conservatively.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])

        local undoFiles = fn.glob(path.join(undoDir, '*'), false, true)
        for _, undoFile in ipairs(undoFiles) do
            fn.delete(undoFile)
        end
        fn.writefile({'external', 'missing-undo'}, file)
        local missingUndo = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            local ok, err = pcall(vim.cmd, 'undo')
            WriteReport({
                'before=' .. before,
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'after=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]]).lines)
        assert.equal('external|missing-undo', missingUndo.before)
        assert.equal('true', missingUndo.undo_ok)
        assert.equal('one|two', missingUndo.after)

        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])
        local archives = fn.glob(path.join(archivesDir, '*'), false, true)
        for _, archive in ipairs(archives) do
            fn.delete(archive)
        end
        fn.writefile({'external', 'missing-archive'}, file)
        local missingArchive = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            local ok, err = pcall(vim.cmd, 'undo')
            WriteReport({
                'before=' .. before,
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'after=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]]).lines)
        assert.equal('external|missing-archive', missingArchive.before)
        assert.equal('true', missingArchive.undo_ok)
        assert.equal('one|two', missingArchive.after)

        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])
        archives = fn.glob(path.join(archivesDir, '*'), false, true)
        for _, archive in ipairs(archives) do
            if not archive:match('%.base$') then
                fn.delete(archive)
            end
        end
        fn.writefile({'external', 'missing-fallback-with-baseline'}, file)
        local missingFallbackWithBaseline = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            local ok, err = pcall(vim.cmd, 'undo')
            WriteReport({
                'before=' .. before,
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'after=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]]).lines)
        assert.equal('external|missing-fallback-with-baseline', missingFallbackWithBaseline.before)
        assert.equal('true', missingFallbackWithBaseline.undo_ok)
        assert.equal('one|two', missingFallbackWithBaseline.after)

        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])
        undoFiles = fn.glob(path.join(undoDir, '*'), false, true)
        for _, undoFile in ipairs(undoFiles) do
            fn.writefile({'not an undo file'}, undoFile)
        end
        fn.writefile({'external', 'corrupt-undo'}, file)
        local corruptUndo = map_report(run([[
            local edit_ok, edit_err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(FILE))
            local out = {
                'edit_ok=' .. tostring(edit_ok),
                'edit_err=' .. tostring(edit_err),
            }
            table.insert(out, 'before=' .. BufferText())
            local undo_ok, undo_err = pcall(vim.cmd, 'undo')
            table.insert(out, 'undo_ok=' .. tostring(undo_ok))
            table.insert(out, 'undo_err=' .. tostring(undo_err))
            table.insert(out, 'after=' .. BufferText())
            local redo_ok, redo_err = pcall(vim.cmd, 'redo')
            table.insert(out, 'redo_ok=' .. tostring(redo_ok))
            table.insert(out, 'redo_err=' .. tostring(redo_err))
            table.insert(out, 'redo=' .. BufferText())
            WriteReport(out)
            vim.cmd('quitall!')
        ]]).lines)
        assert.equal('false', corruptUndo.edit_ok)
        assert.truthy(corruptUndo.edit_err:match('E823'))
        assert.equal('external|corrupt-undo', corruptUndo.before)
        assert.equal('true', corruptUndo.undo_ok)
        assert.equal('one|two', corruptUndo.after)
        assert.equal('true', corruptUndo.redo_ok)
        assert.equal('external|corrupt-undo', corruptUndo.redo)
    end)

    it('recreates a missing fallback archive from native undo when the file is unchanged.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])

        local archives = fn.glob(path.join(archivesDir, '*'), false, true)
        assert.are_not.equal(0, #archives)
        for _, archive in ipairs(archives) do
            fn.delete(archive)
        end

        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.cmd('quitall')
        ]])

        assert.are_not.equal(0, #fn.glob(path.join(archivesDir, '*'), false, true))
    end)

    it('recovers the committed generation when compatibility archives are stale.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])

        local archives = fn.glob(path.join(archivesDir, '*'), false, true)
        assert.are_not.equal(0, #archives)
        for _, archive in ipairs(archives) do
            fn.writefile({'stale', 'archive'}, archive)
        end

        fn.writefile({'external', 'change'}, file)
        local report = map_report(run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local before = BufferText()
            local ok, err = pcall(vim.cmd, 'undo')
            WriteReport({
                'before=' .. before,
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'after=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]]).lines)

        assert.equal('external|change', report.before)
        assert.equal('one|two', report.after)
    end)
end)

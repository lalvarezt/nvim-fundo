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

    local function run(body)
        return session.run({
            tmpdir = tmpdir,
            archives_dir = archivesDir,
            undo_dir = undoDir,
            file = file,
            body = body,
        })
    end

    it('preserves linear undo history after an external edit while closed.', function()
        fn.writefile({'one'}, file)
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two'})
            vim.cmd('write')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two', 'three'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])

        fn.writefile({'external', 'change'}, file)
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

        assert.equal('external|change', report.before)
        assert.equal('true', report.undo1_ok)
        assert.equal('one|two|three', report.undo1)
        assert.equal('true', report.undo2_ok)
        assert.equal('one|two', report.undo2)
        assert.equal('true', report.redo_ok)
        assert.equal('one|two|three', report.redo)
    end)

    it('preserves a branched undo tree after an external edit while closed.', function()
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

        fn.writefile({'external', 'change'}, file)
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

        assert.equal('external|change', report.before)
        assert.is_true(tonumber(report.entries_before) >= 3)
        assert.equal('true', report.undo1_ok)
        assert.equal('base|branch1', report.undo1)
        assert.equal('true', report.undo2_ok)
        assert.equal('base|main1', report.undo2)
        assert.equal('true', report.redo_ok)
        assert.equal('base|branch1', report.redo)
        assert.is_true(tonumber(report.entries_after) >= 3)
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
            local out = {'before=' .. BufferText()}
            local ok, err = pcall(vim.cmd, 'undo')
            table.insert(out, 'undo_ok=' .. tostring(ok))
            table.insert(out, 'undo_err=' .. tostring(err))
            table.insert(out, 'undo=' .. BufferText())
            WriteReport(out)
            vim.cmd('quitall!')
        ]]).lines)

        assert.equal('external|change', report.before)
        assert.equal('true', report.undo_ok)
        assert.equal('external|one|inside', report.undo)
    end)

    it('fails safely when recovery artifacts are missing or corrupted.', function()
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
            local ok, err = pcall(vim.cmd, 'undo')
            WriteReport({
                'before=' .. BufferText(),
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'after=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]]).lines)
        assert.equal('external|missing-undo', missingUndo.before)
        assert.equal('true', missingUndo.undo_ok)

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
            local ok, err = pcall(vim.cmd, 'undo')
            WriteReport({
                'before=' .. BufferText(),
                'undo_ok=' .. tostring(ok),
                'undo_err=' .. tostring(err),
                'after=' .. BufferText(),
            })
            vim.cmd('quitall!')
        ]]).lines)
        assert.equal('external|missing-archive', missingArchive.before)
        assert.equal('true', missingArchive.undo_ok)

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
            if edit_ok then
                local ok, err = pcall(vim.cmd, 'undo')
                table.insert(out, 'before=' .. BufferText())
                table.insert(out, 'undo_ok=' .. tostring(ok))
                table.insert(out, 'undo_err=' .. tostring(err))
                table.insert(out, 'after=' .. BufferText())
            end
            WriteReport(out)
            vim.cmd('quitall!')
        ]]).lines)
        assert.equal('false', corruptUndo.edit_ok)
        assert.truthy(corruptUndo.edit_err:match('E823'))
    end)
end)

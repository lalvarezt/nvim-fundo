local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('durable pending recovery.', function()
    local dir
    before_each(function()
        dir = fn.tempname()
        fn.mkdir(dir .. '/undo', 'p')
        fn.writefile({'original'}, dir .. '/source.txt')
    end)
    after_each(function() fn.delete(dir, 'rf') end)
    local function run(body)
        return session.run({tmpdir = dir, file = dir .. '/source.txt',
            archives_dir = dir .. '/archives', undo_dir = dir .. '/undo', body = body}).lines
    end

    local outage = [[
        local fs, config = require('fundo.fs'), require('fundo.config')
        local write = fs.writeFileSync
        fs.writeFileSync = function(target, ...)
            if vim.startswith(target, config.archives_dir .. '/') then error('archive outage') end
            return write(target, ...)
        end
    ]]
    local firstDraft = [[
        vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
        vim.cmd('write')
        assert(require('fundo.manager'):syncAllSync())
        vim.cmd('let &l:undolevels = &l:undolevels')
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {'unsaved work'})
    ]] .. outage .. [[
        assert(not require('fundo.manager'):syncAllSync())
    ]]

    for _, event in ipairs({'unload', 'unreadable pointer', 'exit'}) do
        it('recovers an unsaved edit after an archive outage and ' .. event .. '.', function()
            local reopen = [[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                local text = BufferText()
                if RestoreArchive then RestoreArchive() end
                assert(require('fundo.manager'):syncAllSync())
                vim.cmd('undo')
                WriteReport({text, BufferText()})
                vim.cmd('quitall!')
            ]]
            local result
            if event == 'exit' then
                run(firstDraft .. [[vim.cmd('quitall!')]])
                result = run(reopen)
            elseif event == 'unreadable pointer' then
                result = run(firstDraft .. [[
                    vim.cmd('bwipeout!')
                    local storage = require('fundo.storage')
                    local token = storage.token
                    storage.token = function() error('pointer unavailable') end
                    function RestoreArchive() storage.token, fs.writeFileSync = token, write end
                ]] .. reopen)
            else
                result = run(firstDraft .. [[
                    vim.cmd('bwipeout!')
                    fs.writeFileSync = write
                ]] .. reopen)
            end
            assert.same({'saved', 'unsaved work'}, result)
        end)
    end

    it('replays drafts in capture order when their journals were written in reverse.', function()
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
            local journal = require('fundo.journal')
            local second = os.time()
            os.time = function() return second end
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'older'})
            local older = u:transferSnapshot()
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'newer'})
            local newer = u:transferSnapshot()
            journal.write(newer)
            journal.write(older)
            require('fundo.storage').retain(older, newer)
            os.exit(0)
        ]])
        local result = run([[
            local manager = require('fundo.manager')
            local pending = vim.tbl_values(manager.pendingTransfers)[1]
            assert(manager:syncAllSync())
            WriteReport({(require('fundo.storage').read(pending.fallbackPath).contents:gsub('\n$', ''))})
            vim.cmd('quitall!')
        ]])
        assert.same({'newer'}, result)
    end)

    it('journals new edits when an archive outage continues after restart.', function()
        run(firstDraft .. [[vim.cmd('quitall!')]])
        run(outage .. [[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'second draft'})
            vim.cmd('quitall!')
        ]])
        local drafts = run([[
            local saved = {}
            for _, capture in ipairs(require('fundo.journal').list(require('fundo.config').archives_dir)) do
                assert(capture.undoContents)
                saved[#saved + 1] = capture.contents:gsub('\n$', '')
            end
            table.sort(saved)
            WriteReport(saved)
            vim.cmd('quitall!')
        ]])
        assert.same({'second draft', 'unsaved work'}, drafts)
    end)

    it('publishes an unchanged pending baseline after an archive outage and editor exit.', function()
        local first = run([[
            require('fundo.storage').publish = function() error('baseline archive outage') end
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local ok = require('fundo.manager'):syncAllSync()
            local records = require('fundo.journal').list(require('fundo.config').archives_dir, true)
            WriteReport({tostring(ok), tostring(#records), tostring(records[1].baselineOnly)})
            vim.cmd('quitall!')
        ]])
        assert.same({'false', '1', 'true'}, first)
        local second = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local manager = require('fundo.manager')
            local u = manager:get(vim.api.nvim_get_current_buf())
            assert(manager:syncAllSync())
            local record = assert(require('fundo.storage').read(u.fallbackPath))
            local records = require('fundo.journal').list(require('fundo.config').archives_dir, true)
            WriteReport({BufferText(), tostring(EntryCount()), tostring(vim.bo.modified),
                tostring(u.pendingRecovery == nil), tostring(record.baselineOnly), tostring(#records)})
            vim.cmd('quitall!')
        ]])
        assert.same({'original', '0', 'false', 'true', 'true', '0'}, second)
    end)

    it('retains text and diagnostics when undo capture fails during unload.', function()
        local first = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            local manager = require('fundo.manager')
            assert(manager:syncAllSync())
            local bufnr = vim.api.nvim_get_current_buf()
            local u = manager:get(bufnr)
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'uncaptured work'})
            u.saveUndo = function() return false, 'undo capture outage' end
            vim.cmd('enew!')
            vim.cmd('bunload! ' .. bufnr)
            local records = require('fundo.journal').list(require('fundo.config').archives_dir, true)
            WriteReport({tostring(manager:get(bufnr) == nil), tostring(require('fundo').doctor().ok),
                records[1] and records[1].contents:gsub('\n$', '') or 'missing',
                require('fundo').status(FILE).last_error and 'failure retained' or 'missing error'})
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'false', 'uncaptured work', 'failure retained'}, first)
        local second = run([[
            local records = require('fundo.journal').list(require('fundo.config').archives_dir, true)
            local candidates = require('fundo').recovery_candidates(FILE)
            local id
            for _, candidate in ipairs(candidates) do if candidate.text_only then id = candidate.id end end
            local opened = require('fundo').recover(id, FILE)
            local text = table.concat(vim.api.nvim_buf_get_lines(opened.bufnr, 0, -1, false), '|')
            WriteReport({text, tostring(records[1].textOnly),
                tostring(require('fundo').doctor().ok)})
            vim.cmd('quitall!')
        ]])
        assert.same({'uncaptured work', 'true', 'false'}, second)
    end)

    it('preserves the text read before a failed undo capture changes the buffer.', function()
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'original draft'})
            local u = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
            local save = u.saveUndo
            u.saveUndo = function()
                vim.api.nvim_buf_set_lines(0, 0, -1, false, {'changed during capture'})
                return false, 'capture interrupted'
            end
            local ok = pcall(u.transferSync, u)
            u.saveUndo = save
            WriteReport({tostring(ok), (u.captureFailure.contents:gsub('\n$', ''))})
            vim.cmd('quitall!')
        ]])
        assert.same({'false', 'original draft'}, result)
    end)
end)

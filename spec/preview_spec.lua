local fn = vim.fn
local path = require('fundo.fs.path')
local session = dofile('spec/helper/session.lua')

describe('recovered change preview.', function()
    local tmpdir, file
    before_each(function()
        tmpdir = fn.tempname()
        file = path.join(tmpdir, 'source.txt')
        fn.mkdir(path.join(tmpdir, 'undo'), 'p')
        fn.writefile({'original'}, file)
    end)
    after_each(function() fn.delete(tmpdir, 'rf') end)

    local function run(body)
        return session.run({
            tmpdir = tmpdir, archives_dir = path.join(tmpdir, 'archives'),
            undo_dir = path.join(tmpdir, 'undo'), file = file, body = body,
        }).lines
    end

    for _, history in ipairs({false, true}) do
        it('preserves the source and recovery pair with native history=' .. tostring(history) .. '.', function()
            run(([[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                if %s then
                    vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
                    vim.cmd('write')
                end
                vim.cmd('quitall!')
            ]]):format(tostring(history)))
            fn.writefile({'outside'}, file)
            local result = run(([[
                local api, fundo = vim.api, require('fundo')
                local delivered
                api.nvim_create_autocmd('User', {pattern = 'FundoRecovered', callback = function(event)
                    delivered = event.data
                    event.data.before[1] = 'handler mutation'
                end})
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                local source, sourceTab = api.nvim_get_current_buf(), api.nvim_get_current_tabpage()
                assert(vim.wait(1000, function() return delivered ~= nil end))
                local recovery = fundo.recovery()
                assert(recovery.before[1] == %q and recovery.after[1] == 'outside')
                recovery.before[1] = 'caller mutation'
                assert(require('fundo.manager'):syncAllSync())
                assert(fundo.recovery().before[1] == %q)
                api.nvim_buf_set_lines(source, 0, -1, false, {'local edits'})
                local tree = vim.fn.undotree()
                local tick, modified = api.nvim_buf_get_changedtick(source), vim.bo[source].modified
                local preview = fundo.preview()
                assert(api.nvim_buf_get_lines(preview.before_buffer, 0, -1, false)[1] == %q)
                assert(api.nvim_buf_get_lines(preview.after_buffer, 0, -1, false)[1] == 'local edits')
                for _, buffer in ipairs({preview.before_buffer, preview.after_buffer}) do
                    assert(vim.bo[buffer].readonly and not vim.bo[buffer].modifiable)
                    assert(not vim.bo[buffer].undofile and vim.bo[buffer].buftype == 'nofile')
                end
                assert(vim.wo[preview.before_window].diff and vim.wo[preview.after_window].diff)
                vim.cmd('tabclose!')
                assert(api.nvim_get_current_tabpage() == sourceTab)
                assert(api.nvim_get_current_buf() == source)
                assert(api.nvim_buf_get_changedtick(source) == tick and vim.bo[source].modified == modified)
                local afterTree = vim.fn.undotree()
                -- Switching buffers finalizes an open undo block, but must not
                -- move the undo position or add, remove, or rewrite entries.
                assert(afterTree.seq_cur == tree.seq_cur and afterTree.seq_last == tree.seq_last)
                assert(vim.deep_equal(afterTree.entries, tree.entries))
                assert(fundo.recovery().after[1] == 'outside')
                WriteReport({'ok'})
                vim.cmd('quitall!')
            ]]):format(history and 'saved' or 'original', history and 'saved' or 'original', history and 'saved' or 'original'))
            assert.same({'ok'}, result)
        end)
    end

    it('rejects preview when no external change was recovered.', function()
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local tabs = #vim.api.nvim_list_tabpages()
            assert(require('fundo').recovery() == nil)
            assert(not pcall(vim.cmd, 'FundoPreview'))
            assert(#vim.api.nvim_list_tabpages() == tabs and BufferText() == 'original')
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
    end)
end)

local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('editing workflows across restart.', function()
    local dir
    before_each(function()
        dir = fn.tempname()
        fn.mkdir(dir .. '/undo', 'p')
        fn.writefile({'original'}, dir .. '/source.txt')
    end)
    after_each(function() fn.delete(dir, 'rf') end)

    local function run(body)
        return session.run({
            tmpdir = dir, file = dir .. '/source.txt', undo_dir = dir .. '/undo',
            archives_dir = dir .. '/archives', body = body,
        }).lines
    end

    it('syncs hidden unsaved work without writing either source file.', function()
        run([[
            vim.o.swapfile = false
            vim.o.hidden = true
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            vim.cmd('let &l:undolevels = &l:undolevels')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'hidden draft'})
            local hidden = vim.api.nvim_get_current_buf()
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE .. '.other'))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'visible draft'})
            local finished, failure = false, nil
            require('fundo').sync():thenCall(function() finished = true end, function(err)
                failure = err
                finished = true
            end)
            assert(vim.wait(1000, function() return finished end, 10))
            assert(not failure, tostring(failure))
            assert(vim.bo[hidden].modified and vim.bo.modified)
            assert(vim.fn.readfile(FILE)[1] == 'saved')
            assert(vim.fn.filereadable(FILE .. '.other') == 0)
            os.exit(0)
        ]])
        local result = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(BufferText() == 'saved')
            vim.cmd('undo')
            assert(BufferText() == 'hidden draft')
            vim.cmd('undo')
            assert(BufferText() == 'saved')
            vim.cmd('undo')
            assert(BufferText() == 'original')
            for _ = 1, 3 do vim.cmd('redo') end
            assert(BufferText() == 'saved')
            vim.cmd('edit! ' .. vim.fn.fnameescape(FILE .. '.other'))
            assert(BufferText() == '')
            vim.cmd('undo')
            assert(BufferText() == 'visible draft')
            vim.cmd('redo')
            assert(BufferText() == '')
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
        assert.same({'saved'}, fn.readfile(dir .. '/source.txt'))
        assert.equal(0, fn.filereadable(dir .. '/source.txt.other'))
    end)

    it('keeps independent histories after saveas and further edits to both files.', function()
        run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'shared'})
            vim.cmd('write')
            vim.cmd('saveas ' .. vim.fn.fnameescape(FILE .. '.copy'))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'copy only'})
            vim.cmd('write')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'source only'})
            vim.cmd('write')
            vim.cmd('quitall')
        ]])
        fn.writefile({'outside source'}, dir .. '/source.txt')
        fn.writefile({'outside copy'}, dir .. '/source.txt.copy')
        local result = run([[
            for _, case in ipairs({{FILE, 'source only', 'outside source'},
                {FILE .. '.copy', 'copy only', 'outside copy'}}) do
                vim.cmd('edit! ' .. vim.fn.fnameescape(case[1]))
                assert(BufferText() == case[3])
                vim.cmd('undo')
                assert(BufferText() == case[2])
                vim.cmd('undo')
                assert(BufferText() == 'shared')
                vim.cmd('redo')
                vim.cmd('redo')
                assert(BufferText() == case[3])
            end
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
        assert.same({'outside source'}, fn.readfile(dir .. '/source.txt'))
        assert.same({'outside copy'}, fn.readfile(dir .. '/source.txt.copy'))
    end)
end)

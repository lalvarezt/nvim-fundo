local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('editor input across checkpoints.', function()
    local dir
    before_each(function()
        dir = fn.tempname()
        fn.mkdir(dir .. '/undo', 'p')
    end)
    after_each(function() fn.delete(dir, 'rf') end)

    local cases = {
        {
            name = 'Replace mode and backspacing', initial = {'abcdefghij', 'second line'},
            steps = {
                {keys = 'gg0RXYZ', lines = {'XYZdefghij', 'second line'}, mode = 'R', seq = 1},
                {keys = '<BS><BS>12', lines = {'X12defghij', 'second line'}, mode = 'R', seq = 1},
                {keys = '<Esc>u', lines = {'abcdefghij', 'second line'}, mode = 'n', seq = 0},
                {keys = '<C-r>', lines = {'X12defghij', 'second line'}, mode = 'n', seq = 1},
            },
        },
        {
            name = 'visual block insertion', initial = {'one', 'two', 'three'},
            steps = {
                {keys = 'gg0<C-v>jjIprefix', lines = {'prefixone', 'two', 'three'}, mode = 'i', seq = 1},
                {keys = '-continued-', lines = {'prefix-continued-one', 'two', 'three'}, mode = 'i', seq = 1},
                {keys = '<Esc>', lines = {'prefix-continued-one', 'prefix-continued-two', 'prefix-continued-three'}, mode = 'n'},
                {keys = 'u', lines = {'one', 'two', 'three'}, mode = 'n', seq = 0},
                {keys = '<C-r>', lines = {'prefix-continued-one', 'prefix-continued-two', 'prefix-continued-three'}, mode = 'n', seq = 1},
            },
        },
        {
            name = 'keyword completion', initial = {'alpha alphabet alpine', 'tail'},
            steps = {
                {keys = 'Goalp', lines = {'alpha alphabet alpine', 'tail', 'alp'}, mode = 'i'},
                {keys = '<C-n>', lines = {'alpha alphabet alpine', 'tail', 'alp'}, mode = 'ic'},
                {keys = '<C-n>', lines = {'alpha alphabet alpine', 'tail', 'alpha'}, mode = 'ic'},
                {keys = '<C-y> completed', lines = {'alpha alphabet alpine', 'tail', 'alpha completed'}, mode = 'i', seq = 1},
                {keys = '<Esc>u', lines = {'alpha alphabet alpine', 'tail'}, mode = 'n', seq = 0},
                {keys = '<C-r>', lines = {'alpha alphabet alpine', 'tail', 'alpha completed'}, mode = 'n', seq = 1},
            },
        },
        {
            name = 'macro recording and playback', initial = {'one', 'two', 'three'},
            steps = {
                {keys = 'gg0qaCmacro', lines = {'macro', 'two', 'three'}, mode = 'i'},
                {keys = ' continued', lines = {'macro continued', 'two', 'three'}, mode = 'i', seq = 1},
                {keys = '<Esc>qj0@a', lines = {'macro continued', 'macro continued', 'three'}, mode = 'n', seq = 2},
                {keys = 'u', lines = {'macro continued', 'two', 'three'}, mode = 'n', seq = 1},
                {keys = '<C-r>', lines = {'macro continued', 'macro continued', 'three'}, mode = 'n', seq = 2},
            },
        },
        {
            name = 'normal commands inside Insert mode', initial = {'one two three', 'other text'},
            steps = {
                {keys = 'gg0A draft', lines = {'one two three draft', 'other text'}, mode = 'i'},
                {keys = '<C-o>b', lines = {'one two three draft', 'other text'}, mode = 'i'},
                {keys = 'word ', lines = {'one two three word draft', 'other text'}, mode = 'i', seq = 2},
                {keys = '<C-w>', lines = {'one two three draft', 'other text'}, mode = 'i', seq = 3},
                {keys = '<Esc>u', lines = {'one two three word draft', 'other text'}, mode = 'n', seq = 2},
                {keys = 'u', lines = {'one two three draft', 'other text'}, mode = 'n', seq = 1},
            },
        },
        {
            name = 'undo branches', initial = {'original', 'second'},
            steps = {
                {keys = 'gg0Cbranch one', lines = {'branch one', 'second'}, mode = 'i'},
                {keys = '<Esc>u', lines = {'original', 'second'}, mode = 'n', seq = 0},
                {keys = 'Cbranch two', lines = {'branch two', 'second'}, mode = 'i', seq = 2},
                {keys = '<Esc>u', lines = {'original', 'second'}, mode = 'n', seq = 0},
                {keys = 'g+', lines = {'branch one', 'second'}, mode = 'n', seq = 1},
            },
        },
        {
            name = 'cancelled and accepted substitute previews', initial = {'one one', 'two one'},
            steps = {
                {keys = ':%s/one/preview/g', lines = {'one one', 'two one'}, mode = 'c', min_ms = 100},
                {keys = '<Esc>', lines = {'one one', 'two one'}, mode = 'n', seq = 0},
                {keys = ':%s/one/replaced/g<CR>', lines = {'replaced replaced', 'two replaced'}, mode = 'n', seq = 1},
                {keys = 'u', lines = {'one one', 'two one'}, mode = 'n', seq = 0},
                {keys = '<C-r>', lines = {'replaced replaced', 'two replaced'}, mode = 'n', seq = 1},
            },
        },
        {
            name = 'writing from Insert mode', initial = {'original'}, source = {'before write'},
            steps = {
                {keys = 'gg0Cbefore write', lines = {'before write'}, mode = 'i'},
                {keys = '<C-o>:write<CR>', lines = {'before write'}, mode = 'i', checkpoint = false},
                {keys = ' after write', lines = {'before write after write'}, mode = 'i', seq = 2},
                {keys = '<Esc>u', lines = {'before write'}, mode = 'n', seq = 1},
                {keys = 'u', lines = {'original'}, mode = 'n', seq = 0},
            },
        },
        {
            name = 'hidden buffer checkpoints during typing', initial = {'visible original'},
            setup = [[
                hidden = vim.api.nvim_create_buf(true, false)
                vim.api.nvim_buf_set_name(hidden, FILE .. '.hidden')
                vim.api.nvim_buf_set_lines(hidden, 0, -1, false, {'hidden original'})
            ]],
            steps = {
                {keys = 'gg0Cvisible draft', lines = {'visible draft'}, mode = 'i'},
                {lua = [[vim.api.nvim_buf_set_lines(hidden, 0, -1, false, {'hidden draft'})]],
                    lines = {'visible draft'}, mode = 'i', checkpoint_buffer = 'hidden'},
                {keys = ' continued', lines = {'visible draft continued'}, mode = 'i', seq = 1},
                {keys = '<Esc>u', lines = {'visible original'}, mode = 'n', seq = 0},
                {keys = '<C-r>', lines = {'visible draft continued'}, mode = 'n', seq = 1},
            },
        },
    }

    for _, case in ipairs(cases) do
        it('preserves ' .. case.name .. '.', function()
            fn.writefile(case.initial, dir .. '/source.txt')
            local result = session.run({tmpdir = dir, file = dir .. '/source.txt', undo_dir = dir .. '/undo',
                archives_dir = dir .. '/archives', checkpoint = {enabled = true, debounce_ms = 30, max_delay_ms = 100},
                body = ([=[
                    vim.o.completeopt = 'menu,menuone,noselect'
                    vim.o.inccommand = 'split'
                    vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                    %s
                    dofile('spec/helper/input.lua').run(vim.fn.json_decode(%q), function()
                        assert(vim.deep_equal(vim.fn.readfile(FILE), vim.fn.json_decode(%q)), 'source file changed')
                        assert(vim.v.errmsg == '', vim.v.errmsg)
                        if hidden then
                            local u = require('fundo.manager'):get(hidden)
                            assert(require('fundo.storage').read(u.fallbackPath).contents == 'hidden draft\n')
                        end
                        WriteReport({'ok'})
                        vim.cmd('quitall!')
                    end)
                ]=]):format(case.setup or '', fn.json_encode(case.steps), fn.json_encode(case.source or case.initial))})
            assert.same({'ok'}, result.lines)
        end)
    end
end)

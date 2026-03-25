local api = vim.api
local fn = vim.fn
local path = require('fundo.fs.path')

describe('fundo integration.', function()
    local tmpdir
    local archivesDir
    local undoDir
    local file

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

        local archives = fn.glob(path.join(archivesDir, '*'), false, true)
        assert.are_not.equal(0, #archives)

        fn.writefile({'external', 'change'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))

        local undolist = api.nvim_exec('undolist', true)
        assert.truthy(undolist:match('^number'))
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

        local archives = fn.glob(path.join(archivesDir, '*'), false, true)
        assert.are_not.equal(0, #archives)

        fn.writefile({'external', 'change'}, file)
        vim.cmd('edit ' .. fn.fnameescape(file))

        local undolist = api.nvim_exec('undolist', true)
        assert.truthy(undolist:match('^number'))
    end)
end)

local api = vim.api
local fn = vim.fn
local uv = vim.loop
local async = require('async')
local manager = require('fundo.manager')
local path = require('fundo.fs.path')

describe('fundo integration.', function()
    local tmpdir
    local archivesDir
    local undoDir
    local file

    local function buffer_lines()
        return api.nvim_buf_get_lines(0, 0, -1, false)
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
        assert.same({'external', 'change'}, buffer_lines())

        local undolist = api.nvim_exec('undolist', true)
        assert.truthy(undolist:match('^number'))
        vim.cmd('undo')
        assert.same({'one', 'two'}, buffer_lines())
        vim.cmd('redo')
        assert.same({'external', 'change'}, buffer_lines())
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
        assert.same({'external', 'change'}, buffer_lines())

        local undolist = api.nvim_exec('undolist', true)
        assert.truthy(undolist:match('^number'))
        vim.cmd('undo')
        assert.same({'one', 'two'}, buffer_lines())
        vim.cmd('redo')
        assert.same({'external', 'change'}, buffer_lines())
    end)

    it('prunes the oldest archives when the size limit is exceeded.', function()
        local file_a = path.join(tmpdir, 'a.txt')
        local file_b = path.join(tmpdir, 'b.txt')

        require('fundo').setup({
            archives_dir = archivesDir,
            limit_archives_size = 0.00004,
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

        local archives = fn.glob(path.join(archivesDir, '*'), false, true)
        assert.equal(2, #archives)

        uv.fs_utime(archives[1], 100, 100)
        uv.fs_utime(archives[2], 200, 200)

        async(function()
            await(manager:scanArchivesDir())
            done()
        end)
        assert.True(wait())

        local remaining = fn.glob(path.join(archivesDir, '*'), false, true)
        assert.equal(1, #remaining)
        assert.equal(archives[2], remaining[1])
    end)
end)

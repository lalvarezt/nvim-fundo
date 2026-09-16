local fn = vim.fn
local path = require('fundo.fs.path')
local session = dofile('spec/helper/session.lua')

describe('configured archive paths.', function()
    local tmpdir

    before_each(function()
        tmpdir = fn.tempname()
        fn.mkdir(path.join(tmpdir, 'undo'), 'p')
        fn.writefile({'original'}, path.join(tmpdir, 'source.txt'))
    end)

    after_each(function()
        fn.delete(tmpdir, 'rf')
    end)

    local function run(body)
        return session.run({
            tmpdir = tmpdir,
            archives_dir = path.join(tmpdir, 'archives'),
            undo_dir = path.join(tmpdir, 'undo'),
            file = path.join(tmpdir, 'source.txt'),
            body = body,
        }).lines
    end

    it('keeps relative archive paths fixed when the working directory changes.', function()
        local lines = run([[
            local root = vim.fn.fnamemodify(FILE, ':h')
            vim.cmd('cd ' .. vim.fn.fnameescape(root))
            require('fundo').setup({archives_dir = 'relative-archives'})
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local tracked = require('fundo.manager'):get(vim.api.nvim_get_current_buf())
            local expected = root .. '/relative-archives/' .. vim.fn.fnamemodify(tracked.fallbackPath, ':t')
            vim.fn.mkdir(root .. '/other', 'p')
            vim.cmd('cd ' .. vim.fn.fnameescape(root .. '/other'))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'changed'})
            local ok = require('fundo.manager'):syncAllSync()
            WriteReport({
                tostring(ok),
                tostring(vim.fn.filereadable(expected) == 1),
                tostring(vim.fn.isdirectory(root .. '/other/relative-archives') == 0),
                tostring(require('fundo').status().fallback.path == expected),
            })
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'true', 'true', 'true'}, lines)
    end)

    it('excludes archives when the configured directory has a trailing separator.', function()
        local lines = run([[
            local dir = vim.fn.fnamemodify(FILE, ':h') .. '/archives'
            require('fundo').setup({archives_dir = dir .. '/'})
            local archive = dir .. '/snapshot'
            vim.fn.writefile({'archived'}, archive)
            vim.cmd('edit ' .. vim.fn.fnameescape(archive))
            local report = {
                tostring(vim.bo.undofile),
                tostring(require('fundo.manager'):get(vim.api.nvim_get_current_buf()) == nil),
            }
            local metadata = dir .. '/.metadata/record.json'
            vim.fn.mkdir(dir .. '/.metadata', 'p')
            vim.fn.writefile({'{}'}, metadata)
            vim.cmd('edit ' .. vim.fn.fnameescape(metadata))
            table.insert(report, tostring(vim.bo.undofile))
            table.insert(report, tostring(require('fundo.manager'):get(vim.api.nvim_get_current_buf()) == nil))
            WriteReport(report)
            vim.cmd('quitall!')
        ]])
        assert.same({'false', 'true', 'false', 'true'}, lines)
    end)

    it('retains root paths and expands the home directory during configuration.', function()
        local lines = run([[
            require('fundo').disable()
            local config = require('fundo.config')
            local root = vim.fn.fnamemodify(FILE, ':p'):match('^%a:[/\\]') or '/'
            require('fundo')._config = {archives_dir = root}
            config.reload()
            local rootUnchanged = config.archives_dir == root
            require('fundo')._config = {archives_dir = '~/fundo-path-test/'}
            config.reload()
            WriteReport({
                tostring(rootUnchanged),
                tostring(config.archives_dir == vim.fn.expand('~/fundo-path-test')),
            })
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'true'}, lines)
    end)
end)

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

    for _, scenario in ipairs({'edit', 'literal archive directory', 'enable', 'manual track', 'manual after edit'}) do
        it('rejects a matching colliding native undo tree on ' .. scenario .. '.', function()
            local lines = run(([=[
                local fn, api = vim.fn, vim.api
                local root = fn.fnamemodify(FILE, ':h')
                local fundo, scenario = require('fundo'), %q
                if scenario == 'literal archive directory' then
                    fundo.setup({archives_dir = root .. '/arc[2026]'})
                end
                local percent, nested = root .. '/a%%b', root .. '/a/b'
                fn.mkdir(root .. '/a')
                fn.writefile({'percent original'}, percent)
                fn.writefile({'percent draft'}, nested)
                assert(fn.undofile(percent) == fn.undofile(nested))
                local manager = require('fundo.manager')
                vim.cmd('edit ' .. fn.fnameescape(percent))
                api.nvim_buf_set_lines(0, 0, -1, false, {'percent draft'})
                assert(manager:syncAllSync())
                local first = manager:get(api.nvim_get_current_buf()).fallbackPath
                vim.cmd('bwipeout!')
                if scenario == 'enable' then fundo.disable() end
                if scenario:match('^manual') then require('fundo.config').track_on = 'manual' end
                vim.cmd('edit ' .. fn.fnameescape(nested))
                if scenario == 'enable' then fundo.enable() end
                if scenario == 'manual after edit' then api.nvim_buf_set_lines(0, 0, -1, false, {'local draft'}) end
                if scenario:match('^manual') then vim.cmd('FundoTrack') end
                local second = manager:get(api.nvim_get_current_buf()).fallbackPath
                assert(manager:syncAllSync())
                local stored = assert(require('fundo.storage').read(second))
                vim.cmd('undo')
                if scenario == 'manual after edit' then vim.cmd('undo') end
                WriteReport({tostring(first ~= second), tostring(stored.baselineOnly), BufferText()})
                vim.cmd('quitall!')
            ]=]):format(scenario))
            assert.same({'true', tostring(scenario ~= 'manual after edit'), 'percent draft'}, lines)
        end)
    end

    it('protects native files when the archive directory overlaps a shared undodir.', function()
        run([[
            local fundo, fn = require('fundo'), vim.fn
            vim.cmd('edit ' .. fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            assert(require('fundo.manager'):syncAllSync())
            local ok, err = pcall(fundo.setup, {archives_dir = vim.o.undodir})
            assert(not ok and tostring(err):find('undodir', 1, true))
            local original = vim.o.undodir
            vim.o.undodir = require('fundo.config').archives_dir
            local native = fn.undofile(FILE)
            vim.cmd('wundo! ' .. fn.fnameescape(native))
            local before = fn.readfile(native, 'b')
            assert(not require('fundo.manager'):syncAllSync())
            local removed = fundo.forget(FILE, {apply = true})
            assert(not removed.applied and vim.deep_equal(before, fn.readfile(native, 'b')))
            vim.o.undodir = original
            vim.cmd('quitall!')
        ]])
    end)

    it('recognizes an escaped comma in a shared undodir.', function()
        run([[
            local dir = vim.fn.fnamemodify(FILE, ':h') .. '/arc,old'
            vim.fn.mkdir(dir, 'p')
            vim.o.undodir = vim.fn.escape(dir, ',')
            assert(vim.fn.fnamemodify(vim.fn.undofile(FILE), ':h') == dir)
            local ok, err = pcall(require('fundo').setup, {archives_dir = dir})
            assert(not ok and tostring(err):find('undodir', 1, true))
            vim.cmd('quitall!')
        ]])
    end)

    it('keeps the recorded native undo after upgrading an overlapping layout.', function()
        run([[
            local fn, manager = vim.fn, require('fundo.manager')
            vim.cmd('edit ' .. fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
            vim.cmd('write')
            local u = manager:get(vim.api.nvim_get_current_buf())
            local old = u:transferSnapshot()
            vim.cmd('bwipeout!')
            local storage = require('fundo.storage')
            old.expectedGeneration = storage.token(old.fallbackPath)
            old.undoPath = old.fallbackPath
            storage.publish(old, function()
                require('fundo.fs').writeFileSync(old.undoPath, old.undoContents)
                require('fundo.manifest').write(old)
            end)
            local before = fn.readfile(old.undoPath, 'b')
            assert(require('fundo').forget(FILE, {apply = true}).applied)
            assert(vim.deep_equal(before, fn.readfile(old.undoPath, 'b')))
            manager.prunePolicy, manager.limitArchivesSize = 'delete', 0
            local done = false
            manager:scanArchivesDir():thenCall(function() done = true end)
            assert(vim.wait(2000, function() return done end))
            assert(vim.deep_equal(before, fn.readfile(old.undoPath, 'b')))
            vim.cmd('quitall!')
        ]])
    end)

    it('checks the live undodir before deleting flat files during a prune scan.', function()
        run([[
            local manager, fn = require('fundo.manager'), vim.fn
            manager.prunePolicy, manager.limitArchivesSize = 'delete', 0
            require('fundo.config').track_on = 'manual'
            vim.cmd('edit ' .. fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'local draft'})
            local list = manager.listFileStats
            local native, before
            manager.listFileStats = function(self, dir, size)
                manager.listFileStats = list
                return require('promise')(function(resolve, reject)
                    vim.schedule(function()
                        vim.o.undodir = self.archivesDir
                        native = fn.undofile(FILE)
                        vim.cmd('wundo! ' .. fn.fnameescape(native))
                        before = fn.readfile(native, 'b')
                        list(self, dir, size):thenCall(resolve, reject)
                    end)
                end)
            end
            local done = false
            local function finish() done = true end
            manager:scanArchivesDir():thenCall(finish, finish)
            assert(vim.wait(2000, function() return done end))
            assert(native and vim.deep_equal(before, fn.readfile(native, 'b')))
            vim.cmd('quitall!')
        ]])
    end)

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

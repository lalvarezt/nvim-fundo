local fn = vim.fn
local path = require('fundo.fs.path')
local session = dofile('spec/helper/session.lua')

describe('baseline metadata policy.', function()
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

    it('removes metadata when setup disables a baseline-only record.', function()
        local lines = run([[
            local fundo = require('fundo')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local config = require('fundo.config')
            local before = fundo.status()
            fundo.setup({archives_dir = config.archives_dir, baseline_max_file_size = 0})
            WriteReport({
                tostring(before.baseline.exists),
                tostring(vim.fn.filereadable(before.baseline.path) == 0),
                tostring(vim.fn.filereadable(before.manifest.path) == 0),
                tostring(fundo.doctor().ok),
            })
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'true', 'true', 'true'}, lines)
    end)

    it('updates retained fallback metadata after removing its baseline.', function()
        local lines = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'changed'})
            vim.cmd('write')
            local manager = require('fundo.manager')
            manager:syncAllSync()
            local tracked = manager:get(vim.api.nvim_get_current_buf())
            require('fundo.config').baseline_max_file_size = 0
            tracked:saveBaseline()
            local manifest = require('fundo.manifest')
            local record = manifest.read(manifest.path(tracked.fallbackPath), tracked.fallbackPath)
            WriteReport({
                tostring(vim.fn.filereadable(tracked.fallbackPath) == 1),
                tostring(vim.fn.filereadable(tracked.baselinePath) == 0),
                tostring(record.baseline == nil),
                tostring(record.baseline_format == nil),
                tostring(record.snapshot_format == 'buffer-lines-v1'),
            })
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'true', 'true', 'true', 'true'}, lines)
    end)

    it('reports metadata deletion failures and retries them during sync.', function()
        local lines = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            local manager = require('fundo.manager')
            local tracked = manager:get(vim.api.nvim_get_current_buf())
            local fs = require('fundo.fs')
            local metadata = require('fundo.manifest').path(tracked.fallbackPath)
            require('fundo.config').baseline_max_file_size = 0
            local unlink = fs.unlinkSync
            fs.unlinkSync = function(target)
                if target == metadata then return nil, 'metadata removal denied', 'EACCES' end
                return unlink(target)
            end
            local saved, err = tracked:saveBaseline()
            local failure = tracked.lastError
            fs.unlinkSync = unlink
            local synced = manager:syncAllSync()
            WriteReport({
                tostring(not saved and err ~= nil),
                tostring(failure and failure.stage == 'manifest' or false),
                tostring(synced),
                tostring(vim.fn.filereadable(metadata) == 0),
                tostring(tracked.lastError == nil),
            })
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'true', 'true', 'true', 'true'}, lines)
    end)

    it('reports retained metadata write failures and retries them during sync.', function()
        local lines = run([[
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'changed'})
            vim.cmd('write')
            local manager = require('fundo.manager')
            manager:syncAllSync()
            local tracked = manager:get(vim.api.nvim_get_current_buf())
            local fs = require('fundo.fs')
            local manifest = require('fundo.manifest')
            local metadata = manifest.path(tracked.fallbackPath)
            require('fundo.config').baseline_max_file_size = 0
            local write = fs.writeFileSync
            fs.writeFileSync = function(target, ...)
                if target == metadata then error('metadata write denied') end
                return write(target, ...)
            end
            local saved, err = tracked:saveBaseline()
            local failure = tracked.lastError
            fs.writeFileSync = write
            local synced = manager:syncAllSync()
            local record = manifest.read(metadata, tracked.fallbackPath)
            WriteReport({
                tostring(not saved and err ~= nil),
                tostring(failure and failure.stage == 'manifest' or false),
                tostring(synced),
                tostring(record.baseline == nil),
                tostring(tracked.lastError == nil),
            })
            vim.cmd('quitall!')
        ]])
        assert.same({'true', 'true', 'true', 'true', 'true'}, lines)
    end)

    for _, policy in ipairs({'retention', 'size'}) do
        it('prunes existing orphan metadata under the ' .. policy .. ' policy.', function()
            local lines = run(([[
                local manager = require('fundo.manager')
                local fs = require('fundo.fs')
                local manifest = require('fundo.manifest')
                local metadata = manifest.path(manager.archivesDir .. '/orphan')
                fs.mkdirpSync(manifest.dir(manager.archivesDir), 448)
                fs.writeFileSync(metadata, '{}')
                if %q == 'retention' then
                    manager.retentionDays = 1
                    local old = os.time() - 3 * 24 * 60 * 60
                    vim.loop.fs_utime(metadata, old, old)
                else
                    manager.limitArchivesSize = 0
                end
                local finished, failure
                manager:scanArchivesDir():thenCall(function()
                    finished = true
                end, function(err)
                    failure = err
                    finished = true
                end)
                local completed = vim.wait(1000, function() return finished end)
                WriteReport({
                    tostring(completed and failure == nil),
                    tostring(vim.fn.filereadable(metadata) == 0),
                })
                vim.cmd('quitall!')
            ]]):format(policy))
            assert.same({'true', 'true'}, lines)
        end)
    end
end)

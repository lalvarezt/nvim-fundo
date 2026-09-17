local fn = vim.fn
local path = require('fundo.fs.path')
local session = dofile('spec/helper/session.lua')

describe('tracking controls.', function()
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

    for _, policy in ipairs({'write', 'manual'}) do
        it('starts new records on ' .. policy .. ' and recovers existing records on open.', function()
            run(([[
                local fundo, config = require('fundo'), require('fundo.config')
                fundo.setup({archives_dir = config.archives_dir, track_on = %q})
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                assert(not fundo.status().tracked)
                assert(fundo.status().baseline.reason == 'awaiting-' .. %q)
                assert(require('fundo.manager'):syncAllSync())
                assert(not fundo.status().baseline.exists)
                if %q == 'manual' then vim.cmd('FundoTrack') else vim.cmd('write') end
                assert(fundo.status().tracked)
                assert(require('fundo.manager'):syncAllSync())
                vim.cmd('quitall!')
            ]]):format(policy, policy, policy))
            fn.writefile({'outside'}, file)
            local result = run(([[
                local fundo, config = require('fundo'), require('fundo.config')
                fundo.setup({archives_dir = config.archives_dir, track_on = %q})
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                assert(fundo.status().tracked)
                vim.cmd('undo')
                WriteReport({BufferText()})
                vim.cmd('quitall!')
            ]]):format(policy))
            assert.same({'original'}, result)
        end)
    end

    it('previews and forgets a file without deleting native undo or recapturing it.', function()
        local result = run([[
            local fundo = require('fundo')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'edited'})
            vim.cmd('write')
            assert(require('fundo.manager'):syncAllSync())
            local before = fundo.status()
            local preview = fundo.forget()
            assert(not preview.applied and #preview.records == 1 and preview.bytes > 0)
            assert(fundo.status().baseline.exists)
            vim.cmd('FundoForget!')
            assert(not fundo.status().tracked and fundo.status().baseline.reason == 'forgotten')
            assert(require('fundo.manager'):syncAllSync())
            vim.wait(20, function() return false end)
            assert(not fundo.status().baseline.exists and not fundo.status().generation)
            assert(vim.fn.filereadable(before.native_undo.path) == 1)
            assert(BufferText() == 'edited')
            vim.cmd('undo')
            assert(BufferText() == 'original')
            vim.cmd('FundoTrack')
            assert(fundo.status().tracked)
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
    end)

    it('forgets project records without matching a sibling directory or leaving queued captures.', function()
        local result = run([[
            local fundo, fn = require('fundo'), vim.fn
            local parent = fn.fnamemodify(FILE, ':h')
            local project, sibling = parent .. '/project', parent .. '/project-other'
            fn.mkdir(project, 'p'); fn.mkdir(sibling, 'p')
            local a, b = project .. '/a', sibling .. '/b'
            fn.writefile({'a'}, a); fn.writefile({'b'}, b)
            vim.cmd('edit ' .. fn.fnameescape(a))
            vim.cmd('edit ' .. fn.fnameescape(b))
            local plan = fundo.forget(project)
            assert(#plan.records == 1 and plan.records[1].name == a)
            assert(fundo.forget(project, {apply = true}).applied)
            assert(require('fundo.manager'):syncAllSync())
            assert(not fundo.status(a).baseline.exists and fundo.status(b).baseline.exists)
            local c = project .. '/c'
            fn.writefile({'c'}, c)
            vim.cmd('edit ' .. fn.fnameescape(c))
            assert(fundo.status().baseline.reason == 'forgotten')
            fundo.track()
            assert(fundo.status().tracked)
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
    end)

    it('keeps records and tracking intact when a live lock blocks removal.', function()
        local result = run([[
            local fundo = require('fundo')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            local before = fundo.status()
            require('fundo.storage').withLock(before.fallback.path, function()
                local result = fundo.forget(FILE, {apply = true})
                assert(not result.applied and #result.errors == 1)
                assert(fundo.status().tracked and fundo.status().baseline.exists)
            end)
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
    end)

    it('removes an explicitly selected file with a damaged generation pointer.', function()
        local result = run([[
            local fundo = require('fundo')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            local state = fundo.status()
            local dir = require('fundo.storage').directory(state.fallback.path)
            require('fundo.fs').writeFileSync(dir .. '/current', 'damaged')
            assert(#fundo.forget(FILE).records == 1)
            local removed = fundo.forget(FILE, {apply = true})
            assert(removed.applied and removed.removed == 1)
            assert(vim.fn.isdirectory(dir) == 0)
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
    end)

    it('does not let explicit tracking bypass exclusions or disabled undo.', function()
        local result = run([[
            local fundo, config = require('fundo'), require('fundo.config')
            fundo.setup({archives_dir = config.archives_dir, track_on = 'manual', filter = function() return false end})
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(not pcall(fundo.track))
            config.filter = function() return true end
            vim.bo.undofile = false
            assert(not pcall(fundo.track))
            vim.bo.undofile = true
            vim.bo.undolevels = -1
            assert(not pcall(fundo.track))
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
    end)
end)

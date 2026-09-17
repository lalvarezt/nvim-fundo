local fn = vim.fn
local path = require('fundo.fs.path')
local session = dofile('spec/helper/session.lua')

describe('explicit history association.', function()
    local tmpdir, file, moved
    before_each(function()
        tmpdir = fn.tempname()
        file = path.join(tmpdir, 'old name.txt')
        moved = path.join(tmpdir, 'new name.txt')
        fn.mkdir(path.join(tmpdir, 'undo'), 'p')
        fn.writefile({'original'}, file)
    end)
    after_each(function() fn.delete(tmpdir, 'rf') end)

    local function run(body)
        return session.run({
            tmpdir = tmpdir, archives_dir = path.join(tmpdir, 'archives'),
            undo_dir = path.join(tmpdir, 'undo'), file = file,
            body = 'MOVED = ' .. string.format('%q', moved) .. '\n' .. body,
        }).lines
    end

    for _, kind in ipairs({'baseline', 'generation', 'legacy'}) do
        it('associates ' .. kind .. ' history after an external move without modifying either file.', function()
            run(([[
                vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
                if %q ~= 'baseline' then
                    vim.api.nvim_buf_set_lines(0, 0, -1, false, {'saved'})
                    vim.cmd('write')
                end
                assert(require('fundo.manager'):syncAllSync())
                if %q == 'legacy' then
                    require('fundo.storage').remove(require('fundo').status().fallback.path)
                end
                vim.cmd('quitall!')
            ]]):format(kind, kind))
            assert.equal(0, fn.rename(file, moved))
            fn.writefile({'outside'}, moved)
            local result = run(([[
                local fundo = require('fundo')
                vim.cmd('edit ' .. vim.fn.fnameescape(MOVED))
                local sourceBefore = fundo.status(FILE)
                vim.cmd('FundoAssociate ' .. vim.fn.fnameescape(FILE))
                local out = {BufferText()}
                vim.cmd('undo')
                table.insert(out, BufferText())
                if %q ~= 'baseline' then
                    vim.cmd('undo')
                    assert(BufferText() == 'original')
                    vim.cmd('redo')
                end
                vim.cmd('redo')
                table.insert(out, BufferText())
                assert(vim.fn.filereadable(FILE) == 0)
                assert(vim.fn.readfile(MOVED)[1] == 'outside')
                assert(fundo.status(FILE).generation == sourceBefore.generation)
                assert(fundo.recovery().kind == 'association')
                WriteReport(out)
                vim.cmd('quitall!')
            ]]):format(kind))
            assert.same({'outside', kind == 'baseline' and 'original' or 'saved', 'outside'}, result)
            fn.writefile({'later'}, moved)
            local reopened = run([[
                vim.cmd('edit ' .. vim.fn.fnameescape(MOVED))
                vim.cmd('undo')
                WriteReport({BufferText()})
                vim.cmd('quitall!')
            ]])
            assert.same({'outside'}, reopened)
        end)
    end

    it('keeps destination and source histories intact when the destination has its own edits.', function()
        local result = run([[
            local api, fundo = vim.api, require('fundo')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            api.nvim_buf_set_lines(0, 0, -1, false, {'source saved'})
            vim.cmd('write')
            assert(require('fundo.manager'):syncAllSync())
            local source = fundo.status()
            vim.fn.writefile({'destination original'}, MOVED)
            vim.cmd('edit ' .. vim.fn.fnameescape(MOVED))
            api.nvim_buf_set_lines(0, 0, -1, false, {'destination saved'})
            vim.cmd('write')
            assert(require('fundo.manager'):syncAllSync())
            local destination, tree = fundo.status(), vim.fn.undotree()
            local ok, err = pcall(fundo.associate, FILE)
            assert(not ok and err:find('destination already has undo history', 1, true))
            assert(fundo.status(FILE).generation == source.generation)
            assert(fundo.status().generation == destination.generation)
            assert(vim.deep_equal(tree, vim.fn.undotree()))
            vim.cmd('undo')
            WriteReport({BufferText()})
            vim.cmd('quitall!')
        ]])
        assert.same({'destination original'}, result)
    end)

    it('rejects corrupt source generations before publishing or changing the destination.', function()
        local result = run([[
            local api, fundo = vim.api, require('fundo')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            api.nvim_buf_set_lines(0, 0, -1, false, {'source saved'})
            vim.cmd('write')
            assert(require('fundo.manager'):syncAllSync())
            local source = fundo.status()
            local storage = require('fundo.storage')
            require('fundo.fs').writeFileSync(storage.directory(source.fallback.path) .. '/' ..
                source.generation .. '/undoContents', 'damaged')
            vim.fn.writefile({'destination'}, MOVED)
            vim.cmd('edit ' .. vim.fn.fnameescape(MOVED))
            local before = fundo.status()
            assert(not pcall(fundo.associate, FILE))
            assert(fundo.status().generation == before.generation)
            assert(EntryCount() == 0 and not vim.bo.modified)
            WriteReport({BufferText()})
            vim.cmd('quitall!')
        ]])
        assert.same({'destination'}, result)
    end)

    it('rejects dirty destinations and files excluded by the filter.', function()
        local result = run([[
            local fundo = require('fundo')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            vim.fn.writefile({'destination'}, MOVED)
            vim.cmd('edit ' .. vim.fn.fnameescape(MOVED))
            vim.bo.modified = true
            local ok, err = pcall(fundo.associate, FILE)
            assert(not ok and err:find('modified', 1, true))
            vim.bo.modified = false
            require('fundo.config').filter = function() return false end
            ok, err = pcall(fundo.associate, FILE)
            assert(not ok and err:find('filter', 1, true))
            assert(EntryCount() == 0)
            WriteReport({BufferText()})
            vim.cmd('quitall!')
        ]])
        assert.same({'destination'}, result)
    end)

    it('suggests an unchanged move by filesystem identity rather than equal contents alone.', function()
        local result = run([[
            local fundo, fs = require('fundo'), require('fundo.fs')
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            vim.cmd('bwipeout!')
            fs.copyFileSync(FILE, MOVED)
            local renamed = MOVED .. '.renamed'
            assert(vim.fn.rename(FILE, renamed) == 0)
            vim.cmd('edit ' .. vim.fn.fnameescape(MOVED))
            assert(#fundo.association_candidates() == 0)
            vim.cmd('edit ' .. vim.fn.fnameescape(renamed))
            local identity = fs.statSync(renamed)
            local candidates = fundo.association_candidates()
            if identity.ino ~= 0 and identity.birthtime and identity.birthtime.sec ~= 0 then
                assert(#candidates == 1 and candidates[1] == FILE)
            else
                assert(#candidates == 0)
            end
            vim.cmd('FundoAssociate')
            assert(EntryCount() == 0)
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
    end)

    it('does not suggest an ambiguous pair of archived hardlink paths.', function()
        local result = run([[
            local fundo = require('fundo')
            local alias = FILE .. '.alias'
            assert(vim.loop.fs_link(FILE, alias))
            vim.cmd('edit ' .. vim.fn.fnameescape(FILE))
            assert(require('fundo.manager'):syncAllSync())
            vim.cmd('bwipeout!')
            vim.cmd('edit ' .. vim.fn.fnameescape(alias))
            assert(require('fundo.manager'):syncAllSync())
            vim.cmd('bwipeout!')
            assert(vim.fn.rename(FILE, MOVED) == 0)
            assert(vim.fn.delete(alias) == 0)
            vim.cmd('edit ' .. vim.fn.fnameescape(MOVED))
            assert(#fundo.association_candidates() == 0)
            WriteReport({'ok'})
            vim.cmd('quitall!')
        ]])
        assert.same({'ok'}, result)
    end)
end)

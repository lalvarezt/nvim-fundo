local fn = vim.fn
local fs = require('fundo.fs')
local journal = require('fundo.journal')

describe('recovery journal integrity.', function()
    local dir, transfer, root
    before_each(function()
        dir = fn.tempname()
        transfer = {name = dir .. '/source', undoPath = dir .. '/undo', fallbackPath = dir .. '/archives/copy',
            contents = 'draft\0text\n', undoContents = '\255\0\128undo', expectedGeneration = false}
        root = journal.directory(dir .. '/archives')
    end)
    after_each(function() fn.delete(root, 'rf'); fn.delete(dir, 'rf') end)

    it('round trips binary captures and leaves live writers alone.', function()
        journal.write(transfer)
        assert.equal(0, #journal.list(dir .. '/archives'))
        local records, errors = journal.list(dir .. '/archives', true)
        assert.equal(0, #errors)
        assert.equal(1, #records)
        assert.equal(transfer.contents, records[1].contents)
        assert.equal(transfer.undoContents, records[1].undoContents)
        assert.equal(384, fs.statSync(transfer.journalPath .. '/contents').mode % 512)
        journal.finish(transfer)
        assert.equal(0, #journal.list(dir .. '/archives', true))
    end)

    it('reports damaged captures without deleting their data.', function()
        journal.write(transfer)
        fs.writeFileSync(transfer.journalPath .. '/undoContents', 'damaged')
        local records, errors = journal.list(dir .. '/archives', true)
        assert.equal(0, #records)
        assert.equal(1, #errors)
        assert.truthy(errors[1].message:find('checksum', 1, true))
        assert.truthy(fs.statSync(transfer.journalPath .. '/contents'))
    end)

    it('keeps the previous capture if a replacement journal fails to synchronize.', function()
        journal.write(transfer)
        local nextTransfer = vim.tbl_extend('force', transfer, {contents = 'new draft\n'})
        nextTransfer.journalPath = nil
        local write = fs.writeFileSync
        ---@diagnostic disable-next-line: duplicate-set-field
        fs.writeFileSync = function(filename, ...)
            if filename:sub(-7) == '/record' then error('journal outage') end
            return write(filename, ...)
        end
        local ok = pcall(journal.write, nextTransfer)
        fs.writeFileSync = write
        assert.False(ok)
        local records = journal.list(dir .. '/archives', true)
        assert.equal(1, #records)
        assert.equal(transfer.contents, records[1].contents)
    end)
end)

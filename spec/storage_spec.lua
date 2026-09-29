local fn = vim.fn
local fs = require('fundo.fs')
local storage = require('fundo.storage')

describe('generation storage.', function()
    local dir, fallback
    before_each(function()
        dir = fn.tempname()
        fn.mkdir(dir, 'p')
        fallback = dir .. '/archive'
    end)
    after_each(function() fn.delete(dir, 'rf') end)

    local function snapshot(contents, expected)
        return {
            name = dir .. '/source', fallbackPath = fallback, undoPath = dir .. '/undo',
            baselinePath = fallback .. '.base', contents = contents .. '\n',
            undoContents = 'undo\0' .. contents, expectedGeneration = expected or false,
            capturedAt = os.time(),
        }
    end

    local function publish(contents, expected)
        local value = snapshot(contents, expected)
        storage.publish(value, function() end)
        return value
    end

    it('keeps the last committed generation when publication is interrupted.', function()
        local first = publish('first')
        local nextSnapshot = snapshot('second', first.generation)
        local ok = pcall(storage.publish, nextSnapshot, function() error('interrupted') end)
        assert.False(ok)
        assert.equal('first\n', storage.read(fallback).contents)
        storage.clean(dir)
        assert.equal(2, #fn.glob(storage.directory(fallback) .. '/*/record', false, true))
        storage.publish(nextSnapshot, function() end)
        assert.equal('second\n', storage.read(fallback).contents)
    end)

    it('rejects a stale writer before changing published artifacts.', function()
        local first = publish('first')
        local newer = publish('newer', first.generation)
        local called = false
        local ok, err = pcall(storage.publish, snapshot('stale', first.generation), function() called = true end)
        assert.False(ok)
        assert.False(called)
        assert.truthy(tostring(err):find('another session', 1, true))
        assert.equal(newer.generation, storage.read(fallback).generation)
    end)

    it('retries publication when pointer rename succeeded before directory sync failed.', function()
        local first = publish('first')
        local transfer = snapshot('second', first.generation)
        local sync = fs.syncDirectorySync
        ---@diagnostic disable-next-line: duplicate-set-field
        fs.syncDirectorySync = function(target)
            if target == storage.directory(fallback) and storage.token(fallback) ~= first.generation then
                error('injected pointer directory sync failure')
            end
            return sync(target)
        end
        local ok, err = pcall(storage.publish, transfer, function() end)
        fs.syncDirectorySync = sync
        assert.False(ok)
        assert.truthy(tostring(err):find('pointer directory sync failure', 1, true))
        assert.equal(storage.token(fallback), transfer.expectedGeneration)
        assert.truthy(fs.statSync(storage.directory(fallback) .. '/' .. first.generation .. '/record'))
        storage.publish(transfer, function() end)
        assert.equal('second\n', storage.read(fallback).contents)
    end)

    it('falls back to the previous complete generation and retains it on repair.', function()
        local first = publish('first')
        local second = publish('second', first.generation)
        fs.writeFileSync(storage.directory(fallback) .. '/' .. second.generation .. '/undoContents', 'corrupt')
        assert.equal(first.generation, storage.read(fallback).generation)
        local third = publish('third', second.generation)
        fs.writeFileSync(storage.directory(fallback) .. '/' .. third.generation .. '/contents', 'corrupt')
        assert.equal('first\n', storage.read(fallback).contents)
        assert.equal(3, #fn.glob(storage.directory(fallback) .. '/*/record', false, true))
    end)

    it('does not enter a record locked by a live process.', function()
        storage.withLock(fallback, function()
            local called = false
            local ok = pcall(storage.withLock, fallback, function() called = true end)
            assert.False(ok)
            assert.False(called)
        end)
        assert.truthy(publish('after lock').generation)
    end)

    it('keeps captured generation files when their pointer is missing on startup.', function()
        local first = publish('captured work')
        assert(fs.unlinkSync(storage.directory(fallback) .. '/current'))
        storage.clean(dir)
        assert.truthy(fs.statSync(storage.directory(fallback) .. '/' .. first.generation .. '/contents'))
        assert.equal(1, #storage.records(dir))
        assert.truthy(storage.records(dir)[1].error)
    end)

    it('serializes acquisition while a dead owner is being reclaimed.', function()
        local lock = storage.directory(fallback) .. '.lock'
        fs.mkdirpSync(lock, 448)
        local deadPid = 99999999
        local alive, _, code = vim.loop.kill(deadPid, 0)
        assert.falsy(alive)
        assert.equal('ESRCH', code)
        fs.writeFileSync(lock .. '/owner', fn.json_encode({pid = deadPid, host = vim.loop.os_gethostname()}))
        local open = fs.openSync
        local competitor, entered, attempted = nil, false, false
        fs.openSync = function(target, ...)
            if target == lock .. '/reaping' and not attempted then
                attempted = true
                competitor = coroutine.create(function()
                    pcall(storage.withLock, fallback, function()
                        entered = true
                        coroutine.yield()
                    end)
                end)
                assert(coroutine.resume(competitor))
            end
            return open(target, ...)
        end
        local ok, err = pcall(storage.withLock, fallback, function() end)
        fs.openSync = open
        if competitor and coroutine.status(competitor) == 'suspended' then
            assert(coroutine.resume(competitor))
        end
        if not ok then error(err) end
        assert.True(attempted)
        assert.False(entered)
        assert.truthy(publish('after reclamation').generation)
    end)

    it('preserves history when an acquisition guard survives interruption.', function()
        local first = publish('first')
        local claim = storage.directory(fallback) .. '.claim'
        fs.mkdirpSync(claim, 448)
        fs.writeFileSync(claim .. '/owner', fn.json_encode({pid = 99999999, host = vim.loop.os_gethostname()}))
        local ok, err = pcall(publish, 'second', first.generation)
        assert.False(ok)
        assert.truthy(tostring(err):find(claim, 1, true))
        assert.equal('first\n', storage.read(fallback).contents)
        fn.delete(claim, 'rf')
        assert.truthy(publish('second', first.generation).generation)
    end)

    it('accounts for damaged metadata and preserves it until explicit removal.', function()
        publish('first')
        local pointer = storage.directory(fallback) .. '/current'
        local valid = table.concat(fn.readfile(pointer, 'b'), '\n')
        fs.writeFileSync(pointer, 'invalid')
        local records = storage.records(dir)
        assert.equal(1, #records)
        assert.truthy(records[1].error)
        assert.True(records[1].size > 0)
        fs.writeFileSync(pointer, valid)
        storage.removeInvalid(records[1].directory)
        assert.equal('first\n', storage.read(fallback).contents)
        fs.writeFileSync(pointer, 'invalid')
        assert.False(storage.removeInvalid(records[1].directory))
        assert.equal(1, #storage.records(dir))
        storage.withLock(fallback, function() storage.remove(fallback) end)
        assert.equal(0, #storage.records(dir))
    end)
end)

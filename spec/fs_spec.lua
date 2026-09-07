local pwd = os.getenv('PWD')
local fs = require('fundo.fs')
local path = require('fundo.fs.path')
local async = require('async')
local await = async.wait


describe('fs module on Unix.', function()
    local samplePath
    setup(function()
        samplePath = path.join(pwd, 'spec', 'sample')
    end)
    describe('synchronous stat file,', function()
        it('stat an existed file.', function()
            local state = fs.statSync(path.join(samplePath, 'foo.txt'))
            assert.equal('file', state.type)
        end)
        it('stat an existed directory.', function()
            local state = fs.statSync(path.join(samplePath, 'empty_dir'))
            assert.equal('directory', state.type)
        end)
        it('stat a non-existed file.', function()
            local state = fs.statSync(path.join(samplePath, 'foo_non_existed.txt'))
            assert.Nil(state)
        end)
    end)
    describe('asynchronous stat file,', function()
        local state
        it('stat an existed file.', function()
            async(function()
                state = await(fs.stat(path.join(samplePath, 'foo.txt')))
                assert.equal('file', state.type)
                done()
            end)
            assert.True(wait())
        end)
        it('stat an existed directory.', function()
            async(function()
                state = await(fs.stat(path.join(samplePath, 'empty_dir')))
                assert.equal('directory', state.type)
                done()
            end)
            assert.True(wait())
        end)
        it('stat a non-existed file.', function()
            async(function()
                state = await(fs.stat(path.join(samplePath, 'foo_non_existed.txt')))
                done()
            end)
            local ok, msg = wait()
            assert.False(ok)
            assert.truthy(msg:match('^ENOENT: no such file or directory'))
        end)
    end)
    describe('asynchronous copy file,', function()
        local dupPath
        setup(function()
            dupPath = path.join(samplePath, '__dup__.txt')
        end)
        after_each(function()
            os.remove(dupPath)
            for _, p in ipairs(vim.fn.glob(dupPath .. '.__*', false, true)) do
                os.remove(p)
            end
        end)
        it('copy an existed file', function()
            async(function()
                await(fs.copyFile(path.join(samplePath, 'foo.txt'), dupPath))
                done()
            end)
            assert.True(wait())
        end)
        it('copy a non-existed file', function()
            async(function()
                await(fs.copyFile(path.join(samplePath, 'foo_non_existed.txt'), dupPath))
                done()
            end)
            local ok, msg = wait()
            assert.False(ok)
            assert.truthy(msg:match('^ENOENT: no such file or directory'))
        end)
        it('removes the temporary copy when the target cannot be renamed', function()
            local dirTarget = path.join(samplePath, 'empty_dir')

            async(function()
                await(fs.copyFile(path.join(samplePath, 'foo.txt'), dirTarget))
                done()
            end)

            local ok, msg = wait()
            assert.False(ok)
            assert.equal('string', type(msg))
            assert.same({}, vim.fn.glob(dirTarget .. '.__*', false, true))
        end)
        it('removes the temporary copy when sync target cannot be renamed', function()
            local dirTarget = path.join(samplePath, 'empty_dir')

            local ok, msg = pcall(fs.copyFileSync, path.join(samplePath, 'foo.txt'), dirTarget)

            assert.False(ok)
            assert.equal('string', type(msg))
            assert.same({}, vim.fn.glob(dirTarget .. '.__*', false, true))
        end)
    end)
    describe('synchronous atomic write,', function()
        local target
        local write

        before_each(function()
            target = vim.fn.tempname()
            vim.fn.writefile({'original'}, target, 'b')
            write = vim.loop.fs_write
        end)

        after_each(function()
            vim.loop.fs_write = write
            os.remove(target)
            for _, p in ipairs(vim.fn.glob(target .. '.__*', false, true)) do
                os.remove(p)
            end
        end)

        it('completes partial writes before replacing the target', function()
            vim.loop.fs_write = function(fd, data, offset)
                return write(fd, data:sub(1, 2), offset)
            end

            fs.writeFileSync(target, 'replacement')

            assert.same({'replacement'}, vim.fn.readfile(target, 'b'))
            assert.same({}, vim.fn.glob(target .. '.__*', false, true))
        end)

        it('preserves the target and removes the temporary file after a write error', function()
            vim.loop.fs_write = function(fd, data, offset)
                if offset == 0 then
                    return write(fd, data:sub(1, 2), offset)
                end
                return nil, 'injected write failure'
            end

            local ok, err = pcall(fs.writeFileSync, target, 'replacement')

            assert.False(ok)
            assert.truthy(tostring(err):find('injected write failure', 1, true))
            assert.same({'original'}, vim.fn.readfile(target, 'b'))
            assert.same({}, vim.fn.glob(target .. '.__*', false, true))
        end)

        it('fails without retrying when a write makes no progress', function()
            local calls = 0
            vim.loop.fs_write = function()
                calls = calls + 1
                if calls > 1 then
                    return nil, 'unexpected retry'
                end
                return 0
            end

            local ok, err = pcall(fs.writeFileSync, target, 'replacement')

            assert.False(ok)
            assert.truthy(tostring(err):find('write made no progress', 1, true))
            assert.equal(1, calls)
            assert.same({'original'}, vim.fn.readfile(target, 'b'))
            assert.same({}, vim.fn.glob(target .. '.__*', false, true))
        end)

        it('replaces the target with an empty file', function()
            fs.writeFileSync(target, '')

            assert.equal(0, fs.statSync(target).size)
            assert.same({}, vim.fn.glob(target .. '.__*', false, true))
        end)
    end)
    describe('synchronous mkdirp,', function()
        local nestedPath
        setup(function()
            nestedPath = path.join(vim.fn.tempname(), 'a', 'b', 'c')
        end)
        teardown(function()
            vim.fn.delete(path.dirname(path.dirname(path.dirname(nestedPath))), 'rf')
        end)
        it('creates nested directories.', function()
            fs.mkdirpSync(nestedPath, 493)
            assert.equal('directory', fs.statSync(nestedPath).type)
        end)
        it('fails when the path exists as a file.', function()
            local filePath = path.join(vim.fn.tempname(), 'fundo-file')
            vim.fn.mkdir(path.dirname(filePath), 'p')
            vim.fn.writefile({'not a directory'}, filePath)

            local ok = pcall(fs.mkdirpSync, filePath, 493)

            assert.False(ok)
            vim.fn.delete(path.dirname(filePath), 'rf')
        end)
    end)
end)

local fn = vim.fn
local session = dofile('spec/helper/session.lua')

describe('child session failures.', function()
    it('returns assertion errors and their traceback instead of waiting for timeout.', function()
        local dir = fn.tempname()
        fn.mkdir(dir .. '/undo', 'p')
        local ok, err = pcall(session.run, {
            tmpdir = dir, file = dir .. '/source', undo_dir = dir .. '/undo',
            archives_dir = dir .. '/archives', body = "assert(false, 'workflow assertion failed')",
        })
        fn.delete(dir, 'rf')
        assert.False(ok)
        assert.truthy(tostring(err):find('exit code 1', 1, true))
        assert.truthy(tostring(err):find('workflow assertion failed', 1, true))
        assert.truthy(tostring(err):find('stack traceback:', 1, true))
    end)
end)

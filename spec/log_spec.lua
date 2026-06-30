local pwd = os.getenv('PWD')
local path = require('fundo.fs.path')

describe('log module.', function()
    local log
    local tmpdir

    before_each(function()
        vim.env.FUNDO_LOG = nil
        package.loaded['fundo.lib.log'] = nil
        package.path = pwd .. '/lua/?.lua;' .. pwd .. '/lua/?/init.lua;' .. package.path
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, 'p')
        log = require('fundo.lib.log')
    end)

    after_each(function()
        vim.env.FUNDO_LOG = nil
        if log then
            log.configure({enabled = false, level = 'warn', path = tmpdir .. path.sep .. 'disabled.log'})
        end
        vim.fn.delete(tmpdir, 'rf')
    end)

    it('does not create or append to a file when disabled.', function()
        local logfile = tmpdir .. path.sep .. 'disabled.log'
        log.configure({enabled = false, level = 'debug', path = logfile})

        log.warn('this should not be written')

        assert.equal(0, vim.fn.filereadable(logfile))
    end)

    it('writes messages at or above the configured level to the configured path.', function()
        local logfile = tmpdir .. path.sep .. 'enabled.log'
        log.configure({enabled = true, level = 'info', path = logfile})

        log.debug('hidden debug message')
        log.info('visible info message')
        log.error('visible error message')

        assert.equal(1, vim.fn.filereadable(logfile))
        local text = table.concat(vim.fn.readfile(logfile), '\n')
        assert.True(text:find('visible info message', 1, true) ~= nil)
        assert.True(text:find('visible error message', 1, true) ~= nil)
        assert.True(text:find('hidden debug message', 1, true) == nil)
    end)

    it('sets log directory and file permissions to owner-only.', function()
        local logdir = tmpdir .. path.sep .. 'private'
        local logfile = logdir .. path.sep .. 'fundo.log'
        log.configure({enabled = true, level = 'debug', path = logfile})

        log.debug('private log')

        assert.equal(448, vim.loop.fs_stat(logdir).mode % 512)
        assert.equal(384, vim.loop.fs_stat(logfile).mode % 512)
    end)

    it('uses FUNDO_LOG to enable logging during initialization.', function()
        vim.env.FUNDO_LOG = 'debug'
        package.loaded['fundo.lib.log'] = nil

        log = require('fundo.lib.log')

        assert.True(log.isEnabled('debug'))
        assert.equal('debug', log.level())
    end)

    it('keeps each write on one line without trailing whitespace.', function()
        local logfile = tmpdir .. path.sep .. 'format.log'
        log.configure({enabled = true, level = 'debug', path = logfile})

        log.debug('empty value:', '')
        log.debug('table value:', {nested = {status = 'fulfilled'}})

        local lines = vim.fn.readfile(logfile)
        assert.equal(2, #lines)
        assert.True(lines[1]:find('empty value: ""', 1, true) ~= nil)
        assert.True(lines[2]:find('table value: { nested = { status = "fulfilled" } }', 1, true) ~= nil)
        assert.True(lines[2]:find('\\n', 1, true) == nil)
        assert.False(lines[1]:match('%s$') ~= nil)
        assert.False(lines[2]:match('%s$') ~= nil)
    end)
end)

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

    it('uses FUNDO_LOG to enable logging during initialization.', function()
        vim.env.FUNDO_LOG = 'debug'
        package.loaded['fundo.lib.log'] = nil

        log = require('fundo.lib.log')

        assert.True(log.isEnabled('debug'))
        assert.equal('debug', log.level())
    end)
end)

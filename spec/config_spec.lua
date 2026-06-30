local pwd = os.getenv('PWD')

describe('config module.', function()
    local fundo
    local config

    before_each(function()
        vim.env.FUNDO_LOG = nil
        package.loaded['fundo'] = nil
        package.loaded['fundo.config'] = nil
        package.loaded['fundo.main'] = nil
        package.loaded['fundo.manager'] = nil
        package.loaded['fundo.lib.log'] = nil
        package.path = pwd .. '/lua/?.lua;' .. pwd .. '/lua/?/init.lua;' .. package.path
        fundo = require('fundo')
        config = require('fundo.config')
    end)

    it('reloads config values on repeated setup calls.', function()
        fundo.setup({
            archives_dir = '~/fundo-a',
            limit_archives_size = 1,
            logging = {
                enabled = true,
                level = 'debug',
                path = '~/fundo-a.log'
            }
        })
        assert.equal(vim.fn.expand('~/fundo-a'), config.archives_dir)
        assert.equal(1, config.limit_archives_size)
        assert.True(config.logging.enabled)
        assert.equal('debug', config.logging.level)
        assert.equal(vim.fn.expand('~/fundo-a.log'), config.logging.path)

        fundo.setup({
            archives_dir = '~/fundo-b',
            limit_archives_size = 2,
            logging = {
                enabled = false,
                level = 'error',
                path = '~/fundo-b.log'
            }
        })
        assert.equal(vim.fn.expand('~/fundo-b'), config.archives_dir)
        assert.equal(2, config.limit_archives_size)
        assert.False(config.logging.enabled)
        assert.equal('error', config.logging.level)
        assert.equal(vim.fn.expand('~/fundo-b.log'), config.logging.path)
    end)

    it('defaults logging to disabled.', function()
        fundo.setup({archives_dir = '~/fundo-default', limit_archives_size = 1})
        assert.False(config.logging.enabled)
        assert.equal('warn', config.logging.level)
        assert.equal(vim.fn.stdpath('cache') .. require('fundo.fs.path').sep .. 'fundo.log', config.logging.path)
    end)

    it('rejects invalid logging config.', function()
        assert.False(pcall(fundo.setup, {logging = {enabled = 'yes'}}))
        assert.False(pcall(fundo.setup, {logging = {level = 'verbose'}}))
        assert.False(pcall(fundo.setup, {logging = {path = false}}))
    end)

    it('uses FUNDO_LOG as an opt-in override.', function()
        vim.env.FUNDO_LOG = 'debug'
        package.loaded['fundo'] = nil
        package.loaded['fundo.config'] = nil
        package.loaded['fundo.lib.log'] = nil

        fundo = require('fundo')
        config = require('fundo.config')

        assert.True(config.logging.enabled)
        assert.equal('debug', config.logging.level)
    end)
end)

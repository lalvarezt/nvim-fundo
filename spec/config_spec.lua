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
        local firstFilter = function()
            return false
        end
        fundo.setup({
            archives_dir = '~/fundo-a',
            limit_archives_size = 1,
            baseline_max_file_size = 0.5,
            retention_days = 7,
            prune_policy = 'delete',
            filter = firstFilter,
            logging = {
                enabled = true,
                level = 'debug',
                path = '~/fundo-a.log'
            }
        })
        assert.equal(vim.fn.expand('~/fundo-a'), config.archives_dir)
        assert.equal(1, config.limit_archives_size)
        assert.equal(0.5, config.baseline_max_file_size)
        assert.equal(7, config.retention_days)
        assert.equal('delete', config.prune_policy)
        assert.equal(firstFilter, config.filter)
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
        assert.equal(2, config.baseline_max_file_size)
        assert.Nil(config.retention_days)
        assert.equal('preserve', config.prune_policy)
        assert.True(config.filter('anything', 0))
        assert.False(config.logging.enabled)
        assert.equal('error', config.logging.level)
        assert.equal(vim.fn.expand('~/fundo-b.log'), config.logging.path)
    end)

    it('defaults logging to disabled.', function()
        fundo.setup({archives_dir = '~/fundo-default', limit_archives_size = 1})
        assert.equal(1, config.baseline_max_file_size)
        assert.Nil(config.retention_days)
        assert.True(config.filter('anything', 0))
        assert.False(config.logging.enabled)
        assert.equal('warn', config.logging.level)
        assert.same({enabled = true, debounce_ms = 200, max_delay_ms = 1000}, config.checkpoint)
        assert.equal(vim.fn.stdpath('cache') .. require('fundo.fs.path').sep .. 'fundo.log', config.logging.path)
    end)

    it('rejects invalid logging config.', function()
        assert.False(pcall(fundo.setup, {logging = {enabled = 'yes'}}))
        assert.False(pcall(fundo.setup, {logging = {level = 'verbose'}}))
        assert.False(pcall(fundo.setup, {logging = {path = false}}))
    end)

    it('caps the default baseline size but respects an explicit larger limit.', function()
        fundo.setup({archives_dir = '~/fundo-default', limit_archives_size = 512})
        assert.equal(8, config.baseline_max_file_size)
        fundo.setup({archives_dir = '~/fundo-default', baseline_max_file_size = 32})
        assert.equal(32, config.baseline_max_file_size)
    end)

    it('rejects invalid storage policy config.', function()
        assert.False(pcall(fundo.setup, {baseline_max_file_size = -1}))
        assert.False(pcall(fundo.setup, {retention_days = -1}))
        assert.False(pcall(fundo.setup, {prune_policy = 'unknown'}))
        assert.False(pcall(fundo.setup, {filter = 'all'}))
        assert.False(pcall(fundo.setup, {track_on = 'sometimes'}))
        assert.False(pcall(fundo.setup, {checkpoint = {enabled = 'yes'}}))
        assert.False(pcall(fundo.setup, {checkpoint = {debounce_ms = 0}}))
        assert.False(pcall(fundo.setup, {checkpoint = {max_delay_ms = math.huge}}))
        assert.False(pcall(fundo.setup, {checkpoint = {max_delay_ms = 100}}))
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

local pwd = os.getenv('PWD')

describe('config module.', function()
    local fundo
    local config

    before_each(function()
        package.loaded['fundo'] = nil
        package.loaded['fundo.config'] = nil
        package.loaded['fundo.main'] = nil
        package.loaded['fundo.manager'] = nil
        package.path = pwd .. '/lua/?.lua;' .. pwd .. '/lua/?/init.lua;' .. package.path
        fundo = require('fundo')
        config = require('fundo.config')
    end)

    it('reloads config values on repeated setup calls.', function()
        fundo.setup({archives_dir = '~/fundo-a', limit_archives_size = 1})
        assert.equal(vim.fn.expand('~/fundo-a'), config.archives_dir)
        assert.equal(1, config.limit_archives_size)

        fundo.setup({archives_dir = '~/fundo-b', limit_archives_size = 2})
        assert.equal(vim.fn.expand('~/fundo-b'), config.archives_dir)
        assert.equal(2, config.limit_archives_size)
    end)
end)

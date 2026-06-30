local path = require('fundo.fs.path')

---@class FundoConfig
---@field archives_dir string
---@field limit_archives_size number
local def = {
    archives_dir = vim.fn.stdpath('cache') .. path.sep .. 'fundo',
    limit_archives_size = 512
}

---@class FundoConfigModule: FundoConfig
---@field reload fun()
local Config

local function reload()
    local fundo = require('fundo')
    local resolved = vim.tbl_deep_extend('keep', fundo._config or {}, def)
    vim.validate('archives_dir', resolved.archives_dir, 'string')
    vim.validate('limit_archives_size', resolved.limit_archives_size, 'number')
    Config.archives_dir = vim.fn.expand(resolved.archives_dir)
    Config.limit_archives_size = resolved.limit_archives_size
    fundo._config = nil
end

---@type FundoConfigModule
Config = {
    archives_dir = def.archives_dir,
    limit_archives_size = def.limit_archives_size,
    reload = reload
}

Config.reload()

return Config

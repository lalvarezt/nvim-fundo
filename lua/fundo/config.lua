local path = require('fundo.fs.path')

---@class FundoConfig
---@field archives_dir string
---@field limit_archives_size number
---@field logging? FundoLoggingConfig
---@class FundoLoggingConfig
---@field enabled boolean
---@field level string
---@field path string
local def = {
    archives_dir = vim.fn.stdpath('cache') .. path.sep .. 'fundo',
    limit_archives_size = 512,
    logging = {
        enabled = false,
        level = 'warn',
        path = vim.fn.stdpath('cache') .. path.sep .. 'fundo.log'
    }
}

---@class FundoConfigModule: FundoConfig
---@field reload fun()
local Config
local loggingLevels = {trace = true, debug = true, info = true, warn = true, error = true}

local function resolveLogging(resolved, userLogging)
    local envLevel = vim.env.FUNDO_LOG
    userLogging = userLogging or {}

    if envLevel and envLevel ~= '' then
        if userLogging.enabled == nil then
            resolved.logging.enabled = true
        end
        if userLogging.level == nil then
            resolved.logging.level = envLevel
        end
    end
end

local function validateLogging(logging)
    vim.validate('logging', logging, 'table')
    vim.validate('logging.enabled', logging.enabled, 'boolean')
    vim.validate('logging.level', logging.level, 'string')
    vim.validate('logging.path', logging.path, 'string')
    logging.level = logging.level:lower()
    if not loggingLevels[logging.level] then
        error(('logging.level must be one of: trace, debug, info, warn, error; got %s'):format(logging.level), 3)
    end
end

local function reload()
    local fundo = require('fundo')
    local user = fundo._config or {}
    local userLogging = type(user.logging) == 'table' and vim.deepcopy(user.logging) or nil
    local resolved = vim.tbl_deep_extend('keep', vim.deepcopy(user), def)
    resolveLogging(resolved, userLogging)
    vim.validate('archives_dir', resolved.archives_dir, 'string')
    vim.validate('limit_archives_size', resolved.limit_archives_size, 'number')
    validateLogging(resolved.logging)
    Config.archives_dir = vim.fn.expand(resolved.archives_dir)
    Config.limit_archives_size = resolved.limit_archives_size
    Config.logging = {
        enabled = resolved.logging.enabled,
        level = resolved.logging.level,
        path = vim.fn.expand(resolved.logging.path)
    }
    require('fundo.lib.log').configure(Config.logging)
    fundo._config = nil
end

---@type FundoConfigModule
Config = {
    archives_dir = def.archives_dir,
    limit_archives_size = def.limit_archives_size,
    logging = vim.deepcopy(def.logging),
    reload = reload
}

Config.reload()

return Config

local path = require('fundo.fs.path')

---@class FundoConfig
---@field archives_dir string
---@field limit_archives_size number
---@field baseline_max_file_size? number
---@field retention_days? number
---@field prune_policy? 'preserve'|'delete'
---@field filter? fun(path: string, bufnr: number): boolean
---@field track_on? 'open'|'write'|'manual'
---@field logging? FundoLoggingConfig
---@field checkpoint? {enabled?: boolean, debounce_ms?: number, max_delay_ms?: number}
---@class FundoLoggingConfig
---@field enabled boolean
---@field level string
---@field path string
local def = {
    archives_dir = vim.fn.stdpath('cache') .. path.sep .. 'fundo',
    limit_archives_size = 512,
    prune_policy = 'preserve',
    track_on = 'open',
    checkpoint = {enabled = true, debounce_ms = 200, max_delay_ms = 1000},
    filter = function()
        return true
    end,
    logging = {
        enabled = false,
        level = 'warn',
        path = vim.fn.stdpath('cache') .. path.sep .. 'fundo.log'
    }
}

---@class FundoConfigModule: FundoConfig
---@field reload fun()
local Config
local defaultBaselineMaxFileSize = 8
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
    vim.validate('limit_archives_size', resolved.limit_archives_size, 'number')
    if resolved.baseline_max_file_size == nil then
        resolved.baseline_max_file_size = math.min(defaultBaselineMaxFileSize, resolved.limit_archives_size)
    end
    resolveLogging(resolved, userLogging)
    vim.validate('archives_dir', resolved.archives_dir, 'string')
    vim.validate('baseline_max_file_size', resolved.baseline_max_file_size, 'number')
    vim.validate('filter', resolved.filter, 'function')
    vim.validate('checkpoint', resolved.checkpoint, 'table')
    vim.validate('checkpoint.enabled', resolved.checkpoint.enabled, 'boolean')
    for _, key in ipairs({'debounce_ms', 'max_delay_ms'}) do
        local value = resolved.checkpoint[key]
        vim.validate('checkpoint.' .. key, value, 'number')
        if value ~= value or value <= 0 or value >= math.huge or value % 1 ~= 0 then
            error('checkpoint.' .. key .. ' must be a positive finite integer', 3)
        end
    end
    if resolved.checkpoint.max_delay_ms < resolved.checkpoint.debounce_ms then
        error('checkpoint.max_delay_ms must be at least checkpoint.debounce_ms', 3)
    end
    if resolved.prune_policy ~= 'preserve' and resolved.prune_policy ~= 'delete' then
        error('prune_policy must be preserve or delete', 3)
    end
    if resolved.track_on ~= 'open' and resolved.track_on ~= 'write' and resolved.track_on ~= 'manual' then
        error('track_on must be open, write, or manual', 3)
    end
    if resolved.retention_days ~= nil then
        vim.validate('retention_days', resolved.retention_days, 'number')
        if resolved.retention_days < 0 then
            error('retention_days must be greater than or equal to zero', 3)
        end
    end
    if resolved.baseline_max_file_size < 0 then
        error('baseline_max_file_size must be greater than or equal to zero', 3)
    end
    validateLogging(resolved.logging)
    local archivesDir = path.normalize(vim.fn.fnamemodify(vim.fn.expand(resolved.archives_dir), ':p'))
    if archivesDir ~= path.sep and not archivesDir:match('^%a:' .. path.sep .. '$') then
        archivesDir = archivesDir:gsub(path.sep .. '+$', '')
    end
    Config.archives_dir = archivesDir
    Config.limit_archives_size = resolved.limit_archives_size
    Config.baseline_max_file_size = resolved.baseline_max_file_size
    Config.retention_days = resolved.retention_days
    Config.prune_policy = resolved.prune_policy
    Config.filter = resolved.filter
    Config.track_on = resolved.track_on
    Config.checkpoint = vim.deepcopy(resolved.checkpoint)
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
    baseline_max_file_size = defaultBaselineMaxFileSize,
    retention_days = nil,
    prune_policy = def.prune_policy,
    filter = def.filter,
    track_on = def.track_on,
    checkpoint = vim.deepcopy(def.checkpoint),
    logging = vim.deepcopy(def.logging),
    reload = reload
}

Config.reload()

return Config

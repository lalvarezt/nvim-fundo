local M = {}

---Enable fundo
function M.enable()
    require('fundo.main').enable()
end

---Disable fundo
function M.disable()
    require('fundo.main').disable()
end

---Return preservation status for the current buffer, a buffer number, or a path.
---@param target? number|string
---@return table
function M.status(target)
    return require('fundo.diagnostics').status(target)
end

---Inspect the archive directory and return a health report.
---@return table
function M.doctor()
    return require('fundo.diagnostics').doctor()
end

---Setup configuration and enable fundo
---@param opts? FundoConfig
function M.setup(opts)
    opts = opts or {}
    M._config = opts
    if package.loaded['fundo.config'] then
        require('fundo.config').reload()
    end
    local disabled = M.disable()
    M.enable()
    local config = require('fundo.config')
    local log = require('fundo.lib.log')
    if disabled then
        log.debug('setup reloaded existing fundo instance')
    end
    log.debug('setup effective config:', {
        archives_dir = config.archives_dir,
        limit_archives_size = config.limit_archives_size,
        baseline_max_file_size = config.baseline_max_file_size,
        retention_days = config.retention_days,
        logging = config.logging
    })
    log.info('setup complete')
end

---Compatibility shim for older install snippets. Dependencies are vendored, so
---there is currently no install-time work to perform.
function M.install()
end

return M

--- Singleton
---@class FundoLog
---@field trace fun(...)
---@field debug fun(...)
---@field info fun(...)
---@field warn fun(...)
---@field error fun(...)
---@field configure fun(opts?: FundoLoggingConfig): boolean, any?
---@field setLevel fun(level: number|string)
---@field isEnabled fun(level: number|string): boolean
---@field level fun(): string
---@field enabled boolean
---@field path string
local Log = {}
local fn = vim.fn
local uv = vim.loop
local fs = require('fundo.fs')

---@type table<string, number>
local levelMap
local levelNr
local defaultLevel
local enabled
local writeError
local logDateFmt = '%y-%m-%d %T'
local logDirMode = 448 -- 0o700
local logFileMode = 384 -- 0o600
local isWindows = uv.os_uname().sysname == 'Windows_NT'

local function pathSep()
    return isWindows and [[\]] or '/'
end

local function defaultPath()
    return table.concat({fn.stdpath('cache'), 'fundo.log'}, pathSep())
end

local function dirname(p)
    return p:match('^(.+)[/\\][^/\\]+$')
end

local function getLevelNr(level)
    local nr
    if type(level) == 'number' then
        nr = level
    elseif type(level) == 'string' then
        nr = levelMap[level:upper()]
    else
        nr = defaultLevel
    end
    return nr or defaultLevel
end

---
---@param l number|string
function Log.setLevel(l)
    levelNr = getLevelNr(l)
end

---
---@param l number|string
---@return boolean
function Log.isEnabled(l)
    return enabled and not writeError and getLevelNr(l) >= levelNr
end

---
---@return string|'trace'|'debug'|'info'|'warn'|'error'
function Log.level()
    for l, nr in pairs(levelMap) do
        if nr == levelNr then
            return l:lower()
        end
    end
    return 'UNDEFINED'
end

local function inspect(v)
    local s
    local t = type(v)
    if t == 'nil' then
        s = 'nil'
    elseif t ~= 'string' then
        local ok, inspected = pcall(vim.inspect, v, {newline = ' ', indent = ''})
        s = ok and inspected or vim.inspect(v)
    elseif v == '' then
        s = '""'
    else
        s = tostring(v)
    end
    s = s:gsub('\r', '\\r')
    s = s:gsub('\n', '\\n')
    return s
end

---@param opts? FundoLoggingConfig
function Log.configure(opts)
    opts = opts or {}
    enabled = opts.enabled == true
    Log.enabled = enabled
    Log.path = fn.expand(opts.path or defaultPath())
    Log.setLevel(opts.level or defaultLevel)
    writeError = nil

    if enabled then
        local dir = dirname(Log.path)
        if dir then
            local ok, err = pcall(fs.mkdirpSync, dir, logDirMode)
            if not ok then
                writeError = err
                return false, err
            end
        end
        local fd, err = uv.fs_open(Log.path, 'a', logFileMode)
        if not fd then
            writeError = err or ('failed to open log file: ' .. Log.path)
            return false, writeError
        end
        local chmodOk, chmodErr = true, nil
        if not isWindows then
            chmodOk, chmodErr = uv.fs_chmod(Log.path, logFileMode)
        end
        local closeOk, closeErr = uv.fs_close(fd)
        if not chmodOk or not closeOk then
            writeError = chmodErr or closeErr or ('failed to secure log file: ' .. Log.path)
            return false, writeError
        end
    end
    return true
end

local function init()
    levelMap = {TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}
    defaultLevel = 3
    Log.configure({
        enabled = vim.env.FUNDO_LOG ~= nil and vim.env.FUNDO_LOG ~= '',
        level = vim.env.FUNDO_LOG,
        path = defaultPath()
    })

    for l in pairs(levelMap) do
        Log[l:lower()] = function(...)
            local argc = select('#', ...)
            if argc == 0 or not Log.isEnabled(l) then
                return false, writeError
            end
            local msgTbl = {}
            for i = 1, argc do
                local arg = select(i, ...)
                table.insert(msgTbl, inspect(arg))
            end
            local msg = table.concat(msgTbl, ' ')
            local info = debug.getinfo(2, 'Sl')
            local linfo = info.short_src:match('[^/]*$') .. ':' .. info.currentline

            local str = string.format('[%s] [%s] %s : %s\n', os.date(logDateFmt), l, linfo, msg)
            local ok, err = pcall(function()
                local fd, openErr = uv.fs_open(Log.path, 'a', logFileMode)
                if not fd then
                    error(openErr or ('failed to open log file: ' .. Log.path))
                end
                local _, writeErr = uv.fs_write(fd, str, -1)
                local closeOk, closeErr = uv.fs_close(fd)
                if writeErr or not closeOk then
                    error(writeErr or closeErr or ('failed to write log file: ' .. Log.path))
                end
            end)
            if not ok then
                writeError = err
                return false, err
            end
            return true
        end
    end
end

init()

return Log

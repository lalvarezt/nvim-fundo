local fn = vim.fn

local fs = require('fundo.fs')
local path = require('fundo.fs.path')
local utils = require('fundo.utils')

local M = {
    version = 1,
}

local dirMode = 448 -- 0o700
local fileMode = 384 -- 0o600

local escapes = {
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['"'] = '\\"',
    ['\\'] = '\\\\',
}

local function encodeString(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return escapes[char] or ('\\u%04x'):format(char:byte())
    end) .. '"'
end

local function encode(value)
    local kind = type(value)
    if kind == 'nil' then
        return 'null'
    elseif kind == 'boolean' or kind == 'number' then
        return tostring(value)
    elseif kind == 'string' then
        return encodeString(value)
    elseif kind ~= 'table' then
        error('cannot encode manifest value of type ' .. kind)
    end

    local keys = {}
    for key in pairs(value) do
        if type(key) ~= 'string' then
            error('manifest object keys must be strings')
        end
        table.insert(keys, key)
    end
    table.sort(keys)
    local fields = {}
    for _, key in ipairs(keys) do
        table.insert(fields, encodeString(key) .. ':' .. encode(value[key]))
    end
    return '{' .. table.concat(fields, ',') .. '}'
end

local function stat(pathname)
    local value = fs.statSync(pathname)
    if not value then
        return
    end
    return {
        dev = value.dev,
        ino = value.ino,
        mode = value.mode,
        mtime = value.mtime and value.mtime.sec or nil,
        size = value.size,
        type = value.type,
    }
end

function M.dir(archivesDir)
    return path.join(archivesDir, '.metadata')
end

function M.path(fallbackPath)
    return path.join(M.dir(path.dirname(fallbackPath)), path.basename(fallbackPath) .. '.json')
end

function M.isPath(pathname, archivesDir)
    return path.dirname(pathname) == M.dir(archivesDir)
end

function M.create(transfer)
    return {
        version = M.version,
        snapshot_format = transfer.snapshot_format,
        baseline_format = transfer.baseline_format,
        updated_at = os.time(),
        source = {
            path = path.normalize(transfer.name),
            stat = stat(transfer.name),
        },
        undo = {
            path = path.normalize(transfer.undoPath),
            stat = stat(transfer.undoPath),
        },
        fallback = {
            path = path.normalize(transfer.fallbackPath),
            stat = stat(transfer.fallbackPath),
        },
        baseline = fs.statSync(transfer.baselinePath) and {
            path = path.normalize(transfer.baselinePath),
            stat = stat(transfer.baselinePath),
        } or nil,
    }
end

function M.validate(value, expectedFallbackPath)
    if type(value) ~= 'table' then
        return false, 'manifest is not an object'
    end
    if value.version ~= M.version then
        return false, ('unsupported manifest version: %s'):format(tostring(value.version))
    end
    if type(value.updated_at) ~= 'number' then
        return false, 'manifest update time is missing'
    end
    if type(value.source) ~= 'table' or type(value.source.path) ~= 'string' then
        return false, 'manifest source path is missing'
    end
    if type(value.undo) ~= 'table' or type(value.undo.path) ~= 'string' then
        return false, 'manifest undo path is missing'
    end
    if type(value.fallback) ~= 'table' or type(value.fallback.path) ~= 'string' then
        return false, 'manifest fallback path is missing'
    end
    if expectedFallbackPath
        and path.normalize(value.fallback.path) ~= path.normalize(expectedFallbackPath) then
        return false, 'manifest fallback path does not match its archive'
    end
    return true
end

function M.read(manifestPath, expectedFallbackPath)
    if not fs.statSync(manifestPath) then
        return nil, 'missing'
    end
    local ok, lines = pcall(fn.readfile, manifestPath, 'b')
    if not ok then
        return nil, tostring(lines)
    end
    local decodedOk, value = pcall(fn.json_decode, table.concat(lines, '\n'))
    if not decodedOk then
        return nil, tostring(value)
    end
    local valid, err = M.validate(value, expectedFallbackPath)
    if not valid then
        return nil, err
    end
    return value
end

function M.write(transfer)
    local manifestPath = M.path(transfer.fallbackPath)
    fs.mkdirpSync(path.dirname(manifestPath), dirMode)
    if not utils.isWindows() then
        fs.chmodSync(path.dirname(manifestPath), dirMode)
    end
    fs.writeFileSync(manifestPath, encode(M.create(transfer)), fileMode)
    return manifestPath
end

return M

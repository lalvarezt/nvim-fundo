local async = require('async')
local uv = vim.loop
local uvw = require('fundo.fs.uvwrapper')
local path = require('fundo.fs.path')

local FS = setmetatable({}, {__index = uvw})

local function tempPath(target)
    return ('%s.__%d'):format(target, uv.hrtime())
end

for name in pairs(uvw) do
    FS[name .. 'Sync'] = uv['fs_' .. name]
end

function FS.copyFile(path, newPath)
    return async(function()
        local p = tempPath(newPath)
        await(uvw.copyfile(path, p))
        local ok, err = pcall(await, uvw.rename(p, newPath))
        if not ok then
            pcall(await, uvw.unlink(p))
            error(err)
        end
    end)
end

function FS.copyFileSync(path, newPath)
    local p = tempPath(newPath)
    local ok, err = uv.fs_copyfile(path, p)
    if not ok then
        error(err)
    end
    ok, err = uv.fs_rename(p, newPath)
    if not ok then
        pcall(uv.fs_unlink, p)
        error(err)
    end
end

function FS.mkdirpSync(dirpath, mode)
    local target = dirpath
    local normalized = path.normalize(target)
    local sep = path.sep
    local current = ''
    local start = 1

    if sep == '/' and normalized:sub(1, 1) == '/' then
        current = '/'
        start = 2
    elseif sep == [[\]] and normalized:match('^%a:[\\/]') then
        current = normalized:sub(1, 3)
        start = 4
    end

    local function ensure(dir)
        if dir == '' or dir == '.' or dir == sep then
            return
        end
        local stat = uv.fs_stat(dir)
        if stat then
            if stat.type ~= 'directory' then
                error(('path is not a directory: %s'):format(dir))
            end
            return
        end
        local ok, err = uv.fs_mkdir(dir, mode)
        if not ok then
            stat = uv.fs_stat(dir)
            if stat and stat.type == 'directory' then
                return
            end
            error(err or ('failed to create directory: %s'):format(dir))
        end
    end

    local segmentPattern = sep == [[\]] and [[[^\\]+]] or '[^/]+'
    for segment in normalized:sub(start):gmatch(segmentPattern) do
        current = current == '' and segment or path.join(current, segment)
        ensure(current)
    end

    local stat = uv.fs_stat(normalized)
    if not stat or stat.type ~= 'directory' then
        error(('path is not a directory: %s'):format(target))
    end
end

---@param path string
---@param bufferSize? number
---@param iterAction fun(entries: table): boolean?
---@return Promise
function FS.openDirStream(path, bufferSize, iterAction)

    return async(function()
        bufferSize = bufferSize or 32
        local dir = await(uvw.opendir(path, bufferSize))
        local entries
        local ok, res = pcall(function()
            repeat
                entries = await(uvw.readdir(dir))
                if await(iterAction(entries)) then
                    break
                end
            until not entries
        end)
        await(uvw.closedir(dir))
        assert(ok, res)
    end)
end

return FS

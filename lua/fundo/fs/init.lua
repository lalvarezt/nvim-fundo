local async = require('async')
local uv = vim.loop
local uvw = require('fundo.fs.uvwrapper')

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

function FS.mkdirpSync(path, mode)
    local ok = vim.fn.mkdir(path, 'p', mode) ~= 0
    local stat = uv.fs_stat(path)
    if not ok and not stat then
        error(('failed to create directory: %s'):format(path))
    end
    if not stat or stat.type ~= 'directory' then
        error(('path is not a directory: %s'):format(path))
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

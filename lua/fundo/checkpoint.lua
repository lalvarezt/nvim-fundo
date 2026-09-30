local api, uv = vim.api, vim.loop
local M = {}

function M.cancel(tracked)
    tracked.checkpointSerial = (tracked.checkpointSerial or 0) + 1
    tracked.checkpointStarted = nil
    if tracked.checkpointTimer then
        tracked.checkpointTimer:stop()
        tracked.checkpointTimer:close()
        tracked.checkpointTimer = nil
    end
end

local function queue(tracked, completed)
    local settings = require('fundo.config').checkpoint
    if not settings.enabled or not tracked.attached or tracked.recoveryBackup then return end
    local now = uv.hrtime() / 1e6
    tracked.checkpointStarted = tracked.checkpointStarted or now
    local delay = math.max(1, math.min(settings.debounce_ms,
        settings.max_delay_ms - (now - tracked.checkpointStarted)))
    tracked.checkpointSerial = (tracked.checkpointSerial or 0) + 1
    local serial = tracked.checkpointSerial
    tracked.checkpointTimer = tracked.checkpointTimer or uv.new_timer()
    tracked.checkpointTimer:start(delay, 0, function()
        vim.schedule(function()
            if not tracked.attached or tracked.checkpointSerial ~= serial
                or not api.nvim_buf_is_loaded(tracked.bufnr) then return end
            tracked.checkpointStarted = nil
            local ok, err = pcall(tracked.transferSync, tracked)
            completed(ok, err)
            if not ok then
                local message = tostring(err)
                local notice = tracked.checkpointNotice
                if not notice or notice.message ~= message or os.time() - notice.time >= 30 then
                    tracked.checkpointNotice = {message = message, time = os.time()}
                    vim.notify('Fundo checkpoint failed for ' .. tracked.name .. ': ' .. message
                        .. '; inspect :FundoDoctor for recovery copies', vim.log.levels.WARN)
                end
            end
        end)
    end)
end

function M.watch(tracked, completed)
    api.nvim_buf_attach(tracked.bufnr, false, {
        on_lines = function()
            if not tracked.attached then return true end
            queue(tracked, completed)
        end,
        on_reload = function()
            if not tracked.attached then return true end
            queue(tracked, completed)
        end,
        on_detach = function() M.cancel(tracked) end,
    })
end

return M

local api = vim.api
local M = {}

-- Yield to Neovim between inputs so Insert mode, completion, and checkpoint
-- timers run through the editor's event loop instead of a single Lua call.
function M.run(steps, complete)
    local bufnr = api.nvim_get_current_buf()
    local index = 0
    local function fail(err)
        io.stderr:write(tostring(err) .. '\n')
        os.exit(1)
    end
    local function advance()
        index = index + 1
        local step = steps[index]
        if not step then complete(); return end
        if step.lua then assert(loadstring(step.lua))() end
        if step.keys then api.nvim_input(step.keys) end
        local started = vim.loop.hrtime()
        local function check()
            local ok, err = xpcall(function()
                local elapsed = (vim.loop.hrtime() - started) / 1e6
                local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local mode = api.nvim_get_mode().mode
                local captureBuffer = step.checkpoint_buffer and _G[step.checkpoint_buffer] or bufnr
                local tracked = require('fundo.manager'):get(captureBuffer)
                local captured = step.checkpoint == false
                    or tracked.lastCapturedTick == api.nvim_buf_get_changedtick(captureBuffer)
                if vim.deep_equal(lines, step.lines) and mode == step.mode and captured
                    and elapsed >= (step.min_ms or 0) then
                    if step.seq ~= nil then assert(vim.fn.undotree().seq_cur == step.seq, 'undo position changed') end
                    advance()
                    return
                end
                assert(elapsed < 3000, ('input step %d timed out: mode=%s, captured=%s, lines=%s')
                    :format(index, mode, tostring(captured), vim.inspect(lines)))
                vim.defer_fn(check, 10)
            end, debug.traceback)
            if not ok then fail(err) end
        end
        vim.schedule(check)
    end
    vim.schedule(function()
        local ok, err = xpcall(advance, debug.traceback)
        if not ok then fail(err) end
    end)
end

return M

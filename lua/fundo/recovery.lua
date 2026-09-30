local api, fn = vim.api, vim.fn
local config = require('fundo.config')
local storage = require('fundo.storage')
local journal = require('fundo.journal')
local fs = require('fundo.fs')
local path = require('fundo.fs.path')
local Undo = require('fundo.model.undo')
local M = {}

local function source(target)
    local name = type(target) == 'string' and fn.fnamemodify(target, ':p')
        or api.nvim_buf_get_name(type(target) == 'number' and target or 0)
    assert(name ~= '', 'recovery requires a named source')
    name = path.normalize(name)
    local undoPath = fn.undofile(name)
    return name, Undo.archivePath(name, undoPath, config.archives_dir)
end

local function captures(target)
    local name, fallback = source(target)
    local result = {}
    local generations = storage.candidates(fallback)
    for _, capture in ipairs(generations) do
        if path.normalize(capture.name) == name then
            capture.id, capture.kind = capture.generation, 'generation'
            result[#result + 1] = capture
        end
    end
    local journals = journal.list(config.archives_dir, true)
    for _, capture in ipairs(journals) do
        if path.normalize(capture.name) == name then
            capture.id, capture.kind = 'journal:' .. path.basename(capture.journalPath), 'journal'
            result[#result + 1] = capture
        end
    end
    return result, fallback
end

function M.candidates(target)
    local result = {}
    for _, capture in ipairs(captures(target)) do
        result[#result + 1] = {
            id = capture.id, kind = capture.kind, name = capture.name,
            captured_at = capture.capturedAt, text_only = capture.textOnly == true,
            undo_available = capture.undoContents ~= nil, retained = capture.retained == true,
            path = capture.journalPath or path.join(storage.directory(capture.fallbackPath), capture.generation),
        }
    end
    return result
end

local function selected(id, target)
    for _, capture in ipairs(captures(target)) do
        if capture.id == id then return capture end
    end
    error('recovery capture is missing or damaged; inspect :FundoDoctor', 0)
end

function M.open(id, target)
    local capture = selected(id, target)
    local buffer = api.nvim_create_buf(true, true)
    local lines = vim.split(capture.contents, '\n', {plain = true})
    assert(lines[#lines] == '', 'incomplete recovery text')
    table.remove(lines)
    vim.bo[buffer].bufhidden = 'hide'
    vim.bo[buffer].undofile = false
    api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    local loaded, err = false, nil
    if capture.undoContents then
        local temporary = fn.tempname()
        local ok, failure = pcall(function()
            fs.writeFileSync(temporary, capture.undoContents)
            loaded, err = Undo:new(buffer, config.archives_dir):loadUndo(temporary)
        end)
        pcall(fs.unlinkSync, temporary)
        if not ok then err = tostring(failure) end
    end
    vim.bo[buffer].modified = true
    return {bufnr = buffer, id = id, undo_loaded = loaded, error = err}
end

function M.repair(id, target)
    local name, fallback = source(target)
    local capture = selected(id, target)
    assert(capture.kind == 'generation', 'pointer repair requires a generation; open journals with :FundoRecover')
    local revision = storage.revision(fallback)
    local manager = require('fundo.manager')
    local buffer = fn.bufnr(name)
    local tracked = manager.undos and manager.undos[buffer]
    if buffer >= 0 and api.nvim_buf_is_loaded(buffer) then
        assert(not vim.bo[buffer].modified, 'save or inspect the modified buffer before choosing archive history')
        assert(vim.bo[buffer].modifiable, 'pointer repair requires a modifiable source buffer')
        if tracked then
            local native = tracked:isEmpty() and tracked:textSnapshot() or tracked:transferSnapshot()
            native.baselineOnly = native.undoContents == nil
            storage.retain(native)
        end
    end
    local restored = storage.restorePointer(fallback, capture.generation, revision)
    if tracked then
        tracked.generation, tracked.checkedNative = restored.generation, true
        tracked.pendingTransfer, tracked.pendingRecovery, tracked.lastError = nil, nil, nil
        manager.pendingTransfers[fallback] = nil
        local loaded, reason = tracked:loadFallBack(restored)
        if not loaded and not restored.baselineOnly then error('pointer repaired; buffer recovery failed: ' .. tostring(reason), 0) end
    end
    return restored.generation
end

return M

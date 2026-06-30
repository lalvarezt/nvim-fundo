---@class FundoUvHandle
---@field close fun(self: FundoUvHandle, callback?: function)
---@field has_ref fun(self: FundoUvHandle): boolean
---@field is_closing fun(self: FundoUvHandle): boolean

---@class FundoUvTimer: FundoUvHandle
---@field start fun(self: FundoUvTimer, timeout: number, repeat_count: number, callback: function)
---@field stop fun(self: FundoUvTimer)
---@field again fun(self: FundoUvTimer)

---@class FundoUvIdle: FundoUvHandle
---@field start fun(self: FundoUvIdle, callback: function)
---@field stop fun(self: FundoUvIdle)

return {}

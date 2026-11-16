local appearance = require("csharp-explorer.ui.appearance")
local winbar = require("csharp-explorer.ui.winbar")

local M = {}

M.groups = appearance.groups
M.setup = appearance.setup
M.ensure = appearance.ensure

M.escape_winbar = winbar.escape_winbar
M.chunks_width = winbar.chunks_width
M.truncate_chunks = winbar.truncate_chunks
M.format_winbar = winbar.format_winbar

return M

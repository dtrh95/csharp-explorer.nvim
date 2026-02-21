local config = require("csharp-explorer.config")
local navigation = require("csharp-explorer.actions.navigation")
local fs_actions = require("csharp-explorer.actions.fs")
local clipboard = require("csharp-explorer.actions.clipboard")
local renderer = require("csharp-explorer.renderer")

local M = {}

local function bind_keys(keys, action, opts)
    if type(keys) == "table" then
        for _, k in ipairs(keys) do
            vim.keymap.set("n", k, action, opts)
        end
    elseif type(keys) == "string" then
        vim.keymap.set("n", keys, action, opts)
    end
end

function M.apply(state)
    local opts = { buffer = state.buf, silent = true }
    local km = config.current.keymaps

    -- Navigation
    bind_keys(km.close, state.toggle, opts)
    bind_keys(km.open, navigation.open_node(state, false), opts)
    bind_keys(km.vsplit, navigation.open_node(state, true), opts)
    bind_keys(km.close_node, navigation.close_node(state), opts)

    -- File operations (proxied to nvim-tree)
    bind_keys(km.create, fs_actions.proxy_fs(state, "create"), opts)
    bind_keys(km.delete, fs_actions.proxy_fs(state, "remove"), opts)
    bind_keys(km.rename, fs_actions.proxy_fs(state, "rename"), opts)

    -- Clipboard operations (standalone)
    bind_keys(km.copy, function()
        local node = navigation.get_node(state)
        if not node then return end
        clipboard.copy(node)
        renderer.render(state)
    end, opts)

    bind_keys(km.cut, function()
        local node = navigation.get_node(state)
        if not node then return end
        clipboard.cut(node)
        renderer.render(state)
    end, opts)

    bind_keys(km.paste, function()
        local node = navigation.get_node(state)
        if not node then return end
        clipboard.paste(node)
        -- Trigger tree refresh
        local node_utils = require("csharp-explorer.node")
        node_utils.reset_projects(state.tree)
        renderer.render(state)
    end, opts)

    bind_keys(km.toggle_gitignore, state.toggle_gitignore, opts)
end

return M

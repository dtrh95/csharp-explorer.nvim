local config = require("csharp-explorer.config")
local navigation = require("csharp-explorer.actions.navigation")
local properties = require("csharp-explorer.actions.properties")
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

    bind_keys(km.close, state.toggle, opts)

    if km.open then
        if type(km.open) == "table" then
            for _, k in ipairs(km.open) do
                if k:find("Mouse") then
                    vim.keymap.set("n", k, navigation.open_mouse(state), opts)
                else
                    vim.keymap.set("n", k, navigation.open_node(state, false), opts)
                end
            end
        elseif type(km.open) == "string" then
            if km.open:find("Mouse") then
                vim.keymap.set("n", km.open, navigation.open_mouse(state), opts)
            else
                vim.keymap.set("n", km.open, navigation.open_node(state, false), opts)
            end
        end
    end

    bind_keys(km.vsplit, navigation.open_node(state, true), opts)
    bind_keys(km.close_node, navigation.close_node(state), opts)
    if km.toggle_expand then
        bind_keys(km.toggle_expand, navigation.toggle_expand(state), opts)
    end
    bind_keys(km.expand_all, navigation.expand_all(state), opts)
    bind_keys(km.collapse_all, navigation.collapse_all(state), opts)
    bind_keys(km.open_properties, navigation.open_properties(state), opts)
    if km.item_properties then
        bind_keys(km.item_properties, properties.open(state), opts)
    end

    bind_keys(km.create, fs_actions.proxy_fs(state, "create"), opts)
    bind_keys(km.delete, fs_actions.proxy_fs(state, "remove"), opts)
    bind_keys(km.rename, fs_actions.proxy_fs(state, "rename"), opts)

    bind_keys(km.copy, function()
        local node = navigation.get_node(state)
        if not node then
            return
        end
        clipboard.copy(node)
        renderer.render(state)
    end, opts)

    bind_keys(km.cut, function()
        local node = navigation.get_node(state)
        if not node then
            return
        end
        clipboard.cut(node)
        renderer.render(state)
    end, opts)

    bind_keys(km.paste, function()
        local node = navigation.get_node(state)
        if not node then
            return
        end
        clipboard.paste(node)
        local node_utils = require("csharp-explorer.node")
        node_utils.reset_projects(state.tree)
        renderer.render(state)
    end, opts)

    bind_keys(km.toggle_gitignore, state.toggle_gitignore, opts)
end

return M

local config = require("csharp-explorer.config")
local navigation = require("csharp-explorer.actions.navigation")
local properties = require("csharp-explorer.actions.properties")
local clipboard = require("csharp-explorer.actions.clipboard")
local renderer = require("csharp-explorer.renderer")
local chrome = require("csharp-explorer.ui.chrome")

local M = {}

M.specs = {
    { id = "help", group = "Navigation", desc = "Show keyboard shortcuts" },
    { id = "close", group = "Navigation", desc = "Close explorer" },
    { id = "open", group = "Navigation", desc = "Open file or toggle folder" },
    { id = "vsplit", group = "Navigation", desc = "Open file in vertical split" },
    { id = "close_node", group = "Navigation", desc = "Collapse node or parent" },
    { id = "toggle_expand", group = "Navigation", desc = "Toggle expand node" },
    { id = "expand_all", group = "Navigation", desc = "Expand all nodes" },
    { id = "collapse_all", group = "Navigation", desc = "Collapse all nodes" },
    { id = "open_properties", group = "Navigation", desc = "Open project file" },
    { id = "item_properties", group = "Navigation", desc = "Show item properties" },
    { id = "toggle_gitignore", group = "Navigation", desc = "Toggle gitignored items" },
    { id = "reload_all", group = "Navigation", desc = "Reload projects and LSP" },

    { id = "create", group = "Edit & Refactor", desc = "Create new item" },
    { id = "delete", group = "Edit & Refactor", desc = "Delete item" },
    { id = "rename", group = "Edit & Refactor", desc = "Rename item" },
    { id = "copy", group = "Edit & Refactor", desc = "Copy item" },
    { id = "cut", group = "Edit & Refactor", desc = "Cut item" },
    { id = "paste", group = "Edit & Refactor", desc = "Paste item" },
    { id = "add", group = "Edit & Refactor", desc = "Add C# item from template" },
    { id = "sync_namespace", group = "Edit & Refactor", desc = "Sync namespace to folder path" },

    { id = "build", group = "Build & Test", desc = "Build project or solution" },
    { id = "restore", group = "Build & Test", desc = "Restore dependencies" },
    { id = "clean", group = "Build & Test", desc = "Clean build output" },
    { id = "test", group = "Build & Test", desc = "Run tests" },
    { id = "task_output", group = "Build & Test", desc = "Toggle task output window" },
    { id = "cancel_task", group = "Build & Test", desc = "Cancel running task" },

    { id = "run", group = "Run & Debug", desc = "Run project" },
    { id = "run_select", group = "Run & Debug", desc = "Select run profile" },
    { id = "run_window", group = "Run & Debug", desc = "Toggle run window" },
    { id = "debug", group = "Run & Debug", desc = "Debug project" },
    { id = "debug_select", group = "Run & Debug", desc = "Select debug profile" },
    { id = "debug_test", group = "Run & Debug", desc = "Debug unit tests" },
    { id = "debug_window", group = "Run & Debug", desc = "Toggle debug window" },
    { id = "manage_compounds", group = "Run & Debug", desc = "Manage compound launch configurations" },
    { id = "action_menu", group = "Run & Debug", desc = "Open action menu" },

    { id = "search_text", group = "Search", desc = "Search text in solution" },
    { id = "search_symbols", group = "Search", desc = "Search symbols in solution" },
    { id = "find_files", group = "Search", desc = "Find files in solution" },
}

local function resolve_action(id, state)
    if id == "help" then
        return function()
            M.open_help(state)
        end
    elseif id == "close" then
        return state.toggle
    elseif id == "vsplit" then
        return navigation.open_node(state, true)
    elseif id == "close_node" then
        return navigation.close_node(state)
    elseif id == "toggle_expand" then
        return navigation.toggle_expand(state)
    elseif id == "expand_all" then
        return navigation.expand_all(state)
    elseif id == "collapse_all" then
        return navigation.collapse_all(state)
    elseif id == "open_properties" then
        return navigation.open_properties(state)
    elseif id == "item_properties" then
        return properties.open(state)
    elseif id == "create" then
        return function()
            require("csharp-explorer.actions.refactor").create(state)
        end
    elseif id == "delete" then
        return function()
            require("csharp-explorer.actions.refactor").delete(state)
        end
    elseif id == "rename" then
        return function()
            require("csharp-explorer.actions.refactor").rename(state)
        end
    elseif id == "copy" then
        return function()
            local node = navigation.get_node(state)
            if node then
                clipboard.copy(node)
                renderer.render(state)
            end
        end
    elseif id == "cut" then
        return function()
            local node = navigation.get_node(state)
            if node then
                clipboard.cut(node)
                renderer.render(state)
            end
        end
    elseif id == "paste" then
        return function()
            local node = navigation.get_node(state)
            if node then
                clipboard.paste(node, state)
            end
        end
    elseif id == "toggle_gitignore" then
        return state.toggle_gitignore
    elseif id == "build" then
        return function()
            require("csharp-explorer.actions.build").execute(state, "build")
        end
    elseif id == "restore" then
        return function()
            require("csharp-explorer.actions.build").execute(state, "restore")
        end
    elseif id == "clean" then
        return function()
            require("csharp-explorer.actions.build").execute(state, "clean")
        end
    elseif id == "test" then
        return function()
            require("csharp-explorer.actions.test").run_target(state)
        end
    elseif id == "add" then
        return function()
            require("csharp-explorer.actions.templates").add(state)
        end
    elseif id == "action_menu" then
        return function()
            require("csharp-explorer.actions.templates").action_menu(state)
        end
    elseif id == "task_output" then
        return function()
            require("csharp-explorer.runner").toggle_output()
        end
    elseif id == "cancel_task" then
        return function()
            require("csharp-explorer.runner").cancel()
        end
    elseif id == "sync_namespace" then
        return function()
            require("csharp-explorer.actions.namespace").sync_target(state)
        end
    elseif id == "search_text" then
        return function()
            require("csharp-explorer.actions.search").grep(state)
        end
    elseif id == "search_symbols" then
        return function()
            require("csharp-explorer.actions.search").symbols(state)
        end
    elseif id == "find_files" then
        return function()
            require("csharp-explorer.actions.search").files(state)
        end
    elseif id == "run" then
        return function()
            require("csharp-explorer.actions.run").run_target(state)
        end
    elseif id == "run_select" then
        return function()
            require("csharp-explorer.actions.run").select_run_profile(state)
        end
    elseif id == "run_window" then
        return function()
            require("csharp-explorer.actions.run").toggle_run_window(state)
        end
    elseif id == "debug" then
        return function()
            require("csharp-explorer.actions.debug").debug_target(state)
        end
    elseif id == "debug_select" then
        return function()
            require("csharp-explorer.actions.debug").select_debug_profile(state)
        end
    elseif id == "debug_test" then
        return function()
            require("csharp-explorer.actions.test").debug_test(state)
        end
    elseif id == "debug_window" then
        return function()
            require("csharp-explorer.ui.debug_window").toggle(state)
        end
    elseif id == "manage_compounds" then
        return function()
            require("csharp-explorer.compound").manage_compounds(state)
        end
    elseif id == "reload_all" then
        return function()
            require("csharp-explorer.reload").reload_all(state)
        end
    end
end

function M.apply(state)
    local km = config.current.keymaps
    for _, spec in ipairs(M.specs) do
        local keys = km[spec.id]
        if keys then
            local key_list = type(keys) == "table" and keys or { keys }
            for _, k in ipairs(key_list) do
                local action
                if spec.id == "open" then
                    if k:find("Mouse") then
                        action = navigation.open_mouse(state)
                    else
                        action = navigation.open_node(state, false)
                    end
                else
                    action = resolve_action(spec.id, state)
                end
                if action then
                    vim.keymap.set("n", k, action, {
                        buffer = state.buf,
                        silent = true,
                        nowait = true,
                        desc = spec.desc,
                    })
                end
            end
        end
    end
end

function M.open_help(_state)
    local km = config.current.keymaps
    local group_order = { "Navigation", "Edit & Refactor", "Build & Test", "Run & Debug", "Search" }
    local grouped = {}
    for _, g in ipairs(group_order) do
        grouped[g] = {}
    end

    for _, spec in ipairs(M.specs) do
        local keys = km[spec.id]
        if keys then
            local key_str
            if type(keys) == "table" then
                key_str = table.concat(keys, " / ")
            else
                key_str = tostring(keys)
            end
            local list = grouped[spec.group]
            if list then
                list[#list + 1] = {
                    key = key_str,
                    desc = spec.desc,
                }
            end
        end
    end

    local sections = {}
    for _, g in ipairs(group_order) do
        if #grouped[g] > 0 then
            sections[#sections + 1] = {
                title = g,
                items = grouped[g],
            }
        end
    end

    return chrome.show_help_modal("C# Explorer Shortcuts", sections)
end

return M

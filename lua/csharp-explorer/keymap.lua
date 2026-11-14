local config = require("csharp-explorer.config")
local navigation = require("csharp-explorer.actions.navigation")
local properties = require("csharp-explorer.actions.properties")
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

    bind_keys(km.create, function()
        require("csharp-explorer.actions.refactor").create(state)
    end, opts)
    bind_keys(km.delete, function()
        require("csharp-explorer.actions.refactor").delete(state)
    end, opts)
    bind_keys(km.rename, function()
        require("csharp-explorer.actions.refactor").rename(state)
    end, opts)

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
        clipboard.paste(node, state)
    end, opts)

    bind_keys(km.toggle_gitignore, state.toggle_gitignore, opts)

    if km.build then
        bind_keys(km.build, function()
            require("csharp-explorer.actions.build").execute(state, "build")
        end, opts)
    end
    if km.restore then
        bind_keys(km.restore, function()
            require("csharp-explorer.actions.build").execute(state, "restore")
        end, opts)
    end
    if km.clean then
        bind_keys(km.clean, function()
            require("csharp-explorer.actions.build").execute(state, "clean")
        end, opts)
    end
    if km.test then
        bind_keys(km.test, function()
            require("csharp-explorer.actions.test").run_target(state)
        end, opts)
    end
    if km.add then
        bind_keys(km.add, function()
            require("csharp-explorer.actions.templates").add(state)
        end, opts)
    end
    if km.action_menu then
        bind_keys(km.action_menu, function()
            require("csharp-explorer.actions.templates").action_menu(state)
        end, opts)
    end
    if km.task_output then
        bind_keys(km.task_output, function()
            require("csharp-explorer.runner").toggle_output()
        end, opts)
    end
    if km.cancel_task then
        bind_keys(km.cancel_task, function()
            require("csharp-explorer.runner").cancel()
        end, opts)
    end
    if km.sync_namespace then
        bind_keys(km.sync_namespace, function()
            require("csharp-explorer.actions.namespace").sync_target(state)
        end, opts)
    end
    if km.search_text then
        bind_keys(km.search_text, function()
            require("csharp-explorer.actions.search").grep(state)
        end, opts)
    end
    if km.search_symbols then
        bind_keys(km.search_symbols, function()
            require("csharp-explorer.actions.search").symbols(state)
        end, opts)
    end
    if km.find_files then
        bind_keys(km.find_files, function()
            require("csharp-explorer.actions.search").files(state)
        end, opts)
    end
    if km.run then
        bind_keys(km.run, function()
            require("csharp-explorer.actions.run").run_target(state)
        end, opts)
    end
    if km.run_select then
        bind_keys(km.run_select, function()
            require("csharp-explorer.actions.run").select_run_profile(state)
        end, opts)
    end
    if km.run_window then
        bind_keys(km.run_window, function()
            require("csharp-explorer.actions.run").toggle_run_window(state)
        end, opts)
    end
    if km.manage_compounds then
        bind_keys(km.manage_compounds, function()
            require("csharp-explorer.compound").manage_compounds(state)
        end, opts)
    end
    if km.reload_all then
        bind_keys(km.reload_all, function()
            require("csharp-explorer.reload").reload_all(state)
        end, opts)
    end
end

return M

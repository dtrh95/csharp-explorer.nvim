local renderer = require("csharp-explorer.renderer")

local M = {}

function M.get_node(state)
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    return renderer.line_to_node[cursor[1]]
end

function M.open_node(state, vsplit)
    return function()
        local node = M.get_node(state)
        if not node then
            return
        end

        if node._has_children then
            node._expanded = not node._expanded
            renderer.render(state)
            vim.api.nvim_win_set_cursor(state.win, { node._line_num, 0 })
        elseif node._type == "cs_file" or node._type == "appsettings" or node._type == "dockerfile" or node._type == "http_file" then
            vim.cmd("wincmd p")
            if vsplit then
                vim.cmd("vsplit " .. vim.fn.fnameescape(node._path))
            else
                vim.cmd("edit " .. vim.fn.fnameescape(node._path))
            end
        end
    end
end

function M.close_node(state)
    return function()
        local node = M.get_node(state)
        if not node then
            return
        end

        if node._has_children and node._expanded then
            node._expanded = false
            renderer.render(state)
            vim.api.nvim_win_set_cursor(state.win, { node._line_num, 0 })
        else
            if node._parent and node._parent._line_num then
                vim.api.nvim_win_set_cursor(state.win, { node._parent._line_num, 0 })
            end
        end
    end
end

local function set_expanded_recursive(node, expanded)
    if node._has_children then
        if node._type == "project" and expanded and not node._cs_loaded then
            local node_utils = require("csharp-explorer.node")
            node_utils.populate_cs_files(node)
        end
        node._expanded = expanded
        if node._children then
            for _, child in pairs(node._children) do
                set_expanded_recursive(child, expanded)
            end
        end
    end
end

function M.expand_all(state)
    return function()
        if not state.tree then return end
        set_expanded_recursive(state.tree, true)
        renderer.render(state)
    end
end

function M.collapse_all(state)
    return function()
        if not state.tree then return end
        if state.tree._children then
            for _, child in pairs(state.tree._children) do
                set_expanded_recursive(child, false)
            end
        end
        -- keep the root solution expanded
        state.tree._expanded = true
        renderer.render(state)
    end
end

return M

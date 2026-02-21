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
        elseif node._type == "cs_file" then
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

return M

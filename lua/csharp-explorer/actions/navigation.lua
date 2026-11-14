local renderer = require("csharp-explorer.renderer")
local metadata = require("csharp-explorer.metadata")
local node_utils = require("csharp-explorer.node")
local uv = vim.uv or vim.loop

local M = {}

local function focus_editor_window(state)
    local alt = vim.fn.win_getid(vim.fn.winnr("#"))
    if
        alt ~= 0
        and alt ~= state.win
        and vim.api.nvim_win_is_valid(alt)
        and vim.api.nvim_win_get_config(alt).relative == ""
    then
        vim.api.nvim_set_current_win(alt)
        return
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= state.win and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative == "" then
            vim.api.nvim_set_current_win(w)
            return
        end
    end
    vim.cmd("rightbelow vsplit")
end

M.focus_editor_window = focus_editor_window

function M.get_node(state)
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    return renderer.line_to_node[cursor[1]]
end

function M.reveal_project_in_tree(state, abs_path)
    if not state.tree or not abs_path then
        return false
    end
    local norm = metadata.normalize_path(abs_path):lower()
    local matched_node = nil

    local function search_and_expand(n)
        if n._type == "project" and n._path and metadata.normalize_path(n._path):lower() == norm then
            matched_node = n
            return true
        end
        if n._children and (n._type == "solution" or n._type == "folder") then
            for _, child in pairs(n._children) do
                if search_and_expand(child) then
                    n._expanded = true
                    return true
                end
            end
        end
        return false
    end

    if not search_and_expand(state.tree) or not matched_node then
        return false
    end

    matched_node._expanded = true
    renderer.render(state)
    if matched_node._line_num and state.win and vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_win_set_cursor(state.win, { matched_node._line_num, 0 })
        vim.api.nvim_win_call(state.win, function()
            vim.cmd("normal! zz")
        end)
    end
    return true
end

function M.toggle_expand(state)
    return function()
        local node = M.get_node(state)
        if not node then
            return
        end
        if node_utils.can_expand(node) then
            node._expanded = not node._expanded
            renderer.render(state)
            if node._line_num then
                vim.api.nvim_win_set_cursor(state.win, { node._line_num, 0 })
            end
        end
    end
end

function M.open_node(state, vsplit)
    return function()
        local node = M.get_node(state)
        if not node then
            return
        end

        if not node_utils.is_file(node) and node_utils.can_expand(node) then
            node._expanded = not node._expanded
            renderer.render(state)
            if node._line_num then
                vim.api.nvim_win_set_cursor(state.win, { node._line_num, 0 })
            end
            return
        end

        if node._type == "project_reference" then
            local target_path = node._target_path
            if not target_path then
                return
            end

            if not vsplit and M.reveal_project_in_tree(state, target_path) then
                return
            end

            if uv.fs_stat(target_path) then
                focus_editor_window(state)
                local cmd = vsplit and "vsplit " or "edit "
                vim.cmd(cmd .. vim.fn.fnameescape(target_path))
            else
                vim.notify("Project file not found: " .. target_path, vim.log.levels.WARN)
            end
            return
        end

        if node._type == "package" then
            local pkg = node._package_info
            if pkg then
                local ver_str = pkg.resolved_version or (pkg.version ~= "" and pkg.version) or "unspecified"
                local cpm_tag = pkg.is_cpm and " [CPM]" or ""
                vim.notify(string.format("NuGet Package: %s v%s%s", pkg.name, ver_str, cpm_tag), vim.log.levels.INFO)
            end
            return
        end

        if node_utils.is_file(node) or node._path then
            if node._path then
                focus_editor_window(state)
                local cmd = vsplit and "vsplit " or "edit "
                vim.cmd(cmd .. vim.fn.fnameescape(node._path))
            end
        end
    end
end

function M.open_mouse(state)
    return function()
        local pos = vim.fn.getmousepos()
        if pos and pos.winid == state.win and pos.line > 0 then
            vim.api.nvim_win_set_cursor(state.win, { pos.line, 0 })
            local node = renderer.line_to_node[pos.line]
            if node and node_utils.can_expand(node) and pos.column > 0 and pos.column <= (node._arrow_end_col or 2) then
                node._expanded = not node._expanded
                renderer.render(state)
                if node._line_num then
                    vim.api.nvim_win_set_cursor(state.win, { node._line_num, 0 })
                end
                return
            end
        end
        M.open_node(state, false)()
    end
end

function M.close_node(state)
    return function()
        local node = M.get_node(state)
        if not node then
            return
        end

        if node_utils.can_expand(node) and node._expanded then
            node._expanded = false
            renderer.render(state)
            if node._line_num then
                vim.api.nvim_win_set_cursor(state.win, { node._line_num, 0 })
            end
        elseif node._parent and node._parent._line_num then
            vim.api.nvim_win_set_cursor(state.win, { node._parent._line_num, 0 })
        end
    end
end

local function set_expanded_recursive(node, expanded, root_tree)
    if node._has_children then
        if node._virtual then
            return
        end
        if node._type == "project" and expanded then
            if not node._cs_loaded then
                node_utils.populate_cs_files(node)
            end
            if not node._meta_loaded then
                node_utils.populate_dependencies(node, root_tree)
            end
        end
        node._expanded = expanded
        if node._children then
            for _, child in pairs(node._children) do
                set_expanded_recursive(child, expanded, root_tree)
            end
        end
    end
end

function M.expand_all(state)
    return function()
        if not state.tree then
            return
        end
        set_expanded_recursive(state.tree, true, state.tree)
        renderer.render(state)
    end
end

function M.collapse_all(state)
    return function()
        if not state.tree then
            return
        end
        if state.tree._children then
            for _, child in pairs(state.tree._children) do
                set_expanded_recursive(child, false, state.tree)
            end
        end
        state.tree._expanded = true
        renderer.render(state)
    end
end

function M.open_properties(state)
    return function()
        local current_win = vim.api.nvim_get_current_win()
        if state.win and vim.api.nvim_win_is_valid(state.win) and current_win == state.win then
            local node = M.get_node(state)
            if not node then
                return
            end
            local curr = node
            while curr and curr._type ~= "project" and curr._parent do
                curr = curr._parent
            end
            if curr and curr._type == "project" and curr._path then
                focus_editor_window(state)
                vim.cmd("edit " .. vim.fn.fnameescape(curr._path))
            else
                vim.notify("Cursor is not inside a C# project", vim.log.levels.WARN)
            end
            return
        end

        local buf_name = vim.api.nvim_buf_get_name(0)
        if buf_name == "" then
            vim.notify("No active file buffer", vim.log.levels.WARN)
            return
        end

        if state.ensure_tree then
            state.ensure_tree()
        end

        local proj_node = metadata.find_owning_project(buf_name, state.tree)
        if proj_node and proj_node._path then
            vim.cmd("edit " .. vim.fn.fnameescape(proj_node._path))
        else
            vim.notify(
                "Could not find owning C# project for: " .. vim.fn.fnamemodify(buf_name, ":t"),
                vim.log.levels.WARN
            )
        end
    end
end

return M

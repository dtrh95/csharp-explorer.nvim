local config = require("csharp-explorer.config")
local node_utils = require("csharp-explorer.node")
local clipboard = require("csharp-explorer.actions.clipboard")

local M = {}

M.line_to_node = {}

local function ensure_hl_groups()
    vim.api.nvim_set_hl(0, "CSharpExplorerCut", {
        sp = "#e5c07b",
        undercurl = true,
        italic = true,
    })
    vim.api.nvim_set_hl(0, "CSharpExplorerCopied", {
        sp = "#56b6c2",
        undercurl = true,
    })
end

function M.render(state)
    if not state.tree or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        return
    end

    ensure_hl_groups()

    local lines = {}
    local hl_map = {}
    M.line_to_node = {}

    local function build_lines(node, indent, parent)
        node._parent = parent
        local icon = ""
        local hl = "Normal"

        if node._type == "solution" then
            icon = config.current.icons.solution
            hl = "Keyword"
        elseif node._type == "folder" then
            icon = node._expanded and config.current.icons.folder_open or config.current.icons.folder_closed
            hl = "Directory"
        elseif node._type == "project" then
            icon = config.current.icons.project
            hl = "Type"
        elseif node._type == "cs_file" then
            icon = config.current.icons.cs_file
            hl = "String"
        end

        local display = indent .. icon .. node._name
        table.insert(lines, display)
        node._line_num = #lines
        M.line_to_node[#lines] = node

        table.insert(hl_map, { line = #lines - 1, col_start = #indent, col_end = #indent + #icon, hl = hl })

        if node._expanded and node._has_children then
            if node._type == "project" and not node._cs_loaded then
                node_utils.populate_cs_files(node)
            end

            local keys = {}
            for k, _ in pairs(node._children) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b)
                local nodeA = node._children[a]
                local nodeB = node._children[b]
                if nodeA._type == "folder" and nodeB._type ~= "folder" then
                    return true
                end
                if nodeB._type == "folder" and nodeA._type ~= "folder" then
                    return false
                end
                return a < b
            end)

            for _, k in ipairs(keys) do
                build_lines(node._children[k], indent .. "  ", node)
            end
        end
    end

    build_lines(state.tree, "", nil)

    vim.bo[state.buf].readonly = false
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false
    vim.bo[state.buf].readonly = true

    local ns = vim.api.nvim_create_namespace("CSharpExplorer")
    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)

    for _, h in ipairs(hl_map) do
        pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, h.hl, h.line, h.col_start, h.col_end)
    end

    for line_num, node in pairs(M.line_to_node) do
        local node_path = node._path or node._dir
        if node_path then
            local clip_hl = nil
            if clipboard.is_cut(node_path) then
                clip_hl = "CSharpExplorerCut"
            elseif clipboard.is_copied(node_path) then
                clip_hl = "CSharpExplorerCopied"
            end
            if clip_hl then
                pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, line_num - 1, 0, {
                    end_col = #lines[line_num],
                    hl_group = clip_hl,
                    priority = 200,
                })
            end
        end
    end
end

return M

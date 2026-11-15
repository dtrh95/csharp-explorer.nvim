local config = require("csharp-explorer.config")
local node_utils = require("csharp-explorer.node")
local metadata = require("csharp-explorer.metadata")
local clipboard = require("csharp-explorer.actions.clipboard")
local theme = require("csharp-explorer.ui.theme")
local chrome = require("csharp-explorer.ui.chrome")

local M = {}

M.line_to_node = {}
M.process_ns_id = vim.api.nvim_create_namespace("CSharpExplorerProcess")

function M.render(state)
    if not state.tree or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        return
    end

    theme.ensure()

    local lines = {}
    local hl_map = {}
    M.line_to_node = {}

    local function build_lines(node, indent, parent)
        node._parent = parent
        local icon = ""
        local hl = "CSharpExplorerTreeFile"

        if node._type == "solution" then
            icon = config.current.icons.solution
            hl = "CSharpExplorerTreeRoot"
        elseif node._type == "folder" then
            icon = node._expanded and config.current.icons.folder_open or config.current.icons.folder_closed
            hl = "CSharpExplorerTreeFolder"
        elseif node._type == "project" then
            if config.current.dynamic_icons and config.current.dynamic_icons.enabled ~= false and node._path then
                node._archetype = node._archetype or metadata.get_project_profile(node._path).archetype
                icon = config.current.icons["project_" .. node._archetype] or config.current.icons.project
                hl = (config.current.project_highlights and config.current.project_highlights[node._archetype])
                    or "CSharpExplorerTreeProject"
            else
                icon = config.current.icons.project
                hl = "CSharpExplorerTreeProject"
            end
        elseif node_utils.is_file(node) then
            icon = config.current.icons[node._type] or config.current.icons.cs_file
            hl = "CSharpExplorerAccent"
        elseif node._type == "dependencies" then
            icon = config.current.icons.dependencies
            hl = "CSharpExplorerTreeDeps"
        elseif node._type == "package_group" or node._type == "package" then
            icon = config.current.icons[node._type]
            hl = "CSharpExplorerTreeDeps"
        elseif node._type == "project_reference_group" or node._type == "project_reference" then
            icon = config.current.icons[node._type]
            hl = "CSharpExplorerTreeDeps"
        end

        local arrow
        if node._has_children then
            arrow = node._expanded and config.current.icons.arrow_open or config.current.icons.arrow_closed
        else
            arrow = "  "
        end

        local name_hl
        if node._type == "solution" then
            name_hl = "CSharpExplorerTreeRoot"
        elseif node._type == "project" then
            name_hl = (
                config.current.dynamic_icons
                and config.current.dynamic_icons.enabled ~= false
                and node._archetype
                and config.current.project_highlights
                and config.current.project_highlights[node._archetype]
            ) or "CSharpExplorerTreeProject"
        elseif node._type == "folder" or node._type == "solution_folder" then
            name_hl = "CSharpExplorerTreeFolder"
        elseif
            node._type == "dependencies"
            or node._type == "package_group"
            or node._type == "project_reference_group"
            or node._type == "package"
            or node._type == "project_reference"
        then
            name_hl = "CSharpExplorerTreeDeps"
        else
            name_hl = "CSharpExplorerTreeFile"
        end

        local display = indent .. arrow .. icon .. node._name
        table.insert(lines, display)
        node._line_num = #lines
        node._arrow_end_col = vim.fn.strdisplaywidth(indent .. arrow)
        M.line_to_node[#lines] = node

        local col_start = #indent + #arrow
        table.insert(hl_map, { line = #lines - 1, col_start = col_start, col_end = col_start + #icon, hl = hl })
        table.insert(hl_map, {
            line = #lines - 1,
            col_start = col_start + #icon,
            col_end = col_start + #icon + #node._name,
            hl = name_hl,
        })

        if node._expanded and node._has_children then
            if node._type == "project" then
                if not node._cs_loaded then
                    node_utils.populate_cs_files(node)
                end
                if not node._meta_loaded then
                    node_utils.populate_dependencies(node, state.tree)
                end
            end

            local keys = {}
            for k, _ in pairs(node._children) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b)
                local node_a = node._children[a]
                local node_b = node._children[b]
                local prio_a = node_utils.get_priority(node_a)
                local prio_b = node_utils.get_priority(node_b)
                if prio_a ~= prio_b then
                    return prio_a < prio_b
                end
                return a:lower() < b:lower()
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

    if package.loaded["csharp-explorer.diagnostics"] then
        require("csharp-explorer.diagnostics").render_extmarks(state)
    end

    M.render_process_badges(state)

    if state.win and vim.api.nvim_win_is_valid(state.win) then
        local sol_name = (state.tree and state.tree._name) or vim.fs.basename(state.solution_path or "")
        local sol_icon = (config.current.icons and config.current.icons.solution) or "󰘐 "
        chrome.set_winbar(
            state.win,
            { { " " .. sol_icon .. sol_name, "CSharpExplorerTreeRoot" } },
            { { "? Help ", "CSharpExplorerMuted" } }
        )
    end
end

function M.render_process_badges(state)
    if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(state.buf, M.process_ns_id, 0, -1)

    local ok_dbg, debug_engine = pcall(require, "csharp-explorer.debug")
    local ok_proc, process = pcall(require, "csharp-explorer.process")

    for line_num, node in pairs(M.line_to_node) do
        local node_path = node._path or node.path
        if node._type == "project" and node_path then
            local text, hl = nil, nil

            local active_dbg, failed_dbg = nil, nil
            if ok_dbg and debug_engine and debug_engine.get_project_sessions then
                local dbg_sessions = debug_engine.get_project_sessions(node_path)
                for _, s in ipairs(dbg_sessions) do
                    if s.status == "paused" then
                        active_dbg = s
                        break
                    elseif s.status == "running" then
                        if not active_dbg or active_dbg.status ~= "paused" then
                            active_dbg = s
                        end
                    elseif s.status == "building" or s.status == "starting" or s.status == "queued" then
                        if not active_dbg or (active_dbg.status ~= "paused" and active_dbg.status ~= "running") then
                            active_dbg = s
                        end
                    elseif s.status == "failed" and not failed_dbg then
                        failed_dbg = s
                    end
                end
            end

            local active_proc, failed_proc = nil, nil
            if ok_proc and process and process.get_project_sessions then
                local proc_sessions = process.get_project_sessions(node_path)
                for _, s in ipairs(proc_sessions) do
                    if s.status == "running" then
                        active_proc = s
                        break
                    elseif s.status == "starting" or s.status == "stopping" then
                        if not active_proc then
                            active_proc = s
                        end
                    elseif s.status == "failed" and not failed_proc then
                        failed_proc = s
                    end
                end
            end

            if active_dbg then
                if active_dbg.status == "paused" then
                    hl = "CSharpExplorerBadgeWarn"
                    local l = (active_dbg.current_frame and active_dbg.current_frame.line) or "?"
                    text = " ⏸ L" .. tostring(l) .. " "
                elseif active_dbg.status == "running" then
                    hl = "CSharpExplorerBadgeOk"
                    local port = nil
                    if active_dbg.detected_urls and #active_dbg.detected_urls > 0 then
                        port = active_dbg.detected_urls[1]:match(":(%d+)")
                    end
                    text = port and string.format(" ● debug :%s ", port) or " ● debug "
                else
                    hl = "CSharpExplorerBadgeWarn"
                    text = " ◐ building "
                end
            elseif active_proc then
                if active_proc.status == "running" then
                    hl = "CSharpExplorerBadgeOk"
                    local port = nil
                    if active_proc.detected_urls and #active_proc.detected_urls > 0 then
                        port = active_proc.detected_urls[1]:match(":(%d+)")
                    end
                    text = port and string.format(" ● :%s ", port) or " ● running "
                elseif active_proc.status == "starting" then
                    hl = "CSharpExplorerBadgeWarn"
                    text = " ◐ starting "
                elseif active_proc.status == "stopping" then
                    hl = "CSharpExplorerBadgeMuted"
                    text = " ◌ stopping "
                end
            elseif failed_dbg then
                hl = "CSharpExplorerBadgeError"
                text = " ✗ failed "
            elseif failed_proc then
                hl = "CSharpExplorerBadgeError"
                text = string.format(" ▲ exit %s ", tostring(failed_proc.exit_code or 1))
            end

            if text and hl then
                pcall(vim.api.nvim_buf_set_extmark, state.buf, M.process_ns_id, line_num - 1, 0, {
                    virt_text = { { text, hl } },
                    virt_text_pos = "right_align",
                    priority = 160,
                })
            end
        end
    end
end

return M

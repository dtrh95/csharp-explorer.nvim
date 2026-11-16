local config = require("csharp-explorer.config")
local node_utils = require("csharp-explorer.node")
local clipboard = require("csharp-explorer.actions.clipboard")
local git = require("csharp-explorer.git")
local appearance = require("csharp-explorer.ui.appearance")
local chrome = require("csharp-explorer.ui.chrome")

local M = {}

M.line_to_node = {}
M.process_ns_id = vim.api.nvim_create_namespace("CSharpExplorerProcess")

function M.build_sidebar_winbar_chunks(state)
    local sol_name = (state.tree and state.tree._name) or vim.fs.basename(state.solution_path or "")
    local sol_icon = (config.current.icons and config.current.icons.solution) or "󰘐 "
    local left = {
        { " " .. sol_icon .. sol_name, "CSharpExplorerTreeRoot" },
    }
    local git_cfg = config.current.git or {}
    if git_cfg.enable ~= false and git_cfg.show_branch ~= false and state.tree then
        local branch = git.get_branch(state.tree)
        if branch and branch ~= "" then
            left[#left + 1] = { "   " .. branch, "CSharpExplorerGitBranch" }
        end
    end
    local right = {
        { "? Help ", "CSharpExplorerMuted" },
    }
    return left, right
end

function M.render(state)
    if not state.tree or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        return
    end

    appearance.ensure()

    local lines = {}
    local hl_map = {}
    M.line_to_node = {}

    local git_cfg = config.current.git or {}
    local git_placement = git_cfg.placement or "right_align"
    local show_ignored_badges = config.current.filter and config.current.filter.gitignored == false

    local function build_lines(node, indent, parent)
        if git.should_hide_node(node) then
            return
        end

        node._parent = parent
        local node_path = node._path or node._dir
        local is_cut = node_path and clipboard.is_cut(node_path) or false
        local is_copied = node_path and clipboard.is_copied(node_path) or false

        local diag_summary = nil
        if appearance.config and appearance.config.highlight_diagnostics ~= "none" then
            local diags = package.loaded["csharp-explorer.diagnostics"]
            if diags and config.current.diagnostics and config.current.diagnostics.enabled ~= false then
                diag_summary = diags.get_node_display_summary(node, config.current.diagnostics)
            end
        end

        local git_status = git.get_node_status(node)

        local style = appearance.resolve_node_style(node, {
            is_cut = is_cut,
            is_copied = is_copied,
            diagnostics = diag_summary,
            git = git_status,
        })

        local show_git_badge = git_status
            and git_status.badge
            and (git_status.is_dirty or (show_ignored_badges and git_status.is_ignored))

        local git_before = (show_git_badge and git_placement == "before") and (git_status.badge .. " ") or ""
        local git_after = (show_git_badge and git_placement == "after") and (" " .. git_status.badge) or ""

        local arrow = style.arrow
        local icon = style.icon
        local display = indent .. arrow .. icon .. git_before .. node._name .. git_after
        table.insert(lines, display)
        node._line_num = #lines
        node._arrow_end_col = vim.fn.strdisplaywidth(indent .. arrow)
        M.line_to_node[#lines] = node

        local col_indent = #indent
        local col_arrow = col_indent + #arrow
        local col_icon = col_arrow + #icon
        local col_before = col_icon + #git_before
        local col_name = col_before + #node._name
        local col_after = col_name + #git_after

        if col_arrow > col_indent and style.arrow_hl then
            table.insert(hl_map, {
                line = #lines - 1,
                col_start = col_indent,
                col_end = col_arrow,
                hl = style.arrow_hl,
            })
        end
        if col_icon > col_arrow and style.icon_hl then
            table.insert(hl_map, {
                line = #lines - 1,
                col_start = col_arrow,
                col_end = col_icon,
                hl = style.icon_hl,
            })
        end
        if col_before > col_icon and git_status then
            table.insert(hl_map, {
                line = #lines - 1,
                col_start = col_icon,
                col_end = col_before,
                hl = git_status.badge_hl,
            })
        end
        table.insert(hl_map, {
            line = #lines - 1,
            col_start = col_before,
            col_end = col_name,
            hl = style.name_hl,
        })
        if col_after > col_name and git_status then
            table.insert(hl_map, {
                line = #lines - 1,
                col_start = col_name,
                col_end = col_after,
                hl = git_status.badge_hl,
            })
        end

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
        if vim.hl and vim.hl.range then
            vim.hl.range(state.buf, ns, h.hl, { h.line, h.col_start }, { h.line, h.col_end })
        else
            pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, h.hl, h.line, h.col_start, h.col_end)
        end
    end

    git.render_extmarks(state)

    if package.loaded["csharp-explorer.diagnostics"] then
        require("csharp-explorer.diagnostics").render_extmarks(state)
    end

    M.render_process_badges(state)

    if state.win and vim.api.nvim_win_is_valid(state.win) then
        local left, right = M.build_sidebar_winbar_chunks(state)
        chrome.set_winbar(state.win, left, right)
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
                        port = process.extract_port(active_dbg.detected_urls[1])
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
                        port = process.extract_port(active_proc.detected_urls[1])
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

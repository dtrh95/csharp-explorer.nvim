local metadata = require("csharp-explorer.metadata")
local config = require("csharp-explorer.config")
local node_utils = require("csharp-explorer.node")
local diagnostics = require("csharp-explorer.diagnostics")
local navigation = require("csharp-explorer.actions.navigation")
local uv = vim.uv or vim.loop

local M = {
    current_win = nil,
    current_buf = nil,
    _caller_win = nil,
    _prev_win = nil,
}

local FILE_TYPE_NAMES = {
    cs_file = "C# Source File",
    appsettings = "Application Settings",
    dockerfile = "Dockerfile",
    http_file = "HTTP Request",
    cshtml_file = "Razor Page",
    razor_file = "Razor Component",
    css_file = "Stylesheet",
    xaml_file = "XAML Page",
    resx_file = "Resource File",
    launch_settings = "Launch Settings",
}

local function format_bytes(bytes)
    if not bytes or bytes < 0 then
        return "0 B"
    end
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%.2f MB", bytes / (1024 * 1024))
    end
end

function M.inspect_node(node, state)
    if not node then
        return {
            title = "Item Properties",
            rows = {},
        }
    end

    local tree = state and state.tree

    if node_utils.is_file(node) then
        local owning_proj = nil
        if tree and node._path then
            owning_proj = metadata.find_owning_project(node._path, tree)
        end

        local rows = {
            { label = "Name", value = node._name },
            { label = "Type", value = FILE_TYPE_NAMES[node._type] or "File" },
        }

        if owning_proj then
            local prof = metadata.get_project_profile(owning_proj._path)
            local arch_cap = prof.archetype:sub(1, 1):upper() .. prof.archetype:sub(2)
            table.insert(rows, { label = "Project", value = string.format("%s (%s)", owning_proj._name, arch_cap) })
        else
            table.insert(rows, { label = "Project", value = "None" })
        end

        local rel_path = node._path
        if owning_proj and owning_proj._dir and node._path then
            local norm_proj = metadata.normalize_path(owning_proj._dir)
            local norm_f = metadata.normalize_path(node._path)
            if vim.startswith(norm_f:lower(), norm_proj:lower() .. "/") then
                rel_path = norm_f:sub(#norm_proj + 2)
            end
        end
        table.insert(rows, { label = "Relative Path", value = rel_path or "None" })
        table.insert(rows, { label = "Full Path", value = node._path or "None" })

        if node._path then
            local st = uv.fs_stat(node._path)
            if st then
                table.insert(rows, { label = "Size", value = format_bytes(st.size) })
                table.insert(rows, { label = "Modified", value = os.date("%Y-%m-%d %H:%M:%S", st.mtime.sec) })
            end
        end

        local build_action = metadata.resolve_build_action(node._path, owning_proj)
        table.insert(rows, { label = "Build Action", value = build_action })

        if node._name:match("%.cs$") and node._path then
            local max_lines = (config.current.properties and config.current.properties.max_scan_lines) or 120
            local decl_ns, scope = metadata.extract_csharp_namespace(node._path, max_lines)
            local exp_ns = metadata.infer_expected_namespace(node._path, owning_proj)

            local ns_val
            if decl_ns then
                ns_val = string.format("%s (%s)", decl_ns, scope)
                if exp_ns and decl_ns ~= exp_ns then
                    ns_val = ns_val .. string.format(" [expected: %s]", exp_ns)
                end
            elseif exp_ns then
                ns_val = string.format("%s (inferred from path)", exp_ns)
            else
                ns_val = "None"
            end
            table.insert(rows, { label = "Namespace", value = ns_val })
        end

        if node._type == "launch_settings" and node._path then
            local run_config = require("csharp-explorer.run_config")
            local ok, cfgs =
                pcall(run_config.parse_launch_settings, node._path, owning_proj and owning_proj._path or "")
            if ok and cfgs and #cfgs > 0 then
                local names = {}
                for _, c in ipairs(cfgs) do
                    table.insert(names, c.profile_name)
                end
                table.insert(
                    rows,
                    { label = "Profiles", value = string.format("%d (%s)", #cfgs, table.concat(names, ", ")) }
                )
            end
        end

        if node_utils.is_nested_parent(node) then
            local count = 0
            for _ in pairs(node._children) do
                count = count + 1
            end
            table.insert(rows, { label = "Nested Children", value = string.format("%d file(s)", count) })
        elseif node._parent and node_utils.is_file(node._parent) then
            table.insert(rows, { label = "Nested Under", value = node._parent._name })
        end

        local diag_sum = diagnostics.get_file_summary(node._path)
        if diag_sum and (diag_sum.error + diag_sum.warn + diag_sum.info + diag_sum.hint > 0) then
            table.insert(rows, {
                label = "Diagnostics",
                value = string.format(
                    "Errors: %d, Warnings: %d, Info: %d, Hints: %d",
                    diag_sum.error,
                    diag_sum.warn,
                    diag_sum.info,
                    diag_sum.hint
                ),
            })
        else
            table.insert(rows, { label = "Diagnostics", value = "Clean (0 issues)" })
        end

        return {
            title = "Item Properties: " .. node._name,
            rows = rows,
        }
    end

    if node._type == "project" then
        local prof = metadata.get_project_profile(node._path)
        local meta = metadata.get_project_metadata(node._path)
        local arch_cap = prof.archetype:sub(1, 1):upper() .. prof.archetype:sub(2)

        local tfm_str = "None"
        if #prof.target_frameworks > 0 then
            tfm_str = table.concat(prof.target_frameworks, ", ")
        end

        local pkg_count = 0
        for _ in pairs(meta.packages) do
            pkg_count = pkg_count + 1
        end

        local ref_count = 0
        for _ in pairs(meta.project_references) do
            ref_count = ref_count + 1
        end

        local rows = {
            { label = "Name", value = node._name },
            { label = "Archetype", value = arch_cap },
            { label = "SDK", value = prof.sdk },
            { label = "Target Frameworks", value = tfm_str },
            { label = "Output Type", value = prof.output_type or "Library" },
            { label = "Root Namespace", value = prof.root_namespace },
            { label = "Project File", value = node._path or "None" },
            { label = "Restore Source", value = meta.is_restored and "project.assets.json" or "MSBuild Evaluation" },
            { label = "Direct Packages", value = tostring(pkg_count) },
            { label = "Project References", value = tostring(ref_count) },
        }

        local ok_proc, process = pcall(require, "csharp-explorer.process")
        if ok_proc and node._path then
            local sessions = process.get_project_sessions(node._path)
            if #sessions > 0 then
                local best = sessions[1]
                for _, s in ipairs(sessions) do
                    if s.status == "running" then
                        best = s
                        break
                    end
                end
                local val = best.status
                if best.pid then
                    val = val .. string.format(" (PID %d)", best.pid)
                end
                if best.detected_urls and #best.detected_urls > 0 then
                    val = val .. " [" .. best.detected_urls[1] .. "]"
                end
                table.insert(rows, { label = "Process", value = val })
            end
        end

        local diag_sum = diagnostics.get_dir_summary(node._dir)
        if diag_sum and (diag_sum.error + diag_sum.warn + diag_sum.info + diag_sum.hint > 0) then
            table.insert(rows, {
                label = "Diagnostics",
                value = string.format(
                    "Errors: %d, Warnings: %d, Info: %d, Hints: %d",
                    diag_sum.error,
                    diag_sum.warn,
                    diag_sum.info,
                    diag_sum.hint
                ),
            })
        else
            table.insert(rows, { label = "Diagnostics", value = "Clean (0 issues)" })
        end

        return {
            title = "Project Properties: " .. node._name,
            rows = rows,
        }
    end

    if node._type == "solution" then
        local counts = { total = 0, web = 0, console = 0, library = 0, test = 0 }
        local function walk_projects(n)
            if n._type == "project" and n._path then
                counts.total = counts.total + 1
                local arch = n._archetype or metadata.get_project_profile(n._path).archetype
                counts[arch] = (counts[arch] or 0) + 1
                return
            end
            if n._children then
                for _, child in pairs(n._children) do
                    walk_projects(child)
                end
            end
        end
        walk_projects(node)

        local fmt = (node._name and node._name:match("%.slnx$")) and "XML Solution (.slnx)" or "Classic Solution (.sln)"
        local rows = {
            { label = "Name", value = node._name },
            { label = "Type", value = "C# Solution" },
            { label = "Format", value = fmt },
            {
                label = "Projects",
                value = string.format(
                    "%d total (%d Web, %d Console, %d Library, %d Test)",
                    counts.total,
                    counts.web,
                    counts.console,
                    counts.library,
                    counts.test
                ),
            },
            { label = "Path", value = node._path or "None" },
            { label = "Directory", value = node._dir or "None" },
        }

        local diag_sum = diagnostics.get_subtree_summary(node)
        if diag_sum and (diag_sum.error + diag_sum.warn + diag_sum.info + diag_sum.hint > 0) then
            table.insert(rows, {
                label = "Diagnostics",
                value = string.format(
                    "Errors: %d, Warnings: %d, Info: %d, Hints: %d",
                    diag_sum.error,
                    diag_sum.warn,
                    diag_sum.info,
                    diag_sum.hint
                ),
            })
        else
            table.insert(rows, { label = "Diagnostics", value = "Clean (0 issues)" })
        end

        return {
            title = "Solution Properties: " .. node._name,
            rows = rows,
        }
    end

    if node._type == "package" then
        local pkg = node._package_info or {}
        local req_v = (pkg.version and pkg.version ~= "") and pkg.version or "unspecified"
        local res_v = pkg.resolved_version or "unspecified"
        local mgmt = pkg.is_cpm and "Centrally Managed [CPM]" or "Project Managed"

        local rows = {
            { label = "Name", value = pkg.name or node._name },
            { label = "Type", value = "NuGet Package Reference" },
            { label = "Requested Version", value = req_v },
            { label = "Resolved Version", value = res_v },
            { label = "Management", value = mgmt },
        }

        return {
            title = "Package Properties: " .. (pkg.name or node._name),
            rows = rows,
        }
    end

    if node._type == "project_reference" then
        local ref = node._project_ref_info or {}
        local in_sol = (ref.in_solution ~= nil and ref.in_solution) and "Yes" or "No (External)"

        local rows = {
            { label = "Name", value = node._name },
            { label = "Type", value = "Project Reference" },
            { label = "Target Path", value = node._target_path or "unspecified" },
            { label = "In Solution", value = in_sol },
        }

        return {
            title = "Reference Properties: " .. node._name,
            rows = rows,
        }
    end

    if node._type == "folder" then
        local is_sol_folder = node._dir == nil
        local rows = {
            { label = "Name", value = node._name },
            { label = "Type", value = is_sol_folder and "Solution Folder" or "Directory" },
        }
        if node._dir then
            table.insert(rows, { label = "Directory", value = node._dir })
        end
        local child_count = 0
        if node._children then
            for _ in pairs(node._children) do
                child_count = child_count + 1
            end
        end
        table.insert(rows, { label = "Direct Items", value = tostring(child_count) })

        local diag_sum = diagnostics.get_subtree_summary(node)
        if diag_sum and (diag_sum.error + diag_sum.warn + diag_sum.info + diag_sum.hint > 0) then
            table.insert(rows, {
                label = "Diagnostics",
                value = string.format(
                    "Errors: %d, Warnings: %d, Info: %d, Hints: %d",
                    diag_sum.error,
                    diag_sum.warn,
                    diag_sum.info,
                    diag_sum.hint
                ),
            })
        else
            table.insert(rows, { label = "Diagnostics", value = "Clean (0 issues)" })
        end
        return {
            title = "Folder Properties: " .. node._name,
            rows = rows,
        }
    end

    return {
        title = "Item Properties: " .. (node._name or "Unknown"),
        rows = {
            { label = "Name", value = node._name or "Unknown" },
            { label = "Type", value = node._type or "Unknown" },
        },
    }
end

function M.format_model(model)
    local max_lbl = 0
    for _, row in ipairs(model.rows) do
        if #row.label > max_lbl then
            max_lbl = #row.label
        end
    end
    if max_lbl < 12 then
        max_lbl = 12
    end

    local lines = {}
    local hl_map = {}

    table.insert(lines, "")
    for _, row in ipairs(model.rows) do
        local line = string.format("  %-" .. max_lbl .. "s :  %s", row.label, row.value)
        table.insert(lines, line)
        local l_idx = #lines - 1
        table.insert(hl_map, { line = l_idx, col_start = 2, col_end = 2 + #row.label, hl = "Directory" })
        table.insert(hl_map, { line = l_idx, col_start = 2 + max_lbl + 1, col_end = 2 + max_lbl + 2, hl = "Delimiter" })
        table.insert(hl_map, { line = l_idx, col_start = 2 + max_lbl + 4, col_end = #line, hl = "Normal" })
    end
    table.insert(lines, "")

    return lines, hl_map
end

function M.close()
    local caller_win = M._caller_win
    local prev_win = M._prev_win
    local closing_win = M.current_win
    M.current_win = nil
    M.current_buf = nil
    M._caller_win = nil
    M._prev_win = nil

    if closing_win and vim.api.nvim_win_is_valid(closing_win) then
        pcall(vim.api.nvim_win_close, closing_win, true)
    end
    if prev_win and prev_win ~= 0 and prev_win ~= caller_win and vim.api.nvim_win_is_valid(prev_win) then
        pcall(vim.api.nvim_set_current_win, prev_win)
    end
    if caller_win and vim.api.nvim_win_is_valid(caller_win) then
        pcall(vim.api.nvim_set_current_win, caller_win)
    end
end

function M.show_node(node, state)
    M.close()

    local caller_win = vim.api.nvim_get_current_win()
    local prev_win = vim.fn.win_getid(vim.fn.winnr("#"))

    local model = M.inspect_node(node, state)
    local lines, hl_map = M.format_model(model)

    local max_len = 0
    for _, l in ipairs(lines) do
        local width = vim.fn.strdisplaywidth(l)
        if width > max_len then
            max_len = width
        end
    end

    local cfg_width = (config.current.properties and config.current.properties.max_width) or 76
    local width = math.max(45, math.min(max_len + 4, cfg_width))
    local height = #lines

    local row = math.max(1, math.floor((vim.o.lines - height) / 2))
    local col = math.max(1, math.floor((vim.o.columns - width) / 2))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].undolevels = -1
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local ns = vim.api.nvim_create_namespace("CSharpExplorerProperties")
    for _, h in ipairs(hl_map) do
        pcall(vim.api.nvim_buf_add_highlight, buf, ns, h.hl, h.line, h.col_start, h.col_end)
    end

    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    local border = (config.current.properties and config.current.properties.border) or "rounded"
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = border,
        title = " " .. model.title .. " ",
        title_pos = "center",
        footer = " q / <Esc> to close ",
        footer_pos = "center",
    })

    M.current_win = win
    M.current_buf = buf
    M._caller_win = caller_win
    M._prev_win = prev_win

    local function close_fn()
        M.close()
    end

    local b_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "q", close_fn, b_opts)
    vim.keymap.set("n", "<Esc>", close_fn, b_opts)
    vim.keymap.set("n", "<CR>", close_fn, b_opts)
    vim.keymap.set("n", "K", close_fn, b_opts)

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            M.close()
        end,
    })

    return buf, win
end

function M.open(state)
    return function()
        if M.current_win and vim.api.nvim_win_is_valid(M.current_win) then
            local curr_win = vim.api.nvim_get_current_win()
            if curr_win == M.current_win then
                M.close()
                return
            end
        end

        local curr_win = vim.api.nvim_get_current_win()
        if state.win and vim.api.nvim_win_is_valid(state.win) and curr_win == state.win then
            local node = navigation.get_node(state)
            if node then
                M.show_node(node, state)
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

        if buf_name:match("%.csproj$") and state.tree then
            local proj_node = metadata.find_owning_project(buf_name, state.tree)
            if proj_node then
                M.show_node(proj_node, state)
                return
            end
        end

        local f_name = vim.fn.fnamemodify(buf_name, ":t")
        local f_type = node_utils.classify_file_type(f_name)
        local mock_node = {
            _name = f_name,
            _type = f_type,
            _path = metadata.normalize_path(buf_name),
            _children = {},
            _has_children = false,
        }

        M.show_node(mock_node, state)
    end
end

return M

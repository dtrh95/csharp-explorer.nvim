local config = require("csharp-explorer.config")
local debug_engine = require("csharp-explorer.debug")
local navigation = require("csharp-explorer.actions.navigation")

local M = {
    buf = nil,
    win = nil,
    active_session_id = nil,
    current_view = "debugger",
    follow_tail = true,
    line_items = {},
    ns_id = vim.api.nvim_create_namespace("CSharpExplorerDebugWindow"),
    _rendered_session = nil,
    _rendered_gen = 0,
    _last_rendered_seq = 0,
    _has_placeholder = false,
}

local function get_status_badge(status)
    if status == "running" then
        return "●", "DiagnosticOk"
    elseif status == "paused" then
        return "⏸", "DiagnosticWarn"
    elseif status == "building" or status == "starting" or status == "queued" then
        return "◐", "DiagnosticWarn"
    elseif status == "stopping" then
        return "◌", "DiagnosticWarn"
    elseif status == "failed" then
        return "▲", "DiagnosticError"
    end
    return "○", "Comment"
end

local function select_session(session_id)
    if not session_id then
        return
    end
    M.active_session_id = session_id
    debug_engine.active_session_id = session_id
    M.render()
end

local function cycle_session(direction)
    local sessions = debug_engine.get_sessions()
    if #sessions <= 1 then
        return
    end
    local cur_idx = 1
    for i, s in ipairs(sessions) do
        if s.id == M.active_session_id then
            cur_idx = i
            break
        end
    end
    local next_idx = cur_idx + direction
    if next_idx > #sessions then
        next_idx = 1
    elseif next_idx < 1 then
        next_idx = #sessions
    end
    select_session(sessions[next_idx].id)
end

local function open_url_under_cursor_or_active()
    local active = M.active_session_id and debug_engine.get_session(M.active_session_id)
    local url = nil
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        local cursor = vim.api.nvim_win_get_cursor(M.win)
        local line = vim.api.nvim_buf_get_lines(M.buf, cursor[1] - 1, cursor[1], false)[1]
        if line then
            url = line:match("(https?://[^%s%c\"'<>]+)")
            if url then
                url = url:gsub("[%.,;:)%]]+$", "")
            end
        end
    end
    if not url and active and active.detected_urls and #active.detected_urls > 0 then
        url = active.detected_urls[1]
    end
    if url then
        if vim.ui.open then
            vim.ui.open(url)
        elseif vim.fn.has("win32") == 1 then
            vim.fn.jobstart({ "cmd.exe", "/c", "start", "", url }, { detach = true })
        elseif vim.fn.has("mac") == 1 then
            vim.fn.jobstart({ "open", url }, { detach = true })
        else
            vim.fn.jobstart({ "xdg-open", url }, { detach = true })
        end
    else
        vim.notify("No URL found under cursor or in active debug session.", vim.log.levels.INFO)
    end
end

local function prompt_add_watch()
    vim.ui.input({ prompt = "Add Watch Expression: " }, function(input)
        if input and vim.trim(input) ~= "" then
            debug_engine.add_watch(vim.trim(input))
            M.render()
        end
    end)
end

local function prompt_evaluate(session)
    vim.ui.input({ prompt = "Evaluate C# Expression: " }, function(input)
        if input and vim.trim(input) ~= "" then
            local sid = session and session.id or M.active_session_id
            debug_engine.evaluate(input, { session_id = sid }, function(err, res)
                if err then
                    vim.notify("Eval error: " .. tostring(err), vim.log.levels.ERROR)
                elseif res then
                    vim.notify(tostring(input) .. " => " .. tostring(res.result), vim.log.levels.INFO)
                    if session and session.ring_buffer then
                        session.ring_buffer:push(">> " .. input .. " => " .. tostring(res.result))
                    end
                end
            end)
        end
    end)
end

local function handle_cr_action()
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(M.win)[1]
    local item = M.line_items[lnum]
    if not item then
        if M.current_view == "console" then
            open_url_under_cursor_or_active()
        end
        return
    end

    if item.type == "variable" or item.type == "watch" then
        if item.node and (item.node.variables_reference or 0) > 0 then
            debug_engine.toggle_variable(item.session_id, item.node, function()
                M.render()
            end)
        end
    elseif item.type == "frame" then
        if item.frame then
            debug_engine.select_frame(item.session_id, item.frame)
            M.render()
        end
    elseif item.type == "exception_filter" then
        if item.filter_id then
            debug_engine.toggle_exception_filter(item.filter_id)
            M.render()
        end
    elseif item.type == "breakpoint" then
        if item.bp then
            local target_win = nil
            for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                local ok_cfg, win_cfg = pcall(vim.api.nvim_win_get_config, w)
                local is_float = ok_cfg and win_cfg.relative ~= ""
                local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype or ""
                if vim.api.nvim_win_is_valid(w) and not is_float and not ft:find("^csharpexplorer") then
                    target_win = w
                    break
                end
            end
            if target_win then
                vim.api.nvim_set_current_win(target_win)
                local b = vim.fn.bufadd(item.bp.file_path)
                vim.fn.bufload(b)
                vim.api.nvim_win_set_buf(target_win, b)
                pcall(vim.api.nvim_win_set_cursor, target_win, { math.max(1, item.bp.line or 1), 0 })
            end
        end
    end
end

local function handle_delete_action()
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(M.win)[1]
    local item = M.line_items[lnum]
    if not item then
        return
    end
    if item.type == "watch" and item.node then
        debug_engine.remove_watch(item.node.expression)
        M.render()
    elseif item.type == "breakpoint" and item.bp then
        local dap_bp = require("dap.breakpoints")
        dap_bp.remove(item.bp.bufnr, item.bp.line)
        debug_engine.sync_breakpoints_for_buf(item.bp.bufnr)
        M.render()
    end
end

local function handle_condition_action()
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
        return
    end
    local lnum = vim.api.nvim_win_get_cursor(M.win)[1]
    local item = M.line_items[lnum]
    if item and item.type == "breakpoint" and item.bp then
        vim.ui.input({ prompt = "Edit Breakpoint Condition: ", default = item.bp.condition or "" }, function(input)
            if input ~= nil then
                debug_engine.set_breakpoint_condition(item.bp.bufnr, item.bp.line, vim.trim(input))
                M.render()
            end
        end)
    elseif M.current_view ~= "breakpoints" then
        if M.active_session_id then
            debug_engine.continue_session(M.active_session_id)
        end
    end
end

local function setup_keymaps(buf)
    local opts = { buffer = buf, nowait = true, silent = true }

    vim.keymap.set("n", "q", function()
        M.close()
    end, opts)

    vim.keymap.set("n", "1", function()
        M.switch_view("debugger")
    end, opts)
    vim.keymap.set("n", "2", function()
        M.switch_view("console")
    end, opts)
    vim.keymap.set("n", "3", function()
        M.switch_view("breakpoints")
    end, opts)
    vim.keymap.set("n", "gd", function()
        M.switch_view("debugger")
    end, opts)
    vim.keymap.set("n", "gc", function()
        M.switch_view("console")
    end, opts)
    vim.keymap.set("n", "gb", function()
        M.switch_view("breakpoints")
    end, opts)

    vim.keymap.set("n", "]", function()
        cycle_session(1)
    end, opts)
    vim.keymap.set("n", "[", function()
        cycle_session(-1)
    end, opts)

    vim.keymap.set("n", "<Tab>", function()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local item = M.line_items[lnum]
        if item and (item.type == "variable" or item.type == "watch") and (item.node.variables_reference or 0) > 0 then
            handle_cr_action()
        else
            cycle_session(1)
        end
    end, opts)

    vim.keymap.set("n", "<S-Tab>", function()
        cycle_session(-1)
    end, opts)

    vim.keymap.set("n", "<CR>", handle_cr_action, opts)
    vim.keymap.set("n", "o", handle_cr_action, opts)
    vim.keymap.set("n", "<Space>", function()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local item = M.line_items[lnum]
        if item and item.type == "exception_filter" then
            handle_cr_action()
        end
    end, opts)

    vim.keymap.set("n", "d", handle_delete_action, opts)
    vim.keymap.set("n", "x", handle_delete_action, opts)
    vim.keymap.set("n", "X", function()
        debug_engine.clear_breakpoints()
        M.render()
    end, opts)

    vim.keymap.set("n", "c", handle_condition_action, opts)
    vim.keymap.set("n", "n", function()
        if M.active_session_id then
            debug_engine.step_over(M.active_session_id)
        end
    end, opts)
    vim.keymap.set("n", "i", function()
        if M.active_session_id then
            debug_engine.step_into(M.active_session_id)
        end
    end, opts)
    vim.keymap.set("n", "u", function()
        if M.active_session_id then
            debug_engine.step_out(M.active_session_id)
        end
    end, opts)
    vim.keymap.set("n", "p", function()
        if M.active_session_id then
            debug_engine.pause_session(M.active_session_id)
        end
    end, opts)
    vim.keymap.set("n", "r", function()
        if M.active_session_id then
            debug_engine.restart(M.active_session_id)
        end
    end, opts)
    vim.keymap.set("n", "s", function()
        if M.active_session_id then
            debug_engine.stop(M.active_session_id)
        end
    end, opts)
    vim.keymap.set("n", "S", function()
        debug_engine.stop_all()
    end, opts)

    vim.keymap.set("n", "a", prompt_add_watch, opts)
    vim.keymap.set("n", "e", function()
        local s = M.active_session_id and debug_engine.get_session(M.active_session_id)
        prompt_evaluate(s)
    end, opts)

    vim.keymap.set("n", "f", function()
        M.follow_tail = not M.follow_tail
        vim.notify("Follow tail: " .. (M.follow_tail and "ON" or "OFF"), vim.log.levels.INFO)
        M.render()
    end, opts)
    vim.keymap.set("n", "C", function()
        if M.active_session_id then
            debug_engine.clear_session_log(M.active_session_id)
            M.render()
        end
    end, opts)
    vim.keymap.set("n", "gx", open_url_under_cursor_or_active, opts)
end

function M.ensure_buffer()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        M.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[M.buf].undolevels = -1
        vim.bo[M.buf].buftype = "nofile"
        vim.bo[M.buf].bufhidden = "hide"
        vim.bo[M.buf].swapfile = false
        vim.bo[M.buf].filetype = "csharpexplorerdebug"
        pcall(vim.api.nvim_buf_set_name, M.buf, "CSharpExplorer://Debug")
        setup_keymaps(M.buf)
    end
    return M.buf
end

function M.open(state, opts)
    opts = opts or {}
    if opts.session_id then
        M.active_session_id = opts.session_id
    end
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        M.render()
        if opts.focus ~= false then
            vim.api.nvim_set_current_win(M.win)
        end
        return M.win
    end

    local prev_win = vim.api.nvim_get_current_win()
    if state and state.win then
        navigation.focus_editor_window(state)
    else
        local cs = package.loaded["csharp-explorer"]
        if cs and cs.win and vim.api.nvim_win_is_valid(cs.win) then
            navigation.focus_editor_window(cs)
        else
            for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                local ok_cfg, win_cfg = pcall(vim.api.nvim_win_get_config, w)
                local is_float = ok_cfg and win_cfg.relative ~= ""
                local b = vim.api.nvim_win_get_buf(w)
                local ft = vim.bo[b].filetype or ""
                if vim.api.nvim_win_is_valid(w) and not is_float and not ft:find("^csharpexplorer") then
                    vim.api.nvim_set_current_win(w)
                    break
                end
            end
        end
    end

    local buf = M.ensure_buffer()
    local height = (config.current.debug and config.current.debug.window_height) or 14
    vim.cmd("belowright " .. height .. "split")
    M.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.win, buf)

    vim.wo[M.win].number = false
    vim.wo[M.win].relativenumber = false
    vim.wo[M.win].wrap = false
    vim.wo[M.win].signcolumn = "no"

    M.render()

    if opts.focus == false and prev_win and vim.api.nvim_win_is_valid(prev_win) then
        pcall(vim.api.nvim_set_current_win, prev_win)
    end

    return M.win
end

function M.close()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        pcall(vim.api.nvim_win_close, M.win, true)
        M.win = nil
    end
end

function M.toggle(state)
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        M.close()
    else
        M.open(state, { focus = true })
    end
end

function M.switch_view(view_name)
    if view_name == "debugger" or view_name == "console" or view_name == "breakpoints" then
        M.current_view = view_name
        M.render()
    end
end

local function build_header(sessions, active, win_width)
    local tab_str = ""
    for i, s in ipairs(sessions) do
        local is_active = active and s.id == active.id
        local sym = get_status_badge(s.status)
        local extra = ""
        if s.status == "paused" and s.current_frame and s.current_frame.line then
            extra = " L" .. tostring(s.current_frame.line)
        elseif s.detected_urls and #s.detected_urls > 0 then
            local port = s.detected_urls[1]:match(":(%d+)")
            if port then
                extra = " :" .. port
            end
        end
        local title = string.format("%s%s", s.name or (s.config and s.config.project_name) or s.id, extra)
        local prefix = is_active and string.format("[%d: ", i) or string.format(" %d: ", i)
        local suffix = is_active and "] " or "  "
        tab_str = tab_str .. prefix .. sym .. " " .. title .. suffix
    end
    if #sessions == 0 then
        tab_str = " (No active debug sessions)"
    end

    local v_dbg = M.current_view == "debugger" and "{1:Debugger}" or " 1:Debugger "
    local v_con = M.current_view == "console" and "{2:Console}" or " 2:Console "
    local v_bps = M.current_view == "breakpoints" and "{3:Breakpoints}" or " 3:Breakpoints "
    local views_str = string.format("Views: %s %s %s", v_dbg, v_con, v_bps)

    local bar =
        string.format(" %s  │  [c]ont [n]ext [i]nto [u]p [p]ause [r]estart [s]top [S]top-all [q]hide", views_str)
    local sep = string.rep("─", math.max(win_width, #bar, #tab_str))
    return { tab_str, bar, sep }
end

local function sanitize_lines(raw_lines)
    local out = {}
    for _, str in ipairs(raw_lines) do
        local s = tostring(str)
        if s:find("[\r\n]") then
            s = s:gsub("\r\n", "\n")
            local parts = vim.split(s, "\n", { plain = true })
            for _, p in ipairs(parts) do
                out[#out + 1] = p:gsub("\r", "")
            end
        else
            out[#out + 1] = s
        end
    end
    return out
end

local function render_var_tree(lines, items, vars, indent, session_id)
    for _, v in ipairs(vars or {}) do
        local has_children = (v.variables_reference or 0) > 0
        local icon = has_children and (v.is_expanded and "▾ " or "▸ ") or "  "
        local val_clean = v.value ~= nil and tostring(v.value):gsub("\r\n", "\n"):gsub("\n", "\\n") or nil
        local val_str = val_clean ~= nil and (" = " .. val_clean) or ""
        local text = string.format("%s%s%s%s", indent, icon, v.name or "?", val_str)
        table.insert(lines, text)
        items[#lines] = { type = "variable", node = v, session_id = session_id }
        if v.is_expanded and v.children then
            render_var_tree(lines, items, v.children, indent .. "    ", session_id)
        end
    end
end

function M.render()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        return
    end

    local sessions = debug_engine.get_sessions()
    if not M.active_session_id or not debug_engine.get_session(M.active_session_id) then
        if #sessions > 0 then
            M.active_session_id = sessions[1].id
        end
    end

    local active = M.active_session_id and debug_engine.get_session(M.active_session_id)
    local win_width = 80
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        win_width = vim.api.nvim_win_get_width(M.win)
    end

    local lines = build_header(sessions, active, win_width)
    local items = {}

    if M.current_view == "debugger" then
        if active and active.exception_info then
            local desc = active.exception_info.description
                or (active.exception_info.details and active.exception_info.details.message)
                or "Exception occurred"
            local desc_lines = vim.split(tostring(desc):gsub("\r\n", "\n"), "\n", { plain = true })
            for i, dl in ipairs(desc_lines) do
                local prefix = i == 1 and " 💥 Exception: " or "    "
                table.insert(lines, prefix .. dl)
            end
            table.insert(lines, "")
        end

        table.insert(
            lines,
            "── Watches ────────────────────────────────────────────── [a]dd [d]elete [e]val"
        )
        local watches = debug_engine.get_watches()
        if #watches == 0 then
            table.insert(lines, "    (No watches defined)")
        else
            for _, w in ipairs(watches) do
                local w_state = (active and active.watch_states and active.watch_states[w.expression]) or w
                local val = w_state.value or w_state.result
                local val_clean = val ~= nil and tostring(val):gsub("\r\n", "\n"):gsub("\n", "\\n") or nil
                local val_str = val_clean ~= nil and val_clean
                    or (
                        w_state.error
                            and ("<error: " .. tostring(w_state.error):gsub("\r\n", "\n"):gsub("\n", "\\n") .. ">")
                        or "..."
                    )
                local has_children = (w_state.variables_reference or 0) > 0
                local icon = has_children and (w_state.is_expanded and "▾ " or "▸ ") or "  "
                table.insert(lines, string.format("    %s%s = %s", icon, w.expression, val_str))
                items[#lines] = { type = "watch", node = w_state, session_id = active and active.id }
                if w_state.is_expanded and w_state.children then
                    render_var_tree(lines, items, w_state.children, "        ", active and active.id)
                end
            end
        end
        table.insert(lines, "")

        table.insert(
            lines,
            "── Scope Variables ────────────────────────────────────── <CR>/<Tab> expand"
        )
        if not active or not active.scopes or #active.scopes == 0 then
            table.insert(lines, "    (No variables available in current frame)")
        else
            for _, sc in ipairs(active.scopes) do
                table.insert(lines, string.format("  [%s]", sc.name or "Scope"))
                render_var_tree(lines, items, sc.variables, "    ", active.id)
            end
        end
        table.insert(lines, "")

        table.insert(
            lines,
            "── Call Stack ─────────────────────────────────────────── <CR> jump to frame"
        )
        if not active or not active.frames or #active.frames == 0 then
            table.insert(lines, "    (No call stack frames)")
        else
            for _, f in ipairs(active.frames) do
                local is_cur = active.current_frame and active.current_frame.id == f.id
                local arrow = is_cur and "▶ " or "  "
                local src = f.source_path
                        and string.format(" at %s:%d", vim.fn.fnamemodify(f.source_path, ":t"), f.line or 0)
                    or ""
                table.insert(lines, string.format("  %s%s%s", arrow, f.name or "frame", src))
                items[#lines] = { type = "frame", frame = f, session_id = active.id }
            end
        end
    elseif M.current_view == "breakpoints" then
        table.insert(
            lines,
            "── .NET Exception Filters ─────────────────────────────── <CR>/<Space> toggle"
        )
        local active_filters = debug_engine.get_exception_filters()
        local available = { "user-unhandled", "all" }
        for _, f in ipairs(available) do
            local checked = vim.tbl_contains(active_filters, f)
            local mark = checked and "[x]" or "[ ]"
            table.insert(lines, string.format("  %s %s", mark, f))
            items[#lines] = { type = "exception_filter", filter_id = f }
        end
        table.insert(lines, "")

        table.insert(
            lines,
            "── Workspace Breakpoints ──────────────────────────────── [c]ond [d]el [X]clear"
        )
        local bps = debug_engine.get_breakpoints()
        if #bps == 0 then
            table.insert(lines, "    (No breakpoints set)")
        else
            for _, bp in ipairs(bps) do
                local c_str = (bp.condition and bp.condition ~= "") and string.format(" [cond: %s]", bp.condition) or ""
                local v_mark = bp.verified and "●" or "○"
                local name = vim.fn.fnamemodify(bp.file_path, ":t")
                table.insert(lines, string.format("  %s %s:%d%s", v_mark, name, bp.line, c_str))
                items[#lines] = { type = "breakpoint", bp = bp }
            end
        end
    elseif M.current_view == "console" then
        local log_lines_raw = active and active.ring_buffer and active.ring_buffer:get_lines() or {}
        local has_placeholder = #log_lines_raw == 0
        local log_lines = has_placeholder and { " Process started. Waiting for console output..." } or log_lines_raw
        for _, l in ipairs(log_lines) do
            table.insert(lines, l)
        end
        M._has_placeholder = has_placeholder
        if active and active.ring_buffer then
            M._rendered_session = active
            M._rendered_gen = active.ring_buffer._gen
            M._last_rendered_seq = active.ring_buffer._total_seq
        end
    end

    M.line_items = items

    lines = sanitize_lines(lines)
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    vim.bo[M.buf].modifiable = false

    if M.current_view == "console" and M.follow_tail and M.win and vim.api.nvim_win_is_valid(M.win) then
        local in_visual = vim.api.nvim_get_current_win() == M.win and vim.fn.mode():match("^[vV\22]") ~= nil
        if not in_visual then
            pcall(vim.api.nvim_win_set_cursor, M.win, { #lines, 0 })
        end
    end
end

function M.append_active_output(session)
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        return
    end
    if M.current_view ~= "console" then
        return
    end
    if not session or session.id ~= M.active_session_id then
        return
    end
    if M._rendered_session ~= session or M._rendered_gen ~= session.ring_buffer._gen then
        M.render()
        return
    end

    local new_lines, new_seq, replaced_all = session.ring_buffer:get_lines_since(M._last_rendered_seq)
    if #new_lines == 0 then
        return
    end

    new_lines = sanitize_lines(new_lines)
    vim.bo[M.buf].modifiable = true
    if replaced_all or M._has_placeholder then
        vim.api.nvim_buf_set_lines(M.buf, 3, -1, false, new_lines)
        M._has_placeholder = false
    else
        vim.api.nvim_buf_set_lines(M.buf, -1, -1, false, new_lines)
        local overflow = vim.api.nvim_buf_line_count(M.buf) - (3 + session.ring_buffer._max)
        if overflow > 0 then
            vim.api.nvim_buf_set_lines(M.buf, 3, 3 + overflow, false, {})
        end
    end
    vim.bo[M.buf].modifiable = false
    M._last_rendered_seq = new_seq

    if M.follow_tail and M.win and vim.api.nvim_win_is_valid(M.win) then
        local in_visual = vim.api.nvim_get_current_win() == M.win and vim.fn.mode():match("^[vV\22]") ~= nil
        if not in_visual then
            local count = vim.api.nvim_buf_line_count(M.buf)
            pcall(vim.api.nvim_win_set_cursor, M.win, { count, 0 })
        end
    end
end

debug_engine.subscribe(function(event_type, session)
    if event_type == "started" or event_type == "paused" then
        if not M.win or not vim.api.nvim_win_is_valid(M.win) then
            if config.current.debug and config.current.debug.auto_open_window then
                M.open(nil, { session_id = session and session.id, focus = false })
            end
        end
    end
    if event_type == "paused" and session then
        M.active_session_id = session.id
    end
    if not M.win or not vim.api.nvim_win_is_valid(M.win) then
        return
    end
    if event_type == "output" then
        if session and session.id == M.active_session_id then
            M.append_active_output(session)
        end
        return
    end
    if event_type == "started" and not M.active_session_id and session then
        M.active_session_id = session.id
    end
    M.render()
end)

return M

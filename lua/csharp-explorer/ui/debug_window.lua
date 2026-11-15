local config = require("csharp-explorer.config")
local debug_engine = require("csharp-explorer.debug")
local chrome = require("csharp-explorer.ui.chrome")
local ViewBuilder = require("csharp-explorer.ui.view_builder")

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

local KEYMAP_SECTIONS = {
    {
        title = "Views & Sessions",
        items = {
            { key = "1 / gd", desc = "Switch to Debugger view" },
            { key = "2 / gc", desc = "Switch to Console view" },
            { key = "3 / gb", desc = "Switch to Breakpoints view" },
            { key = "] / [", desc = "Next / previous debug session" },
            { key = "g1-g9", desc = "Select debug session 1-9" },
            { key = "x", desc = "Dismiss stopped debug session" },
        },
    },
    {
        title = "Execution Control",
        items = {
            { key = "<F5> / c", desc = "Continue execution" },
            { key = "<F10> / n", desc = "Step over" },
            { key = "<F11> / i", desc = "Step into" },
            { key = "<S-F11> / u", desc = "Step out" },
            { key = "p", desc = "Pause execution" },
            { key = "r", desc = "Restart active session" },
            { key = "s", desc = "Stop active session" },
            { key = "S", desc = "Stop all sessions" },
        },
    },
    {
        title = "Watches & Variables",
        items = {
            { key = "<CR> / o", desc = "Toggle variable or jump to frame" },
            { key = "<Tab>", desc = "Toggle variable or jump to next section" },
            { key = "a", desc = "Add watch expression" },
            { key = "d", desc = "Delete watch or breakpoint" },
            { key = "e", desc = "Evaluate C# expression" },
        },
    },
    {
        title = "Breakpoints & Console",
        items = {
            { key = "<F9>", desc = "Toggle breakpoint or exception filter" },
            { key = "c", desc = "Edit breakpoint condition (in Breakpoints view)" },
            { key = "X", desc = "Clear all breakpoints" },
            { key = "C / <C-l>", desc = "Clear console log" },
            { key = "f", desc = "Toggle follow-tail scroll" },
        },
    },
    {
        title = "General",
        items = {
            { key = "?", desc = "Show keyboard shortcuts" },
            { key = "q", desc = "Hide debug window" },
        },
    },
}

local function get_status_badge(status)
    if status == "running" then
        return "●", "CSharpExplorerBadgeOk"
    elseif status == "paused" then
        return "⏸", "CSharpExplorerBadgeWarn"
    elseif status == "building" or status == "starting" or status == "queued" then
        return "◐", "CSharpExplorerBadgeWarn"
    elseif status == "stopping" then
        return "◌", "CSharpExplorerBadgeMuted"
    elseif status == "failed" then
        return "▲", "CSharpExplorerBadgeError"
    end
    return "○", "CSharpExplorerBadgeMuted"
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
                        vim.schedule(function()
                            if M.win and vim.api.nvim_win_is_valid(M.win) then
                                if M.current_view == "console" then
                                    M.append_active_output(session)
                                else
                                    M.render()
                                end
                            end
                        end)
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
        if item.bp and item.bp.file_path then
            local target_win = chrome.resolve_editor_window()
            if target_win and vim.api.nvim_win_is_valid(target_win) then
                vim.api.nvim_set_current_win(target_win)
                vim.cmd("edit " .. vim.fn.fnameescape(item.bp.file_path))
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

local function show_help_popup()
    chrome.show_help_modal("Debug Window Shortcuts", KEYMAP_SECTIONS)
end

local function update_winbar(sessions, active)
    if not M.win or not vim.api.nvim_win_is_valid(M.win) then
        return
    end

    local left_chunks = {}
    if #sessions == 0 or not active then
        left_chunks[#left_chunks + 1] = { " [No Active Sessions] ", "CSharpExplorerMuted" }
    else
        for i, s in ipairs(sessions) do
            local is_active = (s.id == active.id)
            local sym, _ = get_status_badge(s.status)
            local label = string.format(" %d: %s %s ", i, sym, s.config.project_name)
            local hl = is_active and "CSharpExplorerTabActive" or "CSharpExplorerTabInactive"
            left_chunks[#left_chunks + 1] = { label, hl }
        end
    end

    left_chunks[#left_chunks + 1] = { " │ ", "CSharpExplorerMuted" }

    local views = {
        { id = "debugger", key = "1", label = "Debugger" },
        { id = "console", key = "2", label = "Console" },
        { id = "breakpoints", key = "3", label = "Breakpoints" },
    }
    for _, v in ipairs(views) do
        local is_cur = (M.current_view == v.id)
        local pill_txt = string.format(" %s:%s ", v.key, v.label)
        local pill_hl = is_cur and "CSharpExplorerPillActive" or "CSharpExplorerPillInactive"
        left_chunks[#left_chunks + 1] = { pill_txt, pill_hl }
    end

    local right_chunks = {}
    if active then
        local status_txt = active.status
        if active.status == "paused" then
            local l = (active.current_frame and active.current_frame.line) or "?"
            status_txt = "paused: L" .. tostring(l)
        end
        right_chunks[#right_chunks + 1] = { status_txt .. "  ", "CSharpExplorerMuted" }
    end
    right_chunks[#right_chunks + 1] = { "? Help ", "CSharpExplorerMuted" }

    chrome.set_winbar(M.win, left_chunks, right_chunks)
end

local function setup_keymaps(buf)
    local opts = { buffer = buf, nowait = true, silent = true }

    vim.keymap.set("n", "q", function()
        M.close()
    end, vim.tbl_extend("force", opts, { desc = "Hide debug window" }))

    vim.keymap.set("n", "1", function()
        M.switch_view("debugger")
    end, vim.tbl_extend("force", opts, { desc = "Switch to Debugger view" }))

    vim.keymap.set("n", "2", function()
        M.switch_view("console")
    end, vim.tbl_extend("force", opts, { desc = "Switch to Console view" }))

    vim.keymap.set("n", "3", function()
        M.switch_view("breakpoints")
    end, vim.tbl_extend("force", opts, { desc = "Switch to Breakpoints view" }))

    vim.keymap.set("n", "gd", function()
        M.switch_view("debugger")
    end, vim.tbl_extend("force", opts, { desc = "Switch to Debugger view" }))

    vim.keymap.set("n", "gc", function()
        M.switch_view("console")
    end, vim.tbl_extend("force", opts, { desc = "Switch to Console view" }))

    vim.keymap.set("n", "gb", function()
        M.switch_view("breakpoints")
    end, vim.tbl_extend("force", opts, { desc = "Switch to Breakpoints view" }))

    vim.keymap.set("n", "]", function()
        cycle_session(1)
    end, vim.tbl_extend("force", opts, { desc = "Next debug session" }))

    vim.keymap.set("n", "[", function()
        cycle_session(-1)
    end, vim.tbl_extend("force", opts, { desc = "Previous debug session" }))

    for i = 1, 9 do
        vim.keymap.set("n", "g" .. i, function()
            local sessions = debug_engine.get_sessions()
            if sessions[i] then
                select_session(sessions[i].id)
            end
        end, vim.tbl_extend("force", opts, { desc = "Select debug session " .. i }))
    end

    vim.keymap.set("n", "<Tab>", function()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local item = M.line_items[lnum]
        if
            item
            and (item.type == "variable" or item.type == "watch")
            and item.node
            and (item.node.variables_reference or 0) > 0
        then
            handle_cr_action()
        else
            local total = vim.api.nvim_buf_line_count(M.buf)
            local target = nil
            for i = lnum + 1, total do
                local it = M.line_items[i]
                if it and it.type == "section" then
                    target = i
                    break
                end
            end
            if not target then
                for i = 1, lnum do
                    local it = M.line_items[i]
                    if it and it.type == "section" then
                        target = i
                        break
                    end
                end
            end
            if target and M.win and vim.api.nvim_win_is_valid(M.win) then
                pcall(vim.api.nvim_win_set_cursor, M.win, { target, 0 })
            end
        end
    end, vim.tbl_extend("force", opts, { desc = "Toggle variable or jump to next section" }))

    vim.keymap.set("n", "<CR>", handle_cr_action, vim.tbl_extend("force", opts, { desc = "Toggle variable or frame" }))
    vim.keymap.set("n", "o", handle_cr_action, vim.tbl_extend("force", opts, { desc = "Toggle variable or frame" }))

    vim.keymap.set("n", "<Space>", function()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local item = M.line_items[lnum]
        if item and item.type == "exception_filter" then
            handle_cr_action()
        end
    end, vim.tbl_extend("force", opts, { desc = "Toggle exception filter" }))

    vim.keymap.set(
        "n",
        "d",
        handle_delete_action,
        vim.tbl_extend("force", opts, { desc = "Delete watch or breakpoint" })
    )

    vim.keymap.set("n", "x", function()
        if M.win and vim.api.nvim_win_is_valid(M.win) then
            local lnum = vim.api.nvim_win_get_cursor(M.win)[1]
            local item = M.line_items[lnum]
            if item and (item.type == "watch" or item.type == "breakpoint") then
                handle_delete_action()
                return
            end
        end
        if M.active_session_id then
            local removed_id = M.active_session_id
            local sessions = debug_engine.get_sessions()
            local next_id = nil
            for _, s in ipairs(sessions) do
                if s.id ~= removed_id then
                    next_id = s.id
                    break
                end
            end
            if debug_engine.remove_session(removed_id) then
                M.active_session_id = next_id
                M.render()
            else
                vim.notify("Cannot remove an active debug session. Stop it first.", vim.log.levels.WARN)
            end
        end
    end, vim.tbl_extend("force", opts, { desc = "Dismiss stopped session" }))

    vim.keymap.set("n", "X", function()
        debug_engine.clear_breakpoints()
        M.render()
    end, vim.tbl_extend("force", opts, { desc = "Clear all breakpoints" }))

    vim.keymap.set("n", "c", handle_condition_action, vim.tbl_extend("force", opts, { desc = "Continue or edit cond" }))
    vim.keymap.set("n", "<F5>", function()
        if M.active_session_id then
            debug_engine.continue_session(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Continue execution" }))

    vim.keymap.set("n", "<F9>", function()
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local item = M.line_items[lnum]
        if item and item.type == "exception_filter" then
            handle_cr_action()
        elseif item and item.type == "breakpoint" then
            handle_delete_action()
        else
            local ed_win = chrome.find_editor_window()
            if ed_win and vim.api.nvim_win_is_valid(ed_win) then
                local ed_buf = vim.api.nvim_win_get_buf(ed_win)
                if vim.api.nvim_buf_get_name(ed_buf) ~= "" then
                    local ed_line = vim.api.nvim_win_get_cursor(ed_win)[1]
                    debug_engine.toggle_breakpoint({ bufnr = ed_buf, line = ed_line })
                    M.render()
                end
            end
        end
    end, vim.tbl_extend("force", opts, { desc = "Toggle breakpoint or filter" }))

    vim.keymap.set("n", "n", function()
        if M.active_session_id then
            debug_engine.step_over(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Step over" }))
    vim.keymap.set("n", "<F10>", function()
        if M.active_session_id then
            debug_engine.step_over(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Step over" }))

    vim.keymap.set("n", "i", function()
        if M.active_session_id then
            debug_engine.step_into(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Step into" }))
    vim.keymap.set("n", "<F11>", function()
        if M.active_session_id then
            debug_engine.step_into(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Step into" }))

    vim.keymap.set("n", "u", function()
        if M.active_session_id then
            debug_engine.step_out(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Step out" }))
    vim.keymap.set("n", "<S-F11>", function()
        if M.active_session_id then
            debug_engine.step_out(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Step out" }))

    vim.keymap.set("n", "p", function()
        if M.active_session_id then
            debug_engine.pause_session(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Pause session" }))

    vim.keymap.set("n", "r", function()
        if M.active_session_id then
            debug_engine.restart(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Restart active session" }))

    vim.keymap.set("n", "s", function()
        if M.active_session_id then
            debug_engine.stop(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Stop active session" }))

    vim.keymap.set("n", "S", function()
        debug_engine.stop_all()
    end, vim.tbl_extend("force", opts, { desc = "Stop all sessions" }))

    vim.keymap.set("n", "C", function()
        if M.active_session_id then
            debug_engine.clear_session_log(M.active_session_id)
            M.render()
        end
    end, vim.tbl_extend("force", opts, { desc = "Clear console log" }))

    vim.keymap.set("n", "<C-l>", function()
        if M.active_session_id then
            debug_engine.clear_session_log(M.active_session_id)
            M.render()
        end
    end, vim.tbl_extend("force", opts, { desc = "Clear console log" }))

    vim.keymap.set("n", "a", prompt_add_watch, vim.tbl_extend("force", opts, { desc = "Add watch expression" }))
    vim.keymap.set("n", "e", function()
        local s = M.active_session_id and debug_engine.get_session(M.active_session_id)
        prompt_evaluate(s)
    end, vim.tbl_extend("force", opts, { desc = "Evaluate C# expression" }))

    vim.keymap.set("n", "f", function()
        M.follow_tail = not M.follow_tail
        local sessions = debug_engine.get_sessions()
        local active = M.active_session_id and debug_engine.get_session(M.active_session_id)
        update_winbar(sessions, active)
        if M.follow_tail and M.win and vim.api.nvim_win_is_valid(M.win) then
            local count = vim.api.nvim_buf_line_count(M.buf)
            pcall(vim.api.nvim_win_set_cursor, M.win, { count, 0 })
        end
    end, vim.tbl_extend("force", opts, { desc = "Toggle follow-tail scroll" }))

    vim.keymap.set("n", "?", show_help_popup, vim.tbl_extend("force", opts, { desc = "Show keyboard shortcuts" }))
end

function M.ensure_buffer()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        M.follow_tail = not (config.current.debug and config.current.debug.auto_scroll == false)
        M.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[M.buf].undolevels = -1
        vim.bo[M.buf].buftype = "nofile"
        vim.bo[M.buf].bufhidden = "hide"
        vim.bo[M.buf].swapfile = false
        vim.bo[M.buf].filetype = "csharpexplorer-debug"
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

    M.ensure_buffer()
    local height = (config.current.debug and config.current.debug.window_height) or 14
    local docked = chrome.open_docked_window(state, {
        height = height,
        filetype = "csharpexplorer-debug",
        bufname = "CSharpExplorer://Debug",
        focus = opts.focus,
        cursorline = true,
        buf = M.buf,
    })

    M.win = docked.win
    M.buf = docked.buf
    setup_keymaps(M.buf)
    M.render()

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

function M.switch_view(view)
    if view == "debugger" or view == "console" or view == "breakpoints" then
        M.current_view = view
        M.render()
    end
end

local function render_var_tree(vb, vars, indent, session_id)
    for _, v in ipairs(vars or {}) do
        local has_children = (v.variables_reference or 0) > 0
        local icon = has_children and (v.is_expanded and "▾ " or "▸ ") or "  "
        local icon_hl = has_children and "CSharpExplorerAccent" or "CSharpExplorerMuted"
        local name = tostring(v.name or "?")
        local val_clean = v.value ~= nil and tostring(v.value):gsub("\r\n", "\n"):gsub("\n", "\\n") or nil
        local val_str = val_clean ~= nil and val_clean or ""
        local type_str = (v.type and #v.type > 0) and ("  " .. v.type) or ""

        local chunks = {
            { indent .. icon, icon_hl },
            { name, "CSharpExplorerVarName" },
        }
        if #val_str > 0 then
            chunks[#chunks + 1] = { " = ", "CSharpExplorerMuted" }
            chunks[#chunks + 1] = { val_str, "CSharpExplorerVarValue" }
        end
        if #type_str > 0 then
            chunks[#chunks + 1] = { type_str, "CSharpExplorerVarType" }
        end

        vb:add_chunks(chunks, { type = "variable", node = v, session_id = session_id })
        if v.is_expanded and v.children then
            render_var_tree(vb, v.children, indent .. "    ", session_id)
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
    update_winbar(sessions, active)

    local vb = ViewBuilder.new()

    if M.current_view == "debugger" then
        if active and active.exception_info then
            local err_icon = (config.current.icons and config.current.icons.error) or "󰅚 "
            local desc = active.exception_info.description
                or (active.exception_info.details and active.exception_info.details.message)
                or "Exception occurred"
            local desc_lines = vim.split(tostring(desc):gsub("\r\n", "\n"), "\n", { plain = true })
            for i, dl in ipairs(desc_lines) do
                local prefix = i == 1 and ("  " .. err_icon .. "Exception: ") or "    "
                vb:add_line(prefix .. dl, "CSharpExplorerExceptionBanner", { type = "exception" })
            end
            vb:add_line("")
        end

        vb:add_section("Watches", "a add · d delete · e eval")
        vb.line_items[#vb.lines] = { type = "section", name = "watches" }
        local watches = debug_engine.get_watches()
        if #watches == 0 then
            vb:add_line("    (No watches defined)", "CSharpExplorerMuted")
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
                local icon_hl = has_children and "CSharpExplorerAccent" or "CSharpExplorerMuted"
                local val_hl = w_state.error and "CSharpExplorerBadgeError" or "CSharpExplorerVarValue"
                local chunks = {
                    { "    " .. icon, icon_hl },
                    { w.expression, "CSharpExplorerVarName" },
                    { " = ", "CSharpExplorerMuted" },
                    { val_str, val_hl },
                }
                vb:add_chunks(chunks, { type = "watch", node = w_state, session_id = active and active.id })
                if w_state.is_expanded and w_state.children then
                    render_var_tree(vb, w_state.children, "        ", active and active.id)
                end
            end
        end
        vb:add_line("")

        vb:add_section("Variables", "<CR>/<Tab> expand")
        vb.line_items[#vb.lines] = { type = "section", name = "variables" }
        if not active or not active.scopes or #active.scopes == 0 then
            vb:add_line("    (No variables available in current frame)", "CSharpExplorerMuted")
        else
            for _, sc in ipairs(active.scopes) do
                vb:add_line(string.format("  [%s]", sc.name or "Scope"), "CSharpExplorerTitle", { type = "scope" })
                render_var_tree(vb, sc.variables, "    ", active.id)
            end
        end
        vb:add_line("")

        vb:add_section("Call stack", "<CR> jump to frame")
        vb.line_items[#vb.lines] = { type = "section", name = "call_stack" }
        if not active or not active.frames or #active.frames == 0 then
            vb:add_line("    (No call stack frames)", "CSharpExplorerMuted")
        else
            for _, f in ipairs(active.frames) do
                local is_cur = active.current_frame and active.current_frame.id == f.id
                local arrow = is_cur and "  ▶ " or "    "
                local arrow_hl = is_cur and "CSharpExplorerStackCurrent" or "CSharpExplorerStackFrame"
                local method_hl = is_cur and "CSharpExplorerStackCurrent" or "CSharpExplorerStackFrame"
                local src = f.source_path
                        and string.format("%s:%d", vim.fn.fnamemodify(f.source_path, ":t"), f.line or 0)
                    or ""
                local right_opts = src ~= ""
                        and { right_chunks = { { " " .. src .. " ", "CSharpExplorerStackLocation" } } }
                    or nil
                vb:add_chunks(
                    { { arrow, arrow_hl }, { f.name or "frame", method_hl } },
                    { type = "frame", frame = f, session_id = active.id },
                    right_opts
                )
            end
        end
    elseif M.current_view == "breakpoints" then
        vb:add_section(".NET Exception Filters", "<CR>/<Space> toggle")
        vb.line_items[#vb.lines] = { type = "section", name = "filters" }
        local active_filters = debug_engine.get_exception_filters()
        local available = { "user-unhandled", "all" }
        for _, f in ipairs(available) do
            local checked = vim.tbl_contains(active_filters, f)
            local mark = checked and "[x]" or "[ ]"
            local mark_hl = checked and "CSharpExplorerFilterActive" or "CSharpExplorerFilterInactive"
            vb:add_chunks(
                { { "  " .. mark .. " ", mark_hl }, { f, "CSharpExplorerNormal" } },
                { type = "exception_filter", filter_id = f }
            )
        end
        vb:add_line("")

        vb:add_section("Workspace Breakpoints", "[c]ond [d]el [X]clear")
        vb.line_items[#vb.lines] = { type = "section", name = "breakpoints" }
        local bps = debug_engine.get_breakpoints()
        if #bps == 0 then
            vb:add_line("    (No breakpoints set)", "CSharpExplorerMuted")
        else
            for _, bp in ipairs(bps) do
                local c_str = (bp.condition and bp.condition ~= "") and string.format(" [when: %s]", bp.condition) or ""
                local v_mark = bp.verified and "●" or "○"
                local v_hl = bp.verified and "CSharpExplorerBpVerified" or "CSharpExplorerBpUnverified"
                local name = vim.fn.fnamemodify(bp.file_path, ":t")
                local chunks = {
                    { "  " .. v_mark .. " ", v_hl },
                    { string.format("%s:%d", name, bp.line), "CSharpExplorerNormal" },
                }
                if #c_str > 0 then
                    chunks[#chunks + 1] = { c_str, "CSharpExplorerBpCondition" }
                end
                vb:add_chunks(chunks, { type = "breakpoint", bp = bp })
            end
        end
    elseif M.current_view == "console" then
        local log_lines_raw = active and active.ring_buffer and active.ring_buffer:get_lines() or {}
        local has_placeholder = #log_lines_raw == 0
        local log_lines = has_placeholder and { "  Process started. Waiting for console output..." } or log_lines_raw
        for _, l in ipairs(log_lines) do
            vb:add_line(l, nil)
        end
        M._has_placeholder = has_placeholder
    end

    local prev_count = vim.api.nvim_buf_line_count(M.buf)
    local session_changed = M._rendered_session ~= active
    if M.current_view == "console" and active and active.ring_buffer then
        M._rendered_session = active
        M._rendered_gen = active.ring_buffer._gen
        M._last_rendered_seq = active.ring_buffer._total_seq
    end

    M.line_items = vb:render(M.buf, M.ns_id)

    if M.current_view == "console" and M.follow_tail and M.win and vim.api.nvim_win_is_valid(M.win) then
        if session_changed or chrome.should_auto_scroll(M.win, M.buf, prev_count) then
            pcall(vim.api.nvim_win_set_cursor, M.win, { #vb.lines, 0 })
        end
    end
end

function M.append_active_output(session)
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        return
    end
    if not session or session.id ~= M.active_session_id then
        return
    end
    if M.current_view ~= "console" then
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

    local prev_count = vim.api.nvim_buf_line_count(M.buf)
    vim.bo[M.buf].modifiable = true
    if replaced_all or M._has_placeholder then
        vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, new_lines)
        M._has_placeholder = false
    else
        vim.api.nvim_buf_set_lines(M.buf, -1, -1, false, new_lines)
        local overflow = vim.api.nvim_buf_line_count(M.buf) - session.ring_buffer._max
        if overflow > 0 then
            vim.api.nvim_buf_set_lines(M.buf, 0, overflow, false, {})
        end
    end
    vim.bo[M.buf].modifiable = false
    M._last_rendered_seq = new_seq

    if M.follow_tail and chrome.should_auto_scroll(M.win, M.buf, prev_count) then
        local count = vim.api.nvim_buf_line_count(M.buf)
        pcall(vim.api.nvim_win_set_cursor, M.win, { count, 0 })
    end
end

debug_engine.subscribe(function(event_type, session)
    if not M.win or not vim.api.nvim_win_is_valid(M.win) then
        return
    end

    if event_type == "output" then
        if session and session.id == M.active_session_id and M.current_view == "console" then
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

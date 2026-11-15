local config = require("csharp-explorer.config")
local process = require("csharp-explorer.process")
local chrome = require("csharp-explorer.ui.chrome")
local theme = require("csharp-explorer.ui.theme")

local M = {
    buf = nil,
    win = nil,
    active_session_id = nil,
    follow_tail = true,
    wrap_lines = nil,
    ns_id = vim.api.nvim_create_namespace("CSharpExplorerRunWindow"),
    _rendered_session = nil,
    _rendered_gen = 0,
    _last_rendered_seq = 0,
    _has_placeholder = false,
}

local function is_wrap_enabled()
    if M.wrap_lines == nil then
        M.wrap_lines = not (config.current.run and config.current.run.wrap == false)
    end
    return M.wrap_lines
end

local KEYMAP_SECTIONS = {
    {
        title = "Tabs & Sessions",
        items = {
            { key = "] / <Tab>", desc = "Next process tab" },
            { key = "[ / <S-Tab>", desc = "Previous process tab" },
            { key = "g1-g9", desc = "Select tab 1-9" },
            { key = "p", desc = "Pick tab from list" },
            { key = "x", desc = "Dismiss stopped session" },
        },
    },
    {
        title = "Process Control",
        items = {
            { key = "r", desc = "Restart active process" },
            { key = "s", desc = "Stop active process" },
            { key = "S", desc = "Stop all processes" },
            { key = "d", desc = "Attach debugger to active process" },
        },
    },
    {
        title = "Console Output",
        items = {
            { key = "c", desc = "Clear active console log" },
            { key = "f", desc = "Toggle follow-tail scroll" },
            { key = "w", desc = "Toggle line wrap" },
            { key = "<CR> / o / gx", desc = "Open URL in browser" },
        },
    },
    {
        title = "General",
        items = {
            { key = "?", desc = "Show keyboard shortcuts" },
            { key = "q", desc = "Hide run window" },
        },
    },
}

local function get_status_badge(status)
    if status == "running" then
        return "●", "CSharpExplorerBadgeOk"
    elseif status == "starting" then
        return "◐", "CSharpExplorerBadgeWarn"
    elseif status == "stopping" then
        return "◌", "CSharpExplorerBadgeMuted"
    elseif status == "failed" then
        return "▲", "CSharpExplorerBadgeError"
    end
    return "○", "CSharpExplorerBadgeMuted"
end

local function select_tab(session_id)
    if not session_id then
        return
    end
    M.active_session_id = session_id
    M.render()
end

local function cycle_tab(direction)
    local sessions = process.get_sessions()
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
    select_tab(sessions[next_idx].id)
end

local function open_url_under_cursor_or_active()
    local active = M.active_session_id and process.get_session(M.active_session_id)
    local url = nil

    if M.win and vim.api.nvim_win_is_valid(M.win) then
        local cursor = vim.api.nvim_win_get_cursor(M.win)
        local line = vim.api.nvim_buf_get_lines(M.buf, cursor[1] - 1, cursor[1], false)[1]
        if line then
            url = process.extract_url_at(line, cursor[2] + 1)
        end
    end

    if not url and active then
        if active.detected_urls and #active.detected_urls > 0 then
            url = active.detected_urls[1]
        elseif active.config and active.config.application_urls and #active.config.application_urls > 0 then
            url = active.config.application_urls[1]
        end
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
        vim.notify("No URL found under cursor or in active process.", vim.log.levels.INFO)
    end
end

local function show_help_popup()
    chrome.show_help_modal("Run Window Shortcuts", KEYMAP_SECTIONS)
end

local function update_winbar(sessions, active)
    if not M.win or not vim.api.nvim_win_is_valid(M.win) then
        return
    end

    if #sessions == 0 or not active then
        local left = { { " [No Active Processes]", "CSharpExplorerMuted" } }
        local right = { { "? Help ", "CSharpExplorerMuted" } }
        chrome.set_winbar(M.win, left, right)
        return
    end

    local tab_items = {}
    for i, s in ipairs(sessions) do
        local is_active = s.id == active.id
        local sym, _ = get_status_badge(s.status)
        local short_url = ""
        if s.detected_urls and #s.detected_urls > 0 then
            local port = process.extract_port(s.detected_urls[1])
            if port then
                short_url = " :" .. port
            end
        end
        local proj_name = (s.config and s.config.project_name) or s.name or s.id
        local label = string.format(" %d: %s %s%s ", i, sym, proj_name, short_url)
        local compact_label = string.format(" %d: %s %s ", i, sym, proj_name)
        local hl = is_active and "CSharpExplorerTabActive" or "CSharpExplorerTabInactive"
        tab_items[#tab_items + 1] = { id = s.id, label = label, compact_label = compact_label, hl = hl }
    end

    local status_txt = active.status
    if active.status == "starting" and active.stage == "queued" then
        status_txt = "starting (queued)"
    elseif active.status == "starting" and active.stage == "building" then
        status_txt = "building"
        if active.build_pid then
            status_txt = status_txt .. " (PID " .. active.build_pid .. ")"
        end
    elseif (active.status == "running" or active.status == "stopping") and active.pid then
        status_txt = status_txt .. " (PID " .. active.pid .. ")"
    end

    local status_chunk = { "  " .. status_txt, "CSharpExplorerNormal" }
    local url_chunk = (active.detected_urls and #active.detected_urls > 0)
            and { " " .. active.detected_urls[1], "CSharpExplorerAccent" }
        or nil

    local follow_txt = "Follow: " .. (M.follow_tail and "ON" or "OFF")

    chrome.set_winbar(M.win, function(win_w)
        local compact_right = win_w < 80
        local right_chunks = {
            { follow_txt .. (compact_right and " " or "  "), "CSharpExplorerMuted" },
        }
        if not is_wrap_enabled() then
            right_chunks[#right_chunks + 1] = { compact_right and "W:OFF " or "Wrap: OFF  ", "CSharpExplorerMuted" }
        end
        right_chunks[#right_chunks + 1] = { compact_right and "? " or "? Help ", "CSharpExplorerMuted" }

        local right_w = theme.chunks_width(right_chunks)
        local avail_left = math.max(0, win_w - right_w - 2)
        local status_w = theme.chunks_width({ status_chunk })
        local tab_budget = avail_left >= (status_w + 40) and (avail_left - status_w) or avail_left
        local left_chunks = chrome.build_tab_chunks({
            items = tab_items,
            active_id = active.id,
            max_width = tab_budget,
        })
        local used_w = theme.chunks_width(left_chunks)
        if used_w + status_w <= avail_left then
            left_chunks[#left_chunks + 1] = status_chunk
            used_w = used_w + status_w
            if url_chunk and (avail_left - used_w) >= 12 then
                local clipped_url = theme.truncate_chunks({ url_chunk }, avail_left - used_w)
                for _, c in ipairs(clipped_url) do
                    left_chunks[#left_chunks + 1] = c
                end
            end
        end
        return left_chunks, right_chunks
    end)
end

local function setup_keymaps(buf)
    local opts = { buffer = buf, nowait = true, silent = true }

    vim.keymap.set("n", "q", function()
        M.close()
    end, vim.tbl_extend("force", opts, { desc = "Hide run window" }))

    vim.keymap.set("n", "]", function()
        cycle_tab(1)
    end, vim.tbl_extend("force", opts, { desc = "Next process tab" }))

    vim.keymap.set("n", "[", function()
        cycle_tab(-1)
    end, vim.tbl_extend("force", opts, { desc = "Previous process tab" }))

    vim.keymap.set("n", "<Tab>", function()
        cycle_tab(1)
    end, vim.tbl_extend("force", opts, { desc = "Next process tab" }))

    vim.keymap.set("n", "<S-Tab>", function()
        cycle_tab(-1)
    end, vim.tbl_extend("force", opts, { desc = "Previous process tab" }))

    for i = 1, 9 do
        vim.keymap.set("n", "g" .. i, function()
            local sessions = process.get_sessions()
            if sessions[i] then
                select_tab(sessions[i].id)
            end
        end, vim.tbl_extend("force", opts, { desc = "Select tab " .. i }))
    end

    vim.keymap.set("n", "p", function()
        local sessions = process.get_sessions()
        if #sessions == 0 then
            return
        end
        local items = {}
        for i, s in ipairs(sessions) do
            items[#items + 1] = string.format("%d: %s (%s)", i, s.config.project_name, s.status)
        end
        vim.ui.select(items, { prompt = "Select Process Session: " }, function(_, idx)
            if idx and sessions[idx] then
                select_tab(sessions[idx].id)
            end
        end)
    end, vim.tbl_extend("force", opts, { desc = "Pick tab from list" }))

    vim.keymap.set("n", "r", function()
        if M.active_session_id then
            process.restart(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Restart active process" }))

    vim.keymap.set("n", "s", function()
        if M.active_session_id then
            process.stop(M.active_session_id)
        end
    end, vim.tbl_extend("force", opts, { desc = "Stop active process" }))

    vim.keymap.set("n", "S", function()
        process.stop_all()
    end, vim.tbl_extend("force", opts, { desc = "Stop all processes" }))

    vim.keymap.set("n", "c", function()
        if M.active_session_id then
            process.clear_session_log(M.active_session_id)
            M.render()
        end
    end, vim.tbl_extend("force", opts, { desc = "Clear active console log" }))

    vim.keymap.set("n", "f", function()
        M.follow_tail = not M.follow_tail
        local sessions = process.get_sessions()
        local active = M.active_session_id and process.get_session(M.active_session_id)
        update_winbar(sessions, active)
        if M.follow_tail and M.win and vim.api.nvim_win_is_valid(M.win) then
            local count = vim.api.nvim_buf_line_count(M.buf)
            pcall(vim.api.nvim_win_set_cursor, M.win, { count, 0 })
        end
    end, vim.tbl_extend("force", opts, { desc = "Toggle follow-tail scroll" }))

    vim.keymap.set("n", "w", function()
        M.wrap_lines = not is_wrap_enabled()
        if M.win and vim.api.nvim_win_is_valid(M.win) then
            chrome.apply_window_options(M.win, {
                mode = "log",
                wrap = M.wrap_lines,
                cursorline = false,
                winfixheight = true,
            })
            if not M.wrap_lines then
                chrome.reset_horizontal_scroll(M.win)
            end
        end
        local sessions = process.get_sessions()
        local active = M.active_session_id and process.get_session(M.active_session_id)
        update_winbar(sessions, active)
    end, vim.tbl_extend("force", opts, { desc = "Toggle line wrap" }))

    vim.keymap.set("n", "d", function()
        if M.active_session_id then
            local ok_dbg, dbg = pcall(require, "csharp-explorer.debug")
            if ok_dbg and dbg and dbg.attach_run_session then
                dbg.attach_run_session(M.active_session_id)
            end
        end
    end, vim.tbl_extend("force", opts, { desc = "Attach debugger to active process" }))

    vim.keymap.set(
        "n",
        "<CR>",
        open_url_under_cursor_or_active,
        vim.tbl_extend("force", opts, { desc = "Open URL in browser" })
    )
    vim.keymap.set(
        "n",
        "o",
        open_url_under_cursor_or_active,
        vim.tbl_extend("force", opts, { desc = "Open URL in browser" })
    )
    vim.keymap.set(
        "n",
        "gx",
        open_url_under_cursor_or_active,
        vim.tbl_extend("force", opts, { desc = "Open URL in browser" })
    )

    vim.keymap.set("n", "x", function()
        if M.active_session_id then
            local removed_id = M.active_session_id
            local sessions = process.get_sessions()
            local next_id = nil
            for _, s in ipairs(sessions) do
                if s.id ~= removed_id then
                    next_id = s.id
                    break
                end
            end
            if process.remove_session(removed_id) then
                M.active_session_id = next_id
                M.render()
            else
                vim.notify("Cannot remove an active session. Stop it first.", vim.log.levels.WARN)
            end
        end
    end, vim.tbl_extend("force", opts, { desc = "Dismiss stopped session" }))

    vim.keymap.set("n", "?", show_help_popup, vim.tbl_extend("force", opts, { desc = "Show keyboard shortcuts" }))
end

function M.ensure_buffer()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        M.follow_tail = not (config.current.run and config.current.run.auto_scroll == false)
        M.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[M.buf].undolevels = -1
        vim.bo[M.buf].buftype = "nofile"
        vim.bo[M.buf].bufhidden = "hide"
        vim.bo[M.buf].swapfile = false
        vim.bo[M.buf].filetype = "csharpexplorer-run"
        pcall(vim.api.nvim_buf_set_name, M.buf, "CSharpExplorer://Run")
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
    local height = (config.current.run and config.current.run.window_height) or 12
    local docked = chrome.open_docked_window(state, {
        height = height,
        filetype = "csharpexplorer-run",
        bufname = "CSharpExplorer://Run",
        focus = opts.focus,
        cursorline = false,
        mode = "log",
        wrap = is_wrap_enabled(),
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

function M.render()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        return
    end

    if M.win and vim.api.nvim_win_is_valid(M.win) then
        chrome.apply_window_options(M.win, {
            mode = "log",
            wrap = is_wrap_enabled(),
            cursorline = false,
            winfixheight = true,
        })
    end

    vim.api.nvim_buf_clear_namespace(M.buf, M.ns_id, 0, -1)
    local sessions = process.get_sessions()

    if #sessions == 0 then
        M._rendered_session = nil
        M._rendered_gen = 0
        M._last_rendered_seq = 0
        M._has_placeholder = false
        update_winbar(sessions, nil)
        local lines = {
            "  No active or recent process sessions.",
            "  Press 'u' on a project node in CSharpExplorer or run :CSharpExplorerRun to start a service.",
        }
        vim.bo[M.buf].modifiable = true
        vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
        vim.bo[M.buf].modifiable = false
        return
    end

    if not M.active_session_id or not process.get_session(M.active_session_id) then
        M.active_session_id = sessions[1].id
    end

    local active = process.get_session(M.active_session_id)
    update_winbar(sessions, active)

    local log_lines_raw = active.ring_buffer:get_lines()
    local has_placeholder = #log_lines_raw == 0
    local log_lines = has_placeholder and { "  Process started. Waiting for console output..." } or log_lines_raw
    local prev_count = vim.api.nvim_buf_line_count(M.buf)
    local session_changed = M._rendered_session ~= active

    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, log_lines)
    vim.bo[M.buf].modifiable = false

    M._rendered_session = active
    M._rendered_gen = active.ring_buffer._gen
    M._last_rendered_seq = active.ring_buffer._total_seq
    M._has_placeholder = has_placeholder

    if M.win and vim.api.nvim_win_is_valid(M.win) then
        if M.follow_tail and (session_changed or chrome.should_auto_scroll(M.win, M.buf, prev_count)) then
            pcall(vim.api.nvim_win_set_cursor, M.win, { #log_lines, 0 })
        end
        if not is_wrap_enabled() then
            chrome.reset_horizontal_scroll(M.win)
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

function M.render_header()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        return
    end

    local sessions = process.get_sessions()
    if #sessions == 0 or not M.active_session_id then
        M.render()
        return
    end

    local active = process.get_session(M.active_session_id)
    if not active or M._rendered_session ~= active or M._rendered_gen ~= active.ring_buffer._gen then
        M.render()
        return
    end

    update_winbar(sessions, active)
    M.append_active_output(active)
end

process.subscribe(function(event_type, session)
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
    M.render_header()
end)

return M

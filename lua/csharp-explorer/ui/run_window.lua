local config = require("csharp-explorer.config")
local navigation = require("csharp-explorer.actions.navigation")
local process = require("csharp-explorer.process")

local M = {
    buf = nil,
    win = nil,
    active_session_id = nil,
    follow_tail = true,
    ns_id = vim.api.nvim_create_namespace("CSharpExplorerRunWindow"),
    _rendered_session = nil,
    _rendered_gen = 0,
    _last_rendered_seq = 0,
    _has_placeholder = false,
}

local function get_status_badge(status)
    if status == "running" then
        return "●", "DiagnosticOk"
    elseif status == "starting" then
        return "◐", "DiagnosticWarn"
    elseif status == "stopping" then
        return "◌", "DiagnosticWarn"
    elseif status == "failed" then
        return "▲", "DiagnosticError"
    end
    return "○", "Comment"
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
            url = line:match("(https?://[^%s%c\"'<>]+)")
            if url then
                url = url:gsub("[%.,;:)%]]+$", "")
            end
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
    local help_lines = {
        " CSharpExplorer Run Window Keymaps",
        " ──────────────────────────────────",
        "  ] / <Tab>      Next process tab",
        "  [ / <S-Tab>    Previous process tab",
        "  g1-g9          Select tab 1-9",
        "  p              Pick tab from list",
        "  r              Restart active process",
        "  s              Stop active process",
        "  S              Stop all processes",
        "  c              Clear active console log",
        "  f              Toggle follow-tail scroll",
        "  <CR> / gx      Open URL in browser",
        "  x              Remove stopped/failed session",
        "  ?              Show this help",
        "  q              Hide run window",
        " ──────────────────────────────────",
        "  Press q or <Esc> to close",
    }

    local width = 44
    local height = #help_lines
    local uis = vim.api.nvim_list_uis()
    local total_w = (uis[1] and uis[1].width) or 80
    local total_h = (uis[1] and uis[1].height) or 24
    local row = math.floor((total_h - height) / 2)
    local col = math.floor((total_w - width) / 2)

    local hbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[hbuf].undolevels = -1
    vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, help_lines)
    vim.bo[hbuf].modifiable = false
    vim.bo[hbuf].buftype = "nofile"

    local hwin = vim.api.nvim_open_win(hbuf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
    })

    local function close_help()
        if vim.api.nvim_win_is_valid(hwin) then
            vim.api.nvim_win_close(hwin, true)
        end
    end

    vim.keymap.set("n", "q", close_help, { buffer = hbuf, nowait = true })
    vim.keymap.set("n", "<Esc>", close_help, { buffer = hbuf, nowait = true })
end

local function setup_keymaps(buf)
    local opts = { buffer = buf, nowait = true, silent = true }

    vim.keymap.set("n", "q", function()
        M.close()
    end, opts)

    vim.keymap.set("n", "]", function()
        cycle_tab(1)
    end, opts)
    vim.keymap.set("n", "<Tab>", function()
        cycle_tab(1)
    end, opts)
    vim.keymap.set("n", "[", function()
        cycle_tab(-1)
    end, opts)
    vim.keymap.set("n", "<S-Tab>", function()
        cycle_tab(-1)
    end, opts)

    for i = 1, 9 do
        vim.keymap.set("n", "g" .. tostring(i), function()
            local sessions = process.get_sessions()
            if sessions[i] then
                select_tab(sessions[i].id)
            end
        end, opts)
    end

    vim.keymap.set("n", "p", function()
        local sessions = process.get_sessions()
        if #sessions == 0 then
            return
        end
        local items = {}
        for _, s in ipairs(sessions) do
            local sym = get_status_badge(s.status)
            items[#items + 1] = string.format("%s %s (%s)", sym, s.config.project_name, s.config.profile_name)
        end
        vim.ui.select(items, { prompt = "Select Process Session:" }, function(_, idx)
            if idx and sessions[idx] then
                select_tab(sessions[idx].id)
            end
        end)
    end, opts)

    vim.keymap.set("n", "r", function()
        if M.active_session_id then
            process.restart(M.active_session_id)
        end
    end, opts)

    vim.keymap.set("n", "s", function()
        if M.active_session_id then
            process.stop(M.active_session_id)
        end
    end, opts)

    vim.keymap.set("n", "S", function()
        process.stop_all()
    end, opts)

    vim.keymap.set("n", "c", function()
        if M.active_session_id then
            process.clear_session_log(M.active_session_id)
            M.render()
        end
    end, opts)

    vim.keymap.set("n", "f", function()
        M.follow_tail = not M.follow_tail
        vim.notify("Follow tail: " .. (M.follow_tail and "ON" or "OFF"), vim.log.levels.INFO)
        M.render()
    end, opts)

    vim.keymap.set("n", "<CR>", open_url_under_cursor_or_active, opts)
    vim.keymap.set("n", "gx", open_url_under_cursor_or_active, opts)

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
    end, opts)

    vim.keymap.set("n", "?", show_help_popup, opts)
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

    local prev_win = vim.api.nvim_get_current_win()
    if state then
        navigation.focus_editor_window(state)
    end

    local buf = M.ensure_buffer()
    local height = (config.current.run and config.current.run.window_height) or 12
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

local function build_header_lines(sessions, active, win_width)
    local tab_spans = {}
    local tab_str = ""
    for i, s in ipairs(sessions) do
        local is_active = s.id == active.id
        local sym, sym_hl = get_status_badge(s.status)
        local short_url = ""
        if s.detected_urls and #s.detected_urls > 0 then
            local port = s.detected_urls[1]:match(":(%d+)")
            if port then
                short_url = " :" .. port
            end
        end

        local title = string.format("%s%s", s.config.project_name, short_url)
        local prefix = is_active and string.format("[%d: ", i) or string.format(" %d: ", i)
        local suffix = is_active and "] " or "  "

        local start_col = #tab_str
        local sym_col = start_col + #prefix
        tab_str = tab_str .. prefix .. sym .. " " .. title .. suffix
        local end_col = #tab_str

        tab_spans[#tab_spans + 1] = {
            start_col = start_col,
            end_col = end_col,
            sym_col = sym_col,
            sym_len = #sym,
            sym_hl = sym_hl,
            is_active = is_active,
        }
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

    local url_txt = ""
    if active.detected_urls and #active.detected_urls > 0 then
        url_txt = "URL: " .. active.detected_urls[1] .. "  "
    end

    local follow_txt = "Follow: " .. (M.follow_tail and "ON" or "OFF")
    local bar = string.format(
        " Status: %s  %s%s  │  [r]estart [s]top [S]top-all [c]lear [f]ollow [p]ick [gx/<CR>]url [?]help [q]hide",
        status_txt,
        url_txt,
        follow_txt
    )

    local sep = string.rep("─", math.max(win_width, #bar, #tab_str))

    return tab_str, bar, sep, tab_spans
end

local function apply_tab_extmarks(buf, ns_id, tab_spans)
    vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, 1)
    for _, span in ipairs(tab_spans) do
        local hl = span.is_active and "Title" or "Comment"
        vim.api.nvim_buf_set_extmark(buf, ns_id, 0, span.start_col, {
            end_col = span.end_col,
            hl_group = hl,
        })
        vim.api.nvim_buf_set_extmark(buf, ns_id, 0, span.sym_col, {
            end_col = span.sym_col + span.sym_len,
            hl_group = span.sym_hl,
        })
    end
end

function M.render()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(M.buf, M.ns_id, 0, -1)
    local sessions = process.get_sessions()

    if #sessions == 0 then
        M._rendered_session = nil
        M._rendered_gen = 0
        M._last_rendered_seq = 0
        M._has_placeholder = false
        local lines = {
            " [No Active Processes]",
            " Status: idle  │  [u]run project [U]select profile [gc]compounds [q]hide",
            string.rep("─", 80),
            " No active or recent process sessions.",
            " Press 'u' on a project node in CSharpExplorer or run :CSharpExplorerRun to start a service.",
        }
        vim.bo[M.buf].modifiable = true
        vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
        vim.bo[M.buf].modifiable = false
        return
    end

    if not M.active_session_id or not process.get_session(M.active_session_id) then
        M.active_session_id = sessions[1].id
    end

    local win_width = 80
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        win_width = vim.api.nvim_win_get_width(M.win)
    end

    local active = process.get_session(M.active_session_id)
    local tab_str, bar, sep, tab_spans = build_header_lines(sessions, active, win_width)

    local log_lines_raw = active.ring_buffer:get_lines()
    local has_placeholder = #log_lines_raw == 0
    local log_lines = has_placeholder and { " Process started. Waiting for console output..." } or log_lines_raw

    local all_lines = { tab_str, bar, sep }
    for _, l in ipairs(log_lines) do
        all_lines[#all_lines + 1] = l
    end

    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, all_lines)
    vim.bo[M.buf].modifiable = false

    apply_tab_extmarks(M.buf, M.ns_id, tab_spans)

    M._rendered_session = active
    M._rendered_gen = active.ring_buffer._gen
    M._last_rendered_seq = active.ring_buffer._total_seq
    M._has_placeholder = has_placeholder

    if M.follow_tail and M.win and vim.api.nvim_win_is_valid(M.win) then
        local in_visual = vim.api.nvim_get_current_win() == M.win and vim.fn.mode():match("^[vV\22]") ~= nil
        if not in_visual then
            pcall(vim.api.nvim_win_set_cursor, M.win, { #all_lines, 0 })
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

    if vim.api.nvim_buf_line_count(M.buf) < 4 then
        M.render()
        return
    end

    local win_width = 80
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        win_width = vim.api.nvim_win_get_width(M.win)
    end

    local tab_str, bar, sep, tab_spans = build_header_lines(sessions, active, win_width)

    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, 3, false, { tab_str, bar, sep })
    vim.bo[M.buf].modifiable = false

    apply_tab_extmarks(M.buf, M.ns_id, tab_spans)

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

local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local run_config = require("csharp-explorer.run_config")
local uv = vim.uv or vim.loop

local M = {
    sessions = {},
    session_order = {},
}

local subscribers = {}
local deferred_timers = {}

local function create_ring_buffer(max_size)
    local buf = {
        _items = {},
        _head = 1,
        _count = 0,
        _max = max_size or 5000,
    }

    function buf:push(item)
        if self._count < self._max then
            self._count = self._count + 1
            self._items[self._count] = item
        else
            self._items[self._head] = item
            self._head = (self._head % self._max) + 1
        end
    end

    function buf:clear()
        self._items = {}
        self._head = 1
        self._count = 0
    end

    function buf:get_lines()
        if self._count < self._max then
            local out = {}
            for i = 1, self._count do
                out[#out + 1] = self._items[i]
            end
            return out
        end
        local out = {}
        for i = 0, self._max - 1 do
            local idx = ((self._head - 1 + i) % self._max) + 1
            out[#out + 1] = self._items[idx]
        end
        return out
    end

    return buf
end

local function notify_subscribers(event_type, session)
    for _, sub in ipairs(subscribers) do
        pcall(sub, event_type, session)
    end
end

function M.subscribe(callback)
    subscribers[#subscribers + 1] = callback
    return function()
        for i, sub in ipairs(subscribers) do
            if sub == callback then
                table.remove(subscribers, i)
                break
            end
        end
    end
end

local function dispatch_event(event_type, session)
    if event_type == "output" and session then
        if not session._output_pending then
            session._output_pending = true
            vim.schedule(function()
                session._output_pending = false
                notify_subscribers("output", session)
            end)
        end
    else
        vim.schedule(function()
            notify_subscribers(event_type, session)
        end)
    end
end

local function strip_ansi(line)
    return line:gsub("\27%[[0-9;?]*[a-zA-Z]", ""):gsub("\27%].-\7", ""):gsub("\r$", "")
end

local function extract_urls(clean_line)
    local urls = {}
    for url in clean_line:gmatch("[Nn]ow listening on:%s*(https?://[^%s%c]+)") do
        urls[#urls + 1] = url
    end
    for url in clean_line:gmatch("[Ll]istening on:%s*(https?://[^%s%c]+)") do
        urls[#urls + 1] = url
    end
    return urls
end

local function process_stream_data(session, chunk, is_stderr)
    local rem_key = is_stderr and "stderr_rem" or "stdout_rem"
    local raw = (session[rem_key] or "") .. chunk
    local lines = vim.split(raw, "\n", { plain = true })
    session[rem_key] = table.remove(lines) or ""

    local url_detected = false
    for _, line in ipairs(lines) do
        local clean = strip_ansi(line)
        local urls = extract_urls(clean)
        for _, u in ipairs(urls) do
            local exists = false
            for _, existing in ipairs(session.detected_urls) do
                if existing == u then
                    exists = true
                    break
                end
            end
            if not exists then
                session.detected_urls[#session.detected_urls + 1] = u
                url_detected = true
            end
        end
        session.ring_buffer:push(clean)
    end

    if url_detected then
        dispatch_event("url_detected", session)
    end
    dispatch_event("output", session)
end

function M.get_session(id)
    return M.sessions[id]
end

function M.get_sessions()
    local list = {}
    for _, id in ipairs(M.session_order) do
        if M.sessions[id] then
            list[#list + 1] = M.sessions[id]
        end
    end
    return list
end

function M.get_project_sessions(project_path)
    local norm = metadata.normalize_path(project_path):lower()
    local list = {}
    for _, s in pairs(M.sessions) do
        if s.config and metadata.normalize_path(s.config.project_path):lower() == norm then
            list[#list + 1] = s
        end
    end
    return list
end

function M.remove_session(id)
    local session = M.sessions[id]
    if not session then
        return false
    end
    if session.status == "starting" or session.status == "running" or session.status == "stopping" then
        return false
    end

    M.sessions[id] = nil
    for i, sid in ipairs(M.session_order) do
        if sid == id then
            table.remove(M.session_order, i)
            break
        end
    end
    dispatch_event("removed", session)
    return true
end

function M.clear_session_log(id)
    local session = M.sessions[id]
    if session and session.ring_buffer then
        session.ring_buffer:clear()
        dispatch_event("output", session)
        return true
    end
    return false
end

function M.start(run_cfg, opts)
    opts = opts or {}
    local id = run_cfg.id
    local existing = M.sessions[id]

    if
        existing and (existing.status == "starting" or existing.status == "running" or existing.status == "stopping")
    then
        existing.pending_restart = { cfg = run_cfg, opts = opts }
        M.stop(id, { single = true, preserve_restart = true })
        return existing
    end

    local hot_reload = opts.hot_reload
    if hot_reload == nil then
        hot_reload = run_cfg.hot_reload == true
    end

    local max_lines = (config.current.run and config.current.run.max_log_lines) or 5000
    local session = {
        id = id,
        config = run_cfg,
        status = "starting",
        user_stopped = false,
        pid = nil,
        handle = nil,
        exit_code = nil,
        exit_signal = nil,
        started_at = os.time(),
        ended_at = nil,
        ring_buffer = create_ring_buffer(max_lines),
        detected_urls = {},
        compound_id = opts.compound_id,
        stop_together = opts.stop_together == true,
        hot_reload = hot_reload,
        kill_timer = nil,
        pending_restart = nil,
        _output_pending = false,
        stdout_rem = "",
        stderr_rem = "",
    }

    M.sessions[id] = session
    local in_order = false
    for _, sid in ipairs(M.session_order) do
        if sid == id then
            in_order = true
            break
        end
    end
    if not in_order then
        M.session_order[#M.session_order + 1] = id
    end

    local cmd, env, cwd = run_config.build_command_and_env(run_cfg, opts)

    local function on_stdout(err, data)
        if not err and data and data ~= "" then
            process_stream_data(session, data, false)
        end
    end

    local function on_stderr(err, data)
        if not err and data and data ~= "" then
            process_stream_data(session, data, true)
        end
    end

    local function on_exit(obj)
        if session.kill_timer then
            pcall(session.kill_timer.stop, session.kill_timer)
            pcall(session.kill_timer.close, session.kill_timer)
            session.kill_timer = nil
        end

        session.exit_code = obj.code
        session.exit_signal = obj.signal
        session.ended_at = os.time()

        if session.stdout_rem ~= "" then
            session.ring_buffer:push(strip_ansi(session.stdout_rem))
            session.stdout_rem = ""
        end
        if session.stderr_rem ~= "" then
            session.ring_buffer:push(strip_ansi(session.stderr_rem))
            session.stderr_rem = ""
        end

        if session.user_stopped or obj.code == 0 then
            session.status = "stopped"
        else
            session.status = "failed"
        end

        dispatch_event("exited", session)

        if session.pending_restart then
            local next_run = session.pending_restart
            session.pending_restart = nil
            vim.schedule(function()
                M.start(next_run.cfg or session.config, next_run.opts)
            end)
        end
    end

    -- Setsid via detach=true makes process group ID equal to child PID for reliable tree termination
    local ok_spawn, handle = pcall(vim.system, cmd, {
        cwd = cwd,
        env = env,
        detach = true,
        stdout = on_stdout,
        stderr = on_stderr,
    }, on_exit)

    if not ok_spawn or not handle then
        session.status = "failed"
        session.exit_code = -1
        session.ended_at = os.time()
        session.ring_buffer:push("Failed to start process: " .. tostring(handle))
        dispatch_event("exited", session)
        return session
    end

    session.handle = handle
    session.pid = handle.pid
    session.status = "running"

    dispatch_event("started", session)
    return session
end

local function cancel_deferred_timers(compound_id)
    local kept = {}
    for _, entry in ipairs(deferred_timers) do
        if compound_id == nil or entry.compound_id == compound_id then
            pcall(entry.timer.stop, entry.timer)
            pcall(entry.timer.close, entry.timer)
        else
            kept[#kept + 1] = entry
        end
    end
    deferred_timers = kept
end

function M.schedule_start(delay_ms, run_cfg, opts)
    opts = opts or {}
    if not delay_ms or delay_ms <= 0 then
        return M.start(run_cfg, opts)
    end
    local timer = uv.new_timer()
    if not timer then
        return M.start(run_cfg, opts)
    end
    local entry = { timer = timer, compound_id = opts.compound_id }
    deferred_timers[#deferred_timers + 1] = entry
    timer:start(delay_ms, 0, function()
        pcall(timer.stop, timer)
        pcall(timer.close, timer)
        for i, e in ipairs(deferred_timers) do
            if e == entry then
                table.remove(deferred_timers, i)
                break
            end
        end
        vim.schedule(function()
            M.start(run_cfg, opts)
        end)
    end)
    return nil
end

function M.stop(id, opts)
    opts = opts or {}
    local session = M.sessions[id]
    if not session then
        return false
    end
    if not opts.preserve_restart then
        session.pending_restart = nil
    end
    if not opts.single and session.compound_id and session.stop_together then
        return M.stop_compound(session.compound_id)
    end
    if not session.handle then
        return false
    end
    if session.status == "stopping" or session.status == "stopped" or session.status == "failed" then
        return false
    end

    session.user_stopped = true
    session.status = "stopping"
    dispatch_event("status_changed", session)

    local pid = session.pid
    if not pid then
        return true
    end

    if vim.fn.has("win32") == 1 then
        vim.system({ "taskkill", "/PID", tostring(pid), "/T", "/F" })
    else
        pcall(uv.kill, -pid, 15)
        pcall(uv.kill, pid, 15)

        local timeout = (config.current.run and config.current.run.terminate_timeout_ms) or 1500
        local timer = uv.new_timer()
        session.kill_timer = timer
        if timer then
            timer:start(timeout, 0, function()
                pcall(uv.kill, -pid, 9)
                pcall(uv.kill, pid, 9)
                pcall(timer.stop, timer)
                pcall(timer.close, timer)
                if session.kill_timer == timer then
                    session.kill_timer = nil
                end
            end)
        end
    end

    return true
end

function M.restart(id, opts)
    local session = M.sessions[id]
    if not session then
        return false
    end

    local next_opts = vim.tbl_extend("force", {
        compound_id = session.compound_id,
        stop_together = session.stop_together,
        hot_reload = session.hot_reload,
    }, opts or {})

    if session.status == "starting" or session.status == "running" or session.status == "stopping" then
        session.pending_restart = {
            cfg = session.config,
            opts = next_opts,
        }
        M.stop(id, { single = true, preserve_restart = true })
        return true
    end

    M.start(session.config, next_opts)
    return true
end

function M.stop_compound(compound_id)
    if not compound_id then
        return false
    end
    cancel_deferred_timers(compound_id)
    local stopped_any = false
    for _, s in pairs(M.sessions) do
        if s.compound_id == compound_id then
            s.pending_restart = nil
            if s.status == "starting" or s.status == "running" then
                if M.stop(s.id, { single = true }) then
                    stopped_any = true
                end
            end
        end
    end
    return stopped_any
end

function M.stop_all()
    cancel_deferred_timers(nil)
    for _, s in pairs(M.sessions) do
        s.pending_restart = nil
        if s.status == "starting" or s.status == "running" then
            M.stop(s.id, { single = true })
        end
    end
end

function M.shutdown()
    cancel_deferred_timers(nil)
    for _, s in pairs(M.sessions) do
        s.pending_restart = nil
        if s.pid and (s.status == "starting" or s.status == "running" or s.status == "stopping") then
            if s.kill_timer then
                pcall(s.kill_timer.stop, s.kill_timer)
                pcall(s.kill_timer.close, s.kill_timer)
                s.kill_timer = nil
            end
            if vim.fn.has("win32") == 1 then
                pcall(vim.fn.system, "taskkill /PID " .. tostring(s.pid) .. " /T /F")
            else
                pcall(uv.kill, -s.pid, 15)
                pcall(uv.kill, s.pid, 15)
                pcall(uv.kill, -s.pid, 9)
                pcall(uv.kill, s.pid, 9)
            end
            s.status = "stopped"
        end
    end
end

return M

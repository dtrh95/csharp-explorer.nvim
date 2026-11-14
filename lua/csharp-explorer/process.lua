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
local build_queue = {}
local active_build = nil

local MAX_REMAINDER_BYTES = 64 * 1024
local MAX_LINE_CHARS = 4096

local function create_ring_buffer(max_size)
    local buf = {
        _items = {},
        _head = 1,
        _count = 0,
        _max = max_size or 5000,
        _total_seq = 0,
        _gen = 0,
    }

    function buf:push(item)
        self._total_seq = self._total_seq + 1
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
        self._total_seq = 0
        self._gen = self._gen + 1
    end

    function buf:get_lines()
        local out = {}
        if self._count < self._max then
            for i = 1, self._count do
                out[#out + 1] = self._items[i]
            end
        else
            for i = 0, self._max - 1 do
                out[#out + 1] = self._items[((self._head - 1 + i) % self._max) + 1]
            end
        end
        return out
    end

    function buf:get_lines_since(last_seq)
        if last_seq >= self._total_seq then
            return {}, self._total_seq, false
        end
        local delta = self._total_seq - last_seq
        if delta >= self._count then
            return self:get_lines(), self._total_seq, true
        end
        local out = {}
        if self._count < self._max then
            for i = self._count - delta + 1, self._count do
                out[#out + 1] = self._items[i]
            end
        else
            for k = 0, delta - 1 do
                out[#out + 1] = self._items[((self._head - 1 + (self._max - delta) + k) % self._max) + 1]
            end
        end
        return out, self._total_seq, false
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

local function sanitize_line(raw_line)
    local line = raw_line
    if line:find("\r") then
        line = line:gsub("\r+$", "")
        local after_cr = line:match(".*\r([^\r]+)$")
        line = (after_cr and after_cr ~= "") and after_cr or line:gsub("\r", "")
    end
    local clean = strip_ansi(line)
    if #clean > MAX_LINE_CHARS then
        local cut = MAX_LINE_CHARS - 15
        while cut > 0 and (string.byte(clean, cut) or 0) >= 128 and (string.byte(clean, cut) or 0) < 192 do
            cut = cut - 1
        end
        if cut > 0 and (string.byte(clean, cut) or 0) >= 192 then
            cut = cut - 1
        end
        clean = clean:sub(1, cut) .. "... [truncated]"
    end
    return clean
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
    local raw = ((session[rem_key] or "") .. chunk):gsub("\r\n", "\n")
    local lines = vim.split(raw, "\n", { plain = true })
    local rem = table.remove(lines) or ""

    if #rem > MAX_REMAINDER_BYTES then
        if rem:find("\r") then
            local stripped_rem = rem:gsub("\r+$", "")
            local collapsed = stripped_rem:match(".*\r([^\r]+)$")
            rem = (collapsed and collapsed ~= "") and collapsed or stripped_rem:gsub("\r", "")
        end
        if #rem > MAX_REMAINDER_BYTES then
            lines[#lines + 1] = rem
            rem = ""
        end
    end
    session[rem_key] = rem

    local url_detected = false
    for _, raw_line in ipairs(lines) do
        local clean = sanitize_line(raw_line)
        for _, u in ipairs(extract_urls(clean)) do
            if not vim.tbl_contains(session.detected_urls, u) then
                session.detected_urls[#session.detected_urls + 1] = u
                url_detected = true
            end
        end
        session.ring_buffer:push(clean)
    end

    if url_detected then
        dispatch_event("url_detected", session)
    end
    if #lines > 0 then
        dispatch_event("output", session)
    end
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
    if not session or session.status == "starting" or session.status == "running" or session.status == "stopping" then
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

local function cancel_kill_timer(session)
    if session and session.kill_timer then
        pcall(session.kill_timer.stop, session.kill_timer)
        pcall(session.kill_timer.close, session.kill_timer)
        session.kill_timer = nil
    end
end

local function cleanup_build_result_file(session)
    if session and session.build_result_file then
        pcall(uv.fs_unlink, session.build_result_file)
        session.build_result_file = nil
    end
end

local function flush_stream_remainders(session)
    if not session then
        return
    end
    if session.stdout_rem and session.stdout_rem ~= "" then
        session.ring_buffer:push(sanitize_line(session.stdout_rem))
        session.stdout_rem = ""
    end
    if session.stderr_rem and session.stderr_rem ~= "" then
        session.ring_buffer:push(sanitize_line(session.stderr_rem))
        session.stderr_rem = ""
    end
end

local function signal_process_tree(pid, immediate, session)
    if not pid then
        return
    end
    if vim.fn.has("win32") == 1 then
        pcall(vim.fn.system, "taskkill /PID " .. tostring(pid) .. " /T /F")
        return
    end
    pcall(uv.kill, -pid, 15)
    pcall(uv.kill, pid, 15)
    if immediate then
        pcall(uv.kill, -pid, 9)
        pcall(uv.kill, pid, 9)
        return
    end
    local timeout = (config.current.run and config.current.run.terminate_timeout_ms) or 1500
    local timer = uv.new_timer()
    if timer then
        if session then
            session.kill_timer = timer
        end
        timer:start(timeout, 0, function()
            pcall(uv.kill, -pid, 9)
            pcall(uv.kill, pid, 9)
            pcall(timer.stop, timer)
            pcall(timer.close, timer)
            if session and session.kill_timer == timer then
                session.kill_timer = nil
            end
        end)
    end
end

local function finalize_session(session, status, exit_code, exit_signal)
    cancel_kill_timer(session)
    cleanup_build_result_file(session)
    flush_stream_remainders(session)

    session.exit_code, session.exit_signal, session.ended_at = exit_code, exit_signal, os.time()
    session.stage, session.status = "exited", status
    session.handle, session.build_handle, session.build_pid = nil, nil, nil

    dispatch_event("exited", session)

    if session.pending_restart then
        local next_run = session.pending_restart
        session.pending_restart = nil
        vim.schedule(function()
            M.start(next_run.cfg or session.config, next_run.opts)
        end)
    end
end

local function spawn_runtime_process(session, cmd, env, cwd, is_direct_start)
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
        local status = (session.user_stopped or obj.code == 0) and "stopped" or "failed"
        if session.user_stopped and session.pid and vim.fn.has("win32") == 0 then
            pcall(uv.kill, -session.pid, 9)
        end
        finalize_session(session, status, obj.code, obj.signal)
    end

    local ok_spawn, handle = pcall(vim.system, cmd, {
        cwd = cwd,
        env = env,
        detach = true,
        stdout = on_stdout,
        stderr = on_stderr,
    }, on_exit)

    if not ok_spawn or not handle then
        session.ring_buffer:push("Failed to start process: " .. tostring(handle))
        finalize_session(session, "failed", -1, nil)
        return session
    end

    session.handle, session.pid, session.status, session.stage = handle, handle.pid, "running", "running"
    dispatch_event(is_direct_start and "started" or "status_changed", session)
    return session
end

local function complete_job(item, ok, props, code, signal)
    if not item or item.completed then
        return
    end
    item.completed = true
    if item.on_complete then
        local cb = item.on_complete
        if vim.in_fast_event() then
            vim.schedule(function()
                pcall(cb, ok, props, code, signal)
            end)
        else
            pcall(cb, ok, props, code, signal)
        end
    end
end

local function pump_build_queue()
    if active_build ~= nil then
        return
    end

    while #build_queue > 0 do
        local item = table.remove(build_queue, 1)
        if not item.cancelled and item.run_cfg then
            local result_file = vim.fn.tempname() .. ".json"
            local ok_prep, bcmd, benv, bcwd =
                pcall(run_config.build_prepare_command, item.run_cfg, result_file, item.opts)
            if not ok_prep or not bcmd then
                pcall(uv.fs_unlink, result_file)
                complete_job(item, false, nil, -1, nil)
                vim.schedule(pump_build_queue)
                return
            end

            item.result_file = result_file
            active_build = item

            local function on_b_stdout(err, data)
                if not err and data and data ~= "" and item.on_output then
                    pcall(item.on_output, data, false)
                end
            end

            local function on_b_stderr(err, data)
                if not err and data and data ~= "" and item.on_output then
                    pcall(item.on_output, data, true)
                end
            end

            local function on_build_exit(obj)
                local cur = active_build
                local bpid = cur and cur.build_pid
                if cur then
                    cur.build_handle = nil
                    cur.build_pid = nil
                end

                local props = cur and cur.result_file and run_config.read_build_properties(cur.result_file) or nil
                if cur and cur.result_file then
                    pcall(uv.fs_unlink, cur.result_file)
                    cur.result_file = nil
                end

                active_build = nil
                vim.schedule(pump_build_queue)

                if not cur then
                    return
                end

                if cur.cancelled then
                    if bpid and vim.fn.has("win32") == 0 then
                        pcall(uv.kill, -bpid, 9)
                        pcall(uv.kill, bpid, 9)
                    end
                    complete_job(cur, false, nil, obj.code, obj.signal)
                    return
                end

                if obj.code ~= 0 then
                    complete_job(cur, false, props, obj.code, obj.signal)
                    return
                end

                complete_job(cur, true, props, obj.code, obj.signal)
            end

            local ok_bspawn, bhandle = pcall(vim.system, bcmd, {
                cwd = bcwd,
                env = benv,
                detach = true,
                stdout = on_b_stdout,
                stderr = on_b_stderr,
            }, on_build_exit)

            if not ok_bspawn or not bhandle then
                active_build = nil
                pcall(uv.fs_unlink, result_file)
                item.result_file = nil
                complete_job(item, false, nil, -1, nil)
                vim.schedule(pump_build_queue)
                return
            end

            item.build_handle = bhandle
            item.build_pid = bhandle.pid
            if item.on_started then
                pcall(item.on_started, bhandle.pid)
            end
            return
        end
    end
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
        stage = "queued",
        user_stopped = false,
        pid = nil,
        handle = nil,
        build_pid = nil,
        build_handle = nil,
        build_result_file = nil,
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
    if not vim.tbl_contains(M.session_order, id) then
        M.session_order[#M.session_order + 1] = id
    end

    if run_cfg.command_type == "Executable" or hot_reload then
        local cmd, env, cwd = run_config.build_command_and_env(run_cfg, opts)
        return spawn_runtime_process(session, cmd, env, cwd, true)
    end

    session.status = "starting"
    session.stage = "queued"
    dispatch_event("started", session)

    session.build_ticket = M.enqueue_project_build(run_cfg, { hot_reload = opts.hot_reload }, {
        on_started = function(bpid)
            session.build_pid = bpid
            session.stage = "building"
            dispatch_event("status_changed", session)
        end,
        on_output = function(data, is_err)
            process_stream_data(session, data, is_err)
        end,
        on_complete = function(ok, props, code, signal)
            session.build_ticket = nil
            session.build_pid = nil
            if session.user_stopped or session.status == "stopped" or session.stage == "exited" then
                if session.stage ~= "exited" then
                    finalize_session(session, "stopped", code, signal)
                end
                return
            end
            if not ok or (code and code ~= 0) then
                finalize_session(session, "failed", code or -1, signal)
                return
            end
            local ok_cmd, rcmd, renv, rcwd = pcall(run_config.build_direct_command_and_env, session.config, props)
            if not ok_cmd or not rcmd then
                session.ring_buffer:push("Failed to resolve direct command: " .. tostring(rcmd))
                finalize_session(session, "failed", -1, nil)
                return
            end
            flush_stream_remainders(session)
            spawn_runtime_process(session, rcmd, renv, rcwd, false)
        end,
    })
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
    if session.status == "stopping" or session.status == "stopped" or session.status == "failed" then
        return false
    end

    if session.stage == "queued" or session.stage == "building" then
        session.user_stopped = true
        if session.build_ticket then
            session.build_ticket.cancel(true)
            session.build_ticket = nil
        end
        finalize_session(session, "stopped", nil, nil)
        return true
    end

    if not session.handle then
        return false
    end

    session.user_stopped = true
    session.status = "stopping"
    dispatch_event("status_changed", session)

    signal_process_tree(session.pid, false, session)
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

function M.stop_compound(compound_id, opts)
    opts = opts or {}
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
    if not opts.from_peer and package.loaded["csharp-explorer.debug"] then
        local ok, dbg = pcall(require, "csharp-explorer.debug")
        if ok and dbg and dbg.stop_compound then
            if dbg.stop_compound(compound_id, { from_peer = true }) then
                stopped_any = true
            end
        end
    end
    return stopped_any
end

function M.stop_all(opts)
    opts = opts or {}
    cancel_deferred_timers(nil)
    for _, s in pairs(M.sessions) do
        s.pending_restart = nil
        if s.status == "starting" or s.status == "running" then
            M.stop(s.id, { single = true })
        end
    end
    if not opts.from_peer and package.loaded["csharp-explorer.debug"] then
        local ok, dbg = pcall(require, "csharp-explorer.debug")
        if ok and dbg and dbg.stop_all then
            dbg.stop_all({ from_peer = true })
        end
    end
end

local next_ticket_id = 1
function M.enqueue_project_build(run_cfg, opts, callbacks)
    opts = opts or {}
    callbacks = callbacks or {}
    local ticket_id = "build_ticket:" .. tostring(next_ticket_id)
    next_ticket_id = next_ticket_id + 1

    local item = {
        id = ticket_id,
        run_cfg = run_cfg,
        opts = opts,
        on_started = callbacks.on_started,
        on_output = callbacks.on_output,
        on_complete = callbacks.on_complete,
        cancelled = false,
        completed = false,
        result_file = nil,
        build_handle = nil,
        build_pid = nil,
    }

    local ticket = {
        id = ticket_id,
        cancel = function(immediate)
            item.cancelled = true
            for i, queued in ipairs(build_queue) do
                if queued == item then
                    table.remove(build_queue, i)
                    complete_job(item, false, nil, -1, nil)
                    return true
                end
            end
            if active_build == item then
                if item.build_pid then
                    signal_process_tree(item.build_pid, immediate == true)
                end
                complete_job(item, false, nil, -1, nil)
                return true
            end
            return false
        end,
    }

    build_queue[#build_queue + 1] = item
    pump_build_queue()
    return ticket
end

function M.shutdown()
    cancel_deferred_timers(nil)
    if active_build then
        active_build.cancelled = true
        if active_build.build_pid then
            signal_process_tree(active_build.build_pid, true)
            active_build.build_handle = nil
            active_build.build_pid = nil
        end
        if active_build.result_file then
            pcall(uv.fs_unlink, active_build.result_file)
            active_build.result_file = nil
        end
        complete_job(active_build, false, nil, -1, nil)
        active_build = nil
    end
    for _, item in ipairs(build_queue) do
        complete_job(item, false, nil, -1, nil)
    end
    build_queue = {}
    for _, s in pairs(M.sessions) do
        s.user_stopped = true
        s.pending_restart = nil
        cancel_kill_timer(s)
        cleanup_build_result_file(s)

        if s.build_ticket then
            s.build_ticket.cancel(true)
            s.build_ticket = nil
        end
        if s.build_pid then
            signal_process_tree(s.build_pid, true, s)
            s.build_handle = nil
            s.build_pid = nil
        end

        if s.pid and (s.status == "starting" or s.status == "running" or s.status == "stopping") then
            signal_process_tree(s.pid, true, s)
            s.handle = nil
        end

        s.status = "stopped"
        s.stage = "exited"
    end
    active_build = nil
end

M.create_ring_buffer = create_ring_buffer
M.sanitize_line = sanitize_line
M.extract_urls = extract_urls
M.signal_process_tree = signal_process_tree

return M

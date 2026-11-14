local config = require("csharp-explorer.config")
local inspector = require("csharp-explorer.debug.inspector")
local metadata = require("csharp-explorer.metadata")
local process = require("csharp-explorer.process")
local run_config = require("csharp-explorer.run_config")
local uv = vim.uv or vim.loop

local M = {
    sessions = {},
    session_order = {},
    active_session_id = nil,
    watches = inspector.watches,
    exception_filters = inspector.exception_filters,
}

local dap_id_to_session_id = {}
local subscribers = {}
local deferred_timers = {}
local listeners_registered = false
local active_states =
    { queued = true, building = true, starting = true, running = true, paused = true, stopping = true }

local function is_active(s)
    return s and active_states[s.status] == true
end

local function notify_subscribers(event_type, session)
    for _, sub in ipairs(subscribers) do
        pcall(sub, event_type, session)
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

inspector.bind_debug_engine(M, dispatch_event)

local function close_timer(t)
    if t then
        pcall(t.stop, t)
        pcall(t.close, t)
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

function M.resolve_netcoredbg()
    local user_cmd = config.current.debug and config.current.debug.adapter_cmd
    if type(user_cmd) == "string" and user_cmd ~= "" and vim.fn.executable(user_cmd) == 1 then
        return user_cmd
    end
    local exepath = vim.fn.exepath("netcoredbg")
    if exepath ~= "" and vim.fn.executable(exepath) == 1 then
        return exepath
    end
    local mason_base = vim.fn.stdpath("data") .. "/mason/bin/netcoredbg"
    if vim.fn.has("win32") == 1 then
        for _, p in ipairs({ mason_base .. ".cmd", mason_base .. ".exe", mason_base }) do
            if vim.fn.executable(p) == 1 then
                return p
            end
        end
    elseif vim.fn.executable(mason_base) == 1 then
        return mason_base
    end
    return nil
end

function M.ensure_dap()
    local ok, dap = pcall(require, "dap")
    return (ok and type(dap) == "table") and true or false, dap
end

local next_session_nonce = 1

function M.resolve_session_from_dap(dap_s)
    if not dap_s then
        return nil
    end
    local sid = dap_s.config and dap_s.config._csharp_explorer_session_id
    local nonce = dap_s.config and dap_s.config._csharp_explorer_nonce
    if sid and M.sessions[sid] then
        local s = M.sessions[sid]
        if nonce ~= nil and s.nonce ~= nil and s.nonce ~= nonce then
            return nil
        end
        s.dap_id, s.dap_session, dap_id_to_session_id[dap_s.id] = dap_s.id, dap_s, s.id
        return s
    end
    local mapped = dap_id_to_session_id[dap_s.id]
    if mapped and M.sessions[mapped] then
        local s = M.sessions[mapped]
        if nonce ~= nil and s.nonce ~= nil and s.nonce ~= nonce then
            return nil
        end
        s.dap_session = dap_s
        return s
    end
    return nil
end

local function create_session(id, mode, cfg, name, opts)
    opts = opts or {}
    local max_lines = (config.current.debug and config.current.debug.max_log_lines) or 5000
    local s = {
        id = id,
        mode = mode,
        config = cfg,
        name = name,
        status = "queued",
        stage = "queued",
        started_at = os.time(),
        nonce = next_session_nonce,
    }
    next_session_nonce = next_session_nonce + 1
    s.ring_buffer, s.detected_urls, s.compound_id = process.create_ring_buffer(max_lines), {}, opts.compound_id
    s.stop_together, s.frames, s.scopes, s.output_rem = opts.stop_together == true, {}, {}, ""
    M.sessions[id] = s
    if not vim.tbl_contains(M.session_order, id) then
        M.session_order[#M.session_order + 1] = id
    end
    M.active_session_id = id
    return s
end

local function append_output(session, text)
    local lines = vim.split((session.output_rem or "") .. text:gsub("\r\n", "\n"), "\n", { plain = true })
    session.output_rem = table.remove(lines) or ""
    local has_url = false
    for _, raw in ipairs(lines) do
        local clean = process.sanitize_line(raw)
        for _, u in ipairs(process.extract_urls(clean)) do
            if not vim.tbl_contains(session.detected_urls, u) then
                session.detected_urls[#session.detected_urls + 1], has_url = u, true
            end
        end
        session.ring_buffer:push(clean)
    end
    if has_url then
        dispatch_event("url_detected", session)
    end
    if #lines > 0 then
        dispatch_event("output", session)
    end
end

local function notify_paused(session)
    dispatch_event("paused", session)
    dispatch_event("status_changed", session)
end

function M.ensure_listeners()
    if listeners_registered then
        return
    end
    local ok_dap, dap = M.ensure_dap()
    if not ok_dap or not dap then
        return
    end
    listeners_registered = true
    pcall(require, "csharp-explorer.ui.debug_window")

    dap.listeners.after.event_initialized["csharp-explorer"] = function(dap_s)
        local session = M.resolve_session_from_dap(dap_s)
        if session then
            session.dap_id, session.dap_session, dap_id_to_session_id[dap_s.id] = dap_s.id, dap_s, session.id
            local filters = inspector.get_exception_filters()
            if #filters > 0 then
                pcall(function()
                    dap_s:set_exception_breakpoints(filters)
                end)
            end
            local all_bps = require("dap.breakpoints").get()
            if all_bps and next(all_bps) then
                pcall(function()
                    dap_s:set_breakpoints(all_bps)
                end)
            end
        end
        return false
    end

    dap.listeners.after.event_process["csharp-explorer"] = function(dap_s, body)
        local session = M.resolve_session_from_dap(dap_s)
        if session and body and body.systemProcessId then
            session.pid = tonumber(body.systemProcessId)
            dispatch_event("status_changed", session)
        end
        return false
    end

    local function on_launch_or_attach(dap_s, err, _response)
        local session = M.resolve_session_from_dap(dap_s)
        if not session then
            return false
        end
        session.dap_id, session.dap_session, dap_id_to_session_id[dap_s.id] = dap_s.id, dap_s, session.id
        if err then
            M.finalize_session(session, "failed", -1, nil)
            return false
        end
        if session.status == "starting" then
            session.status, session.stage = "running", "running"
            dispatch_event("started", session)
            dispatch_event("status_changed", session)
        end
        return false
    end
    dap.listeners.after.launch["csharp-explorer"] = on_launch_or_attach
    dap.listeners.after.attach["csharp-explorer"] = on_launch_or_attach

    dap.listeners.after.event_stopped["csharp-explorer"] = function(dap_s, body)
        local session = M.resolve_session_from_dap(dap_s)
        if not session then
            return false
        end
        session.dap_id, session.dap_session, dap_id_to_session_id[dap_s.id] = dap_s.id, dap_s, session.id
        session.status, session.stage = "paused", "paused"
        session.stopped_thread_id, session.stopped_reason = body and body.threadId, body and body.reason
        session._stop_seq = (session._stop_seq or 0) + 1
        local seq = session._stop_seq
        M.active_session_id = session.id
        dap.set_session(dap_s)

        local tid = (body and body.threadId) or 1
        if body and body.reason == "exception" then
            dap_s:request(
                "exceptionInfo",
                { threadId = tid },
                vim.schedule_wrap(function(_xerr, xresp)
                    if session._stop_seq == seq and session.status == "paused" then
                        session.exception_info = xresp
                    end
                end)
            )
        else
            session.exception_info = nil
        end

        dap_s:request(
            "stackTrace",
            { threadId = tid, startFrame = 0, levels = 40 },
            vim.schedule_wrap(function(err, resp)
                if session._stop_seq ~= seq or session.status ~= "paused" then
                    return
                end
                if err or not resp or not resp.stackFrames then
                    return notify_paused(session)
                end
                local frames, chosen = {}, nil
                for _, f in ipairs(resp.stackFrames) do
                    local entry = {
                        id = f.id,
                        name = f.name,
                        source_path = f.source and f.source.path,
                        line = f.line,
                        column = f.column,
                        raw = f,
                    }
                    frames[#frames + 1] = entry
                    if not chosen and entry.source_path and vim.fn.filereadable(entry.source_path) == 1 then
                        chosen = entry
                    end
                end
                session.frames = frames
                session.current_frame = chosen or frames[1]
                if session.current_frame then
                    inspector.jump_editor_to_frame(session.current_frame)
                end

                local fid = session.current_frame and session.current_frame.id
                if fid then
                    dap_s:request(
                        "scopes",
                        { frameId = fid },
                        vim.schedule_wrap(function(sc_err, sc_resp)
                            if session._stop_seq ~= seq or session.status ~= "paused" then
                                return
                            end
                            inspector.populate_scope_variables(
                                session,
                                (not sc_err and sc_resp and sc_resp.scopes) or {},
                                function()
                                    if session._stop_seq ~= seq or session.status ~= "paused" then
                                        return
                                    end
                                    inspector.refresh_watches(session, function()
                                        if session._stop_seq ~= seq or session.status ~= "paused" then
                                            return
                                        end
                                        dispatch_event("variables_updated", session)
                                        notify_paused(session)
                                    end)
                                end
                            )
                        end)
                    )
                else
                    session.scopes = {}
                    notify_paused(session)
                end
            end)
        )
        return false
    end

    dap.listeners.after.event_continued["csharp-explorer"] = function(dap_s)
        local session = M.resolve_session_from_dap(dap_s)
        if session then
            session._stop_seq = (session._stop_seq or 0) + 1
            session.frames = {}
            session.scopes = {}
            session.current_frame = nil
            session.status, session.stage = "running", "running"
            session.stopped_reason, session.exception_info = nil, nil
            dispatch_event("continued", session)
            dispatch_event("status_changed", session)
        end
        return false
    end

    dap.listeners.after.event_output["csharp-explorer"] = function(dap_s, body)
        local session = M.resolve_session_from_dap(dap_s)
        if session and body and body.category ~= "telemetry" and body.output and body.output ~= "" then
            append_output(session, body.output)
        end
        return false
    end

    dap.listeners.after.event_breakpoint["csharp-explorer"] = function(_dap_s, body)
        if body and body.breakpoint then
            pcall(require("dap.breakpoints").update, body.breakpoint)
        end
        return false
    end

    local function on_dap_exit(dap_s, body)
        local session = M.resolve_session_from_dap(dap_s)
        if session and session.status ~= "stopped" and session.status ~= "failed" then
            local code = body and body.exitCode
            local is_stopped = session.user_stopped
                or (session.mode == "attach" and (code == nil or code == 0))
                or code == 0
            M.finalize_session(session, is_stopped and "stopped" or "failed", code, nil)
        end
        return false
    end
    dap.listeners.after.event_terminated["csharp-explorer"] = on_dap_exit
    dap.listeners.after.event_exited["csharp-explorer"] = on_dap_exit
    dap.listeners.after.disconnect["csharp-explorer"] = on_dap_exit
end

function M.ensure_adapter()
    local ok_dap, dap = M.ensure_dap()
    local bin = M.resolve_netcoredbg()
    if not ok_dap or not dap or not bin then
        return false
    end
    local factory = function(cb)
        cb({ type = "executable", command = bin, args = { "--interpreter=vscode" } })
    end
    dap.adapters["csharp-explorer-coreclr"] = factory
    dap.adapters.coreclr = dap.adapters.coreclr or factory
    dap.adapters.netcoredbg = dap.adapters.netcoredbg or factory
    M.ensure_listeners()
    return true
end

function M.finalize_session(session, status, exit_code, exit_signal)
    if not session then
        return
    end
    if session.dap_id then
        dap_id_to_session_id[session.dap_id] = nil
    end
    if session.output_rem and session.output_rem ~= "" then
        session.ring_buffer:push(process.sanitize_line(session.output_rem))
        session.output_rem = ""
    end
    session.exit_code, session.exit_signal, session.ended_at = exit_code, exit_signal, os.time()
    session.stage, session.status = "exited", status
    session.build_ticket = nil
    dispatch_event("exited", session)
    dispatch_event("status_changed", session)
    if session.pending_restart then
        local next_run = session.pending_restart
        session.pending_restart = nil
        vim.schedule(function()
            if session.mode == "test" then
                M.debug_test(
                    nil,
                    session.test_target or (session.config and session.config.project_path),
                    session.test_filter,
                    session.name,
                    next_run.opts
                )
            elseif session.mode == "attach" and session.pid then
                M.attach(session.pid, next_run.opts)
            else
                M.start(next_run.cfg or session.config, next_run.opts)
            end
        end)
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
        if s.config and s.config.project_path and metadata.normalize_path(s.config.project_path):lower() == norm then
            list[#list + 1] = s
        end
    end
    return list
end

function M.remove_session(id)
    local s = M.sessions[id]
    if not s or is_active(s) then
        return false
    end
    if s.dap_id then
        dap_id_to_session_id[s.dap_id] = nil
    end
    M.sessions[id] = nil
    for i, sid in ipairs(M.session_order) do
        if sid == id then
            table.remove(M.session_order, i)
            break
        end
    end
    if M.active_session_id == id then
        M.active_session_id = M.session_order[1]
    end
    dispatch_event("removed", s)
    return true
end

function M.clear_session_log(id)
    local s = M.sessions[id]
    if s and s.ring_buffer then
        s.ring_buffer:clear()
        dispatch_event("output", s)
        return true
    end
    return false
end

local function with_active_dap(id, fn)
    local s = id and M.get_session(id) or (M.active_session_id and M.get_session(M.active_session_id))
    if s and s.dap_session then
        local ok, dap = M.ensure_dap()
        if ok and dap then
            dap.set_session(s.dap_session)
        end
        return fn(s, s.dap_session)
    end
    return false
end

local function step_dap(id, action)
    return with_active_dap(id, function(s, ds)
        if action == "pause" then
            ds:_pause(s.stopped_thread_id)
        else
            ds:_step(action)
        end
        return true
    end)
end

function M.continue_session(id)
    return step_dap(id, "continue")
end

function M.step_over(id)
    return step_dap(id, "next")
end

function M.step_into(id)
    return step_dap(id, "stepIn")
end

function M.step_out(id)
    return step_dap(id, "stepOut")
end

function M.pause_session(id)
    return step_dap(id, "pause")
end

local function enqueue_build(session, cfg, on_ok)
    session.build_ticket = process.enqueue_project_build(cfg, { configuration = "Debug" }, {
        on_started = function(bpid)
            session.build_pid = bpid
        end,
        on_output = function(chunk)
            append_output(session, chunk)
        end,
        on_complete = function(ok, props, code, signal)
            session.build_ticket = nil
            if not ok or session.user_stopped then
                M.finalize_session(session, session.user_stopped and "stopped" or "failed", code, signal)
            else
                on_ok(props)
            end
        end,
    })
    return session.build_ticket
end

function M.start(run_cfg, opts)
    opts = opts or {}
    M.ensure_adapter()
    local id = "debug:" .. run_cfg.id
    local ex = M.sessions[id]
    if ex and is_active(ex) then
        ex.pending_restart = { cfg = run_cfg, opts = opts }
        M.stop(id, { single = true, preserve_restart = true })
        return ex
    end

    local session = create_session(id, "launch", run_cfg, run_cfg.name or run_cfg.project_name, opts)
    dispatch_event("started", session)
    session.status, session.stage = "building", "building"
    dispatch_event("status_changed", session)

    enqueue_build(session, run_cfg, function(props)
        vim.schedule(function()
            local spec = run_config.build_debug_launch_spec(run_cfg, props, {
                session_id = session.id,
                stop_at_entry = opts.stop_at_entry,
                just_my_code = opts.just_my_code,
            })
            spec._csharp_explorer_nonce = session.nonce
            session.status, session.stage = "starting", "starting"
            dispatch_event("status_changed", session)
            local ok_dap, dap = M.ensure_dap()
            if ok_dap and dap then
                dap.run(spec, { new = true })
            else
                M.finalize_session(session, "failed", -1, nil)
            end
        end)
    end)
    return session
end

local function cancel_deferred_timers(compound_id)
    local kept = {}
    for _, entry in ipairs(deferred_timers) do
        if compound_id == nil or entry.compound_id == compound_id then
            close_timer(entry.timer)
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
    timer:start(
        delay_ms,
        0,
        vim.schedule_wrap(function()
            close_timer(timer)
            for i, e in ipairs(deferred_timers) do
                if e == entry then
                    table.remove(deferred_timers, i)
                    break
                end
            end
            M.start(run_cfg, opts)
        end)
    )
    return nil
end

local function run_attach_dap(session, pid, just_my_code)
    local ok, dap = M.ensure_dap()
    if ok and dap then
        vim.schedule(function()
            dap.run({
                type = "csharp-explorer-coreclr",
                request = "attach",
                name = session.name,
                processId = pid,
                justMyCode = just_my_code ~= false,
                console = "internalConsole",
                _csharp_explorer_session_id = session.id,
                _csharp_explorer_nonce = session.nonce,
            }, { new = true })
        end)
        return true
    end
    M.finalize_session(session, "failed", -1, nil)
    return false
end

function M.attach(pid, opts)
    opts = opts or {}
    M.ensure_adapter()
    local num = tonumber(pid)
    if not num then
        return nil
    end
    local id = "attach:" .. tostring(num)
    local ex = M.sessions[id]
    if ex and (ex.status == "starting" or ex.status == "running" or ex.status == "paused") then
        return ex
    end
    local name = opts.name or ("Attach (" .. tostring(num) .. ")")
    local session = create_session(id, "attach", { id = id, name = name, project_path = opts.project_path }, name, opts)
    session.pid, session.status, session.stage = num, "starting", "starting"
    dispatch_event("started", session)
    run_attach_dap(session, num, opts.just_my_code)
    return session
end

function M.attach_run_session(run_session_id)
    local p = process.get_session(run_session_id)
    if not p or not p.pid or p.status ~= "running" then
        vim.notify("No active running process found for session: " .. tostring(run_session_id), vim.log.levels.WARN)
        return nil
    end
    local name = "Attach: " .. ((p.config and (p.config.name or p.config.project_name)) or tostring(p.pid))
    return M.attach(p.pid, { name = name, project_path = p.config and p.config.project_path })
end

local function cleanup_session_resources(s, terminate)
    if s.build_ticket then
        s.build_ticket.cancel(true)
        s.build_ticket = nil
    end
    close_timer(s.test_timer)
    s.test_timer = nil
    if s.dap_session then
        pcall(function()
            s.dap_session:disconnect({ terminateDebuggee = terminate })
        end)
    end
    if terminate and s.pid then
        process.signal_process_tree(s.pid, false)
    end
    if s.test_pid then
        process.signal_process_tree(s.test_pid, true)
    end
end

function M.debug_test(_state, target, filter_expr, label, opts)
    opts = opts or {}
    M.ensure_adapter()
    local target_p = type(target) == "string" and target
        or (type(target) == "table" and (target.path or target._path))
        or vim.api.nvim_buf_get_name(0)
    local csproj = (target_p and target_p:lower():sub(-7) == ".csproj" and metadata.normalize_path(target_p))
        or (target_p and metadata.find_project_root(target_p))
    if not csproj or vim.fn.filereadable(csproj) ~= 1 then
        vim.notify("Could not resolve test project .csproj", vim.log.levels.ERROR)
        return nil
    end

    local pname = vim.fn.fnamemodify(csproj, ":t:r")
    local sid = "test:" .. csproj .. ":" .. tostring(os.time()) .. ":" .. tostring(math.random(1000, 9999))
    local sname = label or ("Test: " .. pname)
    local session = create_session(
        sid,
        "test",
        { id = sid, name = sname, project_path = csproj, project_name = pname, cwd = vim.fn.fnamemodify(csproj, ":h") },
        sname,
        opts
    )
    session.test_target = csproj
    session.test_filter = filter_expr
    session.status, session.stage = "building", "building"
    dispatch_event("started", session)

    enqueue_build(session, session.config, function()
        local cmd = { require("csharp-explorer.runner").resolve_dotnet(), "test", csproj, "--no-build", "--nologo" }
        if filter_expr and filter_expr ~= "" then
            cmd[#cmd + 1], cmd[#cmd + 2] = "--filter", filter_expr
        end
        local timer = uv.new_timer()
        session.test_timer = timer
        if timer then
            timer:start(
                (config.current.debug and config.current.debug.vstest_timeout_ms) or 20000,
                0,
                vim.schedule_wrap(function()
                    close_timer(session.test_timer)
                    session.test_timer = nil
                    if session.status == "starting" or session.status == "building" then
                        cleanup_session_resources(session, true)
                        M.finalize_session(session, "failed", -1, nil)
                    end
                end)
            )
        end

        local attached_pid = nil
        local stdout_buf = ""
        local on_stdout = vim.schedule_wrap(function(err, data)
            if err or not data or data == "" then
                return
            end
            stdout_buf = stdout_buf .. data
            if not attached_pid then
                local pid_str = stdout_buf:match("Process Id:%s*(%d+)")
                if pid_str then
                    attached_pid = tonumber(pid_str)
                    session.pid = attached_pid
                    close_timer(session.test_timer)
                    session.test_timer = nil
                    session.status, session.stage = "starting", "starting"
                    dispatch_event("status_changed", session)
                    run_attach_dap(session, attached_pid, opts.just_my_code)
                end
            end
            append_output(session, data)
        end)

        local on_stderr = vim.schedule_wrap(function(_err, data)
            if data and data ~= "" then
                append_output(session, data)
            end
        end)

        local on_exit = vim.schedule_wrap(function(obj)
            session.test_handle, session.test_pid = nil, nil
            close_timer(session.test_timer)
            session.test_timer = nil
            if session.dap_session then
                pcall(function()
                    session.dap_session:disconnect({ terminateDebuggee = true })
                end)
            end
            M.finalize_session(
                session,
                (session.user_stopped or obj.code == 0) and "stopped" or "failed",
                obj.code,
                obj.signal
            )
        end)

        local ok_spawn, handle = pcall(vim.system, cmd, {
            cwd = session.config.cwd,
            env = vim.tbl_extend("force", vim.fn.environ(), { VSTEST_HOST_DEBUG = "1" }),
            detach = true,
            stdout = on_stdout,
            stderr = on_stderr,
        }, on_exit)

        if not ok_spawn or not handle then
            close_timer(session.test_timer)
            session.test_timer = nil
            M.finalize_session(session, "failed", -1, nil)
            return
        end
        session.test_handle, session.test_pid = handle, handle.pid
    end)
    return session
end

function M.restart(id, opts)
    local s = M.sessions[id]
    if not s then
        return false
    end
    local next_opts = vim.tbl_extend("force", {
        compound_id = s.compound_id,
        stop_together = s.stop_together,
        stop_at_entry = opts and opts.stop_at_entry,
        just_my_code = opts and opts.just_my_code,
    }, opts or {})

    if is_active(s) then
        s.pending_restart = { cfg = s.config, opts = next_opts }
        M.stop(id, { single = true, preserve_restart = true })
        return true
    end

    if s.mode == "test" then
        M.debug_test(nil, s.test_target or (s.config and s.config.project_path), s.test_filter, s.name, next_opts)
    elseif s.mode == "attach" and s.pid then
        M.attach(s.pid, next_opts)
    else
        M.start(s.config, next_opts)
    end
    return true
end

function M.stop(id, opts)
    opts = opts or {}
    local s = M.sessions[id]
    if not s then
        return false
    end
    if not opts.preserve_restart then
        s.pending_restart = nil
    end
    if not opts.single and s.compound_id and s.stop_together then
        return M.stop_compound(s.compound_id, { single = true })
    end
    if s.status == "stopping" or s.status == "stopped" or s.status == "failed" then
        return false
    end

    s.user_stopped = true
    if s.stage == "queued" or s.stage == "building" then
        cleanup_session_resources(s, false)
        M.finalize_session(s, "stopped", nil, nil)
        return true
    end

    s.status = "stopping"
    dispatch_event("status_changed", s)

    local terminate = s.mode ~= "attach"
    cleanup_session_resources(s, terminate)
    M.finalize_session(s, "stopped", 0, nil)
    return true
end

local function stop_matching_sessions(pred, compound_id, opts)
    opts = opts or {}
    cancel_deferred_timers(compound_id)
    local stopped = false
    for _, s in pairs(M.sessions) do
        if pred(s) and is_active(s) and M.stop(s.id, { single = true }) then
            stopped = true
        end
    end
    if not opts.from_peer and package.loaded["csharp-explorer.process"] then
        local ok, proc = pcall(require, "csharp-explorer.process")
        if ok and proc then
            local fn = compound_id and proc.stop_compound or proc.stop_all
            if fn and fn(compound_id or { from_peer = true }, { from_peer = true }) then
                stopped = true
            end
        end
    end
    return stopped
end

function M.stop_compound(compound_id, opts)
    return compound_id
            and stop_matching_sessions(function(s)
                return s.compound_id == compound_id
            end, compound_id, opts)
        or false
end

function M.stop_all(opts)
    return stop_matching_sessions(function()
        return true
    end, nil, opts)
end

function M.shutdown()
    cancel_deferred_timers(nil)
    for _, s in pairs(M.sessions) do
        s.user_stopped = true
        s.pending_restart = nil
        cleanup_session_resources(s, s.mode ~= "attach")
        s.status, s.stage = "stopped", "exited"
    end
end

M.get_watches = inspector.get_watches
M.clear_watches = inspector.clear_watches
M.add_watch = inspector.add_watch
M.remove_watch = inspector.remove_watch
M.refresh_watches = inspector.refresh_watches
M.toggle_breakpoint = inspector.toggle_breakpoint
M.set_breakpoint_condition = inspector.set_breakpoint_condition
M.clear_breakpoints = inspector.clear_breakpoints
M.get_breakpoints = inspector.get_breakpoints
M.get_exception_filters = inspector.get_exception_filters
M.set_exception_filters = inspector.set_exception_filters
M.toggle_exception_filter = inspector.toggle_exception_filter
M.populate_scope_variables = inspector.populate_scope_variables
M.fetch_variables = inspector.fetch_variables
M.toggle_variable = inspector.toggle_variable
M.evaluate = inspector.evaluate
M.select_frame = inspector.select_frame
M.run_to_cursor = inspector.run_to_cursor
M.list_dotnet_processes = inspector.list_dotnet_processes
M.sync_breakpoints_for_buf = inspector.sync_breakpoints_for_buf

return M

local config = require("csharp-explorer.config")
local uv = vim.uv or vim.loop

local M = {
    watches = {},
    exception_filters = { "user-unhandled" },
    engine = nil,
    dispatch_event = nil,
}

local function get_engine()
    return M.engine
end

local function get_session(id)
    local eng = get_engine()
    return eng and eng.get_session and eng.get_session(id) or nil
end

local function get_active_session()
    local eng = get_engine()
    local sid = eng and eng.active_session_id
    return sid and eng.get_session and eng.get_session(sid) or nil
end

local function get_all_sessions()
    local eng = get_engine()
    return eng and eng.get_sessions and eng.get_sessions() or {}
end

local function dispatch(event_type, session)
    if M.dispatch_event then
        M.dispatch_event(event_type, session)
    else
        local eng = get_engine()
        if eng and eng.dispatch_event then
            eng.dispatch_event(event_type, session)
        end
    end
end

local function close_timer(t)
    if t then
        pcall(t.stop, t)
        pcall(t.close, t)
    end
end

function M.bind_debug_engine(engine, dispatcher)
    M.engine = engine
    M.dispatch_event = dispatcher
end

function M.get_exception_filters()
    local cf = config.current.debug and config.current.debug.exception_filters
    return vim.deepcopy((cf and #cf > 0) and cf or M.exception_filters)
end

function M.set_exception_filters(filters)
    M.exception_filters = vim.deepcopy(filters or {})
    if config.current.debug then
        config.current.debug.exception_filters = vim.deepcopy(M.exception_filters)
    end
    for _, s in ipairs(get_all_sessions()) do
        if s.dap_session then
            pcall(function()
                s.dap_session:set_exception_breakpoints(M.exception_filters)
            end)
        end
    end
end

function M.toggle_exception_filter(id)
    local cur, next_f, found = M.get_exception_filters(), {}, false
    for _, f in ipairs(cur) do
        if f == id then
            found = true
        else
            next_f[#next_f + 1] = f
        end
    end
    if not found then
        next_f[#next_f + 1] = id
    end
    M.set_exception_filters(next_f)
    return next_f
end

function M.sync_breakpoints_for_buf(bufnr)
    local ok_bp, dap_bp = pcall(require, "dap.breakpoints")
    if not ok_bp or not dap_bp then
        return
    end
    local payload = dap_bp.get(bufnr) or {}
    if payload[bufnr] == nil then
        payload[bufnr] = {}
    end
    for _, s in ipairs(get_all_sessions()) do
        if s.dap_session then
            pcall(function()
                s.dap_session:set_breakpoints(payload)
            end)
        end
    end
end

local function ensure_dap_signs()
    pcall(require, "dap")
    if #vim.fn.sign_getdefined("DapBreakpoint") == 0 then
        vim.fn.sign_define("DapBreakpoint", { text = "B", texthl = "DiagnosticError" })
    end
    if #vim.fn.sign_getdefined("DapBreakpointCondition") == 0 then
        vim.fn.sign_define("DapBreakpointCondition", { text = "C", texthl = "DiagnosticWarn" })
    end
    if #vim.fn.sign_getdefined("DapBreakpointRejected") == 0 then
        vim.fn.sign_define("DapBreakpointRejected", { text = "R", texthl = "DiagnosticWarn" })
    end
    if #vim.fn.sign_getdefined("DapLogPoint") == 0 then
        vim.fn.sign_define("DapLogPoint", { text = "L", texthl = "DiagnosticInfo" })
    end
    if #vim.fn.sign_getdefined("DapStopped") == 0 then
        vim.fn.sign_define("DapStopped", { text = "->", texthl = "DiagnosticInfo" })
    end
end

function M.toggle_breakpoint(opts)
    opts = opts or {}
    ensure_dap_signs()
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local line = opts.line or vim.api.nvim_win_get_cursor(0)[1]
    local dap_bp = require("dap.breakpoints")
    local bp_opts = {
        condition = opts.condition,
        hit_condition = opts.hit_condition,
        log_message = opts.log_message,
        replace = opts.condition ~= nil or opts.hit_condition ~= nil or opts.log_message ~= nil,
    }
    dap_bp.toggle(bp_opts, bufnr, line)
    M.sync_breakpoints_for_buf(bufnr)
end

function M.set_breakpoint_condition(bufnr, line, condition)
    ensure_dap_signs()
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    line = line or vim.api.nvim_win_get_cursor(0)[1]
    local dap_bp = require("dap.breakpoints")
    dap_bp.set({ condition = condition }, bufnr, line)
    M.sync_breakpoints_for_buf(bufnr)
end

function M.clear_breakpoints()
    local ok_bp, dap_bp = pcall(require, "dap.breakpoints")
    if not ok_bp or not dap_bp then
        return
    end
    local prev = dap_bp.get() or {}
    local empty_by_buf = {}
    for bufnr, _ in pairs(prev) do
        empty_by_buf[bufnr] = {}
    end
    dap_bp.clear()
    for _, s in ipairs(get_all_sessions()) do
        if s.dap_session then
            pcall(function()
                s.dap_session:set_breakpoints(empty_by_buf)
            end)
        end
    end
end

function M.get_breakpoints()
    local out = {}
    local ok_bp, dap_bp = pcall(require, "dap.breakpoints")
    if not ok_bp or not dap_bp then
        return out
    end
    for bufnr, bplist in pairs(dap_bp.get() or {}) do
        local path = vim.api.nvim_buf_get_name(bufnr)
        for _, bp in ipairs(bplist) do
            out[#out + 1] = {
                bufnr = bufnr,
                file_path = path,
                line = bp.line,
                condition = bp.condition,
                hit_condition = bp.hitCondition,
                log_message = bp.logMessage,
                verified = bp.state and bp.state.verified ~= false,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.file_path == b.file_path then
            return a.line < b.line
        end
        return a.file_path < b.file_path
    end)
    return out
end

function M.get_watches()
    return M.watches
end

function M.clear_watches()
    M.watches = {}
end

function M.evaluate(expr, opts, cb)
    opts = opts or {}
    local s = opts.session_id and get_session(opts.session_id) or get_active_session()
    if not (s and s.dap_session) then
        if cb then
            cb("No active debug session available", nil)
        end
        return
    end
    local fid = opts.frame_id or (s.current_frame and s.current_frame.id)
    local timeout = (config.current.debug and config.current.debug.eval_timeout_ms) or 5000
    local done, timer = false, uv.new_timer()
    local function finish(err, res)
        if not done then
            done = true
            close_timer(timer)
            if cb then
                cb(err, res)
            end
        end
    end
    if timer then
        timer:start(
            timeout,
            0,
            vim.schedule_wrap(function()
                finish("Evaluation timed out", nil)
            end)
        )
    end
    s.dap_session:request(
        "evaluate",
        { expression = expr, frameId = fid, context = opts.context or "repl" },
        vim.schedule_wrap(function(err, resp)
            if err or not resp then
                finish(err or "Evaluation failed", nil)
            else
                finish(
                    nil,
                    { result = resp.result, type = resp.type, variables_reference = resp.variablesReference or 0 }
                )
            end
        end)
    )
end

function M.add_watch(expr, cb)
    if not expr or vim.trim(expr) == "" then
        return nil
    end
    local w = { expression = vim.trim(expr), variables_reference = 0 }
    M.watches[#M.watches + 1] = w
    local s = get_active_session()
    if s and s.status == "paused" and s.current_frame then
        M.evaluate(
            w.expression,
            { session_id = s.id, frame_id = s.current_frame.id, context = "watch" },
            function(err, res)
                if not err and res then
                    w.value, w.result, w.type, w.variables_reference =
                        res.result, res.result, res.type, res.variables_reference or 0
                else
                    w.error = tostring(err)
                end
                if cb then
                    cb(w)
                end
                dispatch("watches_updated", s)
            end
        )
    elseif cb then
        cb(w)
    end
    return w
end

function M.remove_watch(target)
    for i, w in ipairs(M.watches) do
        if i == target or w.expression == target then
            table.remove(M.watches, i)
            local s = get_active_session()
            if s then
                dispatch("watches_updated", s)
            end
            return true
        end
    end
    return false
end

function M.refresh_watches(session, cb)
    if not session or not session.current_frame or #M.watches == 0 then
        if cb then
            cb()
        end
        return
    end
    session.watch_states = session.watch_states or {}
    local pending = #M.watches
    for _, w in ipairs(M.watches) do
        M.evaluate(
            w.expression,
            { session_id = session.id, frame_id = session.current_frame.id, context = "watch" },
            function(err, res)
                local w_state = session.watch_states[w.expression] or { expression = w.expression }
                session.watch_states[w.expression] = w_state
                if not err and res then
                    w_state.value, w_state.result, w_state.type = res.result, res.result, res.type
                    w_state.variables_reference = res.variables_reference or 0
                    w_state.error = nil
                else
                    w_state.error = tostring(err)
                end
                local eng = get_engine()
                if eng and eng.active_session_id == session.id then
                    if not err and res then
                        w.value, w.result, w.type, w.variables_reference, w.error =
                            res.result, res.result, res.type, res.variables_reference or 0, nil
                    else
                        w.error = tostring(err)
                    end
                end
                pending = pending - 1
                if pending == 0 then
                    if cb then
                        cb()
                    end
                    dispatch("watches_updated", session)
                end
            end
        )
    end
end

function M.fetch_variables(session_id, var_ref, cb)
    local s = get_session(session_id)
    if not (s and s.dap_session) then
        if cb then
            cb("No active DAP session", {})
        end
        return
    end
    s.dap_session:request(
        "variables",
        { variablesReference = var_ref },
        vim.schedule_wrap(function(err, resp)
            if err or not resp or not resp.variables then
                if cb then
                    cb(err, {})
                end
                return
            end
            local vars = {}
            for _, v in ipairs(resp.variables) do
                vars[#vars + 1] = {
                    name = v.name,
                    value = v.value,
                    type = v.type,
                    variables_reference = v.variablesReference or 0,
                    evaluate_name = v.evaluateName,
                }
            end
            if cb then
                cb(nil, vars)
            end
        end)
    )
end

function M.toggle_variable(session_id, var_node, cb)
    local s = get_session(session_id)
    if not var_node then
        if cb then
            cb()
        end
        return
    end
    var_node.is_expanded = not var_node.is_expanded
    if s and var_node.path then
        s.expanded_paths = s.expanded_paths or {}
        s.expanded_paths[var_node.path] = var_node.is_expanded and true or nil
    end
    local function finish()
        if cb then
            cb()
        end
        if s then
            dispatch("variables_updated", s)
        end
    end
    if not var_node.is_expanded or (var_node.children and #var_node.children > 0) then
        return finish()
    end
    if (var_node.variables_reference or 0) > 0 then
        M.fetch_variables(session_id, var_node.variables_reference, function(_err, vars)
            var_node.children = vars or {}
            if var_node.path then
                for _, ch in ipairs(var_node.children) do
                    ch.path = var_node.path .. "." .. (ch.name or "")
                end
            end
            finish()
        end)
    else
        var_node.children = {}
        finish()
    end
end

local function auto_expand_var(session, v, done)
    if
        not (
            session
            and session.expanded_paths
            and v.path
            and session.expanded_paths[v.path]
            and (v.variables_reference or 0) > 0
        )
    then
        return done()
    end
    v.is_expanded = true
    M.fetch_variables(session.id, v.variables_reference, function(_err, vars)
        v.children = vars or {}
        for _, ch in ipairs(v.children) do
            ch.path = v.path .. "." .. (ch.name or "")
        end
        local pending = #v.children
        if pending == 0 then
            return done()
        end
        for _, ch in ipairs(v.children) do
            auto_expand_var(session, ch, function()
                pending = pending - 1
                if pending == 0 then
                    done()
                end
            end)
        end
    end)
end

function M.populate_scope_variables(session, raw_scopes, on_done)
    local scopes, count = {}, #(raw_scopes or {})
    if count == 0 then
        session.scopes = scopes
        if on_done then
            on_done()
        end
        return
    end
    local pending = count
    local function finish_one()
        pending = pending - 1
        if pending == 0 then
            session.scopes = scopes
            if on_done then
                on_done()
            end
        end
    end
    for i, sc in ipairs(raw_scopes) do
        local entry = { name = sc.name, variables_reference = sc.variablesReference or 0, variables = {} }
        scopes[i] = entry
        if entry.variables_reference > 0 and session.dap_session then
            M.fetch_variables(session.id, entry.variables_reference, function(_err, vars)
                entry.variables = vars or {}
                local v_pending = #entry.variables
                if v_pending == 0 then
                    finish_one()
                else
                    for _, v in ipairs(entry.variables) do
                        v.path = (sc.name or "Scope") .. ":" .. (v.name or "")
                        auto_expand_var(session, v, function()
                            v_pending = v_pending - 1
                            if v_pending == 0 then
                                finish_one()
                            end
                        end)
                    end
                end
            end)
        else
            finish_one()
        end
    end
end

function M.jump_editor_to_frame(frame)
    if not (frame and frame.source_path and vim.fn.filereadable(frame.source_path) == 1) then
        return
    end
    local cur_win, target_win = vim.api.nvim_get_current_win(), nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local ok_cfg, win_cfg = pcall(vim.api.nvim_win_get_config, w)
        local is_float = ok_cfg and win_cfg.relative ~= ""
        local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype or ""
        if vim.api.nvim_win_is_valid(w) and not is_float and not ft:find("^csharpexplorer") then
            target_win = w
            break
        end
    end
    target_win = target_win or cur_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
        vim.api.nvim_set_current_win(target_win)
        local b = vim.fn.bufadd(frame.source_path)
        vim.fn.bufload(b)
        vim.api.nvim_win_set_buf(target_win, b)
        pcall(
            vim.api.nvim_win_set_cursor,
            target_win,
            { math.max(1, frame.line or 1), math.max(0, (frame.column or 1) - 1) }
        )
        if not (config.current.debug and config.current.debug.focus_on_break) and cur_win ~= target_win then
            vim.api.nvim_set_current_win(cur_win)
        end
    end
end

function M.select_frame(session_id, frame_id_or_frame, _opts)
    local s = get_session(session_id)
    if not s then
        return false
    end
    local frame = type(frame_id_or_frame) == "table" and frame_id_or_frame or nil
    if not frame then
        for _, f in ipairs(s.frames or {}) do
            if f.id == frame_id_or_frame then
                frame = f
                break
            end
        end
    end
    if not frame then
        return false
    end
    s.current_frame = frame
    M.jump_editor_to_frame(frame)
    if s.dap_session then
        pcall(function()
            s.dap_session:_frame_set(frame.raw or frame)
        end)
        s.dap_session:request(
            "scopes",
            { frameId = frame.id },
            vim.schedule_wrap(function(err, resp)
                if not err and resp and resp.scopes then
                    M.populate_scope_variables(s, resp.scopes, function()
                        M.refresh_watches(s, function()
                            dispatch("variables_updated", s)
                        end)
                    end)
                end
            end)
        )
    end
    return true
end

function M.run_to_cursor(id)
    local s = id and get_session(id) or get_active_session()
    if not (s and s.dap_session) then
        return false
    end
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
    if target_win and vim.api.nvim_win_is_valid(target_win) then
        vim.api.nvim_set_current_win(target_win)
    end
    local ok_dap, dap = pcall(require, "dap")
    if ok_dap and dap then
        pcall(dap.set_session, s.dap_session)
        pcall(dap.run_to_cursor)
        return true
    end
    return false
end

function M.list_dotnet_processes()
    local list, seen = {}, {}
    local process = require("csharp-explorer.process")
    for _, s in ipairs(process.get_sessions()) do
        if s.pid and (s.status == "running" or s.status == "starting") then
            seen[s.pid] = true
            list[#list + 1] = {
                pid = s.pid,
                name = (s.config and s.config.name) or ("Session: " .. s.id),
                project_path = s.config and s.config.project_path,
                source = "csharp-explorer",
                is_managed = true,
            }
        end
    end
    if vim.fn.has("win32") == 1 then
        local ok_tl, tl_out = pcall(vim.fn.system, { "tasklist", "/FO", "CSV", "/NH" })
        if ok_tl and type(tl_out) == "string" then
            for line in tl_out:gmatch("[^\r\n]+") do
                local name, pid_str = line:match('^"([^"]+)","(%d+)"')
                local pid = tonumber(pid_str)
                if pid and not seen[pid] and name and name:lower():find("dotnet") then
                    list[#list + 1] = { pid = pid, name = name, source = "os", is_managed = true }
                end
            end
        end
    else
        local ok_ps, ps_out = pcall(vim.fn.system, { "ps", "-eo", "pid=,args=" })
        if ok_ps and type(ps_out) == "string" then
            for line in ps_out:gmatch("[^\r\n]+") do
                local pid_str, args_str = line:match("^%s*(%d+)%s+(.+)$")
                local pid = tonumber(pid_str)
                if pid and not seen[pid] and args_str:find("dotnet") then
                    local lower = args_str:lower()
                    local is_daemon = lower:find("csharp%-ls")
                        or lower:find("omnisharp")
                        or lower:find("netcoredbg")
                        or lower:find("msbuild")
                        or lower:find("vbcscompiler")
                        or lower:find("grep")
                    if not is_daemon then
                        list[#list + 1] = { pid = pid, name = args_str, source = "os", is_managed = true }
                    end
                end
            end
        end
    end
    return list
end

return M

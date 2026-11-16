local uv = vim.uv or vim.loop
local metadata = require("csharp-explorer.metadata")
local parser = require("csharp-explorer.git.parser")

local M = {}

local _in_flight = {}
local _breakers = {}

-- libuv requires closing uv_process_t handles inside the exit callback after SIGCHLD reap.
local function close_reaped_process(handle)
    if handle and not handle:is_closing() then
        handle:close()
    end
end

local function read_head_branch(gitdir)
    if not gitdir or gitdir == "" then
        return nil
    end
    local f = io.open(gitdir .. "/HEAD", "r")
    if not f then
        return nil
    end
    local content = f:read("*a") or ""
    f:close()
    local ref = content:match("^ref:%s*refs/heads/([^\r\n]+)")
    if ref then
        return vim.trim(ref)
    end
    local sha = content:match("^(%x%x%x%x%x%x%x)")
    if sha then
        return sha
    end
    return "HEAD"
end

function M.read_head_branch(gitdir)
    return read_head_branch(gitdir)
end

function M.reset_breaker(toplevel)
    if toplevel then
        _breakers[toplevel] = { timeouts = 0, tripped = false }
    else
        for k in pairs(_breakers) do
            _breakers[k] = { timeouts = 0, tripped = false }
        end
    end
end

function M.is_tripped(toplevel)
    return _breakers[toplevel] ~= nil and _breakers[toplevel].tripped == true
end

function M.cancel_all()
    for _, job in pairs(_in_flight) do
        job.rescan = false
        job.callbacks = {}
        job.rescan_callbacks = {}
        if job.handle and not job.handle:is_closing() then
            pcall(uv.kill, job.pid, "sigkill")
        end
    end
end

function M.discover_repo(dir, cb)
    local stdout = uv.new_pipe(false)
    local output = {}
    local exited = false
    local eof = false
    local exit_code = nil
    local handle

    local function maybe_complete()
        if not exited or not eof then
            return
        end
        vim.schedule(function()
            if exit_code ~= 0 then
                cb(nil)
                return
            end
            local lines = {}
            for line in table.concat(output):gmatch("[^\r\n]+") do
                lines[#lines + 1] = line
            end
            if #lines < 2 then
                cb(nil)
                return
            end
            local toplevel = metadata.normalize_path(lines[1])
            local gitdir = metadata.normalize_path(lines[2])
            cb({
                toplevel = toplevel,
                gitdir = gitdir,
                branch = read_head_branch(gitdir),
            })
        end)
    end

    handle = uv.spawn("git", {
        args = { "-C", dir, "rev-parse", "--show-toplevel", "--absolute-git-dir" },
        stdio = { nil, stdout, nil },
    }, function(code, _signal)
        close_reaped_process(handle)
        exit_code = code
        exited = true
        maybe_complete()
    end)

    if not handle then
        if stdout and not stdout:is_closing() then
            stdout:close()
        end
        vim.schedule(function()
            cb(nil)
        end)
        return
    end

    stdout:read_start(function(err, data)
        if not err and data then
            output[#output + 1] = data
            return
        end
        if stdout and not stdout:is_closing() then
            stdout:read_stop()
            stdout:close()
        end
        eof = true
        maybe_complete()
    end)
end

function M.scan_repo(toplevel, cfg, on_done)
    cfg = cfg or {}
    local breaker = _breakers[toplevel]
    if not breaker then
        breaker = { timeouts = 0, tripped = false }
        _breakers[toplevel] = breaker
    end

    if cfg.force then
        breaker.timeouts = 0
        breaker.tripped = false
    end

    if breaker.tripped then
        if on_done then
            vim.schedule(function()
                on_done(false, "circuit_breaker_tripped")
            end)
        end
        return
    end

    local existing = _in_flight[toplevel]
    if existing then
        existing.rescan = true
        if on_done then
            existing.rescan_callbacks[#existing.rescan_callbacks + 1] = on_done
        end
        return
    end

    local in_flight = {
        rescan = false,
        callbacks = on_done and { on_done } or {},
        rescan_callbacks = {},
        handle = nil,
        pid = nil,
    }
    _in_flight[toplevel] = in_flight

    local entries = {}
    local ignored_dirs = {}
    local stream = parser.new(function(entry)
        entries[#entries + 1] = entry
    end, function(rel_dir)
        ignored_dirs[#ignored_dirs + 1] = rel_dir
    end)

    local stdout = uv.new_pipe(false)
    local timer = uv.new_timer()
    local timed_out = false
    local timeout_ms = tonumber(cfg.timeout) or 400
    local max_timeouts = tonumber(cfg.max_timeouts) or 5

    local function finish_job(success, payload)
        local callbacks = in_flight.callbacks
        local rescan = in_flight.rescan
        local rescan_callbacks = in_flight.rescan_callbacks
        _in_flight[toplevel] = nil

        for _, fn in ipairs(callbacks) do
            pcall(fn, success, payload)
        end

        if rescan then
            if breaker.tripped then
                for _, fn in ipairs(rescan_callbacks) do
                    pcall(fn, false, "circuit_breaker_tripped")
                end
            else
                M.scan_repo(toplevel, cfg, function(ok2, payload2)
                    if #rescan_callbacks > 0 then
                        for _, fn in ipairs(rescan_callbacks) do
                            pcall(fn, ok2, payload2)
                        end
                    elseif cfg.on_rescan_done then
                        pcall(cfg.on_rescan_done, ok2, payload2)
                    end
                end)
            end
        end
    end

    local exited = false
    local eof = false
    local exit_code = nil
    local handle, pid

    local function maybe_finalize()
        if not exited or not eof then
            return
        end
        vim.schedule(function()
            if timed_out then
                breaker.timeouts = breaker.timeouts + 1
                if breaker.timeouts >= max_timeouts then
                    breaker.tripped = true
                    vim.notify(
                        string.format("CSharp Explorer: git status timed out %d times; polling paused", max_timeouts),
                        vim.log.levels.WARN
                    )
                end
                finish_job(false, "timeout")
                return
            end

            if exit_code ~= 0 then
                finish_job(false, "exit_" .. tostring(exit_code))
                return
            end

            breaker.timeouts = 0
            stream.finish()

            finish_job(true, {
                entries = entries,
                ignored_dirs = ignored_dirs,
                branch = cfg.gitdir and read_head_branch(cfg.gitdir) or nil,
            })
        end)
    end

    handle, pid = uv.spawn("git", {
        args = {
            "-C",
            toplevel,
            "--no-optional-locks",
            "status",
            "--porcelain=v1",
            "-z",
            "-uall",
            "--ignored=matching",
        },
        stdio = { nil, stdout, nil },
    }, function(code, _signal)
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        if timed_out and stdout and not stdout:is_closing() then
            stdout:read_stop()
            stdout:close()
            eof = true
        end
        close_reaped_process(handle)
        exit_code = code
        exited = true
        maybe_finalize()
    end)

    if not handle then
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        if stdout and not stdout:is_closing() then
            stdout:close()
        end
        _in_flight[toplevel] = nil
        if on_done then
            vim.schedule(function()
                on_done(false, "spawn_failed")
            end)
        end
        return
    end

    in_flight.handle = handle
    in_flight.pid = pid

    timer:start(timeout_ms, 0, function()
        timed_out = true
        if handle and not handle:is_closing() and pid then
            pcall(uv.kill, pid, "sigkill")
        end
    end)

    stdout:read_start(function(err, data)
        if not err and data then
            stream.push(data)
            return
        end
        if stdout and not stdout:is_closing() then
            stdout:read_stop()
            stdout:close()
        end
        eof = true
        maybe_finalize()
    end)
end

return M

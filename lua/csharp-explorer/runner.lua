local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local node_utils = require("csharp-explorer.node")
local navigation = require("csharp-explorer.actions.navigation")
local uv = vim.uv or vim.loop

local M = {}

M.build_ns_id = vim.api.nvim_create_namespace("CSharpExplorerBuild")
M.current_run = nil
M.last_run = nil
M.output_win = nil
M.output_buf = nil
M._output_caller_win = nil
M._output_prev_win = nil

function M.resolve_dotnet()
    local cfg = config.current.orchestration
    if cfg and cfg.dotnet_cmd and cfg.dotnet_cmd ~= "" then
        return cfg.dotnet_cmd
    end
    local exe = vim.fn.exepath("dotnet")
    if exe and exe ~= "" then
        return exe
    end
    local home = vim.fn.expand("~")
    local candidates = {
        home .. "/.local/bin/dotnet",
        home .. "/.dotnet/dotnet",
        "/usr/local/share/dotnet/dotnet",
    }
    for _, cand in ipairs(candidates) do
        local stat = uv.fs_stat(cand)
        if stat and stat.type == "file" then
            return cand
        end
    end
    return "dotnet"
end

function M.collect_child_projects(node)
    if not node then
        return {}
    end
    local collected = {}
    local seen = {}
    local function walk(n)
        if not n then
            return
        end
        if n._type == "project" and n._path then
            local norm = metadata.normalize_path(n._path)
            if not seen[norm] then
                seen[norm] = true
                table.insert(collected, norm)
            end
        end
        if n._children then
            for _, child in pairs(n._children) do
                walk(child)
            end
        end
    end
    walk(node)
    table.sort(collected)
    return collected
end

function M.compute_solution_folder_path(node)
    if not node then
        return nil
    end
    local parts = {}
    local curr = node
    while curr and curr._type == "folder" and curr._dir == nil do
        if curr._name and curr._name ~= "" then
            table.insert(parts, 1, curr._name)
        end
        curr = curr._parent
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "/")
end

local function find_ancestor_project(n)
    local curr = n
    while curr do
        if curr._type == "project" then
            return curr
        end
        curr = curr._parent
    end
    return nil
end

function M.resolve_target(state, opts)
    if opts and opts.target and opts.target.kind then
        return opts.target
    end

    local solution_path = nil
    if state and state.tree and state.tree._path then
        solution_path = metadata.normalize_path(state.tree._path)
    end
    local solution_dir = (state and state.tree and state.tree._dir)
        or (solution_path and vim.fn.fnamemodify(solution_path, ":h"))
        or vim.fn.getcwd()

    local in_explorer = (opts and opts.node ~= nil)
        or (
            state
            and state.win
            and vim.api.nvim_win_is_valid(state.win)
            and vim.api.nvim_get_current_win() == state.win
        )

    if in_explorer then
        local node = (opts and opts.node) or navigation.get_node(state)
        if not node then
            return nil
        end
        while node and node._virtual and node._parent do
            node = node._parent
        end
        if not node then
            return nil
        end

        if node._type == "solution" then
            return {
                kind = "solution",
                name = node._name or (solution_path and vim.fn.fnamemodify(solution_path, ":t")) or "Solution",
                path = solution_path or (node._path and metadata.normalize_path(node._path)),
                dir = solution_dir,
                cwd = solution_dir,
                solution_path = solution_path,
                solution_folder = nil,
                project_node = nil,
                project_paths = M.collect_child_projects(node),
                cursor_line = nil,
            }
        elseif node._type == "project" then
            local p_path = node._path and metadata.normalize_path(node._path)
            local p_dir = node._dir or (p_path and vim.fn.fnamemodify(p_path, ":h"))
            return {
                kind = "project",
                name = node._name or (p_path and vim.fn.fnamemodify(p_path, ":t:r")) or "Project",
                path = p_path,
                dir = p_dir,
                cwd = p_dir or solution_dir,
                solution_path = solution_path,
                solution_folder = node._parent and M.compute_solution_folder_path(node._parent),
                project_node = node,
                project_paths = p_path and { p_path } or {},
                cursor_line = nil,
            }
        elseif node._type == "folder" then
            if node._dir == nil then
                return {
                    kind = "solution_folder",
                    name = node._name,
                    path = nil,
                    dir = nil,
                    cwd = solution_dir,
                    solution_path = solution_path,
                    solution_folder = M.compute_solution_folder_path(node),
                    project_node = nil,
                    project_paths = M.collect_child_projects(node),
                    cursor_line = nil,
                }
            else
                local p_node = find_ancestor_project(node)
                    or (state and state.tree and metadata.find_owning_project(node._dir, state.tree))
                local p_path = p_node and p_node._path and metadata.normalize_path(p_node._path)
                local d_path = metadata.normalize_path(node._dir or node._path)
                return {
                    kind = "directory",
                    name = node._name,
                    path = d_path,
                    dir = d_path,
                    cwd = d_path,
                    solution_path = solution_path,
                    solution_folder = nil,
                    project_node = p_node,
                    project_paths = p_path and { p_path } or {},
                    cursor_line = nil,
                }
            end
        elseif node_utils.is_file(node) or node._path then
            local f_path = node._path and metadata.normalize_path(node._path)
            local p_node = find_ancestor_project(node)
                or (f_path and state and state.tree and metadata.find_owning_project(f_path, state.tree))
            local p_path = p_node and p_node._path and metadata.normalize_path(p_node._path)
            local f_dir = f_path and vim.fn.fnamemodify(f_path, ":h")
            return {
                kind = "file",
                name = node._name or (f_path and vim.fn.fnamemodify(f_path, ":t")) or "File",
                path = f_path,
                dir = f_dir,
                cwd = f_dir or solution_dir,
                solution_path = solution_path,
                solution_folder = nil,
                project_node = p_node,
                project_paths = p_path and { p_path } or {},
                cursor_line = nil,
            }
        end
        return nil
    end

    if state and state.ensure_tree then
        state.ensure_tree()
    end
    if state and state.tree and state.tree._path then
        solution_path = metadata.normalize_path(state.tree._path)
        solution_dir = state.tree._dir or vim.fn.fnamemodify(solution_path, ":h")
    end

    local buf_name = vim.api.nvim_buf_get_name(0)
    if buf_name == "" then
        if state and state.tree then
            return {
                kind = "solution",
                name = state.tree._name or (solution_path and vim.fn.fnamemodify(solution_path, ":t")) or "Solution",
                path = solution_path,
                dir = solution_dir,
                cwd = solution_dir,
                solution_path = solution_path,
                solution_folder = nil,
                project_node = nil,
                project_paths = M.collect_child_projects(state.tree),
                cursor_line = nil,
            }
        end
        return nil
    end

    local norm_buf = metadata.normalize_path(buf_name)
    if norm_buf:match("%.slnx?$") then
        local sol_node = state and state.tree
        local sol_dir = vim.fn.fnamemodify(norm_buf, ":h")
        return {
            kind = "solution",
            name = vim.fn.fnamemodify(norm_buf, ":t"),
            path = norm_buf,
            dir = sol_dir,
            cwd = sol_dir,
            solution_path = norm_buf,
            solution_folder = nil,
            project_node = nil,
            project_paths = sol_node and M.collect_child_projects(sol_node) or {},
            cursor_line = vim.api.nvim_win_get_cursor(0)[1],
        }
    end

    if norm_buf:match("%.csproj$") then
        local proj_node = state and state.tree and metadata.find_owning_project(norm_buf, state.tree)
        local proj_dir = vim.fn.fnamemodify(norm_buf, ":h")
        local proj_name = (proj_node and proj_node._name) or vim.fn.fnamemodify(norm_buf, ":t:r")
        local sol_folder = proj_node and proj_node._parent and M.compute_solution_folder_path(proj_node._parent)
        return {
            kind = "project",
            name = proj_name,
            path = norm_buf,
            dir = proj_dir,
            cwd = proj_dir,
            solution_path = solution_path,
            solution_folder = sol_folder,
            project_node = proj_node,
            project_paths = { norm_buf },
            cursor_line = vim.api.nvim_win_get_cursor(0)[1],
        }
    end

    local owning = state and state.tree and metadata.find_owning_project(norm_buf, state.tree)
    local owning_path = owning and owning._path and metadata.normalize_path(owning._path)
    local f_dir = vim.fn.fnamemodify(norm_buf, ":h")
    return {
        kind = "file",
        name = vim.fn.fnamemodify(norm_buf, ":t"),
        path = norm_buf,
        dir = f_dir,
        cwd = f_dir,
        solution_path = solution_path,
        solution_folder = nil,
        project_node = owning,
        project_paths = owning_path and { owning_path } or {},
        cursor_line = vim.api.nvim_win_get_cursor(0)[1],
    }
end

local function decode_xml_entities(str)
    if not str then
        return nil
    end
    return (
        str:gsub("&#x0*[dD];", "")
            :gsub("&#x0*[aA];", "\n")
            :gsub("&lt;", "<")
            :gsub("&gt;", ">")
            :gsub("&quot;", '"')
            :gsub("&apos;", "'")
            :gsub("&amp;", "&")
    )
end

function M.parse_msbuild_output(output, cwd)
    local diagnostics = {}
    local quickfix = {}
    local seen = {}
    local errors = 0
    local warnings = 0

    for raw_line in (output or ""):gmatch("[^\r\n]+") do
        local line = vim.trim(raw_line)
        local file, lnum, col, sev, code, msg, proj =
            line:match("^(.-)%((%d+),(%d+)%):%s*(%a+)%s+([%w_]+):%s*(.-)%s*%[(.-)%]$")
        if not file then
            file, lnum, col, sev, code, msg, proj =
                line:match("^(.-)%((%d+),(%d+),%d+,%d+%):%s*(%a+)%s+([%w_]+):%s*(.-)%s*%[(.-)%]$")
        end
        if not file then
            file, lnum, sev, code, msg, proj = line:match("^(.-)%((%d+)%):%s*(%a+)%s+([%w_]+):%s*(.-)%s*%[(.-)%]$")
            if file then
                col = "1"
            end
        end
        if not file then
            file, lnum, col, sev, code, msg = line:match("^(.-)%((%d+),(%d+)%):%s*(%a+)%s+([%w_]+):%s*(.-)$")
        end
        if not file then
            file, sev, code, msg, proj = line:match("^(.-)%s*:%s*(%a+)%s+([%w_]+):%s*(.-)%s*%[(.-)%]$")
            if file then
                lnum = "1"
                col = "1"
            end
        end
        if not file then
            file, sev, code, msg = line:match("^(MSBUILD)%s*:%s*(%a+)%s+([%w_]+):%s*(.-)$")
            if file then
                lnum = "1"
                col = "1"
            end
        end

        if file and sev and code and msg then
            local sev_lower = sev:lower()
            if sev_lower == "error" or sev_lower == "warning" then
                file = vim.trim(file):gsub("\\", "/")
                if file ~= "MSBUILD" and file ~= "CSC" and file:sub(1, 1) ~= "/" then
                    local base = proj and vim.fn.fnamemodify(proj:gsub("\\", "/"), ":h") or cwd
                    if base and base ~= "" then
                        file = (base .. "/" .. file):gsub("//+", "/")
                    end
                end
                local n_line = tonumber(lnum) or 1
                local n_col = tonumber(col) or 1
                local clean_msg = vim.trim(msg)
                local dedup_key = string.format("%s:%d:%d:%s:%s", file, n_line, n_col, code, clean_msg)
                if not seen[dedup_key] then
                    seen[dedup_key] = true
                    if sev_lower == "error" then
                        errors = errors + 1
                    else
                        warnings = warnings + 1
                    end
                    local is_real_file = (file ~= "MSBUILD" and file ~= "CSC")
                    if is_real_file then
                        table.insert(diagnostics, {
                            file = file,
                            lnum = n_line,
                            col = n_col,
                            severity = sev_lower,
                            code = code,
                            message = clean_msg,
                            project = proj,
                        })
                    end
                    table.insert(quickfix, {
                        filename = is_real_file and file or (proj or nil),
                        lnum = n_line,
                        col = n_col,
                        text = string.format("%s %s: %s", sev_lower:upper(), code, clean_msg),
                        type = sev_lower == "error" and "E" or "W",
                    })
                end
            end
        end
    end

    return {
        errors = errors,
        warnings = warnings,
        diagnostics = diagnostics,
        quickfix = quickfix,
    }
end

function M.parse_trx(xml)
    local summary = {
        total = 0,
        passed = 0,
        failed = 0,
        skipped = 0,
        outcome = xml:match('<ResultSummary%s+[^>]*outcome="([^"]+)"') or "Unknown",
    }
    local counters = xml:match("<Counters%s+([^>]+)/>")
    if counters then
        summary.total = tonumber(counters:match('total="(%d+)"')) or 0
        summary.passed = tonumber(counters:match('passed="(%d+)"')) or 0
        local failed = tonumber(counters:match('failed="(%d+)"')) or 0
        local err_c = tonumber(counters:match('error="(%d+)"')) or 0
        local timeout_c = tonumber(counters:match('timeout="(%d+)"')) or 0
        local aborted_c = tonumber(counters:match('aborted="(%d+)"')) or 0
        summary.failed = failed + err_c + timeout_c + aborted_c
        local not_exec = tonumber(counters:match('notExecuted="(%d+)"')) or 0
        local skipped = tonumber(counters:match('skipped="(%d+)"')) or 0
        summary.skipped = skipped + not_exec
    end

    local results = {}
    local quickfix = {}

    local pos = 1
    local xml_len = #xml
    while pos <= xml_len do
        local s, e = xml:find("<UnitTestResult%s+", pos)
        if not s then
            break
        end
        local tag_end = xml:find(">", e + 1, true)
        if not tag_end then
            break
        end

        local is_self_closing = xml:sub(tag_end - 1, tag_end) == "/>"
        local attrs = is_self_closing and xml:sub(e + 1, tag_end - 2) or xml:sub(e + 1, tag_end - 1)
        local inner = nil

        if is_self_closing then
            pos = tag_end + 1
        else
            local close_s, close_e = xml:find("</UnitTestResult>", tag_end + 1, true)
            if close_s then
                inner = xml:sub(tag_end + 1, close_s - 1)
                pos = close_e + 1
            else
                pos = tag_end + 1
            end
        end

        local test_name = decode_xml_entities(attrs:match('testName="([^"]+)"')) or "UnknownTest"
        local outcome = attrs:match('outcome="([^"]+)"') or "Unknown"
        local duration = attrs:match('duration="([^"]+)"') or ""

        if inner then
            local err_msg = decode_xml_entities(inner:match("<Message>(.-)</Message>"))
            local stack = decode_xml_entities(inner:match("<StackTrace>(.-)</StackTrace>"))
            local file, lnum
            if stack then
                file, lnum = stack:match("in%s+([^\r\n:]+):line%s+(%d+)")
                if file then
                    file = vim.trim(file):gsub("\\", "/")
                end
            end
            table.insert(results, {
                test_name = test_name,
                outcome = outcome,
                duration = duration,
                message = err_msg,
                stack_trace = stack,
                file = file,
                lnum = lnum and tonumber(lnum) or nil,
            })
            if outcome == "Failed" or outcome == "Error" or outcome == "Timeout" then
                local headline = err_msg and vim.trim(err_msg:match("^[^\r\n]+") or "") or "Test failed"
                table.insert(quickfix, {
                    filename = file,
                    lnum = tonumber(lnum) or 1,
                    col = 1,
                    text = string.format("[FAIL] %s: %s", test_name, headline),
                    type = "E",
                })
            end
        else
            table.insert(results, {
                test_name = test_name,
                outcome = outcome,
                duration = duration,
            })
            if outcome == "Failed" or outcome == "Error" or outcome == "Timeout" then
                table.insert(quickfix, {
                    filename = nil,
                    lnum = 1,
                    col = 1,
                    text = string.format("[FAIL] %s", test_name),
                    type = "E",
                })
            end
        end
    end

    return {
        summary = summary,
        results = results,
        quickfix = quickfix,
    }
end

function M.aggregate_trx_dir(results_dir, keep_dir)
    local summary = {
        total = 0,
        passed = 0,
        failed = 0,
        skipped = 0,
        outcome = "Unknown",
    }
    local all_results = {}
    local all_quickfix = {}

    local trx_files = vim.fn.glob(results_dir .. "/**/*.trx", false, true)
    if #trx_files == 0 then
        trx_files = vim.fn.glob(results_dir .. "/*.trx", false, true)
    end

    for _, fpath in ipairs(trx_files) do
        local f = io.open(fpath, "r")
        if f then
            local content = f:read("*a")
            f:close()
            local parsed = M.parse_trx(content)
            summary.total = summary.total + parsed.summary.total
            summary.passed = summary.passed + parsed.summary.passed
            summary.failed = summary.failed + parsed.summary.failed
            summary.skipped = summary.skipped + parsed.summary.skipped
            for _, r in ipairs(parsed.results) do
                table.insert(all_results, r)
            end
            for _, q in ipairs(parsed.quickfix) do
                table.insert(all_quickfix, q)
            end
        end
    end

    if summary.failed > 0 then
        summary.outcome = "Failed"
    elseif summary.total > 0 then
        summary.outcome = "Passed"
    else
        summary.outcome = "Unknown"
    end

    if not keep_dir and results_dir and results_dir ~= "" and uv.fs_stat(results_dir) then
        vim.fn.delete(results_dir, "rf")
    end

    return {
        summary = summary,
        results = all_results,
        quickfix = all_quickfix,
    }
end

function M.clear_build_diagnostics()
    vim.diagnostic.reset(M.build_ns_id)
end

function M.sync_build_diagnostics(diagnostics_list)
    vim.diagnostic.reset(M.build_ns_id)
    if not diagnostics_list or #diagnostics_list == 0 then
        return
    end

    local by_file = {}
    for _, d in ipairs(diagnostics_list) do
        if d.file and d.file ~= "" and uv.fs_stat(d.file) then
            local norm = metadata.normalize_path(d.file)
            if not by_file[norm] then
                by_file[norm] = {}
            end
            local sev = d.severity == "error" and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN
            local lnum = math.max(0, (tonumber(d.lnum) or 1) - 1)
            local col = math.max(0, (tonumber(d.col) or 1) - 1)
            table.insert(by_file[norm], {
                lnum = lnum,
                col = col,
                severity = sev,
                message = d.message,
                source = "dotnet",
                code = d.code,
            })
        end
    end

    for file_path, items in pairs(by_file) do
        local bufnr = vim.fn.bufadd(file_path)
        vim.diagnostic.set(M.build_ns_id, bufnr, items, {})
    end
end

function M.is_running()
    return M.current_run ~= nil and (M.current_run.status == "running" or M.current_run.status == "cancelling")
end

function M.open_output()
    if M.output_win and vim.api.nvim_win_is_valid(M.output_win) then
        return M.output_buf, M.output_win
    end

    local caller_win = vim.api.nvim_get_current_win()
    local prev_win = vim.fn.win_getid(vim.fn.winnr("#"))

    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.6)
    local row = math.max(1, math.floor((vim.o.lines - height) / 2))
    local col = math.max(1, math.floor((vim.o.columns - width) / 2))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false

    local lines = (M.current_run and M.current_run.lines) or (M.last_run and M.last_run.lines) or { "No task output" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    local title = M.current_run and (" " .. (M.current_run.title or "Task Output") .. " (Running) ")
        or (M.last_run and (" " .. (M.last_run.title or "Task Output") .. " (" .. M.last_run.status .. ") "))
        or " Task Output "

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = title,
        title_pos = "center",
        footer = " q / <Esc> to close ",
        footer_pos = "center",
    })

    M.output_win = win
    M.output_buf = buf
    M._output_caller_win = caller_win
    M._output_prev_win = prev_win

    local function close_fn()
        M.close_output()
    end

    local b_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "q", close_fn, b_opts)
    vim.keymap.set("n", "<Esc>", close_fn, b_opts)

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            M.close_output()
        end,
    })

    if #lines > 0 then
        pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 })
    end

    return buf, win
end

function M.close_output()
    local caller_win = M._output_caller_win
    local prev_win = M._output_prev_win
    local closing_win = M.output_win

    M.output_win = nil
    M.output_buf = nil
    M._output_caller_win = nil
    M._output_prev_win = nil

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

function M.toggle_output()
    if M.output_win and vim.api.nvim_win_is_valid(M.output_win) then
        M.close_output()
    else
        M.open_output()
    end
end

function M.cancel()
    if not M.current_run or (M.current_run.status ~= "running" and M.current_run.status ~= "cancelling") then
        return
    end
    local run = M.current_run
    run.status = "cancelling"
    if run.handle then
        pcall(function()
            run.handle:kill(15)
        end)
    end
    if run.cancel_timer then
        pcall(function()
            run.cancel_timer:stop()
            run.cancel_timer:close()
        end)
        run.cancel_timer = nil
    end
    local timer = uv.new_timer()
    run.cancel_timer = timer
    timer:start(
        1500,
        0,
        vim.schedule_wrap(function()
            if timer and not timer:is_closing() then
                timer:stop()
                timer:close()
            end
            if run.cancel_timer == timer then
                run.cancel_timer = nil
            end
            if run.status == "cancelling" and run.handle then
                pcall(function()
                    run.handle:kill(9)
                end)
            end
        end)
    )
    vim.notify("Cancelling task: " .. (run.title or "dotnet task"), vim.log.levels.INFO)
end

function M.shutdown()
    if M.current_run and (M.current_run.status == "running" or M.current_run.status == "cancelling") then
        local run = M.current_run
        run.status = "cancelled"
        if run.handle then
            pcall(function()
                run.handle:kill(15)
                run.handle:kill(9)
            end)
        end
        if run.cancel_timer then
            pcall(function()
                run.cancel_timer:stop()
                run.cancel_timer:close()
            end)
            run.cancel_timer = nil
        end
    end
    M.current_run = nil
    M.close_output()
end

function M.run_pipeline(steps, opts)
    if M.is_running() then
        vim.notify("Another task is already running: " .. (M.current_run.title or "dotnet task"), vim.log.levels.WARN)
        if opts and opts.on_complete then
            opts.on_complete({
                status = "failed",
                exit_code = 1,
                lines = { "Task already running" },
                output = "Task already running",
            })
        end
        return nil, "Task already running"
    end

    local max_lines = (config.current.orchestration and config.current.orchestration.output_max_lines) or 2000
    local run = {
        status = "running",
        title = (opts and opts.title) or "Task",
        steps = steps or {},
        current_step = 1,
        handle = nil,
        cancel_timer = nil,
        lines = {},
        exit_code = nil,
        started_at = uv.hrtime(),
        finished_at = nil,
    }
    M.current_run = run

    local function sync_output_float()
        if M.output_win == nil then
            return
        end
        vim.schedule(function()
            if
                M.output_win
                and vim.api.nvim_win_is_valid(M.output_win)
                and M.output_buf
                and vim.api.nvim_buf_is_valid(M.output_buf)
            then
                local active = M.current_run or M.last_run
                local lines_to_show = (active and active.lines and #active.lines > 0) and active.lines
                    or { "No task output" }
                vim.bo[M.output_buf].readonly = false
                vim.bo[M.output_buf].modifiable = true
                vim.api.nvim_buf_set_lines(M.output_buf, 0, -1, false, lines_to_show)
                vim.bo[M.output_buf].modifiable = false
                vim.bo[M.output_buf].readonly = true

                local status_label = M.current_run and "Running" or (M.last_run and M.last_run.status or "Idle")
                local title_text = active and (" " .. (active.title or "Task Output") .. " (" .. status_label .. ") ")
                    or " Task Output "
                pcall(vim.api.nvim_win_set_config, M.output_win, {
                    title = title_text,
                    title_pos = "center",
                })
                local count = vim.api.nvim_buf_line_count(M.output_buf)
                pcall(vim.api.nvim_win_set_cursor, M.output_win, { count, 0 })
            end
        end)
    end

    if #run.steps == 0 then
        run.status = "succeeded"
        run.finished_at = uv.hrtime()
        M.last_run = run
        M.current_run = nil
        sync_output_float()
        if opts and opts.on_complete then
            opts.on_complete({
                status = run.status,
                exit_code = 0,
                lines = run.lines,
                output = "",
            })
        end
        return run
    end

    local function append_log_line(line)
        table.insert(run.lines, line)
        if #run.lines > max_lines then
            table.remove(run.lines, 1)
        end
        sync_output_float()
    end

    local execute_current_step

    execute_current_step = function()
        if run.status ~= "running" then
            return
        end
        local step = run.steps[run.current_step]
        if not step then
            run.status = "succeeded"
            run.finished_at = uv.hrtime()
            M.last_run = run
            M.current_run = nil
            sync_output_float()
            if opts and opts.on_complete then
                opts.on_complete({
                    status = run.status,
                    exit_code = run.exit_code or 0,
                    lines = run.lines,
                    output = table.concat(run.lines, "\n"),
                })
            end
            return
        end

        if step.label then
            append_log_line(">>> " .. step.label)
        end

        local partial_stdout = ""
        local partial_stderr = ""

        local function on_stdout_chunk(_, data)
            if data then
                local combined = partial_stdout .. data
                local s = 1
                while true do
                    local nl = combined:find("\n", s, true)
                    if not nl then
                        break
                    end
                    local l = combined:sub(s, nl - 1):gsub("\r$", "")
                    append_log_line(l)
                    s = nl + 1
                end
                partial_stdout = combined:sub(s)
            end
        end

        local function on_stderr_chunk(_, data)
            if data then
                local combined = partial_stderr .. data
                local s = 1
                while true do
                    local nl = combined:find("\n", s, true)
                    if not nl then
                        break
                    end
                    local l = combined:sub(s, nl - 1):gsub("\r$", "")
                    append_log_line(l)
                    s = nl + 1
                end
                partial_stderr = combined:sub(s)
            end
        end

        local function on_step_exit(obj)
            if partial_stdout ~= "" then
                append_log_line(partial_stdout:gsub("\r$", ""))
                partial_stdout = ""
            end
            if partial_stderr ~= "" then
                append_log_line(partial_stderr:gsub("\r$", ""))
                partial_stderr = ""
            end

            run.exit_code = obj.code
            run.handle = nil

            vim.schedule(function()
                if run.status == "cancelling" then
                    run.status = "cancelled"
                    if run.cancel_timer then
                        pcall(function()
                            run.cancel_timer:stop()
                            run.cancel_timer:close()
                        end)
                        run.cancel_timer = nil
                    end
                    run.finished_at = uv.hrtime()
                    M.last_run = run
                    M.current_run = nil
                    sync_output_float()
                    if opts and opts.on_complete then
                        opts.on_complete({
                            status = "cancelled",
                            exit_code = obj.code,
                            lines = run.lines,
                            output = table.concat(run.lines, "\n"),
                        })
                    end
                    return
                end

                local ok = (obj.code == 0) or (step.allow_nonzero == true)
                if ok then
                    run.current_step = run.current_step + 1
                    if run.current_step <= #run.steps then
                        execute_current_step()
                    else
                        run.status = "succeeded"
                        run.finished_at = uv.hrtime()
                        M.last_run = run
                        M.current_run = nil
                        sync_output_float()
                        if opts and opts.on_complete then
                            opts.on_complete({
                                status = "succeeded",
                                exit_code = obj.code,
                                lines = run.lines,
                                output = table.concat(run.lines, "\n"),
                            })
                        end
                    end
                else
                    run.status = "failed"
                    run.finished_at = uv.hrtime()
                    M.last_run = run
                    M.current_run = nil
                    sync_output_float()
                    if opts and opts.on_complete then
                        opts.on_complete({
                            status = "failed",
                            exit_code = obj.code,
                            lines = run.lines,
                            output = table.concat(run.lines, "\n"),
                        })
                    end
                end
            end)
        end

        run.handle = vim.system(step.cmd, {
            cwd = step.cwd,
            stdout = on_stdout_chunk,
            stderr = on_stderr_chunk,
        }, on_step_exit)
    end

    execute_current_step()
    return run
end

function M.run(step, opts)
    return M.run_pipeline({ step }, opts)
end

return M

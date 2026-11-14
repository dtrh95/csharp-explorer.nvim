local runner = require("csharp-explorer.runner")
local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local navigation = require("csharp-explorer.actions.navigation")

local M = {}

local TEST_ATTRS = {
    Fact = "xunit",
    Theory = "xunit",
    Test = "nunit",
    TestCase = "nunit",
    TestCaseSource = "nunit",
    TestMethod = "mstest",
    DataTestMethod = "mstest",
}

local CS_KEYWORDS = {
    public = true,
    private = true,
    protected = true,
    internal = true,
    static = true,
    async = true,
    virtual = true,
    override = true,
    abstract = true,
    sealed = true,
    extern = true,
    unsafe = true,
    new = true,
    void = true,
    Task = true,
    ValueTask = true,
    ["return"] = true,
    ["if"] = true,
    ["for"] = true,
    ["foreach"] = true,
    ["while"] = true,
    ["switch"] = true,
    ["using"] = true,
    ["lock"] = true,
    ["catch"] = true,
    class = true,
    struct = true,
    record = true,
    interface = true,
    namespace = true,
}

function M.strip_csharp_lexical_noise(src)
    local out = {}
    local i = 1
    local len = #src
    while i <= len do
        local hit = src:find("[/\\\"'@$]", i)
        if not hit then
            table.insert(out, src:sub(i))
            break
        end
        if hit > i then
            table.insert(out, src:sub(i, hit - 1))
            i = hit
        end

        local c = src:sub(i, i)
        local c2 = src:sub(i, i + 1)

        if c2 == "//" then
            local nl = src:find("\n", i + 2, true)
            if nl then
                table.insert(out, string.rep(" ", nl - i))
                i = nl
            else
                table.insert(out, string.rep(" ", len - i + 1))
                break
            end
        elseif c2 == "/*" then
            local end_c = src:find("*/", i + 2, true)
            if end_c then
                local seg = src:sub(i, end_c + 1)
                table.insert(out, (seg:gsub("[^\n]", " ")))
                i = end_c + 2
            else
                local seg = src:sub(i)
                table.insert(out, (seg:gsub("[^\n]", " ")))
                break
            end
        elseif src:sub(i, i + 2) == '"""' then
            local qcount = 3
            while src:sub(i + qcount, i + qcount) == '"' do
                qcount = qcount + 1
            end
            local closing = string.rep('"', qcount)
            local end_r = src:find(closing, i + qcount, true)
            if end_r then
                local last_q = end_r + qcount - 1
                while src:sub(last_q + 1, last_q + 1) == '"' do
                    last_q = last_q + 1
                end
                local seg = src:sub(i, last_q)
                table.insert(out, (seg:gsub("[^\n]", " ")))
                i = last_q + 1
            else
                local seg = src:sub(i)
                table.insert(out, (seg:gsub("[^\n]", " ")))
                break
            end
        elseif
            (c == "@" and src:sub(i + 1, i + 1) == '"')
            or (c == "$" and src:sub(i + 1, i + 2) == '@"')
            or (c == "@" and src:sub(i + 1, i + 2) == '$"')
        then
            local q_start = (c == "@" and src:sub(i + 1, i + 1) == '"') and (i + 2) or (i + 3)
            local j = q_start
            while j <= len do
                if src:sub(j, j) == '"' then
                    if src:sub(j + 1, j + 1) == '"' then
                        j = j + 2
                    else
                        j = j + 1
                        break
                    end
                else
                    j = j + 1
                end
            end
            local seg = src:sub(i, j - 1)
            table.insert(out, (seg:gsub("[^\n]", " ")))
            i = j
        elseif c == '"' then
            local j = i + 1
            while j <= len do
                local sc = src:sub(j, j)
                if sc == "\\" then
                    j = j + 2
                elseif sc == '"' then
                    j = j + 1
                    break
                elseif sc == "\n" then
                    break
                else
                    j = j + 1
                end
            end
            local seg = src:sub(i, j - 1)
            table.insert(out, (seg:gsub("[^\n]", " ")))
            i = j
        elseif c == "'" then
            local j = i + 1
            while j <= len do
                local sc = src:sub(j, j)
                if sc == "\\" then
                    j = j + 2
                elseif sc == "'" then
                    j = j + 1
                    break
                elseif sc == "\n" then
                    break
                else
                    j = j + 1
                end
            end
            local seg = src:sub(i, j - 1)
            table.insert(out, (seg:gsub("[^\n]", " ")))
            i = j
        else
            table.insert(out, c)
            i = i + 1
        end
    end
    return table.concat(out)
end

function M.discover_csharp_tests(src)
    local cleaned = M.strip_csharp_lexical_noise(src)
    local lines = {}
    for line in (cleaned .. "\n"):gmatch("(.-)\r?\n") do
        table.insert(lines, line)
    end

    local file_namespace = nil
    local classes = {}
    local class_stack = {}
    local pending_class = nil
    local pending_attr = nil
    local pending_framework = nil
    local pending_attr_line = nil
    local active_method = nil
    local brace_depth = 0

    for idx, line in ipairs(lines) do
        local ns = line:match("^%s*namespace%s+([%w_%.]+)")
        if ns and not file_namespace then
            file_namespace = ns
        end

        local trimmed = vim.trim(line)
        if not trimmed:match("^file%s+") and not trimmed:match("%f[%w_]file%s+.-class%s+") then
            local cls_name = line:match("%f[%w_]class%s+([%w_]+)")
            if cls_name then
                pending_class = {
                    name = cls_name,
                    namespace = file_namespace,
                    start_line = idx,
                    end_line = idx,
                    brace_depth = nil,
                    tests = {},
                }
                table.insert(classes, pending_class)
            end
        else
            pending_class = nil
        end

        for attr_block in line:gmatch("%b[]") do
            local inner = attr_block:sub(2, -2)
            for token in inner:gmatch("[%w_%.]+") do
                local short = token:match("([%w_]+)$") or token
                local base = short:gsub("Attribute$", "")
                local fw = TEST_ATTRS[short] or TEST_ATTRS[base]
                if fw and not pending_attr then
                    pending_attr = base
                    pending_framework = fw
                    pending_attr_line = idx
                end
            end
        end

        local current_class = class_stack[#class_stack] or pending_class
        if pending_attr and current_class then
            local without_attrs = line:gsub("%b[]", " ")
            local before_paren = without_attrs:match("^(.-)%s*%(")
            if before_paren then
                local words = {}
                for w in before_paren:gmatch("[%w_]+") do
                    table.insert(words, w)
                end
                local mname = words[#words]
                if mname and not CS_KEYWORDS[mname] then
                    local ns_prefix = current_class.namespace and (current_class.namespace .. ".") or ""
                    local test_entry = {
                        name = mname,
                        class_name = current_class.name,
                        namespace = current_class.namespace,
                        full_name = ns_prefix .. current_class.name .. "." .. mname,
                        attribute = pending_attr,
                        framework = pending_framework,
                        line = idx,
                        start_line = pending_attr_line or idx,
                        end_line = idx,
                        _body_depth = nil,
                        _saw_arrow = without_attrs:find("=>", 1, true) ~= nil,
                    }
                    table.insert(current_class.tests, test_entry)
                    active_method = test_entry
                    pending_attr = nil
                    pending_framework = nil
                    pending_attr_line = nil
                end
            end
        end

        if active_method and line:find("=>", 1, true) and not active_method._body_depth then
            active_method._saw_arrow = true
        end

        for ch in line:gmatch("[{};]") do
            if ch == "{" then
                brace_depth = brace_depth + 1
                if pending_class and not pending_class.brace_depth then
                    pending_class.brace_depth = brace_depth
                    table.insert(class_stack, pending_class)
                    pending_class = nil
                elseif active_method and not active_method._body_depth then
                    active_method._body_depth = brace_depth
                end
            elseif ch == "}" then
                if active_method and active_method._body_depth and brace_depth == active_method._body_depth then
                    active_method.end_line = idx
                    active_method._body_depth = nil
                    active_method._saw_arrow = nil
                    active_method = nil
                end
                local top_cls = class_stack[#class_stack]
                if top_cls and top_cls.brace_depth == brace_depth then
                    top_cls.end_line = idx
                    table.remove(class_stack)
                end
                if brace_depth > 0 then
                    brace_depth = brace_depth - 1
                end
            elseif ch == ";" then
                if active_method and not active_method._body_depth and active_method._saw_arrow then
                    active_method.end_line = idx
                    active_method._saw_arrow = nil
                    active_method = nil
                end
                if pending_class and not pending_class.brace_depth then
                    pending_class.end_line = idx
                    pending_class = nil
                end
            end
        end
    end

    for _, cls in ipairs(classes) do
        cls.brace_depth = nil
        for _, t in ipairs(cls.tests) do
            t._body_depth = nil
            t._saw_arrow = nil
        end
    end

    return {
        namespace = file_namespace,
        classes = classes,
    }
end

function M.discover_file_tests(file_path)
    if not file_path or file_path == "" then
        return nil
    end
    local f = io.open(file_path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return M.discover_csharp_tests(content)
end

function M.find_enclosing_test(discovery, cursor_line)
    if not discovery or not discovery.classes then
        return nil
    end
    for _, cls in ipairs(discovery.classes) do
        for _, t in ipairs(cls.tests) do
            if cursor_line >= t.start_line and cursor_line <= t.end_line then
                return { kind = "method", test = t, class = cls }
            end
        end
    end
    for _, cls in ipairs(discovery.classes) do
        if cursor_line >= cls.start_line and cursor_line <= cls.end_line and #cls.tests > 0 then
            return { kind = "class", class = cls }
        end
    end
    return nil
end

function M.run_with_filter(state, target, filter_expr, label, opts)
    local dotnet_bin = runner.resolve_dotnet()
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")

    local steps = {}
    if target.kind == "solution_folder" then
        if not target.project_paths or #target.project_paths == 0 then
            vim.notify(
                "No projects found under solution folder: " .. (target.solution_folder or target.name),
                vim.log.levels.WARN
            )
            if opts and opts.on_complete then
                opts.on_complete({ status = "succeeded", exit_code = 0, lines = {}, output = "" })
            end
            return nil
        end
        for _, proj_path in ipairs(target.project_paths) do
            local proj_name = vim.fn.fnamemodify(proj_path, ":t:r")
            local proj_dir = vim.fn.fnamemodify(proj_path, ":h")
            local cmd = { dotnet_bin, "test", proj_path, "--nologo", "--logger", "trx", "--results-directory", tmp_dir }
            if filter_expr and filter_expr ~= "" then
                table.insert(cmd, "--filter")
                table.insert(cmd, filter_expr)
            end
            table.insert(steps, {
                cmd = cmd,
                cwd = proj_dir,
                label = label or ("Test: " .. proj_name),
            })
        end
    else
        local path = (target.kind == "solution" and (target.path or target.solution_path))
            or (target.kind == "project" and (target.path or (target.project_paths and target.project_paths[1])))
            or ((target.project_paths and target.project_paths[1]) or target.path or target.cwd)
        local cmd = { dotnet_bin, "test", path, "--nologo", "--logger", "trx", "--results-directory", tmp_dir }
        if filter_expr and filter_expr ~= "" then
            table.insert(cmd, "--filter")
            table.insert(cmd, filter_expr)
        end
        table.insert(steps, {
            cmd = cmd,
            cwd = target.cwd,
            label = label or ("Test: " .. target.name),
        })
    end

    local task_title = label or ("Test: " .. target.name)
    return runner.run_pipeline(steps, {
        title = task_title,
        on_complete = function(result)
            local parsed_trx = runner.aggregate_trx_dir(tmp_dir, false)
            result.summary = parsed_trx.summary
            result.trx = parsed_trx
            result.target = target

            local orch = (config.current and config.current.orchestration) or {}

            if parsed_trx.summary.total == 0 and result.exit_code ~= 0 then
                local parsed_msbuild = runner.parse_msbuild_output(result.output, target.cwd)
                if parsed_msbuild.errors > 0 then
                    runner.sync_build_diagnostics(parsed_msbuild.diagnostics)
                    vim.fn.setqflist(parsed_msbuild.quickfix, "r")
                    pcall(function()
                        local diagnostics = require("csharp-explorer.diagnostics")
                        diagnostics.rebuild_index()
                        if state and state.is_active then
                            diagnostics.render_extmarks(state)
                        end
                    end)
                    if result.status ~= "cancelled" then
                        if orch.open_quickfix_on_error ~= false then
                            navigation.focus_editor_window(state)
                            vim.cmd("botright copen")
                        end
                        if orch.open_output_on_error == true then
                            runner.open_output()
                        end
                        vim.notify(
                            string.format("Test build failed: %s (%d error(s))", target.name, parsed_msbuild.errors),
                            vim.log.levels.ERROR
                        )
                    end
                elseif result.status ~= "cancelled" then
                    runner.open_output()
                    vim.notify("Test run failed: " .. target.name, vim.log.levels.ERROR)
                end
            elseif parsed_trx.summary.total > 0 then
                runner.clear_build_diagnostics()
                pcall(function()
                    local diagnostics = require("csharp-explorer.diagnostics")
                    diagnostics.rebuild_index()
                    if state and state.is_active then
                        diagnostics.render_extmarks(state)
                    end
                end)

                if parsed_trx.summary.failed > 0 then
                    vim.fn.setqflist(parsed_trx.quickfix, "r")
                    if result.status ~= "cancelled" then
                        if orch.open_quickfix_on_error ~= false then
                            navigation.focus_editor_window(state)
                            vim.cmd("botright copen")
                        end
                        if orch.open_output_on_error == true then
                            runner.open_output()
                        end
                        vim.notify(
                            string.format(
                                "Tests failed: %d failed, %d passed, %d skipped",
                                parsed_trx.summary.failed,
                                parsed_trx.summary.passed,
                                parsed_trx.summary.skipped
                            ),
                            vim.log.levels.ERROR
                        )
                    end
                else
                    vim.fn.setqflist({}, "r")
                    if result.status ~= "cancelled" then
                        local skip_suffix = parsed_trx.summary.skipped > 0
                                and string.format(" (%d skipped)", parsed_trx.summary.skipped)
                            or ""
                        vim.notify(
                            string.format("Passed %d test(s)%s", parsed_trx.summary.passed, skip_suffix),
                            vim.log.levels.INFO
                        )
                        if orch.close_quickfix_on_success == true then
                            pcall(vim.cmd, "cclose")
                        end
                    end
                end
            end

            if opts and opts.on_complete then
                opts.on_complete(result)
            end
        end,
    })
end

function M.run_target(state, opts)
    local target = runner.resolve_target(state, opts)
    if not target then
        vim.notify("Could not resolve target for test", vim.log.levels.WARN)
        if opts and opts.on_complete then
            opts.on_complete({ status = "failed", exit_code = 1, lines = {}, output = "Target not found" })
        end
        return nil
    end

    if opts and opts.filter and opts.filter ~= "" then
        return M.run_with_filter(state, target, opts.filter, opts.label or ("Tests matching " .. opts.filter), opts)
    end

    if target.kind == "file" and target.path and target.path:match("%.cs$") then
        local disc = M.discover_file_tests(target.path)
        local all_tests = {}
        if disc and disc.classes then
            for _, cls in ipairs(disc.classes) do
                for _, t in ipairs(cls.tests) do
                    table.insert(all_tests, t)
                end
            end
        end

        local in_editor = (
            not state.win
            or not vim.api.nvim_win_is_valid(state.win)
            or vim.api.nvim_get_current_win() ~= state.win
        )
        if in_editor then
            local enclosed = M.find_enclosing_test(disc, target.cursor_line or 1)
            if enclosed and enclosed.kind == "method" then
                return M.run_with_filter(
                    state,
                    target,
                    "FullyQualifiedName=" .. enclosed.test.full_name,
                    string.format("[%s] %s", enclosed.test.attribute, enclosed.test.name),
                    opts
                )
            elseif enclosed and enclosed.kind == "class" then
                local cls_fqn = (enclosed.class.namespace and (enclosed.class.namespace .. ".") or "")
                    .. enclosed.class.name
                return M.run_with_filter(
                    state,
                    target,
                    "FullyQualifiedName~" .. cls_fqn,
                    "Tests in " .. enclosed.class.name,
                    opts
                )
            end
        end

        if #all_tests == 0 then
            vim.notify("No tests discovered in " .. target.name, vim.log.levels.WARN)
            if opts and opts.on_complete then
                opts.on_complete({ status = "succeeded", exit_code = 0, lines = {}, output = "" })
            end
            return nil
        elseif #all_tests == 1 then
            local t = all_tests[1]
            return M.run_with_filter(
                state,
                target,
                "FullyQualifiedName=" .. t.full_name,
                string.format("[%s] %s", t.attribute, t.name),
                opts
            )
        else
            local items = {}
            for _, cls in ipairs(disc.classes) do
                if #cls.tests > 0 then
                    local cls_fqn = (cls.namespace and (cls.namespace .. ".") or "") .. cls.name
                    table.insert(items, {
                        kind = "class",
                        label = string.format("All tests in %s (%d)", cls.name, #cls.tests),
                        filter = "FullyQualifiedName~" .. cls_fqn,
                    })
                end
            end
            for _, t in ipairs(all_tests) do
                table.insert(items, {
                    kind = "method",
                    label = string.format("[%s] %s", t.attribute, t.name),
                    filter = "FullyQualifiedName=" .. t.full_name,
                })
            end

            vim.ui.select(items, {
                prompt = "Select Test to Run:",
                format_item = function(item)
                    return item.label
                end,
            }, function(choice)
                if not choice then
                    return
                end
                M.run_with_filter(state, target, choice.filter, choice.label, opts)
            end)
            return nil
        end
    elseif target.kind == "directory" then
        local cs_files = vim.fn.glob(target.path .. "/**/*.cs", false, true)
        local class_filters = {}
        local seen_classes = {}
        for _, cs_f in ipairs(cs_files) do
            local norm_f = metadata.normalize_path(cs_f)
            if not norm_f:find("/bin/", 1, true) and not norm_f:find("/obj/", 1, true) then
                local disc = M.discover_file_tests(cs_f)
                if disc and disc.classes then
                    for _, cls in ipairs(disc.classes) do
                        if #cls.tests > 0 then
                            local fqn = (cls.namespace and (cls.namespace .. ".") or "") .. cls.name
                            if not seen_classes[fqn] then
                                seen_classes[fqn] = true
                                table.insert(class_filters, "FullyQualifiedName~" .. fqn)
                            end
                        end
                    end
                end
            end
        end
        if #class_filters == 0 then
            vim.notify("No tests found in directory: " .. target.name, vim.log.levels.WARN)
            if opts and opts.on_complete then
                opts.on_complete({ status = "succeeded", exit_code = 0, lines = {}, output = "" })
            end
            return nil
        end
        local filter_expr = table.concat(class_filters, "|")
        return M.run_with_filter(state, target, filter_expr, "Tests in " .. target.name, opts)
    else
        return M.run_with_filter(state, target, nil, "Tests in " .. target.name, opts)
    end
end

function M.run_nearest(state, opts)
    local target = runner.resolve_target(state, opts)
    if target and target.kind == "file" and target.path and target.path:match("%.cs$") then
        local disc = M.discover_file_tests(target.path)
        local enclosed = M.find_enclosing_test(disc, target.cursor_line or 1)
        if enclosed and enclosed.kind == "method" then
            return M.run_with_filter(
                state,
                target,
                "FullyQualifiedName=" .. enclosed.test.full_name,
                string.format("[%s] %s", enclosed.test.attribute, enclosed.test.name),
                opts
            )
        elseif enclosed and enclosed.kind == "class" then
            local cls_fqn = (enclosed.class.namespace and (enclosed.class.namespace .. ".") or "")
                .. enclosed.class.name
            return M.run_with_filter(
                state,
                target,
                "FullyQualifiedName~" .. cls_fqn,
                "Tests in " .. enclosed.class.name,
                opts
            )
        end
    end
    return M.run_target(state, opts)
end

function M.select_test(state, opts)
    local target = runner.resolve_target(state, opts)
    if not target or not target.path or not target.path:match("%.cs$") then
        vim.notify("Select test requires a .cs file target", vim.log.levels.WARN)
        return nil
    end
    local disc = M.discover_file_tests(target.path)
    local all_tests = {}
    if disc and disc.classes then
        for _, cls in ipairs(disc.classes) do
            for _, t in ipairs(cls.tests) do
                table.insert(all_tests, t)
            end
        end
    end
    if #all_tests == 0 then
        vim.notify("No tests discovered in " .. target.name, vim.log.levels.WARN)
        return nil
    end

    local items = {}
    for _, cls in ipairs(disc.classes) do
        if #cls.tests > 0 then
            local cls_fqn = (cls.namespace and (cls.namespace .. ".") or "") .. cls.name
            table.insert(items, {
                kind = "class",
                label = string.format("All tests in %s (%d)", cls.name, #cls.tests),
                filter = "FullyQualifiedName~" .. cls_fqn,
            })
        end
    end
    for _, t in ipairs(all_tests) do
        table.insert(items, {
            kind = "method",
            label = string.format("[%s] %s", t.attribute, t.name),
            filter = "FullyQualifiedName=" .. t.full_name,
        })
    end

    vim.ui.select(items, {
        prompt = "Select Test to Run:",
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if choice then
            M.run_with_filter(state, target, choice.filter, choice.label, opts)
        end
    end)
end

return M

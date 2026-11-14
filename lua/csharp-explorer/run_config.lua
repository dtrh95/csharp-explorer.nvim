local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local node_utils = require("csharp-explorer.node")
local uv = vim.uv or vim.loop

local M = {}

local UTF8_BOM = "\239\187\191"

local IGNORED_SCAN_DIRS = {
    [".git"] = true,
    [".vs"] = true,
    [".idea"] = true,
    bin = true,
    obj = true,
    node_modules = true,
}

function M.sanitize_jsonc(raw_text)
    if not raw_text or raw_text == "" then
        return "{}"
    end
    if raw_text:sub(1, #UTF8_BOM) == UTF8_BOM then
        raw_text = raw_text:sub(#UTF8_BOM + 1)
    end

    local len = #raw_text
    local out1 = {}
    local i = 1
    local in_str = false

    while i <= len do
        local c = raw_text:sub(i, i)
        if in_str then
            if c == "\\" then
                out1[#out1 + 1] = c .. raw_text:sub(i + 1, i + 1)
                i = i + 2
            elseif c == '"' then
                in_str = false
                out1[#out1 + 1] = c
                i = i + 1
            else
                out1[#out1 + 1] = c
                i = i + 1
            end
        else
            if c == '"' then
                in_str = true
                out1[#out1 + 1] = c
                i = i + 1
            elseif c == "/" and i < len and raw_text:sub(i + 1, i + 1) == "/" then
                i = i + 2
                while i <= len and raw_text:sub(i, i) ~= "\n" do
                    i = i + 1
                end
            elseif c == "/" and i < len and raw_text:sub(i + 1, i + 1) == "*" then
                i = i + 2
                while i < len and not (raw_text:sub(i, i) == "*" and raw_text:sub(i + 1, i + 1) == "/") do
                    i = i + 1
                end
                i = i + 2
            else
                out1[#out1 + 1] = c
                i = i + 1
            end
        end
    end

    local no_comments = table.concat(out1)
    local len2 = #no_comments
    local out2 = {}
    local j = 1
    in_str = false

    while j <= len2 do
        local c = no_comments:sub(j, j)
        if in_str then
            if c == "\\" then
                out2[#out2 + 1] = c .. no_comments:sub(j + 1, j + 1)
                j = j + 2
            elseif c == '"' then
                in_str = false
                out2[#out2 + 1] = c
                j = j + 1
            else
                out2[#out2 + 1] = c
                j = j + 1
            end
        else
            if c == '"' then
                in_str = true
                out2[#out2 + 1] = c
                j = j + 1
            elseif c == "," then
                local k = j + 1
                while k <= len2 do
                    local kc = no_comments:sub(k, k)
                    if kc:match("%s") then
                        k = k + 1
                    else
                        break
                    end
                end
                local next_non_ws = no_comments:sub(k, k)
                if next_non_ws == "}" or next_non_ws == "]" then
                    j = j + 1
                else
                    out2[#out2 + 1] = c
                    j = j + 1
                end
            else
                out2[#out2 + 1] = c
                j = j + 1
            end
        end
    end

    return table.concat(out2)
end

function M.discover_launch_settings(project_path)
    local proj_dir = metadata.normalize_path(vim.fn.fnamemodify(project_path, ":h"))
    local found = {}
    local stack = { proj_dir }
    local visited = {}

    while #stack > 0 do
        local curr = stack[#stack]
        stack[#stack] = nil
        local real_curr = (uv.fs_realpath and uv.fs_realpath(curr)) or curr
        if not visited[real_curr] then
            visited[real_curr] = true
            local handle = uv.fs_scandir(curr)
            if handle then
                while true do
                    local name, ftype = uv.fs_scandir_next(handle)
                    if not name then
                        break
                    end
                    local full = curr .. "/" .. name
                    if not ftype then
                        local st = uv.fs_stat(full)
                        ftype = st and st.type or nil
                    end
                    if ftype == "directory" then
                        if not IGNORED_SCAN_DIRS[name] then
                            stack[#stack + 1] = full
                        end
                    elseif ftype == "file" and name:lower() == "launchsettings.json" then
                        found[#found + 1] = full
                    end
                end
            end
        end
    end

    table.sort(found)
    return found
end

local function parse_args(raw_args)
    if type(raw_args) == "table" then
        return vim.deepcopy(raw_args)
    elseif type(raw_args) ~= "string" or raw_args == "" then
        return {}
    end

    local args = {}
    local buf = {}
    local has_token = false
    local in_quote = nil
    local i = 1
    local len = #raw_args

    while i <= len do
        local c = raw_args:sub(i, i)
        if in_quote then
            if in_quote == '"' and c == "\\" and i < len then
                local next_c = raw_args:sub(i + 1, i + 1)
                if next_c == '"' or next_c == "\\" then
                    buf[#buf + 1] = next_c
                    i = i + 2
                else
                    buf[#buf + 1] = c
                    i = i + 1
                end
            elseif c == in_quote then
                in_quote = nil
                i = i + 1
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        else
            if c == '"' or c == "'" then
                in_quote = c
                has_token = true
                i = i + 1
            elseif c:match("%s") then
                if has_token then
                    args[#args + 1] = table.concat(buf)
                    buf = {}
                    has_token = false
                end
                i = i + 1
            else
                buf[#buf + 1] = c
                has_token = true
                i = i + 1
            end
        end
    end

    if has_token then
        args[#args + 1] = table.concat(buf)
    end
    return args
end

local function parse_urls(raw_urls)
    local urls = {}
    if type(raw_urls) == "string" then
        for part in raw_urls:gmatch("[^;,]+") do
            local trimmed = vim.trim(part)
            if trimmed ~= "" then
                urls[#urls + 1] = trimmed
            end
        end
    end
    return urls
end

local function is_absolute_path(path)
    if not path or path == "" then
        return false
    end
    return path:sub(1, 1) == "/" or path:match("^[A-Za-z]:[/\\]") ~= nil
end

function M.parse_launch_settings(file_path, project_path)
    local f = io.open(file_path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()

    local sanitized = M.sanitize_jsonc(content)
    local ok, data = pcall(vim.json.decode, sanitized)
    if not ok or type(data) ~= "table" or type(data.profiles) ~= "table" then
        return {}
    end

    local norm_project_path = metadata.normalize_path(project_path)
    local project_dir = metadata.normalize_path(vim.fn.fnamemodify(norm_project_path, ":h"))
    local project_name = vim.fn.fnamemodify(norm_project_path, ":t:r")
    local configs = {}

    for profile_name, prof in pairs(data.profiles) do
        local cmd_name = prof.commandName
        local valid_exec = cmd_name ~= "Executable"
            or (type(prof.executablePath) == "string" and vim.trim(prof.executablePath) ~= "")
        if (cmd_name == "Project" or cmd_name == "Executable") and valid_exec then
            local cwd = project_dir
            if type(prof.workingDirectory) == "string" and prof.workingDirectory ~= "" then
                if is_absolute_path(prof.workingDirectory) then
                    cwd = metadata.normalize_path(prof.workingDirectory)
                else
                    cwd = metadata.normalize_path(project_dir .. "/" .. prof.workingDirectory)
                end
            end

            local exec_path = prof.executablePath
            if cmd_name == "Executable" and type(exec_path) == "string" and exec_path ~= "" then
                if not is_absolute_path(exec_path) then
                    exec_path = metadata.normalize_path(cwd .. "/" .. exec_path)
                end
            end

            local env_vars = {}
            if type(prof.environmentVariables) == "table" then
                for k, v in pairs(prof.environmentVariables) do
                    env_vars[tostring(k)] = tostring(v)
                end
            end

            configs[#configs + 1] = {
                id = norm_project_path .. ":" .. profile_name,
                name = project_name .. " (" .. profile_name .. ")",
                project_path = norm_project_path,
                project_name = project_name,
                profile_name = profile_name,
                command_type = cmd_name,
                command_name = cmd_name,
                executable_path = exec_path,
                args = parse_args(prof.commandLineArgs),
                cwd = cwd,
                env = env_vars,
                application_urls = parse_urls(prof.applicationUrl),
                launch_browser = prof.launchBrowser == true,
                launch_url = prof.launchUrl,
                hot_reload = false,
                source_file = file_path,
                is_fallback = false,
            }
        end
    end

    table.sort(configs, function(a, b)
        return a.profile_name < b.profile_name
    end)

    return configs
end

function M.is_runnable_project(csproj_path)
    local prof = metadata.get_project_profile(csproj_path)
    if not prof then
        return false
    end
    if prof.archetype == "test" then
        return false
    end
    if prof.archetype == "web" or prof.archetype == "console" then
        return true
    end
    if prof.output_type and prof.output_type:lower():match("exe") ~= nil then
        return true
    end
    return false
end

function M.get_project_configs(csproj_path)
    local norm_project_path = metadata.normalize_path(csproj_path)
    local files = M.discover_launch_settings(norm_project_path)
    local configs = {}

    local seen_ids = {}
    for _, file_path in ipairs(files) do
        local parsed = M.parse_launch_settings(file_path, norm_project_path)
        for _, cfg in ipairs(parsed) do
            if seen_ids[cfg.id] then
                local rel_dir = vim.fn.fnamemodify(file_path, ":h:t")
                cfg.id = cfg.id .. "@" .. rel_dir
                cfg.name = string.format("%s (%s - %s)", cfg.project_name, cfg.profile_name, rel_dir)
            end
            seen_ids[cfg.id] = true
            configs[#configs + 1] = cfg
        end
    end

    if #configs == 0 and M.is_runnable_project(norm_project_path) then
        local project_name = vim.fn.fnamemodify(norm_project_path, ":t:r")
        local project_dir = metadata.normalize_path(vim.fn.fnamemodify(norm_project_path, ":h"))
        configs[#configs + 1] = {
            id = norm_project_path .. ":default",
            name = project_name .. " (Default)",
            project_path = norm_project_path,
            project_name = project_name,
            profile_name = "Default",
            command_type = "Fallback",
            command_name = "Project",
            executable_path = nil,
            args = {},
            cwd = project_dir,
            env = {},
            application_urls = {},
            launch_browser = false,
            launch_url = nil,
            hot_reload = false,
            source_file = nil,
            is_fallback = true,
        }
    end

    return configs
end

function M.get_solution_configs(tree)
    local proj_set = node_utils.collect_solution_projects(tree)
    local projs = {}
    for p in pairs(proj_set) do
        projs[#projs + 1] = p
    end
    table.sort(projs)

    local all_cfgs = {}
    for _, p in ipairs(projs) do
        local cfgs = M.get_project_configs(p)
        for _, c in ipairs(cfgs) do
            all_cfgs[#all_cfgs + 1] = c
        end
    end
    return all_cfgs
end

local function apply_launch_profile_env(run_cfg)
    local env = {}
    for k, v in pairs(vim.fn.environ()) do
        env[k] = v
    end

    if not run_cfg.is_fallback then
        env["DOTNET_LAUNCH_PROFILE"] = run_cfg.profile_name
    end

    if run_cfg.application_urls and #run_cfg.application_urls > 0 then
        local urls = table.concat(run_cfg.application_urls, ";")
        env["ASPNETCORE_URLS"] = urls
        env["DOTNET_URLS"] = urls
    end

    if run_cfg.env then
        for k, v in pairs(run_cfg.env) do
            local str_v = tostring(v)
            str_v = str_v:gsub("%${env:([%w_]+)}", function(var)
                return env[var] or vim.env[var] or ""
            end)
            str_v = str_v:gsub("%%([%w_]+)%%", function(var)
                return env[var] or vim.env[var] or ""
            end)
            env[k] = str_v
        end
    end

    return env
end

function M.build_command_and_env(run_cfg, opts)
    opts = opts or {}
    local dotnet_bin = (config.current.orchestration and config.current.orchestration.dotnet_cmd)
        or require("csharp-explorer.runner").resolve_dotnet()
    local hot_reload = opts.hot_reload
    if hot_reload == nil then
        hot_reload = run_cfg.hot_reload == true
    end

    local cmd = {}
    if run_cfg.command_type == "Executable" and run_cfg.executable_path then
        cmd[#cmd + 1] = run_cfg.executable_path
        if run_cfg.args then
            for _, arg in ipairs(run_cfg.args) do
                cmd[#cmd + 1] = arg
            end
        end
    else
        cmd[#cmd + 1] = dotnet_bin
        if hot_reload then
            cmd[#cmd + 1] = "watch"
            cmd[#cmd + 1] = "--non-interactive"
        end
        cmd[#cmd + 1] = "run"
        cmd[#cmd + 1] = "--no-launch-profile"
        cmd[#cmd + 1] = "--project"
        cmd[#cmd + 1] = run_cfg.project_path
        if run_cfg.args and #run_cfg.args > 0 then
            cmd[#cmd + 1] = "--"
            for _, arg in ipairs(run_cfg.args) do
                cmd[#cmd + 1] = arg
            end
        end
    end

    return cmd, apply_launch_profile_env(run_cfg), run_cfg.cwd
end

return M

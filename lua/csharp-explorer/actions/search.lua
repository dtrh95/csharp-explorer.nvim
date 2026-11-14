local csharp_source = require("csharp-explorer.csharp_source")
local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local navigation = require("csharp-explorer.actions.navigation")
local node_utils = require("csharp-explorer.node")
local uv = vim.uv or vim.loop

local M = {}

local LSP_KIND_MAP = {
    [1] = "file",
    [2] = "module",
    [3] = "namespace",
    [4] = "package",
    [5] = "class",
    [6] = "method",
    [7] = "property",
    [8] = "field",
    [9] = "constructor",
    [10] = "enum",
    [11] = "interface",
    [12] = "function",
    [13] = "variable",
    [14] = "constant",
    [15] = "string",
    [16] = "number",
    [17] = "boolean",
    [18] = "array",
    [19] = "object",
    [20] = "key",
    [21] = "null",
    [22] = "enum-member",
    [23] = "struct",
    [24] = "event",
    [25] = "operator",
    [26] = "type-parameter",
}

local EXCLUDED_DIRS = {
    bin = true,
    obj = true,
    [".git"] = true,
    [".vs"] = true,
    [".idea"] = true,
    node_modules = true,
}

function M.get_scope(state)
    local tree = state and (state.ensure_tree and state.ensure_tree() or state.tree)
    local sol_path = tree and tree._path and metadata.normalize_path(tree._path)
    local sol_dir = (tree and tree._dir and metadata.normalize_path(tree._dir))
        or (sol_path and vim.fn.fnamemodify(sol_path, ":h"))
        or vim.fn.getcwd()
    sol_dir = metadata.normalize_path(sol_dir)

    local raw_project_dirs = node_utils.get_solution_project_dirs(tree)
    local project_dirs = {}
    for _, dir in ipairs(raw_project_dirs) do
        local st = uv.fs_stat(dir)
        if st and st.type == "directory" then
            project_dirs[#project_dirs + 1] = dir
        end
    end
    if #project_dirs == 0 then
        local st = sol_dir and uv.fs_stat(sol_dir)
        if st and st.type == "directory" then
            project_dirs = { sol_dir }
        end
    end

    local sorted = vim.deepcopy(project_dirs)
    table.sort(sorted, function(a, b)
        return #a < #b
    end)

    local search_roots = {}
    for _, dir in ipairs(sorted) do
        local overlapped = false
        for _, root in ipairs(search_roots) do
            if vim.startswith(dir, root .. "/") then
                overlapped = true
                break
            end
        end
        if not overlapped then
            search_roots[#search_roots + 1] = dir
        end
    end

    return {
        solution_path = sol_path,
        solution_dir = sol_dir,
        project_dirs = project_dirs,
        search_roots = search_roots,
    }
end

function M.resolve_picker(preferred)
    local choice = preferred or (config.current.search and config.current.search.picker) or "auto"
    if choice == "fzf-lua" then
        local ok = pcall(require, "fzf-lua")
        return ok and "fzf-lua" or "builtin"
    elseif choice == "snacks" then
        local ok, s = pcall(require, "snacks")
        return (ok and s and s.picker) and "snacks" or "builtin"
    elseif choice == "telescope" then
        local ok = pcall(require, "telescope.builtin")
        return ok and "telescope" or "builtin"
    elseif choice == "builtin" then
        return "builtin"
    end

    local ok_fzf = pcall(require, "fzf-lua")
    if ok_fzf then
        return "fzf-lua"
    end
    local ok_snacks, snacks = pcall(require, "snacks")
    if ok_snacks and snacks and snacks.picker then
        return "snacks"
    end
    local ok_tele = pcall(require, "telescope.builtin")
    if ok_tele then
        return "telescope"
    end
    return "builtin"
end

function M.collect_solution_files(scope)
    local files = {}
    for _, root in ipairs(scope.search_roots) do
        local stack = { root }
        while #stack > 0 do
            local cur = table.remove(stack)
            local handle = uv.fs_scandir(cur)
            if handle then
                while true do
                    local name, ftype = uv.fs_scandir_next(handle)
                    if not name then
                        break
                    end
                    if not ftype then
                        local st = uv.fs_stat(cur .. "/" .. name)
                        ftype = st and st.type or nil
                    end
                    if ftype == "directory" then
                        if not EXCLUDED_DIRS[name] then
                            stack[#stack + 1] = cur .. "/" .. name
                        end
                    elseif ftype == "file" then
                        files[#files + 1] = cur .. "/" .. name
                    end
                end
            end
        end
    end
    table.sort(files)
    return files
end

function M.scan_solution_symbols(scope)
    local all_files = M.collect_solution_files(scope)
    local symbols = {}
    for _, fpath in ipairs(all_files) do
        if vim.endswith(fpath, ".cs") then
            local f = io.open(fpath, "rb")
            if f then
                local content = f:read("*a")
                f:close()
                if content and content ~= "" then
                    local s = csharp_source.scan_csharp_symbols(content, fpath)
                    for _, sym in ipairs(s) do
                        symbols[#symbols + 1] = sym
                    end
                end
            end
        end
    end
    return symbols
end

function M.query_lsp_symbols(scope, query)
    local symbols = {}
    local pdirs = scope.project_dirs

    for _, client in ipairs(vim.lsp.get_clients()) do
        if client.server_capabilities and client.server_capabilities.workspaceSymbolProvider then
            local resp = client:request_sync("workspace/symbol", { query = query or "" }, 3000)
            if resp and resp.result and type(resp.result) == "table" then
                for _, item in ipairs(resp.result) do
                    local loc = item.location
                    local fname = loc and loc.uri and vim.uri_to_fname(loc.uri)
                    if fname then
                        local norm_f = metadata.normalize_path(fname)
                        local in_sol = false
                        for _, pdir in ipairs(pdirs) do
                            if norm_f == pdir or vim.startswith(norm_f, pdir .. "/") then
                                in_sol = true
                                break
                            end
                        end
                        if in_sol then
                            local sp = loc.range and loc.range.start
                            local line = (sp and sp.line or 0) + 1
                            local col = (sp and sp.character or 0) + 1
                            local kind_str = type(item.kind) == "number" and (LSP_KIND_MAP[item.kind] or "symbol")
                                or tostring(item.kind or "symbol")
                            local fqn = (item.containerName and item.containerName ~= "")
                                    and (item.containerName .. "." .. item.name)
                                or item.name
                            symbols[#symbols + 1] = {
                                name = item.name,
                                kind = kind_str,
                                file = norm_f,
                                line = line,
                                col = col,
                                container = item.containerName,
                                fqn = fqn,
                            }
                        end
                    end
                end
            end
        end
    end

    return symbols
end

function M.collect_symbols(state, query, opts)
    local scope = M.get_scope(state)
    local mode = opts and opts.symbol_source
        or (config.current.search and config.current.search.symbol_source)
        or "hybrid"
    local symbols

    if mode == "hybrid" then
        symbols = M.query_lsp_symbols(scope, query)
        if #symbols == 0 then
            symbols = M.scan_solution_symbols(scope)
        end
    elseif mode == "lsp" then
        symbols = M.query_lsp_symbols(scope, query)
    else
        symbols = M.scan_solution_symbols(scope)
    end

    if query and query ~= "" then
        local lquery = query:lower()
        local filtered = {}
        for _, sym in ipairs(symbols) do
            local name_match = sym.name and sym.name:lower():find(lquery, 1, true) ~= nil
            local fqn_match = sym.fqn and sym.fqn:lower():find(lquery, 1, true) ~= nil
            if name_match or fqn_match then
                filtered[#filtered + 1] = sym
            end
        end
        return filtered
    end

    return symbols
end

local function jump_to_location(state, file, line, col)
    navigation.focus_editor_window(state)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    pcall(vim.api.nvim_win_set_cursor, 0, { line or 1, math.max((col or 1) - 1, 0) })
end

local function run_rg_vimgrep(query, roots)
    if #roots == 0 then
        return {}
    end

    local cmd = {
        "rg",
        "--vimgrep",
        "--smart-case",
        "--no-messages",
        "-g",
        "!**/bin/**",
        "-g",
        "!**/obj/**",
        "-g",
        "!**/.git/**",
        "-g",
        "!**/node_modules/**",
        "-e",
        query,
    }
    for _, r in ipairs(roots) do
        cmd[#cmd + 1] = r
    end

    local stdout
    if vim.system then
        local res = vim.system(cmd, { text = true }):wait()
        stdout = res and res.stdout or ""
    else
        stdout = vim.fn.system(cmd) or ""
    end

    local qf_items = {}
    if stdout ~= "" then
        for line in stdout:gmatch("[^\r\n]+") do
            local fn, lnum, col, txt = line:match("^([^:]+):(%d+):(%d+):(.*)$")
            if fn and not vim.startswith(fn, "rg:") then
                qf_items[#qf_items + 1] = {
                    filename = fn,
                    lnum = tonumber(lnum),
                    col = tonumber(col),
                    text = txt,
                }
            end
        end
    end

    return qf_items
end

function M.files(state, opts)
    opts = opts or {}
    local scope = M.get_scope(state)
    local picker = opts.picker or M.resolve_picker()

    if opts.on_results then
        local files = M.collect_solution_files(scope)
        opts.on_results(files)
        return files
    end

    if #scope.search_roots == 0 then
        vim.notify("No existing project directories found in solution", vim.log.levels.WARN)
        return
    end

    if picker == "fzf-lua" then
        navigation.focus_editor_window(state)
        require("fzf-lua").files({
            cmd = false,
            silent = true,
            stderr = false,
            stderr_to_stdout = false,
            search_paths = scope.search_roots,
            rg_opts = "--color=never --files --hidden --follow --no-messages -g '!.git' -g '!**/bin/**' -g '!**/obj/**' -g '!**/node_modules/**'",
            fd_opts = "--color=never --type f --type l --hidden --follow --exclude .git --exclude bin --exclude obj --exclude node_modules",
        })
        return
    elseif picker == "snacks" then
        navigation.focus_editor_window(state)
        require("snacks").picker.files({
            dirs = scope.search_roots,
            exclude = { "bin", "obj", ".git", "node_modules" },
        })
        return
    elseif picker == "telescope" then
        navigation.focus_editor_window(state)
        require("telescope.builtin").find_files({
            search_dirs = scope.search_roots,
        })
        return
    end

    local all_files = M.collect_solution_files(scope)
    local display_items = {}
    for _, fpath in ipairs(all_files) do
        local rel = fpath
        if vim.startswith(fpath, scope.solution_dir .. "/") then
            rel = fpath:sub(#scope.solution_dir + 2)
        end
        display_items[#display_items + 1] = {
            path = fpath,
            label = rel,
        }
    end

    vim.ui.select(display_items, {
        prompt = "Find Solution File:",
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if choice then
            jump_to_location(state, choice.path, 1, 1)
        end
    end)
end

function M.grep(state, opts)
    opts = opts or {}
    local scope = M.get_scope(state)
    local picker = opts.picker or M.resolve_picker()

    if opts.on_results then
        local qf_items = {}
        if opts.query and opts.query ~= "" then
            if vim.fn.executable("rg") == 1 then
                qf_items = run_rg_vimgrep(opts.query, scope.search_roots)
            else
                local sfiles = M.collect_solution_files(scope)
                for _, fp in ipairs(sfiles) do
                    local f = io.open(fp, "rb")
                    if f then
                        local content = f:read("*a")
                        f:close()
                        local lnum = 1
                        for line in (content .. "\n"):gmatch("(.-)\r?\n") do
                            local col = line:find(opts.query, 1, true)
                            if col then
                                qf_items[#qf_items + 1] = {
                                    filename = fp,
                                    lnum = lnum,
                                    col = col,
                                    text = line,
                                }
                            end
                            lnum = lnum + 1
                        end
                    end
                end
            end
        end
        opts.on_results(qf_items)
        return qf_items
    end

    if #scope.search_roots == 0 then
        vim.notify("No existing project directories found in solution", vim.log.levels.WARN)
        return
    end

    if picker == "fzf-lua" then
        navigation.focus_editor_window(state)
        require("fzf-lua").live_grep({
            cmd = false,
            silent = true,
            stderr = false,
            stderr_to_stdout = false,
            search_paths = scope.search_roots,
            search = opts.query,
            rg_opts = "--column --line-number --no-heading --color=always --smart-case --no-messages --max-columns=4096 -g '!**/bin/**' -g '!**/obj/**' -g '!**/.git/**' -g '!**/node_modules/**' -e",
        })
        return
    elseif picker == "snacks" then
        navigation.focus_editor_window(state)
        require("snacks").picker.grep({
            dirs = scope.search_roots,
            search = opts.query,
            exclude = { "bin", "obj", ".git", "node_modules" },
        })
        return
    elseif picker == "telescope" then
        navigation.focus_editor_window(state)
        require("telescope.builtin").live_grep({
            search_dirs = scope.search_roots,
            default_text = opts.query,
            additional_args = { "--no-messages" },
        })
        return
    end

    local function execute_builtin_grep(q)
        if not q or q == "" then
            return
        end
        local qf_items = {}
        if vim.fn.executable("rg") == 1 then
            qf_items = run_rg_vimgrep(q, scope.search_roots)
        else
            local sfiles = M.collect_solution_files(scope)
            for _, fp in ipairs(sfiles) do
                local f = io.open(fp, "rb")
                if f then
                    local content = f:read("*a")
                    f:close()
                    local lnum = 1
                    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
                        local col = line:find(q, 1, true)
                        if col then
                            qf_items[#qf_items + 1] = {
                                filename = fp,
                                lnum = lnum,
                                col = col,
                                text = line,
                            }
                        end
                        lnum = lnum + 1
                    end
                end
            end
        end

        if #qf_items == 0 then
            vim.notify("No matches found for: " .. q, vim.log.levels.INFO)
            return
        end

        navigation.focus_editor_window(state)
        vim.fn.setqflist(qf_items, "r")
        vim.cmd("botright copen")
    end

    if opts.query then
        execute_builtin_grep(opts.query)
    else
        vim.ui.input({ prompt = "Grep Solution: " }, function(input)
            if input and input ~= "" then
                execute_builtin_grep(input)
            end
        end)
    end
end

function M.symbols(state, opts)
    opts = opts or {}
    local scope = M.get_scope(state)
    local query = opts.query or ""
    local syms = M.collect_symbols(state, query, opts)

    if opts.on_results then
        opts.on_results(syms)
        return syms
    end

    if #scope.search_roots == 0 then
        vim.notify("No existing project directories found in solution", vim.log.levels.WARN)
        return
    end

    local picker = opts.picker or M.resolve_picker()
    local display_items = {}
    for _, s in ipairs(syms) do
        local rel = s.file
        if vim.startswith(s.file, scope.solution_dir .. "/") then
            rel = s.file:sub(#scope.solution_dir + 2)
        end
        local label = string.format("[%s] %s  (%s:%d)", s.kind, s.fqn or s.name, rel, s.line)
        display_items[#display_items + 1] = {
            sym = s,
            label = label,
        }
    end

    if picker == "fzf-lua" then
        navigation.focus_editor_window(state)
        local fzf_entries = {}
        for _, item in ipairs(display_items) do
            fzf_entries[#fzf_entries + 1] = item.label
        end
        require("fzf-lua").fzf_exec(fzf_entries, {
            prompt = "Solution Symbols> ",
            actions = {
                ["default"] = function(selected)
                    if selected and selected[1] then
                        for _, item in ipairs(display_items) do
                            if item.label == selected[1] then
                                jump_to_location(state, item.sym.file, item.sym.line, item.sym.col)
                                break
                            end
                        end
                    end
                end,
            },
        })
        return
    elseif picker == "snacks" then
        local ok_s, snacks = pcall(require, "snacks")
        if ok_s and snacks and snacks.picker and type(snacks.picker.select) == "function" then
            navigation.focus_editor_window(state)
            snacks.picker.select(display_items, {
                prompt = "Solution Symbols:",
                format_item = function(item)
                    return item.label
                end,
            }, function(choice)
                if choice then
                    jump_to_location(state, choice.sym.file, choice.sym.line, choice.sym.col)
                end
            end)
            return
        end
    elseif picker == "telescope" then
        local ok_p, pickers = pcall(require, "telescope.pickers")
        local ok_f, finders = pcall(require, "telescope.finders")
        local ok_c, tele_conf = pcall(require, "telescope.config")
        local ok_a, actions = pcall(require, "telescope.actions")
        local ok_as, action_state = pcall(require, "telescope.actions.state")
        if ok_p and ok_f and ok_c and ok_a and ok_as then
            navigation.focus_editor_window(state)
            pickers
                .new({}, {
                    prompt_title = "Solution Symbols",
                    finder = finders.new_table({
                        results = display_items,
                        entry_maker = function(item)
                            return {
                                value = item,
                                display = item.label,
                                ordinal = item.label,
                                filename = item.sym.file,
                                lnum = item.sym.line,
                                col = item.sym.col,
                            }
                        end,
                    }),
                    sorter = tele_conf.values.generic_sorter({}),
                    previewer = tele_conf.values.grep_previewer({}),
                    attach_mappings = function(prompt_bufnr)
                        actions.select_default:replace(function()
                            actions.close(prompt_bufnr)
                            local selection = action_state.get_selected_entry()
                            if selection and selection.value then
                                local s = selection.value.sym
                                jump_to_location(state, s.file, s.line, s.col)
                            end
                        end)
                        return true
                    end,
                })
                :find()
            return
        end
    end

    vim.ui.select(display_items, {
        prompt = "Select Symbol:",
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if choice then
            jump_to_location(state, choice.sym.file, choice.sym.line, choice.sym.col)
        end
    end)
end

return M

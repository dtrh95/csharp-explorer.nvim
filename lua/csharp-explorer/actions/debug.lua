local compound = require("csharp-explorer.compound")
local config = require("csharp-explorer.config")
local debug_engine = require("csharp-explorer.debug")
local debug_window = require("csharp-explorer.ui.debug_window")
local metadata = require("csharp-explorer.metadata")
local process = require("csharp-explorer.process")
local renderer = require("csharp-explorer.renderer")
local run_config = require("csharp-explorer.run_config")

local M = {}

local function ensure_solution_tree(state)
    if state and state.tree then
        return
    end
    local cs = package.loaded["csharp-explorer"]
    if cs and cs.tree and state then
        state.tree = cs.tree
    end
end

local function resolve_project_node(state, opts)
    if opts and opts.project_node then
        return opts.project_node
    end
    if state and state.win and vim.api.nvim_win_is_valid(state.win) then
        local cursor = vim.api.nvim_win_get_cursor(state.win)
        local cur_win = vim.api.nvim_get_current_win()
        if cur_win == state.win then
            local node = renderer.line_to_node[cursor[1]]
            while node do
                if node._type == "project" then
                    return node
                end
                node = node._parent
            end
        end
    end
    local cur_buf = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(cur_buf)
    if path and path ~= "" then
        local csproj = metadata.find_project_root(path)
        if csproj then
            return { _type = "project", _path = csproj, _name = vim.fn.fnamemodify(csproj, ":t:r") }
        end
    end
    return nil
end

local function launch_and_debug(state, cfg, opts)
    opts = opts or {}
    local sess = debug_engine.start(cfg, opts)
    if config.current.debug and config.current.debug.auto_open_window then
        debug_window.open(state, {
            session_id = sess and sess.id,
            focus = config.current.debug and config.current.debug.focus_on_break == true,
        })
    end
    return sess
end

function M.debug_target(state, opts)
    opts = opts or {}
    ensure_solution_tree(state)
    local proj_node = resolve_project_node(state, opts)

    if not proj_node or not proj_node._path then
        local cfgs = run_config.get_solution_configs(state and state.tree)
        if #cfgs == 1 then
            return launch_and_debug(state, cfgs[1], opts)
        end
        return M.select_debug_profile(state, opts)
    end

    local cfgs = run_config.get_project_configs(proj_node._path)
    if #cfgs == 0 then
        vim.notify("Project is not runnable: " .. (proj_node._name or "Unknown"), vim.log.levels.WARN)
        return nil
    end

    if opts.profile then
        local target_name = opts.profile:lower()
        for _, c in ipairs(cfgs) do
            if c.profile_name:lower() == target_name then
                return launch_and_debug(state, c, opts)
            end
        end
        vim.notify("Profile not found: " .. opts.profile, vim.log.levels.WARN)
        return nil
    end

    if #cfgs == 1 and not opts.select then
        return launch_and_debug(state, cfgs[1], opts)
    end

    return M.select_debug_profile(state, { project_node = proj_node })
end

function M.select_debug_profile(state, opts)
    opts = opts or {}
    ensure_solution_tree(state)
    local proj_node = opts.project_node
    local entries = {}

    if proj_node and proj_node._path then
        local cfgs = run_config.get_project_configs(proj_node._path)
        for _, c in ipairs(cfgs) do
            entries[#entries + 1] = { label = "[Profile] " .. c.name, cfg = c }
        end
    else
        local cfgs = run_config.get_solution_configs(state and state.tree)
        for _, c in ipairs(cfgs) do
            entries[#entries + 1] = { label = "[Profile] " .. c.name, cfg = c }
        end

        local compounds = compound.get_compounds(state)
        for _, comp in ipairs(compounds) do
            entries[#entries + 1] = {
                label = string.format("[Compound] %s (%d projects)", comp.name, #comp.items),
                compound = comp,
            }
        end

        entries[#entries + 1] = {
            label = "⚡ Attach to Running Process...",
            is_attach = true,
        }
    end

    if #entries == 0 then
        vim.notify("No runnable projects or compounds found.", vim.log.levels.WARN)
        return
    end

    vim.ui.select(entries, {
        prompt = "Select Debug Profile, Compound, or Action:",
        format_item = function(item)
            return item.label
        end,
    }, function(target)
        if not target then
            return
        end
        if target.is_attach then
            M.attach_debugger(state, opts)
        elseif target.compound then
            M.debug_compound(state, target.compound, opts)
        elseif target.cfg then
            launch_and_debug(state, target.cfg, opts)
        end
    end)
end

function M.debug_compound(state, compound_or_name, opts)
    ensure_solution_tree(state)
    local comp = compound_or_name
    if type(comp) == "string" then
        comp = compound.find_compound(state, compound_or_name)
    elseif type(comp) == "table" and type(comp.items) ~= "table" then
        comp = compound.find_compound(state, comp.id or comp.name)
    end
    if not comp or type(comp.items) ~= "table" then
        local label = type(compound_or_name) == "table" and (compound_or_name.name or compound_or_name.id)
            or tostring(compound_or_name)
        vim.notify("Compound not found: " .. tostring(label), vim.log.levels.WARN)
        return
    end

    local tree = state and state.tree
    local solution_dir = compound.get_solution_dir(state)
    local all_cfgs = run_config.get_solution_configs(tree)
    local stop_together = comp.stop_together ~= false

    local has_explicit_debug = false
    for _, item in ipairs(comp.items) do
        if item.mode == "debug" then
            has_explicit_debug = true
            break
        end
    end

    local started_count = 0
    for _, item in ipairs(comp.items) do
        local cfg = compound.resolve_item_config(item, all_cfgs, solution_dir)
        if cfg then
            started_count = started_count + 1
            local item_opts = {
                compound_id = comp.id,
                stop_together = stop_together,
                stop_at_entry = opts and opts.stop_at_entry,
                just_my_code = opts and opts.just_my_code,
            }
            local delay = item.delay_ms or 0
            local should_run = (not (opts and opts.force_debug)) and has_explicit_debug and item.mode == "run"
            if should_run then
                process.schedule_start(delay, cfg, item_opts)
            else
                debug_engine.schedule_start(delay, cfg, item_opts)
            end
        end
    end

    debug_window.open(state, {
        focus = config.current.debug and config.current.debug.focus_on_break == true,
    })
    vim.notify(
        string.format("Started debug compound '%s' (%d processes).", comp.name, started_count),
        vim.log.levels.INFO
    )
end

function M.attach_debugger(state, opts)
    local procs = debug_engine.list_dotnet_processes()
    if #procs == 0 then
        vim.notify("No .NET processes found to attach.", vim.log.levels.WARN)
        return
    end

    vim.ui.select(procs, {
        prompt = "Select .NET Process to Attach Debugger:",
        format_item = function(item)
            return string.format("[%d] %s (%s)", item.pid, item.name, item.source)
        end,
    }, function(choice)
        if choice then
            local sess = debug_engine.attach(choice.pid, {
                name = choice.name,
                project_path = choice.project_path,
                just_my_code = opts and opts.just_my_code,
            })
            if config.current.debug and config.current.debug.auto_open_window then
                debug_window.open(state, { session_id = sess and sess.id, focus = false })
            end
        end
    end)
end

function M.edit_breakpoint_condition()
    local ok_bp, dap_bp = pcall(require, "dap.breakpoints")
    local bufnr = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local cur_cond = ""
    if ok_bp and dap_bp then
        local bps = dap_bp.get(bufnr) or {}
        for _, b in ipairs(bps) do
            if b.line == line then
                cur_cond = b.condition or ""
                break
            end
        end
    end
    vim.ui.input({ prompt = "Breakpoint Condition: ", default = cur_cond }, function(input)
        if input ~= nil then
            debug_engine.set_breakpoint_condition(bufnr, line, vim.trim(input))
        end
    end)
end

function M.prompt_add_watch()
    vim.ui.input({ prompt = "Add Watch Expression: " }, function(input)
        if input and vim.trim(input) ~= "" then
            debug_engine.add_watch(vim.trim(input))
        end
    end)
end

function M.prompt_evaluate()
    vim.ui.input({ prompt = "Evaluate C# Expression: " }, function(input)
        if input and vim.trim(input) ~= "" then
            debug_engine.evaluate(vim.trim(input), {}, function(err, res)
                if err then
                    vim.notify("Eval error: " .. tostring(err), vim.log.levels.ERROR)
                elseif res then
                    vim.notify(tostring(input) .. " => " .. tostring(res.result), vim.log.levels.INFO)
                end
            end)
        end
    end)
end

return M

local compound = require("csharp-explorer.compound")
local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local process = require("csharp-explorer.process")
local run_config = require("csharp-explorer.run_config")
local run_window = require("csharp-explorer.ui.run_window")
local runner = require("csharp-explorer.runner")

local M = {}

local function ensure_solution_tree(state)
    if state and not state.tree and type(state.ensure_tree) == "function" then
        state.ensure_tree()
    end
end

local function find_project_node_by_path(tree, project_path)
    if not tree or not project_path then
        return nil
    end
    local norm = metadata.normalize_path(project_path):lower()
    local function walk(n)
        if n._type == "project" and n._path and metadata.normalize_path(n._path):lower() == norm then
            return n
        end
        if n._children then
            for _, c in pairs(n._children) do
                local res = walk(c)
                if res then
                    return res
                end
            end
        end
        return nil
    end
    return walk(tree)
end

local function resolve_project_node(state, opts)
    ensure_solution_tree(state)
    local target = runner.resolve_target(state, opts)
    if not target then
        return nil
    end
    if target.project_node then
        return target.project_node
    end
    if target.kind == "project" and target.path then
        return find_project_node_by_path(state and state.tree, target.path)
            or { _type = "project", _path = target.path, _name = target.name }
    end
    return nil
end

local function launch_and_show(state, cfg, opts)
    local session = process.start(cfg, opts)
    run_window.open(state, {
        session_id = session.id,
        focus = config.current.run and config.current.run.focus_on_run == true,
    })
    return session
end

function M.run_target(state, opts)
    opts = opts or {}
    ensure_solution_tree(state)
    local proj_node

    if opts.project_path then
        proj_node = find_project_node_by_path(state and state.tree, opts.project_path)
            or {
                _type = "project",
                _path = metadata.normalize_path(opts.project_path),
                _name = vim.fn.fnamemodify(opts.project_path, ":t:r"),
            }
    else
        proj_node = resolve_project_node(state, opts)
    end

    if not proj_node or not proj_node._path then
        M.select_run_profile(state, opts)
        return
    end

    local cfgs = run_config.get_project_configs(proj_node._path)
    if #cfgs == 0 then
        vim.notify("No runnable profiles found for project: " .. proj_node._name, vim.log.levels.WARN)
        return
    end

    local desired_profile = opts.profile
        or (
            config.current.run
            and type(config.current.run.default_profile) == "string"
            and config.current.run.default_profile
        )

    if desired_profile then
        local target_name = desired_profile:lower()
        for _, c in ipairs(cfgs) do
            if c.profile_name:lower() == target_name then
                launch_and_show(state, c, opts)
                return
            end
        end
        if opts.profile then
            vim.notify("Profile not found: " .. opts.profile, vim.log.levels.WARN)
            return
        end
    end

    if #cfgs == 1 then
        launch_and_show(state, cfgs[1], opts)
        return
    end

    M.select_run_profile(state, { project_node = proj_node })
end

function M.select_run_profile(state, opts)
    opts = opts or {}
    ensure_solution_tree(state)
    local proj_node = opts.project_node
    local entries = {}

    if proj_node and proj_node._path then
        local cfgs = run_config.get_project_configs(proj_node._path)
        for _, c in ipairs(cfgs) do
            entries[#entries + 1] = { label = c.name, cfg = c, hot_reload = false }
            entries[#entries + 1] = { label = c.name .. " [Hot Reload]", cfg = c, hot_reload = true }
        end
    else
        local cfgs = run_config.get_solution_configs(state and state.tree)
        for _, c in ipairs(cfgs) do
            entries[#entries + 1] = { label = c.name, cfg = c, hot_reload = false }
            entries[#entries + 1] = { label = c.name .. " [Hot Reload]", cfg = c, hot_reload = true }
        end

        local compounds = compound.get_compounds(state)
        for _, comp in ipairs(compounds) do
            entries[#entries + 1] = {
                label = string.format("[Compound] %s (%d projects)", comp.name, #comp.items),
                compound = comp,
            }
        end
    end

    if #entries == 0 then
        vim.notify("No runnable projects or compounds found.", vim.log.levels.WARN)
        return
    end

    vim.ui.select(entries, {
        prompt = "Select Run Profile or Compound:",
        format_item = function(item)
            return item.label
        end,
    }, function(target)
        if not target then
            return
        end
        if target.compound then
            M.run_compound(state, target.compound)
        elseif target.cfg then
            launch_and_show(state, target.cfg, { hot_reload = target.hot_reload })
        end
    end)
end

function M.run_compound(state, compound_or_name, _opts)
    ensure_solution_tree(state)

    if compound_or_name == nil or compound_or_name == "" then
        local compounds = compound.get_compounds(state)
        if #compounds == 0 then
            compound.manage_compounds(state)
            return
        end
        local labels = {}
        for _, c in ipairs(compounds) do
            labels[#labels + 1] = string.format("%s (%d projects)", c.name, #c.items)
        end
        vim.ui.select(labels, { prompt = "Select Compound to Run:" }, function(_, idx)
            if idx and compounds[idx] then
                M.run_compound(state, compounds[idx])
            end
        end)
        return
    end

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

    local started_count = 0
    local has_debug = false
    local has_run = false
    for _, item in ipairs(comp.items) do
        local cfg = compound.resolve_item_config(item, all_cfgs, solution_dir)
        if cfg then
            started_count = started_count + 1
            local item_opts = {
                compound_id = comp.id,
                stop_together = stop_together,
                hot_reload = item.hot_reload,
            }
            local delay = item.delay_ms or 0
            if item.mode == "debug" then
                has_debug = true
                local debug_engine = require("csharp-explorer.debug")
                debug_engine.schedule_start(delay, cfg, item_opts)
            else
                has_run = true
                process.schedule_start(delay, cfg, item_opts)
            end
        end
    end

    if has_debug and (not has_run or (config.current.debug and config.current.debug.auto_open_window)) then
        local ok_dw, dw = pcall(require, "csharp-explorer.ui.debug_window")
        if ok_dw and dw.open then
            dw.open(state, { focus = false })
        end
    end
    if has_run then
        run_window.open(state, {
            focus = config.current.run and config.current.run.focus_on_run == true,
        })
    end
    vim.notify(string.format("Started compound '%s' (%d processes).", comp.name, started_count), vim.log.levels.INFO)
end

function M.stop_target(state, opts)
    if
        run_window.win
        and vim.api.nvim_win_is_valid(run_window.win)
        and vim.api.nvim_get_current_win() == run_window.win
        and run_window.active_session_id
    then
        process.stop(run_window.active_session_id)
        return
    end

    local proj_node = resolve_project_node(state, opts)
    if proj_node and proj_node._path then
        local sessions = process.get_project_sessions(proj_node._path)
        for _, s in ipairs(sessions) do
            if s.status == "starting" or s.status == "running" then
                process.stop(s.id)
            end
        end
    end
end

function M.stop_all(_state, _opts)
    process.stop_all()
    vim.notify("Stopped all processes.", vim.log.levels.INFO)
end

function M.restart_target(state, opts)
    if
        run_window.win
        and vim.api.nvim_win_is_valid(run_window.win)
        and vim.api.nvim_get_current_win() == run_window.win
        and run_window.active_session_id
    then
        process.restart(run_window.active_session_id, opts)
        return
    end

    local proj_node = resolve_project_node(state, opts)
    if proj_node and proj_node._path then
        local sessions = process.get_project_sessions(proj_node._path)
        for _, s in ipairs(sessions) do
            if s.status == "starting" or s.status == "running" then
                process.restart(s.id, opts)
                return
            end
        end
    end
end

function M.toggle_run_window(state)
    run_window.toggle(state)
end

return M

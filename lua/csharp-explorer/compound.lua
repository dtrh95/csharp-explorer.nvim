local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local run_config = require("csharp-explorer.run_config")
local uv = vim.uv or vim.loop

local M = {}

function M.get_solution_dir(state)
    if state and not state.tree and type(state.ensure_tree) == "function" then
        state.ensure_tree()
    end
    if state and state.tree and state.tree._dir then
        return metadata.normalize_path(state.tree._dir)
    end
    return metadata.normalize_path(vim.fn.getcwd())
end

local function get_compounds_file_path(solution_dir)
    return solution_dir .. "/.csharp-explorer/compounds.json"
end

function M.load_workspace_compounds(solution_dir)
    local file_path = get_compounds_file_path(solution_dir)
    local f = io.open(file_path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()

    local sanitized = run_config.sanitize_jsonc(content)
    local ok, data = pcall(vim.json.decode, sanitized)
    if not ok or type(data) ~= "table" then
        return {}
    end

    local list = {}
    for _, item in ipairs(data) do
        if type(item) == "table" and type(item.name) == "string" and type(item.items) == "table" then
            list[#list + 1] = {
                id = item.id or ("compound:" .. item.name:lower():gsub("%s+", "-")),
                name = item.name,
                items = item.items,
                stop_together = item.stop_together ~= false,
                source = "file",
            }
        end
    end
    return list
end

function M.save_workspace_compounds(solution_dir, compounds)
    local file_path = get_compounds_file_path(solution_dir)
    local dir_path = vim.fn.fnamemodify(file_path, ":h")
    if vim.fn.isdirectory(dir_path) == 0 then
        vim.fn.mkdir(dir_path, "p")
    end

    local serializable = {}
    for _, c in ipairs(compounds) do
        if c.source == "file" or c.source == nil then
            serializable[#serializable + 1] = {
                id = c.id,
                name = c.name,
                items = c.items,
                stop_together = c.stop_together,
            }
        end
    end

    local encoded = vim.json.encode(serializable)
    local tmp_path = file_path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if f then
        f:write(encoded)
        f:close()
        local ok_ren = uv.fs_rename(tmp_path, file_path)
        if not ok_ren then
            os.remove(file_path)
            ok_ren = uv.fs_rename(tmp_path, file_path)
        end
        return ok_ren ~= nil and ok_ren ~= false
    end
    return false
end

function M.get_compounds(state)
    local solution_dir = M.get_solution_dir(state)
    local file_compounds = M.load_workspace_compounds(solution_dir)

    local config_compounds = {}
    if config.current.run and type(config.current.run.compounds) == "table" then
        for _, c in ipairs(config.current.run.compounds) do
            if type(c) == "table" and type(c.name) == "string" and type(c.items) == "table" then
                config_compounds[#config_compounds + 1] = {
                    id = c.id or ("compound:" .. c.name:lower():gsub("%s+", "-")),
                    name = c.name,
                    items = c.items,
                    stop_together = c.stop_together ~= false,
                    source = "config",
                }
            end
        end
    end

    local merged = {}
    local seen_names = {}

    for _, c in ipairs(file_compounds) do
        merged[#merged + 1] = c
        seen_names[c.name:lower()] = true
        if c.id then
            seen_names[c.id:lower()] = true
        end
    end

    for _, c in ipairs(config_compounds) do
        local name_key = c.name:lower()
        local id_key = c.id and c.id:lower()
        if not seen_names[name_key] and (not id_key or not seen_names[id_key]) then
            merged[#merged + 1] = c
        end
    end

    table.sort(merged, function(a, b)
        return a.name < b.name
    end)

    return merged
end

function M.find_compound(state, name_or_id)
    if not name_or_id or name_or_id == "" then
        return nil
    end
    local target = tostring(name_or_id):lower()
    local compounds = M.get_compounds(state)
    for _, c in ipairs(compounds) do
        if c.id:lower() == target or c.name:lower() == target then
            return c
        end
    end
    return nil
end

function M.create_compound(state, opts)
    opts = opts or {}
    local name = vim.trim(opts.name or "")
    if name == "" then
        error("Compound name cannot be empty")
    end

    local solution_dir = M.get_solution_dir(state)
    local file_compounds = M.load_workspace_compounds(solution_dir)
    local clean_id = opts.id or ("compound:" .. name:lower():gsub("%s+", "-"):gsub("[^%w%-_]", ""))

    local new_comp = {
        id = clean_id,
        name = name,
        items = opts.items or {},
        stop_together = opts.stop_together ~= false,
        source = "file",
    }

    local replaced = false
    for i, c in ipairs(file_compounds) do
        if c.id == clean_id or c.name:lower() == name:lower() then
            file_compounds[i] = new_comp
            replaced = true
            break
        end
    end
    if not replaced then
        file_compounds[#file_compounds + 1] = new_comp
    end

    M.save_workspace_compounds(solution_dir, file_compounds)

    if opts.run then
        local ok, run_actions = pcall(require, "csharp-explorer.actions.run")
        if ok and run_actions.run_compound then
            run_actions.run_compound(state, new_comp)
        end
    end

    return new_comp
end

function M.delete_compound(state, name_or_id)
    if not name_or_id or name_or_id == "" then
        return false
    end
    local target = tostring(name_or_id):lower()
    local solution_dir = M.get_solution_dir(state)
    local file_compounds = M.load_workspace_compounds(solution_dir)
    local remaining = {}
    local deleted = false

    for _, c in ipairs(file_compounds) do
        if c.id:lower() == target or c.name:lower() == target then
            deleted = true
        else
            remaining[#remaining + 1] = c
        end
    end

    if deleted then
        M.save_workspace_compounds(solution_dir, remaining)
    end
    return deleted
end

function M.resolve_item_config(item, all_cfgs, solution_dir)
    if type(item) ~= "table" then
        return nil
    end
    local raw_proj = item.project_path or item.project
    if type(raw_proj) ~= "string" or raw_proj == "" then
        return nil
    end

    local raw_prof = item.profile_name or item.profile
    local target_prof = type(raw_prof) == "string" and raw_prof ~= "" and raw_prof:lower() or nil
    local default_prof = config.current.run
            and type(config.current.run.default_profile) == "string"
            and config.current.run.default_profile:lower()
        or nil

    local norm_proj = metadata.normalize_path(raw_proj):lower()
    local rel_proj = solution_dir and metadata.normalize_path(solution_dir .. "/" .. raw_proj):lower() or nil
    local proj_stem = vim.fn.fnamemodify(raw_proj, ":t:r"):lower()

    local candidates = {}
    for _, c in ipairs(all_cfgs or {}) do
        local c_path = c.project_path:lower()
        local c_name = c.project_name:lower()
        if c_path == norm_proj or (rel_proj and c_path == rel_proj) or c_name == norm_proj or c_name == proj_stem then
            candidates[#candidates + 1] = c
        end
    end

    if #candidates == 0 and vim.fn.filereadable(raw_proj) == 1 then
        candidates = run_config.get_project_configs(raw_proj)
    elseif #candidates == 0 and rel_proj and vim.fn.filereadable(solution_dir .. "/" .. raw_proj) == 1 then
        candidates = run_config.get_project_configs(solution_dir .. "/" .. raw_proj)
    end

    if #candidates == 0 then
        return nil
    end

    if target_prof then
        for _, c in ipairs(candidates) do
            if c.profile_name:lower() == target_prof then
                return c
            end
        end
        return nil
    end

    if default_prof then
        for _, c in ipairs(candidates) do
            if c.profile_name:lower() == default_prof then
                return c
            end
        end
    end

    return candidates[1]
end

local function select_items_loop(state, name, initial_items, on_save)
    if state and not state.tree and type(state.ensure_tree) == "function" then
        state.ensure_tree()
    end
    local tree = state and state.tree
    local solution_dir = M.get_solution_dir(state)
    local all_cfgs = run_config.get_solution_configs(tree)
    if #all_cfgs == 0 then
        vim.notify("No runnable projects found in solution.", vim.log.levels.WARN)
        return
    end

    local selected = {}
    local existing_meta = {}
    for _, item in ipairs(initial_items or {}) do
        local resolved = M.resolve_item_config(item, all_cfgs, solution_dir)
        if resolved then
            local key = resolved.project_path .. ":" .. resolved.profile_name
            selected[key] = true
            existing_meta[key] = {
                delay_ms = item.delay_ms or 0,
                hot_reload = item.hot_reload,
            }
        end
    end

    local function prompt_menu()
        local items = {}
        for _, cfg in ipairs(all_cfgs) do
            local key = cfg.project_path .. ":" .. cfg.profile_name
            local check = selected[key] and "[x] " or "[ ] "
            items[#items + 1] = check .. cfg.name
        end
        items[#items + 1] = "--- Actions ---"
        items[#items + 1] = "[Save & Run]"
        items[#items + 1] = "[Save]"
        items[#items + 1] = "[Cancel]"

        vim.ui.select(items, { prompt = "Compound: " .. name .. " (Select projects):" }, function(choice, idx)
            if not choice or choice == "[Cancel]" or choice == "--- Actions ---" then
                return
            end
            if choice == "[Save]" or choice == "[Save & Run]" then
                local chosen_items = {}
                for _, cfg in ipairs(all_cfgs) do
                    local key = cfg.project_path .. ":" .. cfg.profile_name
                    if selected[key] then
                        local prev = existing_meta[key]
                        chosen_items[#chosen_items + 1] = {
                            project_path = cfg.project_path,
                            project_name = cfg.project_name,
                            profile_name = cfg.profile_name,
                            delay_ms = prev and prev.delay_ms or 0,
                            hot_reload = prev and prev.hot_reload or nil,
                        }
                    end
                end
                if #chosen_items == 0 then
                    vim.notify("Select at least one project profile before saving.", vim.log.levels.WARN)
                    prompt_menu()
                    return
                end
                on_save(chosen_items, choice == "[Save & Run]")
                return
            end

            local cfg = all_cfgs[idx]
            if cfg then
                local key = cfg.project_path .. ":" .. cfg.profile_name
                selected[key] = not selected[key]
            end
            prompt_menu()
        end)
    end

    prompt_menu()
end

function M.manage_compounds(state)
    local compounds = M.get_compounds(state)
    local menu_items = {}

    for _, c in ipairs(compounds) do
        menu_items[#menu_items + 1] = "Run: " .. c.name .. " (" .. #c.items .. " projects)"
    end
    menu_items[#menu_items + 1] = "[+] Create New Compound"
    if #compounds > 0 then
        menu_items[#menu_items + 1] = "[~] Edit Compound"
        menu_items[#menu_items + 1] = "[-] Delete Compound"
    end

    vim.ui.select(menu_items, { prompt = "Manage Compound Configurations:" }, function(choice, idx)
        if not choice then
            return
        end

        if choice == "[+] Create New Compound" then
            vim.ui.input({ prompt = "Compound Name: " }, function(name)
                if not name or vim.trim(name) == "" then
                    return
                end
                name = vim.trim(name)
                select_items_loop(state, name, {}, function(items, run_now)
                    M.create_compound(state, {
                        name = name,
                        items = items,
                        run = run_now,
                    })
                    vim.notify("Created compound: " .. name, vim.log.levels.INFO)
                end)
            end)
            return
        end

        if choice == "[~] Edit Compound" then
            local comp_names = {}
            for _, c in ipairs(compounds) do
                comp_names[#comp_names + 1] = c.name
            end
            vim.ui.select(comp_names, { prompt = "Select Compound to Edit:" }, function(sel_name)
                if not sel_name then
                    return
                end
                local comp = M.find_compound(state, sel_name)
                if not comp then
                    return
                end
                select_items_loop(state, comp.name, comp.items, function(items, run_now)
                    M.create_compound(state, {
                        id = comp.id,
                        name = comp.name,
                        items = items,
                        stop_together = comp.stop_together,
                        run = run_now,
                    })
                    vim.notify("Updated compound: " .. comp.name, vim.log.levels.INFO)
                end)
            end)
            return
        end

        if choice == "[-] Delete Compound" then
            local comp_names = {}
            for _, c in ipairs(compounds) do
                if c.source == "file" then
                    comp_names[#comp_names + 1] = c.name
                end
            end
            if #comp_names == 0 then
                vim.notify("No workspace compounds available to delete.", vim.log.levels.INFO)
                return
            end
            vim.ui.select(comp_names, { prompt = "Select Workspace Compound to Delete:" }, function(sel_name)
                if not sel_name then
                    return
                end
                M.delete_compound(state, sel_name)
                vim.notify("Deleted compound: " .. sel_name, vim.log.levels.INFO)
            end)
            return
        end

        local comp = compounds[idx]
        if comp then
            local ok, run_actions = pcall(require, "csharp-explorer.actions.run")
            if ok and run_actions.run_compound then
                run_actions.run_compound(state, comp)
            else
                vim.notify("Run actions not initialized yet.", vim.log.levels.INFO)
            end
        end
    end)
end

return M

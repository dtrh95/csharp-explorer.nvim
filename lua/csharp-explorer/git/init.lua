local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local node_utils = require("csharp-explorer.node")
local runner = require("csharp-explorer.git.runner")
local watcher = require("csharp-explorer.git.watcher")

local M = {}

M.ns_id = vim.api.nvim_create_namespace("CSharpExplorerGit")

local DEFAULT_ICONS = {
    conflict = "",
    staged = "✓",
    modified = "✗",
    renamed = "➜",
    deleted = "",
    untracked = "★",
    ignored = "◌",
}

local KIND_PRIORITY = {
    conflict = 1,
    staged = 2,
    modified = 3,
    renamed = 4,
    deleted = 5,
    untracked = 6,
    ignored = 7,
}

local KIND_CAPITALIZED = {
    conflict = "Conflict",
    staged = "Staged",
    modified = "Modified",
    renamed = "Renamed",
    deleted = "Deleted",
    untracked = "Untracked",
    ignored = "Ignored",
}

local KIND_LABELS = {
    conflict = "Merge conflict",
    staged = "Staged",
    modified = "Modified",
    renamed = "Renamed",
    deleted = "Deleted",
    untracked = "Untracked",
    ignored = "Ignored",
}

local repos = {}
local dir_to_toplevel = {}
local by_file = {}
local by_dir = {}
local ignored_dirs = {}
local active_state = nil

local function get_git_cfg()
    return (config.current and config.current.git) or {}
end

local function is_enabled()
    local cfg = get_git_cfg()
    return cfg.enable ~= false and cfg.enabled ~= false
end

local function find_owning_repo(abs_path)
    if not abs_path or abs_path == "" then
        return nil
    end
    local norm = metadata.normalize_path(abs_path)
    local direct_top = repos[norm] and norm or dir_to_toplevel[norm]
    if direct_top and repos[direct_top] then
        return repos[direct_top]
    end

    local best_repo = nil
    local best_len = 0
    for toplevel, repo in pairs(repos) do
        if norm == toplevel or vim.startswith(norm, toplevel .. "/") then
            if #toplevel > best_len then
                best_len = #toplevel
                best_repo = repo
            end
        end
    end
    return best_repo
end

local function format_status(raw, is_container, branch)
    if not raw or not raw.kind then
        return nil
    end
    local cfg = get_git_cfg()
    local icons = cfg.icons or DEFAULT_ICONS
    local cap = KIND_CAPITALIZED[raw.kind] or "Modified"
    local icon_hl = "CSharpExplorerGit" .. cap .. "Icon"
    local name_hl = is_container and ("CSharpExplorerGit" .. cap .. "FolderHL")
        or ("CSharpExplorerGit" .. cap .. "FileHL")
    local badge = icons[raw.kind] or DEFAULT_ICONS[raw.kind] or "✗"
    local is_dirty = (raw.prio and raw.prio < 7) or false
    local is_ign = raw.kind == "ignored"

    local display_status = raw.desc or KIND_LABELS[raw.kind] or "Modified"
    if raw.orig_path then
        display_status = string.format("%s (from %s)", display_status, vim.fn.fnamemodify(raw.orig_path, ":t"))
    end

    return {
        kind = raw.kind,
        prio = raw.prio or (KIND_PRIORITY[raw.kind] or 6),
        xy = raw.xy or "",
        badge = badge,
        badge_hl = icon_hl,
        icon_hl = icon_hl,
        name_hl = name_hl,
        is_dirty = is_dirty,
        is_ignored = is_ign,
        display_status = display_status,
        branch = branch,
    }
end

function M.setup(_opts) end

function M.is_indexed(target)
    if not is_enabled() then
        return false
    end
    if not target then
        if next(repos) == nil then
            return false
        end
        for _, repo in pairs(repos) do
            if not repo.indexed then
                return false
            end
        end
        return true
    end
    if type(target) == "string" then
        local repo = find_owning_repo(target)
        return repo ~= nil and repo.indexed == true
    elseif type(target) == "table" then
        local p = target._dir or target._path
        if p then
            return M.is_indexed(p)
        end
        return M.is_indexed(nil)
    end
    return false
end

function M.is_ignored(abs_path)
    if not is_enabled() or not abs_path or abs_path == "" then
        return false
    end
    local norm = metadata.normalize_path(abs_path)
    local f_stat = by_file[norm]
    if f_stat and f_stat.kind == "ignored" then
        return true
    end
    if ignored_dirs[norm] then
        return true
    end
    local curr = vim.fn.fnamemodify(norm, ":h")
    while curr and curr ~= "" and curr ~= "/" do
        curr = metadata.normalize_path(curr)
        if ignored_dirs[curr] then
            return true
        end
        local parent = vim.fn.fnamemodify(curr, ":h")
        if parent == curr then
            break
        end
        curr = parent
    end
    return false
end

function M.get_branch(target)
    if not is_enabled() then
        return nil
    end
    if type(target) == "string" then
        local repo = find_owning_repo(target)
        return repo and repo.branch or nil
    elseif type(target) == "table" then
        local p = target._dir or target._path
        if p then
            local repo = find_owning_repo(p)
            if repo and repo.branch then
                return repo.branch
            end
        end
        for _, repo in pairs(repos) do
            if repo.branch then
                return repo.branch
            end
        end
    end
    return nil
end

function M.get_node_status(node)
    if not is_enabled() or not node or node._virtual then
        return nil
    end

    local cfg = get_git_cfg()
    local show_on_dirs = cfg.show_on_dirs ~= false
    local show_on_open_dirs = cfg.show_on_open_dirs == true
    local show_on_nested = cfg.show_on_nested_parents ~= false
    local node_type = node._type

    if node_utils.is_file(node) then
        local file_path = node._path
        if not file_path then
            return nil
        end
        local norm_path = metadata.normalize_path(file_path)
        if M.is_ignored(norm_path) then
            return format_status({
                kind = "ignored",
                prio = 7,
                xy = "!!",
                desc = "Ignored",
            }, false, nil)
        end

        local res = by_file[norm_path]
        if node_utils.is_nested_parent(node) and not node._expanded and show_on_nested and node._children then
            for _, child in pairs(node._children) do
                if child._path and not M.is_ignored(child._path) then
                    local child_stat = by_file[metadata.normalize_path(child._path)]
                    if child_stat and child_stat.prio < 7 then
                        if not res or child_stat.prio < res.prio then
                            res = child_stat
                        end
                    end
                end
            end
        end

        return format_status(res, false, nil)
    end

    if node_type == "folder" and node._dir ~= nil then
        local dir_path = metadata.normalize_path(node._dir)
        if M.is_ignored(dir_path) then
            return format_status({
                kind = "ignored",
                prio = 7,
                xy = "!!",
                desc = "Ignored",
            }, true, nil)
        end
        if not show_on_dirs then
            return nil
        end
        local dir_stat = by_dir[dir_path]
        if not dir_stat then
            return nil
        end
        if node._expanded and not show_on_open_dirs then
            if dir_stat.has_deleted then
                return format_status({
                    kind = "deleted",
                    prio = 5,
                    xy = " D",
                    desc = "Contains deleted files",
                }, true, nil)
            end
            return nil
        end
        return format_status(dir_stat, true, nil)
    end

    if node_type == "project" then
        local file_stat = nil
        if node._path then
            local norm_p = metadata.normalize_path(node._path)
            if not M.is_ignored(norm_p) then
                file_stat = by_file[norm_p]
            end
        end

        local dir_stat = nil
        if show_on_dirs and node._dir then
            local pdir = metadata.normalize_path(node._dir)
            if not M.is_ignored(pdir) then
                local raw_dir = by_dir[pdir]
                if raw_dir then
                    if node._expanded and not show_on_open_dirs then
                        if raw_dir.has_deleted then
                            dir_stat = {
                                kind = "deleted",
                                prio = 5,
                                xy = " D",
                                desc = "Contains deleted files",
                            }
                        end
                    else
                        dir_stat = raw_dir
                    end
                end
            end
        end

        local chosen
        if file_stat and dir_stat then
            chosen = (file_stat.prio <= dir_stat.prio) and file_stat or dir_stat
        else
            chosen = file_stat or dir_stat
        end

        return format_status(chosen, true, M.get_branch(node))
    end

    local function best_in_projects(root_node, initial_best)
        local best = initial_best
        local function consider(cand)
            if cand and cand.prio and cand.prio < 7 then
                if not best or cand.prio < best.prio then
                    best = cand
                end
            end
        end
        local function walk(n)
            if n._type == "project" then
                consider(n._path and by_file[metadata.normalize_path(n._path)] or nil)
                consider(n._dir and by_dir[metadata.normalize_path(n._dir)] or nil)
                return
            end
            if n._children then
                for _, child in pairs(n._children) do
                    walk(child)
                end
            end
        end
        walk(root_node)
        return best
    end

    if node_type == "solution_folder" or (node_type == "folder" and node._dir == nil) then
        if not show_on_dirs then
            return nil
        end
        return format_status(best_in_projects(node, nil), true, nil)
    end

    if node_type == "solution" then
        local best = node._path and by_file[metadata.normalize_path(node._path)] or nil
        if best and best.prio >= 7 then
            best = nil
        end
        if show_on_dirs and node._children then
            best = best_in_projects(node, best)
        end
        return format_status(best, true, M.get_branch(node))
    end

    return nil
end

function M.has_subtree_changes(node)
    if not is_enabled() or not node or node._virtual then
        return false
    end
    if node_utils.is_file(node) then
        local norm = node._path and metadata.normalize_path(node._path)
        local own = norm and by_file[norm]
        if own and own.prio < 7 then
            return true
        end
        if node._children then
            for _, child in pairs(node._children) do
                local cp = child._path and metadata.normalize_path(child._path)
                local cs = cp and by_file[cp]
                if cs and cs.prio < 7 then
                    return true
                end
            end
        end
        return false
    end
    if node._type == "folder" and node._dir ~= nil then
        local d = by_dir[metadata.normalize_path(node._dir)]
        return d ~= nil and d.prio < 7
    end
    if node._type == "project" then
        local pf = node._path and by_file[metadata.normalize_path(node._path)]
        if pf and pf.prio < 7 then
            return true
        end
        local pd = node._dir and by_dir[metadata.normalize_path(node._dir)]
        return pd ~= nil and pd.prio < 7
    end
    if node._children then
        for _, child in pairs(node._children) do
            if M.has_subtree_changes(child) then
                return true
            end
        end
    end
    return false
end

function M.should_hide_node(node)
    if not is_enabled() then
        return false
    end
    if not (config.current.filter and config.current.filter.git_clean) then
        return false
    end
    if not node or node._type == "solution" then
        return false
    end
    if node._virtual then
        return true
    end
    if not M.is_indexed(node) then
        return false
    end
    return not M.has_subtree_changes(node)
end

function M.toggle_clean_filter(state)
    state = state or active_state
    config.current.filter.git_clean = not config.current.filter.git_clean
    if state and state.is_active and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        require("csharp-explorer.renderer").render(state)
    end
    local label = config.current.filter.git_clean and "hidden" or "visible"
    vim.notify("Git clean files: " .. label, vim.log.levels.INFO)
end

local function collect_dirty_targets(state)
    local tree_changed = false

    local function expand_dirty(node)
        if not node or node._virtual then
            return
        end
        if node._type == "project" then
            if M.has_subtree_changes(node) then
                local pdir = node._dir and metadata.normalize_path(node._dir)
                local dir_dirty = pdir and by_dir[pdir] and by_dir[pdir].prio < 7
                if dir_dirty then
                    if not node._cs_loaded then
                        node_utils.populate_cs_files(node)
                        tree_changed = true
                    end
                    if not node._expanded then
                        node._expanded = true
                        tree_changed = true
                    end
                end
            end
        elseif node._type == "solution" or node._type == "folder" or node_utils.is_nested_parent(node) then
            if M.has_subtree_changes(node) and node._has_children and not node._expanded then
                local should_open = true
                if node_utils.is_file(node) then
                    should_open = false
                    if node._children then
                        for _, child in pairs(node._children) do
                            local cp = child._path and metadata.normalize_path(child._path)
                            local cs = cp and by_file[cp]
                            if cs and cs.prio < 7 then
                                should_open = true
                                break
                            end
                        end
                    end
                end
                if should_open then
                    node._expanded = true
                    tree_changed = true
                end
            end
        end

        if node._children and node._expanded then
            for _, child in pairs(node._children) do
                expand_dirty(child)
            end
        end
    end

    expand_dirty(state.tree)

    local renderer = require("csharp-explorer.renderer")
    if tree_changed then
        renderer.render(state)
    end

    local targets = {}
    for line_num, node in pairs(renderer.line_to_node) do
        local is_target = false
        if node_utils.is_file(node) and node._path then
            local f = by_file[metadata.normalize_path(node._path)]
            is_target = f ~= nil and f.prio < 7
        elseif (node._type == "project" or node._type == "solution") and node._path then
            local f = by_file[metadata.normalize_path(node._path)]
            is_target = f ~= nil and f.prio < 7
        elseif node._type == "folder" and node._dir then
            local d = by_dir[metadata.normalize_path(node._dir)]
            is_target = d ~= nil and d.has_deleted == true
        end
        if is_target then
            targets[#targets + 1] = line_num
        end
    end

    table.sort(targets)
    return targets
end

function M.jump_next(state)
    state = state or active_state
    if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) or not state.tree then
        return
    end
    local targets = collect_dirty_targets(state)
    if #targets == 0 then
        vim.notify("No git changes in solution", vim.log.levels.INFO)
        return
    end

    local cur_line = vim.api.nvim_win_get_cursor(state.win)[1]
    local target_line = nil
    for _, l in ipairs(targets) do
        if l > cur_line then
            target_line = l
            break
        end
    end

    if not target_line then
        if vim.o.wrapscan then
            target_line = targets[1]
        else
            vim.notify("No git changes below cursor", vim.log.levels.INFO)
            return
        end
    end

    vim.api.nvim_win_set_cursor(state.win, { target_line, 0 })
    vim.api.nvim_win_call(state.win, function()
        vim.cmd("normal! zz")
    end)
end

function M.jump_prev(state)
    state = state or active_state
    if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) or not state.tree then
        return
    end
    local targets = collect_dirty_targets(state)
    if #targets == 0 then
        vim.notify("No git changes in solution", vim.log.levels.INFO)
        return
    end

    local cur_line = vim.api.nvim_win_get_cursor(state.win)[1]
    local target_line = nil
    for i = #targets, 1, -1 do
        if targets[i] < cur_line then
            target_line = targets[i]
            break
        end
    end

    if not target_line then
        if vim.o.wrapscan then
            target_line = targets[#targets]
        else
            vim.notify("No git changes above cursor", vim.log.levels.INFO)
            return
        end
    end

    vim.api.nvim_win_set_cursor(state.win, { target_line, 0 })
    vim.api.nvim_win_call(state.win, function()
        vim.cmd("normal! zz")
    end)
end

function M.render_extmarks(state)
    if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(state.buf, M.ns_id, 0, -1)
    if not is_enabled() then
        return
    end

    local cfg = get_git_cfg()
    local placement = cfg.placement or "right_align"
    if placement ~= "right_align" then
        return
    end

    local show_ignored_badges = config.current.filter and config.current.filter.gitignored == false
    local renderer = require("csharp-explorer.renderer")
    for line_num, node in pairs(renderer.line_to_node) do
        local status = M.get_node_status(node)
        if status and status.badge and (status.is_dirty or (show_ignored_badges and status.is_ignored)) then
            pcall(vim.api.nvim_buf_set_extmark, state.buf, M.ns_id, line_num - 1, 0, {
                virt_text = { { " " .. status.badge .. " ", status.badge_hl } },
                virt_text_pos = "right_align",
                hl_mode = "combine",
                priority = 140,
            })
        end
    end
end

local function tables_differ(a, b)
    for k in pairs(a) do
        if not b[k] then
            return true
        end
    end
    for k in pairs(b) do
        if not a[k] then
            return true
        end
    end
    return false
end

function M.scan_toplevel(toplevel, state, opts)
    local repo = repos[toplevel]
    if not repo or not is_enabled() then
        return
    end

    local cfg = get_git_cfg()
    local scan_opts = {
        gitdir = repo.gitdir,
        timeout = cfg.timeout or 400,
        max_timeouts = cfg.max_timeouts or 5,
        force = opts and opts.force == true,
    }

    local function apply_result(ok, result)
        if not ok or not repos[toplevel] then
            if opts and opts.on_complete then
                pcall(opts.on_complete, false)
            end
            return
        end

        local prev_ignored_dirs = repo.ignored_dirs
        local prev_ignored_files = repo.ignored_files

        for file_path in pairs(repo.files) do
            by_file[file_path] = nil
        end
        for dir_path in pairs(repo.dirs) do
            by_dir[dir_path] = nil
        end
        for ign_dir in pairs(repo.ignored_dirs) do
            ignored_dirs[ign_dir] = nil
        end

        repo.files = {}
        repo.dirs = {}
        repo.ignored_dirs = {}
        repo.ignored_files = {}

        if result.branch then
            repo.branch = result.branch
        end

        for _, rel_dir in ipairs(result.ignored_dirs or {}) do
            local abs_dir = metadata.normalize_path(toplevel .. "/" .. rel_dir)
            ignored_dirs[abs_dir] = toplevel
            repo.ignored_dirs[abs_dir] = true
        end

        for _, entry in ipairs(result.entries or {}) do
            local abs_path = metadata.normalize_path(toplevel .. "/" .. entry.path)
            local orig_abs = entry.orig_path and metadata.normalize_path(toplevel .. "/" .. entry.orig_path) or nil
            by_file[abs_path] = {
                xy = entry.xy,
                kind = entry.kind,
                prio = entry.prio,
                desc = entry.desc,
                is_deleted = entry.is_deleted,
                orig_path = orig_abs,
                toplevel = toplevel,
            }
            repo.files[abs_path] = true
            if entry.kind == "ignored" then
                repo.ignored_files[abs_path] = true
            end
        end

        for abs_path in pairs(repo.files) do
            local rec = by_file[abs_path]
            if rec and rec.prio < 7 then
                local file_dir = metadata.normalize_path(vim.fn.fnamemodify(abs_path, ":h"))
                local curr = file_dir
                while curr and curr ~= "" and curr ~= "/" do
                    local d_stat = by_dir[curr]
                    if not d_stat then
                        d_stat = {
                            kind = rec.kind,
                            prio = rec.prio,
                            desc = rec.desc,
                            has_deleted = rec.is_deleted == true,
                            direct_count = 0,
                            indirect_count = 0,
                            toplevel = toplevel,
                        }
                        by_dir[curr] = d_stat
                        repo.dirs[curr] = true
                    else
                        if rec.prio < d_stat.prio then
                            d_stat.prio = rec.prio
                            d_stat.kind = rec.kind
                            d_stat.desc = rec.desc
                        end
                        if rec.is_deleted then
                            d_stat.has_deleted = true
                        end
                    end

                    if curr == file_dir then
                        d_stat.direct_count = d_stat.direct_count + 1
                    end
                    d_stat.indirect_count = d_stat.indirect_count + 1

                    if curr == toplevel then
                        break
                    end
                    local parent = vim.fn.fnamemodify(curr, ":h")
                    if parent == curr then
                        break
                    end
                    curr = metadata.normalize_path(parent)
                end
            end
        end

        local was_unindexed = not repo.indexed
        repo.indexed = true

        local ignored_changed = tables_differ(prev_ignored_dirs, repo.ignored_dirs)
            or tables_differ(prev_ignored_files, repo.ignored_files)

        local eff_state = state or active_state
        if
            (was_unindexed or ignored_changed)
            and config.current.filter
            and config.current.filter.gitignored
            and eff_state
            and eff_state.tree
        then
            local function reconcile_projects(n)
                if n._type == "project" and n._dir then
                    local pdir = metadata.normalize_path(n._dir)
                    if pdir == toplevel or vim.startswith(pdir, toplevel .. "/") then
                        if n._git_ignore_pending or ignored_changed then
                            n._git_ignore_pending = nil
                            node_utils.reset_projects(n, { skip_git_refresh = true })
                        end
                    end
                    return
                end
                if n._children then
                    for _, child in pairs(n._children) do
                        reconcile_projects(child)
                    end
                end
            end
            reconcile_projects(eff_state.tree)
        end

        if eff_state and eff_state.is_active and eff_state.buf and vim.api.nvim_buf_is_valid(eff_state.buf) then
            require("csharp-explorer.renderer").render(eff_state)
        end

        if opts and opts.on_complete then
            pcall(opts.on_complete, true)
        end
    end

    scan_opts.on_rescan_done = apply_result
    runner.scan_repo(toplevel, scan_opts, apply_result)
end

function M.sync_tree(tree, state, on_all_done)
    if state then
        active_state = state
    end
    if not is_enabled() or not tree then
        if on_all_done then
            on_all_done()
        end
        return
    end

    local candidate_dirs = {}
    local seen_dirs = {}
    local function push_dir(d)
        if d and d ~= "" then
            local norm = metadata.normalize_path(d)
            if not seen_dirs[norm] then
                seen_dirs[norm] = true
                candidate_dirs[#candidate_dirs + 1] = norm
            end
        end
    end

    push_dir(tree._dir)
    if tree._path then
        push_dir(vim.fn.fnamemodify(tree._path, ":h"))
    end
    for _, pd in ipairs(node_utils.get_solution_project_dirs(tree)) do
        push_dir(pd)
    end

    local pending_discoveries = 0
    local to_scan = {}

    local function launch_scans()
        local scan_list = {}
        for top in pairs(to_scan) do
            scan_list[#scan_list + 1] = top
        end
        if #scan_list == 0 then
            if on_all_done then
                on_all_done()
            end
            return
        end
        local remaining = #scan_list
        for _, top in ipairs(scan_list) do
            M.scan_toplevel(top, state, {
                on_complete = function()
                    remaining = remaining - 1
                    if remaining == 0 and on_all_done then
                        on_all_done()
                    end
                end,
            })
        end
    end

    for _, dir in ipairs(candidate_dirs) do
        local cached = dir_to_toplevel[dir]
        if cached == nil then
            pending_discoveries = pending_discoveries + 1
            runner.discover_repo(dir, function(info)
                pending_discoveries = pending_discoveries - 1
                if info then
                    dir_to_toplevel[dir] = info.toplevel
                    if not repos[info.toplevel] then
                        repos[info.toplevel] = {
                            toplevel = info.toplevel,
                            gitdir = info.gitdir,
                            branch = info.branch,
                            indexed = false,
                            files = {},
                            dirs = {},
                            ignored_dirs = {},
                            ignored_files = {},
                        }
                        watcher.watch_gitdir(info.gitdir, function()
                            M.refresh_debounced()
                        end)
                        to_scan[info.toplevel] = true
                    elseif not repos[info.toplevel].indexed then
                        to_scan[info.toplevel] = true
                    end
                else
                    dir_to_toplevel[dir] = false
                end

                if pending_discoveries == 0 then
                    launch_scans()
                end
            end)
        elseif cached ~= false and repos[cached] and not repos[cached].indexed then
            to_scan[cached] = true
        end
    end

    if pending_discoveries == 0 then
        launch_scans()
    end
end

function M.refresh_debounced()
    if is_enabled() then
        watcher.trigger_debounced()
    end
end

function M.refresh(state, opts)
    opts = opts or {}
    local eff_state = state or active_state
    if not is_enabled() then
        if opts.on_complete then
            opts.on_complete()
        end
        return
    end
    if opts.force then
        runner.reset_breaker()
    end

    local function scan_existing()
        local list = {}
        for top in pairs(repos) do
            list[#list + 1] = top
        end
        if #list == 0 then
            if opts.on_complete then
                opts.on_complete()
            end
            return
        end
        local rem = #list
        for _, top in ipairs(list) do
            M.scan_toplevel(top, eff_state, {
                force = opts.force,
                on_complete = function()
                    rem = rem - 1
                    if rem == 0 and opts.on_complete then
                        opts.on_complete()
                    end
                end,
            })
        end
    end

    if eff_state and eff_state.tree then
        M.sync_tree(eff_state.tree, eff_state, scan_existing)
    else
        scan_existing()
    end
end

function M.attach(state)
    active_state = state
    if not is_enabled() then
        return
    end
    local cfg = get_git_cfg()
    watcher.attach(function()
        M.refresh(active_state)
    end, { debounce_ms = cfg.debounce_ms or 120 })

    if state and state.tree then
        M.sync_tree(state.tree, state)
    end
end

function M.detach()
    watcher.detach()
    runner.cancel_all()
    repos = {}
    dir_to_toplevel = {}
    by_file = {}
    by_dir = {}
    ignored_dirs = {}
    active_state = nil
end

return M

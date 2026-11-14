local csharp_source = require("csharp-explorer.csharp_source")
local metadata = require("csharp-explorer.metadata")
local node_utils = require("csharp-explorer.node")
local renderer = require("csharp-explorer.renderer")
local uv = vim.uv or vim.loop

local M = {}

local function read_file_bytes(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file_or_buffer(path, new_content)
    local norm_path = metadata.normalize_path(path)
    local f = io.open(norm_path, "wb")
    if f then
        f:write(new_content)
        f:close()
    end

    local bufnr = vim.fn.bufnr(norm_path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        local enc = csharp_source.detect_encoding(new_content)
        vim.bo[bufnr].bomb = enc.has_bom
        vim.bo[bufnr].fileformat = enc.has_crlf and "dos" or "unix"
        local clean_text = enc.raw:gsub("\r\n", "\n")
        local lines = vim.split(clean_text, "\n", { plain = true })
        if #lines > 0 and lines[#lines] == "" then
            lines[#lines] = nil
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].modified = false
    end
end

local EXCLUDED_DIRS = {
    bin = true,
    obj = true,
    [".git"] = true,
    [".vs"] = true,
    [".idea"] = true,
    node_modules = true,
}

function M.collect_cs_files_in_dir(dir_path)
    local files = {}
    local stack = { metadata.normalize_path(dir_path) }

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
                elseif ftype == "file" and vim.endswith(name, ".cs") then
                    files[#files + 1] = cur .. "/" .. name
                end
            end
        end
    end

    table.sort(files)
    return files
end

function M.inject_usings_across_solution(tree, transitions, exclude_paths)
    if not transitions or #transitions == 0 then
        return 0
    end
    local exclude_set = {}
    if exclude_paths then
        for _, p in ipairs(exclude_paths) do
            exclude_set[metadata.normalize_path(p)] = true
        end
    end

    local project_dirs = node_utils.get_solution_project_dirs(tree)
    local all_files = {}
    for _, pdir in ipairs(project_dirs) do
        local found = M.collect_cs_files_in_dir(pdir)
        for _, f in ipairs(found) do
            if not exclude_set[f] then
                all_files[#all_files + 1] = f
            end
        end
    end

    local updated_count = 0
    for _, fpath in ipairs(all_files) do
        local content = read_file_bytes(fpath)
        if content and content ~= "" then
            local modified = false
            for _, tr in ipairs(transitions) do
                if
                    tr.types
                    and #tr.types > 0
                    and tr.new_ns
                    and tr.old_ns ~= tr.new_ns
                    and csharp_source.references_any_type(content, tr.types)
                then
                    local new_content, changed = csharp_source.inject_using(content, tr.new_ns)
                    if changed then
                        content = new_content
                        modified = true
                    end
                end
            end
            if modified then
                M.write_file_or_buffer(fpath, content)
                updated_count = updated_count + 1
            end
        end
    end

    return updated_count
end

function M.sync_file(file_path, tree, opts)
    local norm_path = metadata.normalize_path(file_path)
    local content = read_file_bytes(norm_path)
    if not content or content == "" then
        return { changed = false, status = "read_failed", consumers_updated = 0 }
    end

    local proj_node = metadata.find_owning_project(norm_path, tree)
    local expected_ns = metadata.infer_expected_namespace(norm_path, proj_node)
    if not expected_ns then
        return { changed = false, status = "no_expected_namespace", consumers_updated = 0 }
    end

    local declared_ns = csharp_source.extract_namespace(content)
    if not declared_ns then
        return { changed = false, status = "no_namespace", consumers_updated = 0 }
    end

    local force = opts and opts.force == true
    local old_expected_ns = force and nil or (opts and opts.old_expected_ns or nil)
    local updated_content, changed, reason = csharp_source.rewrite_namespace(content, expected_ns, old_expected_ns)

    if not changed then
        return {
            changed = false,
            status = reason or "unchanged",
            old_ns = declared_ns,
            new_ns = declared_ns,
            consumers_updated = 0,
        }
    end

    M.write_file_or_buffer(norm_path, updated_content)

    local consumers = 0
    if opts == nil or opts.inject_usings ~= false then
        local declared_types = csharp_source.extract_declared_types(updated_content)
        local type_names = {}
        for _, t in ipairs(declared_types) do
            type_names[#type_names + 1] = t.name
        end
        if #type_names > 0 and declared_ns ~= expected_ns then
            consumers = M.inject_usings_across_solution(tree, {
                { old_ns = declared_ns, new_ns = expected_ns, types = type_names },
            }, { norm_path })
        end
    end

    return {
        changed = true,
        status = "synced",
        old_ns = declared_ns,
        new_ns = expected_ns,
        consumers_updated = consumers,
    }
end

function M.sync_directory(dir_path, tree, opts)
    local norm_dir = metadata.normalize_path(dir_path)
    local files = M.collect_cs_files_in_dir(norm_dir)
    local stats = {
        synced = 0,
        unchanged = 0,
        divergent = 0,
        consumers_updated = 0,
    }

    local transitions = {}
    local synced_paths = {}

    for _, fpath in ipairs(files) do
        local file_opts = {}
        if opts and opts.force then
            file_opts.force = true
        elseif opts and opts.old_dir and opts.old_project_node then
            local rel = fpath:sub(#norm_dir + 2)
            local old_fpath = opts.old_dir .. "/" .. rel
            file_opts.old_expected_ns = metadata.infer_expected_namespace(old_fpath, opts.old_project_node)
        elseif opts and opts.old_expected_ns then
            file_opts.old_expected_ns = opts.old_expected_ns
        end
        file_opts.inject_usings = false

        local res = M.sync_file(fpath, tree, file_opts)
        if res.changed then
            stats.synced = stats.synced + 1
            synced_paths[#synced_paths + 1] = fpath
            local content = read_file_bytes(fpath)
            local types = content and csharp_source.extract_declared_types(content) or {}
            local type_names = {}
            for _, t in ipairs(types) do
                type_names[#type_names + 1] = t.name
            end
            if #type_names > 0 and res.old_ns ~= res.new_ns then
                transitions[#transitions + 1] = {
                    old_ns = res.old_ns,
                    new_ns = res.new_ns,
                    types = type_names,
                }
            end
        elseif res.status == "divergent" then
            stats.divergent = stats.divergent + 1
        else
            stats.unchanged = stats.unchanged + 1
        end
    end

    if (opts == nil or opts.inject_usings ~= false) and #transitions > 0 then
        stats.consumers_updated = M.inject_usings_across_solution(tree, transitions, synced_paths)
    end

    return stats
end

local function resolve_sync_target(state, opts)
    if opts and opts.node then
        local node = opts.node
        while node and node._virtual and node._parent do
            node = node._parent
        end
        return node
    end
    local navigation = require("csharp-explorer.actions.navigation")
    local in_explorer = state
        and state.win
        and vim.api.nvim_win_is_valid(state.win)
        and vim.api.nvim_get_current_win() == state.win
    if in_explorer then
        local node = navigation.get_node(state)
        if node then
            while node and node._virtual and node._parent do
                node = node._parent
            end
            return node
        end
    end

    local cur_buf = vim.api.nvim_get_current_buf()
    local bname = vim.api.nvim_buf_get_name(cur_buf)
    if bname and bname ~= "" and vim.endswith(bname, ".cs") then
        return {
            _type = "cs_file",
            _path = metadata.normalize_path(bname),
            _name = vim.fn.fnamemodify(bname, ":t"),
        }
    end
    return nil
end

function M.sync_target(state, opts)
    opts = opts or {}
    local tree = state and (state.ensure_tree and state.ensure_tree() or state.tree)
    local target = resolve_sync_target(state, opts)
    if not target then
        vim.notify("No valid target found for namespace sync", vim.log.levels.WARN)
        if opts.on_complete then
            opts.on_complete({ synced = 0, unchanged = 0, divergent = 0, consumers_updated = 0 })
        end
        return
    end

    local force = not opts.respect_divergence
    local stats = { synced = 0, unchanged = 0, divergent = 0, consumers_updated = 0 }

    if target._type == "cs_file" or target._type == "file" or (target._path and vim.endswith(target._path, ".cs")) then
        local res = M.sync_file(target._path, tree, { force = force })
        if res.changed then
            stats.synced = 1
            stats.consumers_updated = res.consumers_updated
        elseif res.status == "divergent" then
            stats.divergent = 1
        else
            stats.unchanged = 1
        end
    elseif target._type == "folder" and target._dir then
        stats = M.sync_directory(target._dir, tree, { force = force })
    elseif target._type == "project" and target._dir then
        stats = M.sync_directory(target._dir, tree, { force = force })
    elseif
        target._type == "solution"
        or target._type == "solution_folder"
        or (target._type == "folder" and not target._dir)
    then
        local pdirs = node_utils.get_solution_project_dirs(target)
        for _, pdir in ipairs(pdirs) do
            local dir_stats = M.sync_directory(pdir, tree, { force = force })
            stats.synced = stats.synced + dir_stats.synced
            stats.unchanged = stats.unchanged + dir_stats.unchanged
            stats.divergent = stats.divergent + dir_stats.divergent
            stats.consumers_updated = stats.consumers_updated + dir_stats.consumers_updated
        end
    else
        vim.notify("Namespace sync not supported for target type: " .. tostring(target._type), vim.log.levels.WARN)
        return
    end

    if state and state.tree and state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
        renderer.render(state)
    end

    local msg = string.format(
        "Namespace sync complete: %d synced, %d unchanged, %d divergent, %d consumer(s) updated",
        stats.synced,
        stats.unchanged,
        stats.divergent,
        stats.consumers_updated
    )
    vim.notify(msg, vim.log.levels.INFO)

    if opts.on_complete then
        opts.on_complete(stats)
    end
    return stats
end

return M

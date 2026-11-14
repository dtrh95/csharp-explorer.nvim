local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local nesting = require("csharp-explorer.nesting")
local uv = vim.uv or vim.loop

local M = {}

M.FILE_NODE_TYPES = {
    cs_file = true,
    appsettings = true,
    dockerfile = true,
    http_file = true,
    cshtml_file = true,
    razor_file = true,
    css_file = true,
    xaml_file = true,
    resx_file = true,
    launch_settings = true,
}

M.NODE_PRIORITIES = {
    solution = 0,
    dependencies = 10,
    package_group = 20,
    project_reference_group = 21,
    folder = 30,
    project = 35,
    cs_file = 40,
    appsettings = 40,
    dockerfile = 40,
    http_file = 40,
    cshtml_file = 40,
    razor_file = 40,
    css_file = 40,
    xaml_file = 40,
    resx_file = 40,
    launch_settings = 40,
    package = 40,
    project_reference = 40,
}

function M.get_priority(node)
    if not node then
        return M.NODE_PRIORITIES.cs_file
    end
    return node._sort_priority or M.NODE_PRIORITIES[node._type] or M.NODE_PRIORITIES.cs_file
end

function M.is_file(node)
    return node ~= nil and M.FILE_NODE_TYPES[node._type] == true
end

function M.is_directory(node)
    return node ~= nil
        and not node._virtual
        and (node._type == "folder" or node._type == "project" or node._type == "solution")
end

function M.can_expand(node)
    return node ~= nil and node._has_children == true
end

function M.is_nested_parent(node)
    return M.is_file(node) and node._has_children == true
end

function M.classify_file_type(f_name)
    local lower = f_name:lower()
    if lower == "launchsettings.json" then
        return "launch_settings"
    elseif lower:match("^appsettings.*%.json$") then
        return "appsettings"
    elseif lower == "dockerfile" or lower:match("^dockerfile%..+$") or lower == ".dockerignore" then
        return "dockerfile"
    elseif lower:match("%.http$") then
        return "http_file"
    elseif lower:match("%.cshtml$") or lower:match("%.cshtml%.cs$") then
        return lower:match("%.cshtml%.cs$") and "cs_file" or "cshtml_file"
    elseif lower:match("%.razor$") or lower:match("%.razor%.cs$") then
        return lower:match("%.razor%.cs$") and "cs_file" or "razor_file"
    elseif lower:match("%.css$") then
        return "css_file"
    elseif lower:match("%.xaml$") or lower:match("%.xaml%.cs$") then
        return lower:match("%.xaml%.cs$") and "cs_file" or "xaml_file"
    elseif lower:match("%.resx$") or lower:match("%.designer%.cs$") then
        return (lower:match("%.designer%.cs$") or lower:match("%.cs$")) and "cs_file" or "resx_file"
    elseif lower:match("%.cs$") then
        return "cs_file"
    end
    return "cs_file"
end

local function get_gitignored_set(dir, files)
    if #files == 0 then
        return {}
    end
    local input = table.concat(files, "\n")
    local result = vim.fn.system("cd " .. vim.fn.shellescape(dir) .. " && git check-ignore --stdin", input)
    local ignored = {}
    if vim.v.shell_error == 0 then
        for line in result:gmatch("[^\r\n]+") do
            ignored[line] = true
        end
    end
    return ignored
end

local function prune_empty_folders(node, ignored)
    if not node._children then
        return
    end
    for key, child in pairs(node._children) do
        if child._type == "folder" then
            prune_empty_folders(child, ignored)
            if not next(child._children) and (not child._dir or (ignored and ignored[child._dir])) then
                node._children[key] = nil
            end
        end
    end
end

local function snapshot_children(node, prefix, saved)
    if not node._children then
        return
    end
    for k, child in pairs(node._children) do
        local key = prefix == "" and k or (prefix .. "/" .. k)
        if child._expanded then
            saved[key] = true
        end
        snapshot_children(child, key, saved)
    end
end

local function restore_saved_expanded(node, prefix, saved)
    if not saved or not node._children then
        return
    end
    for k, child in pairs(node._children) do
        local key = prefix == "" and k or (prefix .. "/" .. k)
        if saved[key] then
            child._expanded = true
        end
        restore_saved_expanded(child, key, saved)
    end
end

function M.snapshot_tree_expansion(tree)
    local state = {
        nodes = {},
        projects = {},
    }
    if not tree then
        return state
    end

    local function walk(node, prefix)
        if node._type == "project" and node._path then
            local norm = metadata.normalize_path(node._path):lower()
            local proj_saved = node._saved_expanded and vim.deepcopy(node._saved_expanded) or {}
            snapshot_children(node, "", proj_saved)
            state.projects[norm] = {
                expanded = node._expanded == true,
                children = proj_saved,
            }
            return
        end
        if node._children then
            for k, child in pairs(node._children) do
                local key = prefix == "" and k or (prefix .. "/" .. k)
                if child._expanded then
                    state.nodes[key] = true
                end
                walk(child, key)
            end
        end
    end

    walk(tree, "")
    return state
end

function M.restore_tree_expansion(tree, snapshot)
    if not tree or not snapshot then
        return
    end

    local function walk(node, prefix)
        if node._type == "project" and node._path then
            local norm = metadata.normalize_path(node._path):lower()
            local p_state = snapshot.projects[norm]
            if p_state then
                node._expanded = p_state.expanded
                node._saved_expanded = p_state.children
            end
            return
        end
        if node._children then
            for k, child in pairs(node._children) do
                local key = prefix == "" and k or (prefix .. "/" .. k)
                if snapshot.nodes[key] then
                    child._expanded = true
                end
                walk(child, key)
            end
        end
    end

    walk(tree, "")
end

function M.collect_solution_projects(root)
    local projects = {}
    local function traverse(n)
        if n._type == "project" and n._path then
            projects[metadata.normalize_path(n._path)] = true
        end
        if n._children then
            for _, child in pairs(n._children) do
                traverse(child)
            end
        end
    end
    if root then
        traverse(root)
    end
    return projects
end

local function is_supported_project_file(name)
    local lower = name:lower()
    if lower:sub(-3) == ".cs" then
        return true
    end
    if
        lower:sub(-7) == ".cshtml"
        or lower:sub(-6) == ".razor"
        or lower:sub(-10) == ".razor.css"
        or lower:sub(-5) == ".xaml"
        or lower:sub(-5) == ".resx"
        or lower:sub(-5) == ".http"
    then
        return true
    end
    if lower == "launchsettings.json" then
        return true
    end
    if lower:match("^appsettings.*%.json$") then
        return true
    end
    if name == "Dockerfile" or vim.startswith(name, "Dockerfile.") or name == ".dockerignore" then
        return true
    end
    return false
end

local IGNORED_SCAN_DIRS = {
    [".git"] = true,
    [".vs"] = true,
    [".idea"] = true,
    bin = true,
    obj = true,
    node_modules = true,
}

local function scan_project_files(root_dir)
    local files = {}
    local dirs = {}
    local norm_root = metadata.normalize_path(root_dir)
    local stack = { norm_root }
    while #stack > 0 do
        local curr = stack[#stack]
        stack[#stack] = nil
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
                        dirs[#dirs + 1] = full
                    end
                elseif ftype == "file" and is_supported_project_file(name) then
                    files[#files + 1] = full
                end
            end
        end
    end
    return files, dirs
end

function M.populate_cs_files(node)
    if node._type ~= "project" or node._cs_loaded then
        return
    end

    local files, dirs = scan_project_files(node._dir)

    local ignored = {}
    if config.current.filter.gitignored then
        local all_scan = {}
        for _, f in ipairs(files) do
            all_scan[#all_scan + 1] = f
        end
        for _, d in ipairs(dirs) do
            all_scan[#all_scan + 1] = d
        end
        ignored = get_gitignored_set(node._dir, all_scan)
    end

    local by_dir = {}
    local dir_order = {}
    local norm_node_dir = metadata.normalize_path(node._dir)

    for _, d in ipairs(dirs) do
        local norm_d = metadata.normalize_path(d)
        if not by_dir[norm_d] then
            by_dir[norm_d] = {}
            table.insert(dir_order, norm_d)
        end
    end

    for _, f in ipairs(files) do
        if not ignored[f] then
            local file_dir = metadata.normalize_path(vim.fn.fnamemodify(f, ":h"))
            local f_name = vim.fn.fnamemodify(f, ":t")
            if not by_dir[file_dir] then
                by_dir[file_dir] = {}
                table.insert(dir_order, file_dir)
            end
            table.insert(by_dir[file_dir], f_name)
        end
    end

    table.sort(dir_order, function(a, b)
        return #a < #b
    end)

    local nesting_enabled = not (config.current.nesting and config.current.nesting.enabled == false)
    local expand_nested = (config.current.nesting and config.current.nesting.expand_by_default == true)

    for _, dir_path in ipairs(dir_order) do
        local parent_container = node
        if dir_path ~= norm_node_dir then
            local rel_dir = dir_path:sub(#norm_node_dir + 2)
            local current_dir = norm_node_dir
            for part in rel_dir:gmatch("[^/]+") do
                current_dir = current_dir .. "/" .. part
                parent_container._children[part] = parent_container._children[part]
                    or {
                        _children = {},
                        _name = part,
                        _type = "folder",
                        _expanded = false,
                        _has_children = true,
                        _dir = current_dir,
                        _sort_priority = M.NODE_PRIORITIES.folder,
                    }
                parent_container = parent_container._children[part]
            end
        end

        local dir_files = by_dir[dir_path]
        local partition
        if nesting_enabled then
            local custom_rules = config.current.nesting and config.current.nesting.rules
            partition = nesting.partition_directory_files(dir_files, custom_rules)
        else
            partition = {
                top_level = dir_files,
                children_by_parent = {},
            }
        end

        for _, name in ipairs(partition.top_level) do
            local f_type = M.classify_file_type(name)
            local f_path = dir_path .. "/" .. name
            local nested_children = partition.children_by_parent[name]
            local has_nested = nested_children ~= nil and #nested_children > 0

            local file_node = {
                _children = {},
                _name = name,
                _type = f_type,
                _expanded = has_nested and expand_nested or false,
                _path = f_path,
                _has_children = has_nested,
                _sort_priority = M.NODE_PRIORITIES[f_type] or M.NODE_PRIORITIES.cs_file,
            }

            if has_nested then
                for _, child_name in ipairs(nested_children) do
                    local child_type = M.classify_file_type(child_name)
                    local child_path = dir_path .. "/" .. child_name
                    file_node._children[child_name] = {
                        _children = {},
                        _name = child_name,
                        _type = child_type,
                        _expanded = false,
                        _path = child_path,
                        _has_children = false,
                        _sort_priority = M.NODE_PRIORITIES[child_type] or M.NODE_PRIORITIES.cs_file,
                    }
                end
            end

            parent_container._children[name] = file_node
        end
    end

    if config.current.filter.gitignored then
        prune_empty_folders(node, ignored)
    end

    if node._saved_expanded then
        restore_saved_expanded(node, "", node._saved_expanded)
    end

    node._cs_loaded = true
end

function M.populate_dependencies(project_node, root_node)
    if project_node._type ~= "project" or project_node._meta_loaded then
        return
    end

    local solution_projects = M.collect_solution_projects(root_node)
    local meta = metadata.get_project_metadata(project_node._path, solution_projects)

    local dep_container = {
        _children = {},
        _name = "Dependencies",
        _type = "dependencies",
        _expanded = false,
        _has_children = true,
        _virtual = true,
        _sort_priority = M.NODE_PRIORITIES.dependencies,
    }

    local pkg_group = {
        _children = {},
        _name = "Packages",
        _type = "package_group",
        _expanded = false,
        _has_children = true,
        _virtual = true,
        _sort_priority = M.NODE_PRIORITIES.package_group,
    }

    local package_count = 0
    for pkg_id, pkg in pairs(meta.packages) do
        package_count = package_count + 1
        local display_version = pkg.resolved_version or pkg.version
        local label = pkg_id
        if display_version and display_version ~= "" then
            label = string.format("%s (%s)", pkg_id, display_version)
        end

        pkg_group._children[pkg_id] = {
            _children = {},
            _name = label,
            _type = "package",
            _expanded = false,
            _has_children = false,
            _virtual = true,
            _sort_priority = M.NODE_PRIORITIES.package,
            _package_info = pkg,
        }
    end

    if package_count > 0 then
        dep_container._children["Packages"] = pkg_group
    end

    local ref_group = {
        _children = {},
        _name = "Projects",
        _type = "project_reference_group",
        _expanded = false,
        _has_children = true,
        _virtual = true,
        _sort_priority = M.NODE_PRIORITIES.project_reference_group,
    }

    local ref_count = 0
    for target_path, ref in pairs(meta.project_references) do
        ref_count = ref_count + 1
        local label = ref.in_solution and ref.name or string.format("%s (external)", ref.name)

        ref_group._children[ref.name] = {
            _children = {},
            _name = label,
            _type = "project_reference",
            _expanded = false,
            _has_children = false,
            _virtual = true,
            _sort_priority = M.NODE_PRIORITIES.project_reference,
            _target_path = target_path,
            _project_ref_info = ref,
        }
    end

    if ref_count > 0 then
        dep_container._children["Projects"] = ref_group
    end

    if package_count > 0 or ref_count > 0 then
        project_node._children["Dependencies"] = dep_container
    end

    if project_node._saved_expanded then
        restore_saved_expanded(project_node, "", project_node._saved_expanded)
    end

    project_node._meta_loaded = true
end

function M.reset_projects(node)
    if node._type == "project" then
        node._archetype = nil
        if node._cs_loaded or node._meta_loaded then
            local saved = {}
            if node._saved_expanded then
                for k, v in pairs(node._saved_expanded) do
                    local is_dep_key = (k == "Dependencies" or vim.startswith(k, "Dependencies/"))
                    if (is_dep_key and not node._meta_loaded) or (not is_dep_key and not node._cs_loaded) then
                        saved[k] = v
                    end
                end
            end
            snapshot_children(node, "", saved)
            node._saved_expanded = saved

            node._children = {}
            node._cs_loaded = false
            node._meta_loaded = false
        end
    elseif node._children then
        for _, child in pairs(node._children) do
            M.reset_projects(child)
        end
    end
end

function M.get_solution_project_dirs(root)
    local dirs = {}
    if not root then
        return dirs
    end
    local visited = {}
    local function walk(node)
        if node._type == "project" and node._dir then
            local norm = metadata.normalize_path(node._dir)
            if not visited[norm] then
                visited[norm] = true
                dirs[#dirs + 1] = norm
            end
        end
        if node._children then
            for _, child in pairs(node._children) do
                walk(child)
            end
        end
    end
    walk(root)
    table.sort(dirs)
    return dirs
end

function M.rekey_relative_map(map, old_rel, new_rel)
    local out = {}
    if not map then
        return out
    end
    for k, v in pairs(map) do
        if k == old_rel then
            out[new_rel] = v
        elseif vim.startswith(k, old_rel .. "/") then
            out[new_rel .. k:sub(#old_rel + 1)] = v
        else
            out[k] = v
        end
    end
    return out
end

function M.rekey_expansion_snapshot(snapshot, opts)
    if not snapshot then
        return { nodes = {}, projects = {} }
    end
    opts = opts or {}
    local nodes = snapshot.nodes or {}
    if opts.old_node_prefix and opts.new_node_prefix then
        nodes = M.rekey_relative_map(nodes, opts.old_node_prefix, opts.new_node_prefix)
    end

    local projects = {}
    local old_p = opts.old_proj_csproj and metadata.normalize_path(opts.old_proj_csproj):lower() or nil
    local new_p = opts.new_proj_csproj and metadata.normalize_path(opts.new_proj_csproj):lower() or nil
    local target_p = opts.project_csproj and metadata.normalize_path(opts.project_csproj):lower() or nil

    for k, p_state in pairs(snapshot.projects or {}) do
        local out_key = k
        if old_p and new_p then
            if k == old_p then
                out_key = new_p
            elseif vim.startswith(k, old_p .. "/") then
                out_key = new_p .. k:sub(#old_p + 1)
            end
        end
        local children = p_state.children or {}
        if opts.old_rel and opts.new_rel and (not target_p or k == target_p or out_key == target_p) then
            children = M.rekey_relative_map(children, opts.old_rel, opts.new_rel)
        end
        projects[out_key] = {
            expanded = p_state.expanded,
            children = children,
        }
    end

    return {
        nodes = nodes,
        projects = projects,
    }
end

return M

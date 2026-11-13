local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")

local M = {}

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
    package = 40,
    project_reference = 40,
}

function M.get_priority(node)
    if not node then
        return M.NODE_PRIORITIES.cs_file
    end
    return node._sort_priority or M.NODE_PRIORITIES[node._type] or M.NODE_PRIORITIES.cs_file
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

local function prune_empty_folders(node)
    if not node._children then
        return
    end
    for key, child in pairs(node._children) do
        if child._type == "folder" then
            prune_empty_folders(child)
            if not next(child._children) then
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

function M.populate_cs_files(node)
    if node._type ~= "project" or node._cs_loaded then
        return
    end
    local cs_files = vim.fn.glob(node._dir .. "/**/*.cs", false, true)
    local appsettings_files = vim.fn.glob(node._dir .. "/**/appsettings*.json", false, true)
    local dockerfiles = vim.fn.glob(node._dir .. "/**/Dockerfile", false, true)
    local http_files = vim.fn.glob(node._dir .. "/**/*.http", false, true)

    local files = {}
    vim.list_extend(files, cs_files)
    vim.list_extend(files, appsettings_files)
    vim.list_extend(files, dockerfiles)
    vim.list_extend(files, http_files)

    local ignored = {}
    if config.current.filter.gitignored then
        ignored = get_gitignored_set(node._dir, files)
    end

    for _, f in ipairs(files) do
        if not ignored[f] then
            local rel = string.sub(f, string.len(node._dir) + 2)
            local parts = {}
            for part in string.gmatch(rel, "[^/]+") do
                table.insert(parts, part)
            end

            local current = node
            local current_dir = node._dir
            for i = 1, #parts - 1 do
                local part = parts[i]
                current_dir = current_dir .. "/" .. part
                current._children[part] = current._children[part]
                    or {
                        _children = {},
                        _name = part,
                        _type = "folder",
                        _expanded = false,
                        _has_children = true,
                        _dir = current_dir,
                        _sort_priority = M.NODE_PRIORITIES.folder,
                    }
                current = current._children[part]
            end
            local f_name = parts[#parts]

            local f_type = "cs_file"
            if string.match(f_name, "^appsettings.*%.json$") then
                f_type = "appsettings"
            elseif string.match(f_name, "^Dockerfile$") then
                f_type = "dockerfile"
            elseif string.match(f_name, "%.http$") then
                f_type = "http_file"
            end

            current._children[f_name] = {
                _children = {},
                _name = f_name,
                _type = f_type,
                _expanded = false,
                _path = f,
                _has_children = false,
                _sort_priority = M.NODE_PRIORITIES[f_type] or M.NODE_PRIORITIES.cs_file,
            }
        end
    end

    if config.current.filter.gitignored then
        prune_empty_folders(node)
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

return M

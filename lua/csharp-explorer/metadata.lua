local uv = vim.uv or vim.loop

local M = {
    _cache = {},
}

function M.normalize_path(path)
    if not path or path == "" then
        return ""
    end
    local p = path:gsub("\\", "/"):gsub("//+", "/")
    if #p > 1 and p:sub(-1) == "/" then
        p = p:sub(1, -2)
    end
    return p
end

function M.resolve_path(base_dir, rel_path)
    if not rel_path or rel_path == "" then
        return M.normalize_path(base_dir)
    end
    local norm_rel = M.normalize_path(rel_path)
    local norm_base = M.normalize_path(base_dir)

    local combined = norm_rel
    if norm_rel:sub(1, 1) ~= "/" then
        combined = norm_base .. "/" .. norm_rel
    end

    local segments = {}
    for seg in combined:gmatch("[^/]+") do
        if seg == ".." then
            if #segments > 0 and segments[#segments] ~= ".." then
                table.remove(segments)
            else
                table.insert(segments, "..")
            end
        elseif seg ~= "." and seg ~= "" then
            table.insert(segments, seg)
        end
    end

    local canonical = "/" .. table.concat(segments, "/")
    if uv.fs_stat(canonical) then
        return canonical
    end

    local current = "/"
    for _, seg in ipairs(segments) do
        local candidate = current == "/" and ("/" .. seg) or (current .. "/" .. seg)
        if uv.fs_stat(candidate) then
            current = candidate
        else
            local matched = nil
            local handle = uv.fs_scandir(current)
            if handle then
                local lower_seg = seg:lower()
                while true do
                    local name = uv.fs_scandir_next(handle)
                    if not name then
                        break
                    end
                    if name:lower() == lower_seg then
                        matched = name
                        break
                    end
                end
            end
            if matched then
                current = current == "/" and ("/" .. matched) or (current .. "/" .. matched)
            else
                current = candidate
            end
        end
    end

    return current
end

local function stat_stamp(path)
    local st = uv.fs_stat(path)
    if not st or not st.mtime then
        return "missing"
    end
    return string.format("%d:%d:%d", st.mtime.sec or 0, st.mtime.nsec or 0, st.size or 0)
end

local function sanitize_version(ver)
    if not ver or ver == "" then
        return ""
    end
    local v = ver:match("^%s*[%[%(]%s*(.-)%s*[%]%)]?%s*$") or ver
    local first = v:match("^([^,]+)")
    if first then
        v = first
    end
    v = v:gsub("[%[%]%(%)]", "")
    return (v:match("^%s*(.-)%s*$") or "")
end

local function build_lower_set(solution_projects)
    local lower = {}
    for p, enabled in pairs(solution_projects or {}) do
        if enabled then
            lower[M.normalize_path(p):lower()] = true
        end
    end
    return lower
end

local function strip_xml_comments(xml)
    return xml:gsub("<!%-%-.-%-%->", "")
end

local function interpolate_properties(val, properties)
    if not val or not val:find("%$%(") then
        return val or ""
    end
    local res = val
    local depth = 0
    while depth < 5 and res:find("%$%(") do
        res = res:gsub("%$%(([%w_%.]+)%)", function(prop)
            return properties[prop] or ""
        end)
        depth = depth + 1
    end
    return res
end

local function each_xml_element(content, tag_name, fn)
    local self_closing_pattern = "<" .. tag_name .. "%s+([^>]-)/>"
    local paired_pattern = "<" .. tag_name .. "%s+([^>]-)>(.-)</" .. tag_name .. ">"
    local without_self_closing = content:gsub(self_closing_pattern, function(attrs)
        fn(attrs, nil)
        return ""
    end)
    for attrs, inner in without_self_closing:gmatch(paired_pattern) do
        fn(attrs, inner)
    end
end

local function extract_target_frameworks(properties)
    local tfms = {}
    local raw = properties["TargetFrameworks"] or properties["TargetFramework"] or ""
    for tfm in raw:gmatch("[^;%s]+") do
        table.insert(tfms, tfm)
    end
    return tfms
end

local function evaluate_xml_file(file_path, inherited_props, cpm_versions, visited)
    local properties = vim.deepcopy(inherited_props or {})
    local packages = {}
    local project_refs = {}

    local f = io.open(file_path, "r")
    if not f then
        return { properties = properties, packages = packages, project_refs = project_refs }
    end
    local raw_content = f:read("*a")
    f:close()

    local content = strip_xml_comments(raw_content)
    local file_dir = M.normalize_path(vim.fn.fnamemodify(file_path, ":h"))
    properties["MSBuildThisFileDirectory"] = file_dir .. "/"

    for prop_tag, prop_val in content:gmatch("<([%w_%.]+)>([^<]+)</[%w_%.]+>") do
        local lower_tag = prop_tag:lower()
        if lower_tag ~= "packagereference" and lower_tag ~= "projectreference" and lower_tag ~= "packageversion" then
            properties[prop_tag] = interpolate_properties(prop_val, properties)
        end
    end

    each_xml_element(content, "PackageVersion", function(tag_body, inner)
        local name = tag_body:match('Include="([^"]+)"') or tag_body:match('Update="([^"]+)"')
        local ver = tag_body:match('Version="([^"]+)"') or (inner and inner:match("<Version>([^<]+)</Version>"))
        if name and ver then
            local clean_v = sanitize_version(interpolate_properties(ver, properties))
            cpm_versions[name:lower()] = { id = name, version = clean_v }
        end
    end)

    for import_path in content:gmatch('<Import%s+[^>]*Project="([^"]+)"') do
        local interpolated = interpolate_properties(import_path, properties)
        if interpolated ~= "" then
            local resolved = M.resolve_path(file_dir, interpolated)
            if not visited[resolved] then
                visited[resolved] = true
                if uv.fs_stat(resolved) then
                    local imported = evaluate_xml_file(resolved, properties, cpm_versions, visited)
                    for k, v in pairs(imported.properties) do
                        properties[k] = v
                    end
                    for k, v in pairs(imported.packages) do
                        packages[k] = v
                    end
                    for k, v in pairs(imported.project_refs) do
                        project_refs[k] = v
                    end
                end
            end
        end
    end

    local function record_package(tag_body, inner)
        local name = tag_body:match('Include="([^"]+)"') or tag_body:match('Update="([^"]+)"')
        if not name then
            return
        end
        local ver = tag_body:match('Version="([^"]+)"') or (inner and inner:match("<Version>([^<]+)</Version>"))
        local is_cpm = false
        if not ver or ver == "" then
            local cpm = cpm_versions[name:lower()]
            if cpm then
                ver = cpm.version
                is_cpm = true
            else
                ver = ""
            end
        else
            ver = sanitize_version(interpolate_properties(ver, properties))
        end
        packages[name] = {
            name = name,
            version = ver,
            resolved_version = ver ~= "" and ver or nil,
            is_direct = true,
            is_cpm = is_cpm,
        }
    end

    each_xml_element(content, "PackageReference", record_package)

    for tag_body in content:gmatch("<ProjectReference%s+([^>]+)>") do
        local include = tag_body:match('Include="([^"]+)"')
        if include and not include:find("@%(") then
            local interpolated = interpolate_properties(include, properties)
            if interpolated ~= "" then
                local resolved = M.resolve_path(file_dir, interpolated)
                project_refs[resolved] = include
            end
        end
    end

    return {
        properties = properties,
        packages = packages,
        project_refs = project_refs,
    }
end

local function find_ancestor_props(start_dir)
    local ancestors = {}
    local curr = M.normalize_path(start_dir)
    while curr and curr ~= "" and curr ~= "/" do
        local pkg_props = curr .. "/Directory.Packages.props"
        if uv.fs_stat(pkg_props) then
            table.insert(ancestors, 1, pkg_props)
        end
        local build_props = curr .. "/Directory.Build.props"
        if uv.fs_stat(build_props) then
            table.insert(ancestors, 1, build_props)
        end
        local parent = vim.fn.fnamemodify(curr, ":h")
        if parent == curr then
            break
        end
        curr = parent
    end
    return ancestors
end

function M.get_project_metadata(csproj_path, solution_projects)
    local norm_path = M.normalize_path(csproj_path)
    local solution_lower = build_lower_set(solution_projects)

    local project_dir = vim.fn.fnamemodify(norm_path, ":h")
    local assets_file = project_dir .. "/obj/project.assets.json"
    local csproj_stamp = stat_stamp(norm_path)
    local assets_stamp = stat_stamp(assets_file)

    local cached = M._cache[norm_path]
    if cached and cached.csproj_stamp == csproj_stamp and cached.assets_stamp == assets_stamp then
        local refreshed_refs = {}
        for k, ref in pairs(cached.data.project_references) do
            refreshed_refs[k] = vim.tbl_extend("force", ref, {
                in_solution = solution_lower[k:lower()] == true,
            })
        end
        cached.data.project_references = refreshed_refs
        return cached.data
    end

    local is_restored = false
    local packages = {}
    local project_references = {}
    local tfms = {}

    if assets_stamp ~= "missing" then
        local f = io.open(assets_file, "r")
        if f then
            local content = f:read("*a")
            f:close()
            local ok, json = pcall(vim.json.decode, content)
            if ok and type(json) == "table" and type(json.project) == "table" then
                is_restored = true
                local lower_to_id = {}

                local frameworks = vim.tbl_get(json, "project", "frameworks") or {}
                for tfm, tfm_data in pairs(frameworks) do
                    table.insert(tfms, tfm)
                    local deps = tfm_data.dependencies or {}
                    for pkg_name, pkg_def in pairs(deps) do
                        local target_type = pkg_def.target or "Package"
                        local is_auto = pkg_def.autoReferenced == true
                        if target_type == "Package" and not is_auto then
                            local raw_ver = sanitize_version(pkg_def.version or "")
                            packages[pkg_name] = {
                                name = pkg_name,
                                version = raw_ver,
                                resolved_version = nil,
                                is_direct = true,
                                is_cpm = pkg_def.versionCentrallyManaged == true,
                            }
                            lower_to_id[pkg_name:lower()] = pkg_name
                        end
                    end
                end

                local targets = json.targets or {}
                for _, tfm in ipairs(tfms) do
                    local target_map = targets[tfm] or {}
                    for target_key, _ in pairs(target_map) do
                        local slash_pos = target_key:find("/")
                        if slash_pos then
                            local target_id = target_key:sub(1, slash_pos - 1)
                            local resolved_ver = sanitize_version(target_key:sub(slash_pos + 1))
                            local matched_id = lower_to_id[target_id:lower()]
                            if matched_id and packages[matched_id] then
                                packages[matched_id].resolved_version = resolved_ver
                                if packages[matched_id].version == "" then
                                    packages[matched_id].version = resolved_ver
                                end
                            end
                        end
                    end
                end

                local restore_frameworks = vim.tbl_get(json, "project", "restore", "frameworks") or {}
                for _, tfm_restore in pairs(restore_frameworks) do
                    local refs = tfm_restore.projectReferences or {}
                    for ref_path, _ in pairs(refs) do
                        local resolved_ref = M.resolve_path(project_dir, ref_path)
                        local proj_name = vim.fn.fnamemodify(resolved_ref, ":t:r")
                        project_references[resolved_ref] = {
                            name = proj_name,
                            target_path = resolved_ref,
                            relative_path = ref_path,
                            in_solution = solution_lower[resolved_ref:lower()] == true,
                        }
                    end
                end
            end
        end
    end

    if not is_restored then
        local ancestors = find_ancestor_props(project_dir)
        local props = {}
        local cpm_versions = {}
        local visited = {}

        for _, prop_file in ipairs(ancestors) do
            visited[prop_file] = true
            local eval_res = evaluate_xml_file(prop_file, props, cpm_versions, visited)
            props = eval_res.properties
            for k, v in pairs(eval_res.packages) do
                packages[k] = v
            end
            for k, v in pairs(eval_res.project_refs) do
                local proj_name = vim.fn.fnamemodify(k, ":t:r")
                project_references[k] = {
                    name = proj_name,
                    target_path = k,
                    relative_path = v,
                    in_solution = solution_lower[k:lower()] == true,
                }
            end
        end

        visited[norm_path] = true
        local proj_res = evaluate_xml_file(norm_path, props, cpm_versions, visited)
        for k, v in pairs(proj_res.packages) do
            packages[k] = v
        end
        for k, v in pairs(proj_res.project_refs) do
            local proj_name = vim.fn.fnamemodify(k, ":t:r")
            project_references[k] = {
                name = proj_name,
                target_path = k,
                relative_path = v,
                in_solution = solution_lower[k:lower()] == true,
            }
        end
        tfms = extract_target_frameworks(proj_res.properties)
    end

    local result = {
        csproj_path = norm_path,
        target_frameworks = tfms,
        is_restored = is_restored,
        packages = packages,
        project_references = project_references,
    }

    M._cache[norm_path] = {
        csproj_stamp = csproj_stamp,
        assets_stamp = assets_stamp,
        data = result,
    }

    return result
end

function M.invalidate(file_path)
    if not file_path or file_path == "" then
        return
    end
    local norm = M.normalize_path(file_path)
    if norm:match("%.props$") or norm:match("%.targets$") then
        M._cache = {}
        return
    end

    if norm:match("%.csproj$") or norm:match("project%.assets%.json$") then
        local dir = vim.fn.fnamemodify(norm, ":h")
        if norm:match("project%.assets%.json$") then
            dir = vim.fn.fnamemodify(dir, ":h")
        end
        dir = M.normalize_path(dir)
        for cached_path, _ in pairs(M._cache) do
            if vim.startswith(cached_path, dir .. "/") or cached_path == dir then
                M._cache[cached_path] = nil
            end
        end
    end
end

function M.find_owning_project(file_path, tree)
    if not file_path or file_path == "" or not tree then
        return nil
    end
    local norm_target = M.normalize_path(file_path):lower()

    local project_nodes = {}
    local function collect_projects(node)
        if node._type == "project" then
            table.insert(project_nodes, node)
        end
        if node._children then
            for _, child in pairs(node._children) do
                collect_projects(child)
            end
        end
    end
    collect_projects(tree)

    for _, node in ipairs(project_nodes) do
        if node._path and M.normalize_path(node._path):lower() == norm_target then
            return node
        end
    end

    local best_node = nil
    local best_len = -1
    for _, node in ipairs(project_nodes) do
        if node._dir then
            local norm_dir = M.normalize_path(node._dir):lower() .. "/"
            if vim.startswith(norm_target, norm_dir) and #norm_dir > best_len then
                best_len = #norm_dir
                best_node = node
            end
        end
    end

    return best_node
end

return M

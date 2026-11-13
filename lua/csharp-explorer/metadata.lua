local uv = vim.uv or vim.loop

local M = {
    _cache = {},
    _profile_cache = {},
    _props_cache = {},
}

function M.clear_cache()
    M._cache = {}
    M._profile_cache = {}
    M._props_cache = {}
end

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
        M.clear_cache()
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
        for cached_path, _ in pairs(M._profile_cache) do
            if vim.startswith(cached_path, dir .. "/") or cached_path == dir or cached_path == norm then
                M._profile_cache[cached_path] = nil
            end
        end
    end
end

function M.get_project_profile(csproj_path)
    local norm_path = M.normalize_path(csproj_path)
    local csproj_stamp = stat_stamp(norm_path)

    local cached = M._profile_cache[norm_path]
    if cached and cached.csproj_stamp == csproj_stamp then
        return cached.data
    end

    local name = vim.fn.fnamemodify(norm_path, ":t:r")
    local f = io.open(norm_path, "r")
    if not f then
        local data = {
            csproj_path = norm_path,
            name = name,
            sdk = "Microsoft.NET.Sdk",
            output_type = nil,
            root_namespace = name,
            target_frameworks = {},
            is_test_project = false,
            archetype = "library",
            explicit_items = {},
        }
        M._profile_cache[norm_path] = {
            csproj_stamp = csproj_stamp,
            data = data,
        }
        return data
    end

    local raw_content = f:read("*a")
    f:close()
    local content = strip_xml_comments(raw_content)

    local sdk = content:match('<Project[^>]-Sdk="([^"]+)"')
        or content:match('<Sdk%s+Name="([^"]+)"')
        or "Microsoft.NET.Sdk"

    local output_type = content:match("<OutputType>([^<]+)</OutputType>")
    if output_type then
        output_type = vim.trim(output_type)
    end

    local root_namespace = content:match("<RootNamespace>([^<]+)</RootNamespace>")
    if root_namespace then
        root_namespace = vim.trim(root_namespace)
    end

    local raw_tfm = content:match("<TargetFrameworks>([^<]+)</TargetFrameworks>")
        or content:match("<TargetFramework>([^<]+)</TargetFramework>")

    if not raw_tfm or not output_type or not root_namespace then
        local project_dir = vim.fn.fnamemodify(norm_path, ":h")
        local ancestors = find_ancestor_props(project_dir)
        for _, prop_file in ipairs(ancestors) do
            if prop_file:match("Directory%.Build%.props$") then
                local p_stamp = stat_stamp(prop_file)
                local cached_p = M._props_cache[prop_file]
                if not cached_p or cached_p.stamp ~= p_stamp then
                    local pf = io.open(prop_file, "r")
                    local parsed = {}
                    if pf then
                        local pcontent = strip_xml_comments(pf:read("*a"))
                        pf:close()
                        parsed.tfm = pcontent:match("<TargetFrameworks>([^<]+)</TargetFrameworks>")
                            or pcontent:match("<TargetFramework>([^<]+)</TargetFramework>")
                        local ot = pcontent:match("<OutputType>([^<]+)</OutputType>")
                        parsed.output_type = ot and vim.trim(ot) or nil
                        local rns = pcontent:match("<RootNamespace>([^<]+)</RootNamespace>")
                        parsed.root_namespace = rns and vim.trim(rns) or nil
                    end
                    cached_p = { stamp = p_stamp, data = parsed }
                    M._props_cache[prop_file] = cached_p
                end
                local pd = cached_p.data
                raw_tfm = raw_tfm or pd.tfm
                output_type = output_type or pd.output_type
                root_namespace = root_namespace or pd.root_namespace
            end
        end
    end

    local target_frameworks = {}
    if raw_tfm then
        for tfm in raw_tfm:gmatch("[^;%s]+") do
            table.insert(target_frameworks, tfm)
        end
    end

    if not root_namespace or root_namespace == "" then
        root_namespace = name
    end

    local is_test = false
    if
        content:match(
            "<[iI][sS][tT][eE][sS][tT][pP][rR][oO][jJ][eE][cC][tT]>%s*[tT][rR][uU][eE]%s*</[iI][sS][tT][eE][sS][tT][pP][rR][oO][jJ][eE][cC][tT]>"
        )
    then
        is_test = true
    end

    local sdk_lower = sdk:lower()
    if not is_test and sdk_lower:find("mstest.sdk", 1, true) then
        is_test = true
    end

    if not is_test then
        local test_pkg_patterns = {
            "^microsoft%.net%.test%.sdk$",
            "^xunit",
            "^nunit",
            "^mstest",
            "^tunit",
            "^fixie",
            "^expecto",
        }
        each_xml_element(content, "PackageReference", function(tag_body)
            if is_test then
                return
            end
            local inc = tag_body:match('Include="([^"]+)"') or tag_body:match('Update="([^"]+)"')
            if inc then
                local inc_lower = inc:lower()
                for _, pat in ipairs(test_pkg_patterns) do
                    if inc_lower:match(pat) then
                        is_test = true
                        break
                    end
                end
            end
        end)
    end

    if not is_test then
        local test_name_patterns = {
            "%.Tests?$",
            "%.TestBase$",
            "%.IntegrationTests$",
            "%.UnitTests$",
            "%.FunctionalTests$",
        }
        for _, pat in ipairs(test_name_patterns) do
            if name:match(pat) then
                is_test = true
                break
            end
        end
    end

    local archetype
    if is_test then
        archetype = "test"
    elseif
        sdk_lower:find("microsoft.net.sdk.web", 1, true)
        or sdk_lower:find("microsoft.net.sdk.blazorwebassembly", 1, true)
        or sdk_lower:find("microsoft.net.sdk.razor", 1, true)
    then
        archetype = "web"
    elseif
        (output_type and (output_type:lower() == "exe" or output_type:lower() == "winexe"))
        or sdk_lower:find("microsoft.net.sdk.worker", 1, true)
    then
        archetype = "console"
    else
        archetype = "library"
    end

    local explicit_items = {}
    local item_tags = { "Compile", "Content", "EmbeddedResource", "Page", "None" }
    for _, tag in ipairs(item_tags) do
        each_xml_element(content, tag, function(tag_body)
            local inc = tag_body:match('Include="([^"]+)"') or tag_body:match('Update="([^"]+)"')
            if inc and not inc:find("%*") then
                local norm_inc = M.normalize_path(inc):lower()
                if vim.startswith(norm_inc, "./") then
                    norm_inc = norm_inc:sub(3)
                end
                if vim.startswith(norm_inc, "/") then
                    norm_inc = norm_inc:sub(2)
                end
                explicit_items[norm_inc] = tag
            end
        end)
    end

    local data = {
        csproj_path = norm_path,
        name = name,
        sdk = sdk,
        output_type = output_type,
        root_namespace = root_namespace,
        target_frameworks = target_frameworks,
        is_test_project = is_test,
        archetype = archetype,
        explicit_items = explicit_items,
    }

    M._profile_cache[norm_path] = {
        csproj_stamp = csproj_stamp,
        data = data,
    }

    return data
end

function M.extract_csharp_namespace(file_path, max_lines)
    if not file_path or file_path == "" then
        return nil, nil
    end
    local f = io.open(file_path, "r")
    if not f then
        return nil, nil
    end

    local limit = max_lines or 120
    local line_count = 0
    local in_block_comment = false
    local pending_ns = nil

    for raw_line in f:lines() do
        line_count = line_count + 1
        if line_count > limit then
            break
        end

        local line = raw_line
        if line_count == 1 and vim.startswith(line, "\239\187\191") then
            line = line:sub(4)
        end

        while true do
            if in_block_comment then
                local end_pos = line:find("%*/")
                if end_pos then
                    line = line:sub(end_pos + 2)
                    in_block_comment = false
                else
                    line = ""
                    break
                end
            else
                local start_pos = line:find("/%*")
                if start_pos then
                    local end_pos = line:find("%*/", start_pos + 2)
                    if end_pos then
                        line = line:sub(1, start_pos - 1) .. " " .. line:sub(end_pos + 2)
                    else
                        line = line:sub(1, start_pos - 1)
                        in_block_comment = true
                    end
                else
                    break
                end
            end
        end

        local line_comment_pos = line:find("//")
        if line_comment_pos then
            line = line:sub(1, line_comment_pos - 1)
        end

        line = vim.trim(line)

        if line ~= "" then
            if pending_ns then
                f:close()
                return pending_ns, "block-scoped"
            end

            if
                not vim.startswith(line, "#")
                and not line:match("^using%s+")
                and not line:match("^global%s+using%s+")
                and not line:match("^%[%s*assembly%s*:")
                and not line:match("^%[%s*module%s*:")
            then
                local ns, sep = line:match("^namespace%s+([%w_%.]+)%s*([;{]?)")
                if ns then
                    if sep == ";" then
                        f:close()
                        return ns, "file-scoped"
                    elseif sep == "{" then
                        f:close()
                        return ns, "block-scoped"
                    else
                        local after = line:match("^namespace%s+[%w_%.]+%s*(.*)$")
                        if after and vim.startswith(after, ";") then
                            f:close()
                            return ns, "file-scoped"
                        elseif after and vim.startswith(after, "{") then
                            f:close()
                            return ns, "block-scoped"
                        else
                            pending_ns = ns
                        end
                    end
                end
            end
        end
    end

    f:close()
    if pending_ns then
        return pending_ns, "block-scoped"
    end
    return nil, nil
end

function M.infer_expected_namespace(file_path, project_node)
    if not file_path or file_path == "" then
        return nil
    end
    local root_ns = nil
    if project_node then
        if project_node._path then
            local profile = M.get_project_profile(project_node._path)
            root_ns = profile.root_namespace
        end
        if not root_ns or root_ns == "" then
            root_ns = project_node._name
        end
    end
    if not root_ns or root_ns == "" then
        return nil
    end

    if not project_node or not project_node._dir then
        return root_ns
    end

    local proj_dir = M.normalize_path(project_node._dir)
    local file_dir = M.normalize_path(vim.fn.fnamemodify(file_path, ":h"))

    if file_dir == proj_dir then
        return root_ns
    end

    if vim.startswith(file_dir:lower(), proj_dir:lower() .. "/") then
        local rel_dir = file_dir:sub(#proj_dir + 2)
        local segments = {}
        for seg in rel_dir:gmatch("[^/]+") do
            local clean_seg = seg:gsub("[^%w_]", "_")
            if clean_seg ~= "" then
                table.insert(segments, clean_seg)
            end
        end
        if #segments > 0 then
            return root_ns .. "." .. table.concat(segments, ".")
        end
    end

    return root_ns
end

function M.resolve_build_action(file_path, project_node)
    if not file_path or file_path == "" then
        return "None"
    end
    local norm_path = M.normalize_path(file_path)

    if project_node and project_node._path and project_node._dir then
        local norm_dir = M.normalize_path(project_node._dir)
        if vim.startswith(norm_path:lower(), norm_dir:lower() .. "/") then
            local rel = norm_path:sub(#norm_dir + 2):lower()
            local profile = M.get_project_profile(project_node._path)
            if profile and profile.explicit_items and profile.explicit_items[rel] then
                return profile.explicit_items[rel]
            end
        end
    end

    if norm_path:match("%.cs$") then
        return "Compile"
    elseif norm_path:match("%.resx$") then
        return "EmbeddedResource"
    elseif norm_path:match("%.xaml$") then
        return "Page"
    elseif norm_path:match("%.razor$") or norm_path:match("%.cshtml$") then
        return "Content"
    end

    local fname = vim.fn.fnamemodify(norm_path, ":t"):lower()
    if fname:match("^appsettings.*%.json$") then
        return "Content"
    end

    if norm_path:match("%.css$") then
        if project_node and project_node._path then
            local profile = M.get_project_profile(project_node._path)
            if profile and profile.archetype == "web" then
                return "Content"
            end
        end
        return "None"
    end

    return "None"
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

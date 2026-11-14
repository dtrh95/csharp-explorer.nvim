local M = {}

function M.get_default_rules()
    return {
        {
            id = "xaml_code_behind",
            child_patterns = { "^(.+)%.xaml%.cs$" },
            parent_format = "%s.xaml",
        },
        {
            id = "appsettings_environments",
            child_patterns = { "^appsettings%..+%.json$" },
            parent_literal = "appsettings.json",
        },
        {
            id = "razor_code_behind",
            child_patterns = { "^(.+)%.razor%.cs$", "^(.+)%.razor%.css$" },
            parent_format = "%s.razor",
        },
        {
            id = "cshtml_code_behind",
            child_patterns = { "^(.+)%.cshtml%.cs$" },
            parent_format = "%s.cshtml",
        },
        {
            id = "resx_designer",
            child_patterns = {
                "^(.+)%.[dD][eE][sS][iI][gG][nN][eE][rR]%.cs$",
                "^(.+)%.[%w%-]+%.resx$",
            },
            parent_format = "%s.resx",
        },
        {
            id = "dockerfile_variants",
            child_patterns = { "^Dockerfile%..+$", "^%.dockerignore$" },
            parent_literal = "Dockerfile",
        },
        {
            id = "cs_same_dir_splits",
            prefix_ext = ".cs",
        },
    }
end

local function find_parent_for(child_name, candidate_set, active_rules)
    for _, rule in ipairs(active_rules) do
        if rule.parent_literal and rule.child_patterns then
            if candidate_set[rule.parent_literal] and rule.parent_literal ~= child_name then
                for _, pat in ipairs(rule.child_patterns) do
                    if child_name:match(pat) then
                        return rule.parent_literal
                    end
                end
            end
        elseif rule.parent_format and rule.child_patterns then
            for _, pat in ipairs(rule.child_patterns) do
                local stem = child_name:match(pat)
                if stem then
                    local parent_name = string.format(rule.parent_format, stem)
                    if parent_name ~= child_name and candidate_set[parent_name] then
                        return parent_name
                    end
                end
            end
        elseif rule.prefix_ext then
            local ext = rule.prefix_ext
            if vim.endswith(child_name, ext) then
                local best_parent = nil
                local best_len = -1
                for cand, _ in pairs(candidate_set) do
                    if vim.endswith(cand, ext) and cand ~= child_name then
                        local prefix = cand:sub(1, #cand - #ext)
                        if vim.startswith(child_name, prefix .. ".") and #prefix > best_len then
                            best_parent = cand
                            best_len = #prefix
                        end
                    end
                end
                if best_parent then
                    return best_parent
                end
            end
        end
    end

    return nil
end

function M.partition_directory_files(file_names, rules)
    local active_rules = rules or M.get_default_rules()
    local present = {}
    for _, name in ipairs(file_names) do
        present[name] = true
    end

    local roots_set = {}
    local top_level = {}
    for _, name in ipairs(file_names) do
        local p = find_parent_for(name, present, active_rules)
        if not p then
            roots_set[name] = true
            table.insert(top_level, name)
        end
    end

    local children_by_parent = {}
    for _, name in ipairs(file_names) do
        if not roots_set[name] then
            local p = find_parent_for(name, roots_set, active_rules)
            if p then
                children_by_parent[p] = children_by_parent[p] or {}
                table.insert(children_by_parent[p], name)
            else
                table.insert(top_level, name)
                roots_set[name] = true
            end
        end
    end

    table.sort(top_level, function(a, b)
        return a:lower() < b:lower()
    end)

    for _, children in pairs(children_by_parent) do
        table.sort(children, function(a, b)
            return a:lower() < b:lower()
        end)
    end

    return {
        top_level = top_level,
        children_by_parent = children_by_parent,
    }
end

function M.resolve_companions(parent_name, sibling_names, rules)
    local partitioned = M.partition_directory_files(sibling_names, rules)
    return partitioned.children_by_parent[parent_name] or {}
end

function M.rename_companion_name(old_parent_name, new_parent_name, child_name)
    if old_parent_name == new_parent_name then
        return child_name
    end
    if old_parent_name == "appsettings.json" or old_parent_name == "Dockerfile" then
        return child_name
    end
    if vim.startswith(child_name, old_parent_name .. ".") then
        return new_parent_name .. child_name:sub(#old_parent_name + 1)
    end
    local old_stem = old_parent_name:match("^(.+)%.[^.]+$") or old_parent_name
    local new_stem = new_parent_name:match("^(.+)%.[^.]+$") or new_parent_name
    if old_stem ~= "" and vim.startswith(child_name, old_stem .. ".") then
        return new_stem .. child_name:sub(#old_stem + 1)
    end
    return child_name
end

return M

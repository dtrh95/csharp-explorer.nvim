local M = {}

function M.parse(root_dir, target_file)
    local file = io.open(target_file, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()

    local tree = {
        _children = {},
        _name = vim.fn.fnamemodify(target_file, ":t"),
        _type = "solution",
        _expanded = true,
        _is_root = true,
        _has_children = true,
    }

    for project_path in content:gmatch('Project%("{[A-Fa-f0-9%-]+}")%s*=%s*%"[^%"]+%"%s*,%s*%"([^%"]+%.%w+)%"') do
        project_path = project_path:gsub("\\", "/")
        local p_name = vim.fn.fnamemodify(project_path, ":t:r")
        local p_dir = vim.fn.resolve(root_dir .. "/" .. vim.fn.fnamemodify(project_path, ":h"))
        local abs_p = vim.fn.resolve(root_dir .. "/" .. project_path)

        local parts = {}
        for part in string.gmatch(project_path, "[^/]+") do
            table.insert(parts, part)
        end

        local current = tree
        for i = 1, #parts - 1 do
            local part = parts[i]
            current._children[part] = current._children[part]
                or { _children = {}, _name = part, _type = "folder", _expanded = true, _has_children = true }
            current = current._children[part]
        end
        current._children[p_name] = {
            _children = {},
            _name = p_name,
            _type = "project",
            _expanded = false,
            _dir = p_dir,
            _path = abs_p,
            _has_children = true,
        }
    end
    return tree
end

return M

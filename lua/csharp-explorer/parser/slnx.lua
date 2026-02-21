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
    local current_folder_path = ""

    for line in content:gmatch("[^\r\n]+") do
        local f_name = line:match('<Folder%s+Name="([^"]+)"')
        if f_name then
            current_folder_path = f_name:gsub("^/", ""):gsub("/$", "")
            local current = tree
            for part in string.gmatch(current_folder_path, "[^/]+") do
                current._children[part] = current._children[part]
                    or { _children = {}, _name = part, _type = "folder", _expanded = true, _has_children = true }
                current = current._children[part]
            end
        elseif line:match("</Folder>") then
            current_folder_path = ""
        end

        local p_path = line:match('<Project%s+Path="([^"]+)"')
        if p_path then
            local p_name = vim.fn.fnamemodify(p_path, ":t:r")
            local p_dir = vim.fn.resolve(root_dir .. "/" .. vim.fn.fnamemodify(p_path, ":h"))
            local abs_p = vim.fn.resolve(root_dir .. "/" .. p_path)

            local current = tree
            for part in string.gmatch(current_folder_path, "[^/]+") do
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
    end
    return tree
end

return M

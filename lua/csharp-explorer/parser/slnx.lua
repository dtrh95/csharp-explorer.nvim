local M = {}

function M.parse(root_dir, target_file)
    local file = io.open(target_file, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()

    local norm_root = root_dir:gsub("\\", "/"):gsub("/+$", "")
    local tree = {
        _children = {},
        _name = vim.fn.fnamemodify(target_file, ":t"),
        _type = "solution",
        _expanded = true,
        _is_root = true,
        _has_children = true,
    }
    local folder_stack = {}

    local function navigate_to_current_folder()
        local current = tree
        for _, segs in ipairs(folder_stack) do
            for _, part in ipairs(segs) do
                current._children[part] = current._children[part]
                    or { _children = {}, _name = part, _type = "folder", _expanded = false, _has_children = true }
                current = current._children[part]
            end
        end
        return current
    end

    for line in content:gmatch("[^\r\n]+") do
        local f_name = line:match('<Folder%s+Name="([^"]+)"')
        if f_name then
            local is_self_closing = line:match("/%s*>") ~= nil
            local norm_folder = f_name:gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
            local parts = {}
            for part in string.gmatch(norm_folder, "[^/]+") do
                table.insert(parts, part)
            end
            if not is_self_closing then
                table.insert(folder_stack, parts)
                navigate_to_current_folder()
            else
                local current = navigate_to_current_folder()
                for _, part in ipairs(parts) do
                    current._children[part] = current._children[part]
                        or { _children = {}, _name = part, _type = "folder", _expanded = false, _has_children = true }
                    current = current._children[part]
                end
            end
        elseif line:match("</Folder>") then
            if #folder_stack > 0 then
                table.remove(folder_stack)
            end
        end

        local p_path = line:match('<Project%s+Path="([^"]+)"')
        if p_path then
            local norm_p = p_path:gsub("\\", "/")
            local p_name = vim.fn.fnamemodify(norm_p, ":t:r")
            local p_dir = vim.fn.resolve(norm_root .. "/" .. vim.fn.fnamemodify(norm_p, ":h")):gsub("\\", "/")
            local abs_p = vim.fn.resolve(norm_root .. "/" .. norm_p):gsub("\\", "/")

            local current = navigate_to_current_folder()

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

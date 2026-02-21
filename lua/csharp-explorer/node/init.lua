local config = require("csharp-explorer.config")

local M = {}

local function get_gitignored_set(dir, files)
    if #files == 0 then
        return {}
    end
    local input = table.concat(files, "\n")
    local result = vim.fn.system("cd " .. vim.fn.shellescape(dir) .. " && git check-ignore --stdin", input)
    local ignored = {}
    if vim.v.shell_error ~= 128 then -- 128 = not a git repo
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
            }
        end
    end

    if config.current.filter.gitignored then
        prune_empty_folders(node)
    end

    node._cs_loaded = true
end

function M.reset_projects(node)
    if node._type == "project" and node._cs_loaded then
        node._children = {}
        node._cs_loaded = false
    elseif node._children then
        for _, child in pairs(node._children) do
            M.reset_projects(child)
        end
    end
end

return M

local M = {}

M.cut_list = {}
M.copy_list = {}

local function clear_list(list)
    for k in pairs(list) do
        list[k] = nil
    end
end

function M.cut(node)
    local path = node._path or node._dir
    if not path then
        vim.notify("Cannot cut virtual nodes", vim.log.levels.WARN)
        return
    end
    M.copy_list[path] = nil
    if M.cut_list[path] then
        M.cut_list[path] = nil
        vim.notify("Removed from clipboard: " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
    else
        M.cut_list[path] = {
            path = path,
            name = node._name,
            is_dir = node._has_children,
        }
        vim.notify("Cut: " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
    end
end

function M.copy(node)
    local path = node._path or node._dir
    if not path then
        vim.notify("Cannot copy virtual nodes", vim.log.levels.WARN)
        return
    end
    M.cut_list[path] = nil
    if M.copy_list[path] then
        M.copy_list[path] = nil
        vim.notify("Removed from clipboard: " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
    else
        M.copy_list[path] = {
            path = path,
            name = node._name,
            is_dir = node._has_children,
        }
        vim.notify("Copied: " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
    end
end

local function do_copy(source, dest)
    local stat = vim.loop.fs_stat(source)
    if not stat then
        return false, "source not found: " .. source
    end

    if stat.type == "file" then
        local ok, err = vim.loop.fs_copyfile(source, dest)
        if not ok then
            return false, err
        end
        return true
    elseif stat.type == "directory" then
        local ok, err = vim.loop.fs_mkdir(dest, stat.mode)
        if not ok then
            return false, err
        end
        local handle
        handle, err = vim.loop.fs_scandir(source)
        if not handle then
            return false, err
        end
        while true do
            local name = vim.loop.fs_scandir_next(handle)
            if not name then
                break
            end
            local s, e = do_copy(source .. "/" .. name, dest .. "/" .. name)
            if not s then
                return false, e
            end
        end
        return true
    end
    return false, "unsupported type: " .. stat.type
end

local function resolve_dest_dir(dest_node)
    local dest_path = dest_node._path or dest_node._dir
    if not dest_path then
        return nil
    end
    local stat = vim.loop.fs_stat(dest_path)
    if stat and stat.type == "directory" then
        return dest_path
    end
    return vim.fn.fnamemodify(dest_path, ":h")
end

function M.paste(dest_node)
    local dest_dir = resolve_dest_dir(dest_node)
    if not dest_dir then
        vim.notify("Cannot determine paste destination", vim.log.levels.WARN)
        return
    end

    local action = nil
    local items = {}

    if next(M.cut_list) then
        action = "cut"
        for _, entry in pairs(M.cut_list) do
            table.insert(items, entry)
        end
    elseif next(M.copy_list) then
        action = "copy"
        for _, entry in pairs(M.copy_list) do
            table.insert(items, entry)
        end
    else
        vim.notify("Clipboard is empty", vim.log.levels.INFO)
        return
    end

    local errors = {}
    for _, entry in ipairs(items) do
        local target = dest_dir .. "/" .. entry.name
        if vim.loop.fs_stat(target) then
            vim.notify("Already exists, skipping: " .. entry.name, vim.log.levels.WARN)
        else
            if action == "cut" then
                local ok, err = vim.loop.fs_rename(entry.path, target)
                if not ok then
                    table.insert(errors, entry.name .. ": " .. (err or "unknown error"))
                end
            else
                local ok, err = do_copy(entry.path, target)
                if not ok then
                    table.insert(errors, entry.name .. ": " .. (err or "unknown error"))
                end
            end
        end
    end

    clear_list(M.cut_list)
    clear_list(M.copy_list)

    if #errors > 0 then
        vim.notify("Paste errors:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
    else
        local verb = action == "cut" and "Moved" or "Copied"
        vim.notify(verb .. " " .. #items .. " item(s)", vim.log.levels.INFO)
    end

    pcall(function()
        local events = require("nvim-tree.events")
        events._dispatch_folder_created(dest_dir)
    end)
end

function M.is_cut(path)
    return M.cut_list[path] ~= nil
end

function M.is_copied(path)
    return M.copy_list[path] ~= nil
end

function M.clear()
    clear_list(M.cut_list)
    clear_list(M.copy_list)
end

return M

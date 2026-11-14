local metadata = require("csharp-explorer.metadata")
local nesting = require("csharp-explorer.nesting")
local uv = vim.uv or vim.loop

local M = {}

M.cut_list = {}
M.copy_list = {}

local function clear_list(list)
    for k in pairs(list) do
        list[k] = nil
    end
end

function M.cut(node)
    if node._virtual or (not node._path and not node._dir) then
        vim.notify("Cannot cut virtual metadata nodes", vim.log.levels.WARN)
        return
    end
    if node._type == "solution" or node._type == "project" then
        vim.notify("Cannot cut solution or project root nodes", vim.log.levels.WARN)
        return
    end
    local path = node._path or node._dir
    M.copy_list[path] = nil
    if M.cut_list[path] then
        M.cut_list[path] = nil
        vim.notify("Removed from clipboard: " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
    else
        local node_utils = require("csharp-explorer.node")
        M.cut_list[path] = {
            path = path,
            name = node._name,
            is_dir = node_utils.is_directory(node),
        }
        vim.notify("Cut: " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
    end
end

function M.copy(node)
    if node._virtual or (not node._path and not node._dir) then
        vim.notify("Cannot copy virtual metadata nodes", vim.log.levels.WARN)
        return
    end
    local path = node._path or node._dir
    M.cut_list[path] = nil
    if M.copy_list[path] then
        M.copy_list[path] = nil
        vim.notify("Removed from clipboard: " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
    else
        local node_utils = require("csharp-explorer.node")
        M.copy_list[path] = {
            path = path,
            name = node._name,
            is_dir = node_utils.is_directory(node),
        }
        vim.notify("Copied: " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
    end
end

local function do_copy(source, dest)
    local stat = uv.fs_stat(source)
    if not stat then
        return false, "source not found: " .. source
    end

    if stat.type == "file" then
        local ok, err = uv.fs_copyfile(source, dest)
        if not ok then
            return false, err
        end
        return true
    elseif stat.type == "directory" then
        local ok, err = uv.fs_mkdir(dest, stat.mode)
        if not ok then
            return false, err
        end
        local handle
        handle, err = uv.fs_scandir(source)
        if not handle then
            return false, err
        end
        while true do
            local name = uv.fs_scandir_next(handle)
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
    local stat = uv.fs_stat(dest_path)
    if stat and stat.type == "directory" then
        return dest_path
    end
    return vim.fn.fnamemodify(dest_path, ":h")
end

local function scan_directory_simple(dir)
    local names = {}
    local handle = uv.fs_scandir(dir)
    if handle then
        while true do
            local name = uv.fs_scandir_next(handle)
            if not name then
                break
            end
            names[#names + 1] = name
        end
    end
    return names
end

function M.paste(dest_node, state, opts)
    if not dest_node or dest_node._virtual then
        vim.notify("Cannot paste into virtual metadata nodes", vim.log.levels.WARN)
        return
    end

    local dest_dir = resolve_dest_dir(dest_node)
    if not dest_dir then
        vim.notify("Cannot determine paste destination", vim.log.levels.WARN)
        return
    end
    dest_dir = metadata.normalize_path(dest_dir)

    local action
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

    if action == "cut" then
        clear_list(M.cut_list)
        clear_list(M.copy_list)
        local refactor = require("csharp-explorer.actions.refactor")
        return refactor.move_entries(items, dest_dir, state, opts)
    end

    local errors = {}
    local copied_files = {}

    for _, entry in ipairs(items) do
        local target = metadata.normalize_path(dest_dir .. "/" .. entry.name)
        if uv.fs_stat(target) then
            vim.notify("Already exists, skipping: " .. entry.name, vim.log.levels.WARN)
        else
            local ok, err = do_copy(entry.path, target)
            if not ok then
                table.insert(errors, entry.name .. ": " .. (err or "unknown error"))
            else
                copied_files[#copied_files + 1] = { path = target, is_dir = entry.is_dir }
                if not entry.is_dir then
                    local pdir = vim.fn.fnamemodify(entry.path, ":h")
                    local siblings = scan_directory_simple(pdir)
                    local comps = nesting.resolve_companions(entry.name, siblings)
                    for _, c in ipairs(comps) do
                        local comp_src = metadata.normalize_path(pdir .. "/" .. c)
                        local comp_dst = metadata.normalize_path(dest_dir .. "/" .. c)
                        if not uv.fs_stat(comp_dst) then
                            local c_ok, c_err = do_copy(comp_src, comp_dst)
                            if c_ok then
                                copied_files[#copied_files + 1] = { path = comp_dst, is_dir = false }
                            else
                                table.insert(errors, c .. ": " .. (c_err or "unknown error"))
                            end
                        end
                    end
                end
            end
        end
    end

    clear_list(M.cut_list)
    clear_list(M.copy_list)

    local namespace_actions = require("csharp-explorer.actions.namespace")
    local refactor = require("csharp-explorer.actions.refactor")
    local watched = {}
    for _, cp in ipairs(copied_files) do
        if cp.is_dir then
            namespace_actions.sync_directory(cp.path, state and state.tree, { force = true })
            local dir_cs = namespace_actions.collect_cs_files_in_dir(cp.path)
            for _, dfp in ipairs(dir_cs) do
                watched[#watched + 1] = { path = dfp, type = 1 }
            end
        elseif vim.endswith(cp.path, ".cs") then
            namespace_actions.sync_file(cp.path, state and state.tree, { force = true })
            watched[#watched + 1] = { path = cp.path, type = 1 }
        else
            watched[#watched + 1] = { path = cp.path, type = 1 }
        end
    end
    refactor.notify_watched_files(watched)

    if state and state.tree then
        local node_utils = require("csharp-explorer.node")
        local renderer = require("csharp-explorer.renderer")
        node_utils.reset_projects(state.tree)
        if state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
            renderer.render(state)
        end
    end

    if #errors > 0 then
        vim.notify("Paste errors:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
    else
        vim.notify("Copied " .. #items .. " item(s)", vim.log.levels.INFO)
    end
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

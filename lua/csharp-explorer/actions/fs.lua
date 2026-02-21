local navigation = require("csharp-explorer.actions.navigation")

local M = {}

local function get_nvim_tree_mock_node(node)
    if not node then
        return nil
    end
    local is_file = not node._has_children
    local path = node._path or node._dir
    if not path then
        vim.notify("Virtual folders cannot be manipulated directly", vim.log.levels.WARN)
        return nil
    end

    local ok_f, FileNode = pcall(require, "nvim-tree.node.file")
    local ok_d, DirectoryNode = pcall(require, "nvim-tree.node.directory")
    if not ok_f or not ok_d then
        vim.notify("NvimTree dependencies cannot be resolved", vim.log.levels.ERROR)
        return nil
    end

    local pseudo = {
        absolute_path = path,
        name = node._name,
        type = is_file and "file" or "directory",
        is = function(self, cls)
            if is_file and cls == FileNode then
                return true
            end
            if not is_file and cls == DirectoryNode then
                return true
            end
            return false
        end,
        as = function(self, cls)
            return self
        end,
        last_group_node = function(self)
            return self
        end,
    }
    if is_file then
        pseudo.parent = {
            absolute_path = vim.fn.fnamemodify(path, ":h"),
            last_group_node = function(s)
                return s
            end,
            is = function(self, cls)
                return cls == DirectoryNode
            end,
            as = function(s)
                return s
            end,
        }
    end
    return pseudo
end

local function suppress_completion()
    local group = vim.api.nvim_create_augroup("CSharpExplorerSuppressCmp", { clear = true })
    vim.api.nvim_create_autocmd("CmdlineEnter", {
        group = group,
        once = true,
        callback = function()
            pcall(function()
                local blink_config = require("blink.cmp").config or require("blink.cmp.config")
                if blink_config.cmdline then
                    blink_config.cmdline.enabled = false
                end
            end)

            vim.api.nvim_create_autocmd("CmdlineLeave", {
                group = group,
                once = true,
                callback = function()
                    vim.schedule(function()
                        pcall(function()
                            local blink_config = require("blink.cmp").config or require("blink.cmp.config")
                            if blink_config.cmdline then
                                blink_config.cmdline.enabled = true
                            end
                        end)
                        pcall(vim.api.nvim_del_augroup_by_name, "CSharpExplorerSuppressCmp")
                    end)
                end,
            })
        end,
    })
end

function M.proxy_fs(state, action_path)
    return function()
        local node = navigation.get_node(state)
        if not node then
            return
        end
        if node._type == "solution" or node._type == "project" then
            if action_path == "remove" or action_path == "rename" then
                vim.notify("Cannot modify project root nodes from Explorer", vim.log.levels.WARN)
                return
            end
        end

        local mock = get_nvim_tree_mock_node(node)
        if not mock then
            return
        end

        suppress_completion()

        local ok, api = pcall(require, "nvim-tree.api")
        if ok and api.fs then
            if action_path == "copy.node" then
                api.fs.copy.node(mock)
            else
                api.fs[action_path](mock)
            end
        end
    end
end

return M

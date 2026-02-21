local config = require("csharp-explorer.config")
local slnx_parser = require("csharp-explorer.parser.slnx")
local sln_parser = require("csharp-explorer.parser.sln")
local node_utils = require("csharp-explorer.node")
local renderer = require("csharp-explorer.renderer")
local keymap = require("csharp-explorer.keymap")

local M = {}

M.buf = nil
M.win = nil
M.tree = nil
M.is_active = false
M.config = config.current

function M.enable()
    config.current.enabled = true
    vim.notify("CSharp Explorer Enabled", vim.log.levels.INFO)
end

function M.disable()
    config.current.enabled = false
    if M.is_active then
        M.toggle()
    end
    vim.notify("CSharp Explorer Disabled", vim.log.levels.INFO)
end

function M.toggle_plugin()
    if config.current.enabled then
        M.disable()
    else
        M.enable()
    end
end

function M.toggle()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        vim.api.nvim_win_close(M.win, true)
        M.win = nil
        M.is_active = false
        return
    end

    if not config.current.enabled then
        vim.notify("CSharp Explorer is disabled", vim.log.levels.WARN)
        return
    end

    local root_dir = vim.fn.getcwd()
    local slnx_files = vim.fn.glob(root_dir .. "/*.slnx", false, true)
    local sln_files = vim.fn.glob(root_dir .. "/*.sln", false, true)

    if #slnx_files > 0 then
        M.tree = slnx_parser.parse(root_dir, slnx_files[1])
    elseif #sln_files > 0 then
        M.tree = sln_parser.parse(root_dir, sln_files[1])
    else
        vim.notify("No .slnx or .sln found", vim.log.levels.WARN)
        return
    end

    -- Close nvim-tree if it is open
    pcall(function()
        require("nvim-tree.api").tree.close()
    end)

    local width = config.current.ui.width
    if config.current.ui.sync_nvim_tree_width then
        local has_cfg, nvim_tree_config = pcall(require, "nvim-tree.config")
        if has_cfg and type(nvim_tree_config.view) == "table" and type(nvim_tree_config.view.width) == "number" then
            width = nvim_tree_config.view.width
        end
    end

    M.buf = vim.api.nvim_create_buf(false, true)

    -- Use silent modifiers to suppress the W10 warning when creating the buffer/window
    vim.cmd("silent! topleft " .. width .. "vsplit")
    M.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.win, M.buf)

    vim.wo[M.win].wrap = false
    vim.wo[M.win].number = false
    vim.wo[M.win].relativenumber = false
    vim.wo[M.win].signcolumn = "no"
    vim.wo[M.win].foldcolumn = "0"

    vim.bo[M.buf].filetype = "csharpexplorer"
    vim.bo[M.buf].buftype = "nofile"
    vim.bo[M.buf].swapfile = false
    vim.bo[M.buf].bufhidden = "wipe"
    -- set modifiable to false FIRST, then readonly
    vim.bo[M.buf].modifiable = false
    vim.cmd("silent! setlocal readonly")

    -- Disable completion engines in this buffer
    pcall(function()
        require("blink.cmp").setup_buffer(M.buf, { enabled = false })
    end)
    pcall(function()
        require("cmp").setup.buffer({ enabled = false })
    end)

    -- Bind keymaps
    keymap.apply(M)

    renderer.render(M)
    M.is_active = true
end

function M.find_file()
    if not config.current.enabled then
        vim.notify("CSharp Explorer is disabled", vim.log.levels.WARN)
        return
    end

    local target_path = vim.fn.expand("%:p")
    if target_path == "" then
        return
    end
    target_path = target_path:gsub("\\", "/")

    if not M.is_active or not M.tree then
        M.toggle()
    end

    if not M.tree then
        return
    end

    local function search_node(node)
        if not node._has_children then
            if node._path == target_path then
                return true
            end
            return false
        elseif node._type == "project" then
            if vim.startswith(target_path, node._dir .. "/") or target_path == node._dir then
                if not node._cs_loaded then
                    node_utils.populate_cs_files(node)
                end
                for _, child in pairs(node._children) do
                    if search_node(child) then
                        node._expanded = true
                        return true
                    end
                end
            end
            return false
        elseif node._type == "folder" or node._type == "solution" then
            for _, child in pairs(node._children) do
                if search_node(child) then
                    node._expanded = true
                    return true
                end
            end
            return false
        end
        return false
    end

    local found = search_node(M.tree)
    if found then
        renderer.render(M)
        for line_num, node in pairs(renderer.line_to_node) do
            if node._path == target_path then
                vim.api.nvim_set_current_win(M.win)
                vim.api.nvim_win_set_cursor(M.win, { line_num, 0 })
                vim.cmd("normal! zz")
                break
            end
        end
    else
        vim.notify("File not found in C# Solution", vim.log.levels.WARN)
    end
end

function M.toggle_gitignore()
    config.current.filter.gitignored = not config.current.filter.gitignored
    if M.tree then
        node_utils.reset_projects(M.tree)
        if M.is_active and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
            renderer.render(M)
        end
    end
    local state = config.current.filter.gitignored and "hidden" or "visible"
    vim.notify("Gitignored files: " .. state, vim.log.levels.INFO)
end

function M.refresh()
    if not M.tree then
        return
    end

    local root_dir = vim.fn.getcwd()
    local slnx_files = vim.fn.glob(root_dir .. "/*.slnx", false, true)
    local sln_files = vim.fn.glob(root_dir .. "/*.sln", false, true)

    if #slnx_files > 0 then
        M.tree = slnx_parser.parse(root_dir, slnx_files[1])
    elseif #sln_files > 0 then
        M.tree = sln_parser.parse(root_dir, sln_files[1])
    end

    node_utils.reset_projects(M.tree)

    if M.is_active and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
        renderer.render(M)
    end

    vim.notify("CSharp Explorer: Refreshed", vim.log.levels.INFO)
end

function M.expand_all()
    if not M.is_active or not M.tree then return end
    require("csharp-explorer.actions.navigation").expand_all(M)()
end

function M.collapse_all()
    if not M.is_active or not M.tree then return end
    require("csharp-explorer.actions.navigation").collapse_all(M)()
end

function M.setup(opts)
    config.setup(opts)
    M.config = config.current

    vim.api.nvim_create_user_command("CSharpExplorer", M.toggle, { desc = "Toggle C# Solution Explorer" })
    vim.api.nvim_create_user_command(
        "CSharpExplorerFindFile",
        M.find_file,
        { desc = "Find current C# file in Explorer" }
    )
    vim.api.nvim_create_user_command("CSharpExplorerEnable", M.enable, { desc = "Enable C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerDisable", M.disable, { desc = "Disable C# Solution Explorer" })
    vim.api.nvim_create_user_command(
        "CSharpExplorerTogglePlugin",
        M.toggle_plugin,
        { desc = "Toggle C# Solution Explorer Plugin" }
    )
    vim.api.nvim_create_user_command("CSharpExplorerRefresh", M.refresh, { desc = "Refresh C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerExpandAll", M.expand_all, { desc = "Expand All in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerCollapseAll", M.collapse_all, { desc = "Collapse All in C# Solution Explorer" })

    -- Hook into NvimTree commands to override them if a Solution file exists
    vim.api.nvim_create_user_command("NvimTreeToggle", function()
        local root_dir = vim.fn.getcwd()
        local has_slnx = #vim.fn.glob(root_dir .. "/*.slnx", false, true) > 0
        local has_sln = #vim.fn.glob(root_dir .. "/*.sln", false, true) > 0

        if config.current.enabled and (M.is_active or has_slnx or has_sln) then
            M.toggle()
        else
            pcall(function()
                require("nvim-tree.api").tree.toggle()
            end)
        end
    end, { force = true })

    vim.api.nvim_create_user_command("NvimTreeFindFile", function()
        local root_dir = vim.fn.getcwd()
        local has_slnx = #vim.fn.glob(root_dir .. "/*.slnx", false, true) > 0
        local has_sln = #vim.fn.glob(root_dir .. "/*.sln", false, true) > 0

        if config.current.enabled and (M.is_active or has_slnx or has_sln) then
            M.find_file()
        else
            pcall(function()
                require("nvim-tree.api").tree.find_file()
            end)
        end
    end, { force = true })

    -- Subscribe to nvim-tree file events to auto-refresh project trees
    if not M._events_bound then
        M._events_bound = true
        local ok_ev, nev = pcall(require, "nvim-tree.events")
        if ok_ev then
            local function on_fs_change()
                if not M.tree then
                    return
                end
                node_utils.reset_projects(M.tree)
                if M.is_active and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
                    renderer.render(M)
                end
            end

            nev.subscribe(nev.Event.FileCreated, on_fs_change)
            nev.subscribe(nev.Event.FolderCreated, on_fs_change)
            nev.subscribe(nev.Event.FileRemoved, on_fs_change)
            nev.subscribe(nev.Event.FolderRemoved, on_fs_change)
            nev.subscribe(nev.Event.NodeRenamed, on_fs_change)
        end
    end
end

return M

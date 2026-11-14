local config = require("csharp-explorer.config")
local slnx_parser = require("csharp-explorer.parser.slnx")
local sln_parser = require("csharp-explorer.parser.sln")
local node_utils = require("csharp-explorer.node")
local renderer = require("csharp-explorer.renderer")
local keymap = require("csharp-explorer.keymap")
local navigation = require("csharp-explorer.actions.navigation")
local metadata = require("csharp-explorer.metadata")
local diagnostics = require("csharp-explorer.diagnostics")
local properties = require("csharp-explorer.actions.properties")

local M = {}

M.buf = nil
M.win = nil
M.tree = nil
M.is_active = false
M.config = config.current

local function parse_workspace_solution(root_dir)
    local slnx_files = vim.fn.glob(root_dir .. "/*.slnx", false, true)
    local sln_files = vim.fn.glob(root_dir .. "/*.sln", false, true)

    if #slnx_files > 0 then
        return slnx_parser.parse(root_dir, slnx_files[1])
    elseif #sln_files > 0 then
        return sln_parser.parse(root_dir, sln_files[1])
    end
    return nil
end

function M.ensure_tree()
    local root_dir = vim.fn.getcwd()
    if not M.tree or M._root_dir ~= root_dir then
        M.tree = parse_workspace_solution(root_dir)
        M._root_dir = root_dir
    end
    return M.tree
end

function M.enable()
    config.current.enabled = true
    if config.current.diagnostics and config.current.diagnostics.enabled ~= false then
        diagnostics.attach(M)
    end
    vim.api.nvim_exec_autocmds("User", { pattern = "CSharpExplorerEnable" })
    vim.notify("CSharp Explorer Enabled", vim.log.levels.INFO)
end

function M.disable()
    config.current.enabled = false
    if M.is_active then
        M.toggle()
    end
    diagnostics.detach()
    local runner = require("csharp-explorer.runner")
    runner.shutdown()
    vim.api.nvim_exec_autocmds("User", { pattern = "CSharpExplorerDisable" })
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

    if not M.ensure_tree() then
        vim.notify("No .slnx or .sln found", vim.log.levels.WARN)
        return
    end

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
    vim.bo[M.buf].modifiable = false
    vim.bo[M.buf].readonly = true

    pcall(function()
        require("blink.cmp").setup_buffer(M.buf, { enabled = false })
    end)
    pcall(function()
        require("cmp").setup.buffer({ enabled = false })
    end)

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
    local target_lower = metadata.normalize_path(target_path):lower()

    if not M.is_active or not M.tree then
        M.toggle()
    end

    if not M.tree then
        return
    end

    local function search_node(node)
        if node._path and metadata.normalize_path(node._path):lower() == target_lower then
            return true
        end

        if node._type == "project" then
            local proj_dir_lower = metadata.normalize_path(node._dir):lower()
            if vim.startswith(target_lower, proj_dir_lower .. "/") or target_lower == proj_dir_lower then
                if not node._cs_loaded then
                    node_utils.populate_cs_files(node)
                end
                for _, child in pairs(node._children) do
                    if not child._virtual and search_node(child) then
                        node._expanded = true
                        return true
                    end
                end
            end
            return false
        end

        if node._type == "folder" or node._type == "solution" or node_utils.is_nested_parent(node) then
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
            if node._path and metadata.normalize_path(node._path):lower() == target_lower then
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

function M.open_properties()
    navigation.open_properties(M)()
end

function M.item_properties()
    properties.open(M)()
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

    local snapshot = node_utils.snapshot_tree_expansion(M.tree)
    metadata.clear_cache()

    local fresh_tree = parse_workspace_solution(vim.fn.getcwd())
    if fresh_tree then
        node_utils.restore_tree_expansion(fresh_tree, snapshot)
        M.tree = fresh_tree
    end

    if M.is_active and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
        renderer.render(M)
    end

    vim.notify("CSharp Explorer: Refreshed", vim.log.levels.INFO)
end

function M.expand_all()
    if not M.is_active or not M.tree then
        return
    end
    navigation.expand_all(M)()
end

function M.collapse_all()
    if not M.is_active or not M.tree then
        return
    end
    navigation.collapse_all(M)()
end

function M.build(opts)
    return require("csharp-explorer.actions.build").build(M, opts)
end

function M.restore(opts)
    return require("csharp-explorer.actions.build").restore(M, opts)
end

function M.clean(opts)
    return require("csharp-explorer.actions.build").clean(M, opts)
end

function M.test(opts)
    return require("csharp-explorer.actions.test").run_target(M, opts)
end

function M.test_nearest(opts)
    return require("csharp-explorer.actions.test").run_nearest(M, opts)
end

function M.test_select(opts)
    return require("csharp-explorer.actions.test").select_test(M, opts)
end

function M.add(opts)
    return require("csharp-explorer.actions.templates").add(M, opts)
end

function M.add_item(opts)
    return require("csharp-explorer.actions.templates").add_item(M, opts)
end

function M.add_project(opts)
    return require("csharp-explorer.actions.templates").add_project(M, opts)
end

function M.action_menu()
    return require("csharp-explorer.actions.templates").action_menu(M)
end

function M.task_output()
    return require("csharp-explorer.runner").toggle_output()
end

function M.cancel_task()
    return require("csharp-explorer.runner").cancel()
end

function M.setup(opts)
    config.setup(opts)
    M.config = config.current

    vim.api.nvim_create_user_command("CSharpExplorer", M.toggle, { desc = "Toggle C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerToggle", M.toggle, { desc = "Toggle the CSharpExplorer tree" })
    vim.api.nvim_create_user_command(
        "CSharpExplorerFindFile",
        M.find_file,
        { desc = "Find current C# file or .csproj in Explorer" }
    )
    vim.api.nvim_create_user_command(
        "CSharpExplorerOpenProperties",
        M.open_properties,
        { desc = "Open owning .csproj file" }
    )
    vim.api.nvim_create_user_command(
        "CSharpExplorerItemProperties",
        M.item_properties,
        { desc = "Show contextual item properties floating window" }
    )
    vim.api.nvim_create_user_command("CSharpExplorerEnable", M.enable, { desc = "Enable C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerDisable", M.disable, { desc = "Disable C# Solution Explorer" })
    vim.api.nvim_create_user_command(
        "CSharpExplorerTogglePlugin",
        M.toggle_plugin,
        { desc = "Toggle C# Solution Explorer Plugin" }
    )
    vim.api.nvim_create_user_command("CSharpExplorerRefresh", M.refresh, { desc = "Refresh C# Solution Explorer" })
    vim.api.nvim_create_user_command(
        "CSharpExplorerExpandAll",
        M.expand_all,
        { desc = "Expand All in C# Solution Explorer" }
    )
    vim.api.nvim_create_user_command(
        "CSharpExplorerCollapseAll",
        M.collapse_all,
        { desc = "Collapse All in C# Solution Explorer" }
    )
    vim.api.nvim_create_user_command("CSharpExplorerBuild", function(cmd_opts)
        M.build({ args = cmd_opts.args })
    end, { desc = "Build target in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerRestore", function(cmd_opts)
        M.restore({ args = cmd_opts.args })
    end, { desc = "Restore target in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerClean", function(cmd_opts)
        M.clean({ args = cmd_opts.args })
    end, { desc = "Clean target in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerTest", function(cmd_opts)
        M.test({ args = cmd_opts.args })
    end, { desc = "Run tests on target in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerTestNearest", function(cmd_opts)
        M.test_nearest({ args = cmd_opts.args })
    end, { desc = "Run nearest test in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerTestSelect", function(cmd_opts)
        M.test_select({ args = cmd_opts.args })
    end, { desc = "Select and run test in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerAdd", function(cmd_opts)
        M.add({ args = cmd_opts.args })
    end, { desc = "Add item or project in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerAddItem", function(cmd_opts)
        M.add_item({ args = cmd_opts.args })
    end, { desc = "Add C# item in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerAddProject", function(cmd_opts)
        M.add_project({ args = cmd_opts.args })
    end, { desc = "Add .NET project in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerActions", function()
        M.action_menu()
    end, { desc = "Action menu in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerTaskOutput", function()
        M.task_output()
    end, { desc = "Toggle task output in C# Solution Explorer" })
    vim.api.nvim_create_user_command("CSharpExplorerCancel", function()
        M.cancel_task()
    end, { desc = "Cancel running task in C# Solution Explorer" })

    if not M._events_bound then
        M._events_bound = true

        local augroup = vim.api.nvim_create_augroup("CSharpExplorerLiveSync", { clear = true })
        vim.api.nvim_create_autocmd("BufWritePost", {
            group = augroup,
            pattern = { "*.csproj", "*.props", "*.targets", "project.assets.json" },
            callback = function(ev)
                metadata.invalidate(ev.file)
                if M.tree then
                    node_utils.reset_projects(M.tree)
                    if M.is_active and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
                        renderer.render(M)
                    end
                end
            end,
        })

        local ok_api, api = pcall(require, "nvim-tree.api")
        if ok_api and api.events then
            local function on_fs_change()
                if not M.tree then
                    return
                end
                node_utils.reset_projects(M.tree)
                if M.is_active and M.buf and vim.api.nvim_buf_is_valid(M.buf) then
                    renderer.render(M)
                end
            end

            local Event = api.events.Event
            api.events.subscribe(Event.FileCreated, on_fs_change)
            api.events.subscribe(Event.FolderCreated, on_fs_change)
            api.events.subscribe(Event.FileRemoved, on_fs_change)
            api.events.subscribe(Event.FolderRemoved, on_fs_change)
            api.events.subscribe(Event.NodeRenamed, on_fs_change)
        end
    end

    if config.current.diagnostics and config.current.diagnostics.enabled ~= false then
        diagnostics.attach(M)
    end
end

return M

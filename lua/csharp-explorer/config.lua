local M = {}

M.defaults = {
    enabled = true,
    icons = {
        arrow_open = " ",
        arrow_closed = " ",
        solution = "󰘐 ",
        folder_open = "󰜢 ",
        folder_closed = "󰉋 ",
        project = "󰌛 ",
        project_web = "󰖟 ",
        project_console = "󰆍 ",
        project_library = "󰌛 ",
        project_test = "󰙨 ",
        cs_file = "󰠱 ",
        appsettings = " ",
        dockerfile = "󰡨 ",
        http_file = "󰪹 ",
        cshtml_file = "󰌝 ",
        razor_file = "󱦘 ",
        css_file = " ",
        xaml_file = "󰙳 ",
        resx_file = "󰗀 ",
        dependencies = "󰆧 ",
        package_group = "󰏗 ",
        package = "󰏗 ",
        project_reference_group = "󰌛 ",
        project_reference = "󰌛 ",
    },
    project_highlights = {
        web = "Special",
        console = "Function",
        library = "Type",
        test = "DiagnosticOk",
    },
    dynamic_icons = {
        enabled = true,
    },
    nesting = {
        enabled = true,
        expand_by_default = false,
    },
    diagnostics = {
        enabled = true,
        debounce_ms = 80,
        show_on_dirs = true,
        show_on_open_dirs = true,
        show_on_nested_parents = true,
        icons = {
            error = "󰅚 ",
            warn = "󰀪 ",
            info = "󰋽 ",
            hint = "󰌶 ",
        },
        highlights = {
            error = "DiagnosticSignError",
            warn = "DiagnosticSignWarn",
            info = "DiagnosticSignInfo",
            hint = "DiagnosticSignHint",
        },
    },
    properties = {
        border = "rounded",
        max_width = 76,
        max_scan_lines = 120,
    },
    orchestration = {
        dotnet_cmd = nil,
        file_scoped_namespaces = true,
        open_quickfix_on_error = true,
        open_output_on_error = false,
        close_quickfix_on_success = false,
        output_max_lines = 2000,
    },
    filter = {
        gitignored = true,
    },
    ui = {
        width = 30,
        sync_nvim_tree_width = true,
    },
    keymaps = {
        close = "q",
        open = { "<CR>", "o", "<2-LeftMouse>" },
        vsplit = "<C-v>",
        close_node = "<BS>",
        toggle_expand = "<Tab>",
        create = "a",
        delete = "d",
        rename = "r",
        copy = "c",
        cut = "x",
        paste = "p",
        open_properties = "P",
        item_properties = "K",
        toggle_gitignore = "I",
        expand_all = "E",
        collapse_all = "W",
        build = "B",
        restore = "R",
        clean = "C",
        test = "T",
        add = "A",
        action_menu = "m",
        task_output = "O",
        cancel_task = "X",
    },
}

M.current = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.current = vim.tbl_deep_extend("force", M.current, opts or {})
end

return M

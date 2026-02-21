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
        cs_file = "󰠱 ",
        appsettings = " ",
        dockerfile = "󰡨 ",
        http_file = "󰪹 ",
    },
    filter = {
        gitignored = true, -- hide gitignored files/folders by default
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
        create = "a",
        delete = "d",
        rename = "r",
        copy = "c",
        cut = "x",
        paste = "p",
        toggle_gitignore = "I",
        expand_all = "E",
        collapse_all = "W",
    },
}

M.current = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.current = vim.tbl_deep_extend("force", M.current, opts or {})
end

return M

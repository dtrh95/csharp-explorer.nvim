# csharp-explorer.nvim

A lightweight, efficient C# Solution Explorer for Neovim that bridges the gap between `csharp_ls` and `nvim-tree.lua`.

[![Video](https://github.com/user-attachments/assets/a026d7b2-978f-4cbf-af6c-c3a84d76030c)](https://github.com/user-attachments/assets/dd0c0cf4-1b53-446e-aa7a-66aadf7a78cb)

## Features

- **Solution & Project Parsing**: Supports both legacy `.sln` and the modern XML-based `.slnx` files, automatically rendering independently of the LSP.
- **File Parsing Integration**: Provides fully native parsing, navigation, opening, and interaction mapping for C# files, `appsettings*.json`, `Dockerfile`, and `.http` files inside of the project.
- **Nvim-Tree Integration**: Proxies file system operations (create, rename, delete) to `nvim-tree.lua` for a consistent experience.
- **Directory Behaviors**: Nvim-tree style chevron markers and full expand all / collapse all tree manipulation commands.
- **Finding Files**: Quickly locate the current buffer in the solution tree using `CSharpExplorerFindFile`.
- **Gitignore Filtering**: Toggle visibility of gitignored files.
- **Custom Clipboard**: Standalone copy/cut/paste functionality specifically for C# project items.

## Prerequisites

- Neovim 0.9.0+
- [nvim-tree/nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua)
- [nvim-tree/nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) (optional, for icons)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "dtrh95/csharp-explorer.nvim", -- Replace with your actual repo
    dependencies = {
        "nvim-tree/nvim-tree.lua",
        "nvim-tree/nvim-web-devicons",
    },
    config = function()
        require("csharp-explorer").setup({
            -- your configuration here
        })
    end,
}
```

## Configuration

Default setup options:

```lua
require("csharp-explorer").setup({
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
        create = "a",
        delete = "d",
        rename = "r",
        copy = "c",
        cut = "x",
        paste = "p",
        toggle_gitignore = "I",
        expand_all = "E",
        collapse_all = "W",
    }
})
```

## Commands

- `:CSharpExplorer`: Toggle the solution explorer.
- `:CSharpExplorerFindFile`: Reveal current file in the explorer.
- `:CSharpExplorerTogglePlugin`: Toggle this plugin
- `:CSharpExplorerRefresh`: Refresh the solution tree
- `:CSharpExplorerExpandAll`: Expand all folders across the solution.
- `:CSharpExplorerCollapseAll`: Collapse all folders across the solution.

## Events

You can hook into plugin enablement state changes by listening to these Neovim `User` autocommands:

- `CSharpExplorerEnable`: Fired when the plugin is explicitly enabled.
- `CSharpExplorerDisable`: Fired when the plugin is disabled.

Example usage:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "CSharpExplorerEnable",
    callback = function()
        print("CSharpExplorer is now active!")
    end,
})
```

## Roadmap

We aim to achieve feature parity with IDE-like solution trees (Visual Studio/Rider). See our detailed [ROADMAP.md](ROADMAP.md) for more details.

## Development

- **Formatting**: This project uses [StyLua](https://github.com/JohnnyMorganz/StyLua) for code formatting. A `.stylua.toml` is provided in the root.
- **Linting**: We recommend using `luacheck` for static analysis.

## License

MIT

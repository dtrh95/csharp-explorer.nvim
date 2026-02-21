# csharp-explorer.nvim

A lightweight, efficient C# Solution Explorer for Neovim that bridges the gap between `csharp_ls` and `nvim-tree.lua`.

![C# Explorer](https://user-images.githubusercontent.com/placeholder-image.png)

## Features

- **Solution & Project Parsing**: Supports both legacy `.sln` and the modern XML-based `.slnx` files.
- **LSP Integration**: Leverages `csharp_ls` for accurate project structure and file discovery.
- **Nvim-Tree Integration**: Proxies file system operations (create, rename, delete) to `nvim-tree.lua` for a consistent experience.
- **Finding Files**: Quickly locate the current buffer in the solution tree using `CSharpExplorerFindFile`.
- **Gitignore Filtering**: Toggle visibility of gitignored files.
- **Custom Clipboard**: Standalone copy/cut/paste functionality specifically for C# project items.

## Prerequisites

- Neovim 0.9.0+
- `csharp_ls` (Language Server)
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
    icons = {
        solution = "󰘐 ",
        folder_open = "󰜢 ",
        folder_closed = "󰉋 ",
        project = "󰌛 ",
        cs_file = "󰠱 ",
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
    }
})
```

## Commands

- `:CSharpExplorer`: Toggle the solution explorer.
- `:CSharpExplorerFindFile`: Reveal current file in the explorer.

## Roadmap

We aim to achieve feature parity with IDE-like solution trees (Visual Studio/Rider). See our detailed [ROADMAP.md](ROADMAP.md) for more details.

## Development

- **Formatting**: This project uses [StyLua](https://github.com/JohnnyMorganz/StyLua) for code formatting. A `.stylua.toml` is provided in the root.
- **Linting**: We recommend using `luacheck` for static analysis.

## License

MIT

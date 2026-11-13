# csharp-explorer.nvim

A lightweight C# Solution Explorer for Neovim that renders `.sln` and `.slnx` hierarchies and integrates with `nvim-tree.lua`.

[![Video](https://github.com/user-attachments/assets/a026d7b2-978f-4cbf-af6c-c3a84d76030c)](https://github.com/user-attachments/assets/dd0c0cf4-1b53-446e-aa7a-66aadf7a78cb)

## Features

- **Solution & Project Parsing**: Parses both classic `.sln` and XML `.slnx` solutions directly without waiting for an LSP server.
- **Dependencies Tree**: Pins a virtual `Dependencies` node at the top of each expanded project with `Packages` (direct NuGet packages and resolved versions) and `Projects` (project-to-project references), backed by `obj/project.assets.json` and an MSBuild XML fallback (`Directory.Packages.props`, `Directory.Build.props`, and `<Import>`).
- **Project Reference Navigation**: Press `<CR>` on an in-solution project reference to reveal and jump to that project in the explorer, or press `<C-v>` (and `<CR>` on external references) to open the target `.csproj` in the editor.
- **Project Properties Shortcut**: Press `P` in the explorer or run `:CSharpExplorerOpenProperties` from any C# buffer to edit the owning `.csproj` file.
- **File Parsing Integration**: Displays C# source files, `appsettings*.json`, `Dockerfile`, and `.http` files inside each project.
- **Nvim-Tree Integration**: Proxies create, rename, and delete actions to `nvim-tree.lua` while blocking destructive edits on virtual metadata nodes.
- **Live Metadata Sync**: Refreshes dependency nodes automatically on `BufWritePost` for `*.csproj`, `*.props`, `*.targets`, and `project.assets.json` while keeping expanded folders open.
- **Finding Files**: Locate the active source buffer or `.csproj` in the solution tree with `:CSharpExplorerFindFile`.
- **Gitignore Filtering & Clipboard**: Toggle gitignored files with `I` and copy, cut, or paste project files directly in the tree.

## Prerequisites

- Neovim 0.9.0+
- [nvim-tree/nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua)
- [nvim-tree/nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) (optional, for icons)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "dtrh95/csharp-explorer.nvim",
    dependencies = {
        "nvim-tree/nvim-tree.lua",
        "nvim-tree/nvim-web-devicons",
    },
    config = function()
        require("csharp-explorer").setup({})
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
        dependencies = "󰆧 ",
        package_group = "󰏗 ",
        package = "󰏗 ",
        project_reference_group = "󰌛 ",
        project_reference = "󰌛 ",
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
        open_properties = "P",
        toggle_gitignore = "I",
        expand_all = "E",
        collapse_all = "W",
    },
})
```

## Commands

- `:CSharpExplorer` / `:CSharpExplorerToggle`: Toggle the solution explorer window.
- `:CSharpExplorerFindFile`: Reveal the active source file or `.csproj` in the explorer.
- `:CSharpExplorerOpenProperties`: Open the owning `.csproj` for the focused explorer node or active buffer.
- `:CSharpExplorerEnable` / `:CSharpExplorerDisable` / `:CSharpExplorerTogglePlugin`: Enable, disable, or toggle plugin state.
- `:CSharpExplorerRefresh`: Re-parse the solution and refresh expanded nodes.
- `:CSharpExplorerExpandAll`: Expand all solution and project folders.
- `:CSharpExplorerCollapseAll`: Collapse all nodes below the solution root.

## Events

Listen to Neovim `User` autocommands to react when the plugin is enabled or disabled:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "CSharpExplorerEnable",
    callback = function()
        print("CSharpExplorer is active")
    end,
})
```

## Roadmap

See [ROADMAP.md](ROADMAP.md) for completed and upcoming milestones.

## Development

- **Formatting**: Format Lua sources with `stylua lua/ --config-path .stylua.toml`.
- **Linting**: Check static diagnostics with `luacheck lua/ --config .luacheckrc`.

## License

MIT

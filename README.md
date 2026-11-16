# csharp-explorer.nvim

A lightweight C# Solution Explorer for Neovim that renders `.sln` and `.slnx` hierarchies with safe refactoring, namespace synchronization, and solution search.

[![Video](https://github.com/user-attachments/assets/a026d7b2-978f-4cbf-af6c-c3a84d76030c)](https://github.com/user-attachments/assets/dd0c0cf4-1b53-446e-aa7a-66aadf7a78cb)

## Features

- **Solution and Project Parsing**: Parses classic `.sln` and XML `.slnx` solutions directly without waiting for an LSP server.
- **Integrated Build Control**: Run `dotnet build` with `B`, `dotnet restore` with `R`, and `dotnet clean` with `C` on any solution, solution folder, project, directory, or source file. Tasks stream output to an asynchronous ring buffer and floating log window toggled by `O` or stopped with `X`. Build errors populate the quickfix list and sync to `vim.diagnostic` namespace `CSharpExplorerBuild`.
- **Test Discovery and Execution**: Discovers xUnit, NUnit, and MSTest tests from C# source code with a lexical scanner. Press `T` in the tree to run tests across a solution, solution folder, project, or directory. On a test file, press `T` to select an individual test or run the whole file. From editor buffers, `:CSharpExplorerTestNearest` runs the enclosing test method or class. Test failures populate the quickfix list with exact source line numbers.
- **Solution and Item Templates**: Press `A` to add projects or C# item files for the focused target. When focused on a solution or solution folder, `A` creates a new .NET project and adds it to the solution file with `dotnet sln add`. On a project, directory, or file, `A` generates classes, interfaces, records, enums, structs, controllers, or test classes with namespace inference, file-scoped declarations, and UTF-8 LF output without a byte-order mark. Press `m` to open the contextual actions menu.
- **Safe Refactoring**: Create items with `a`, rename items with `r`, and delete items with `d`. When you rename a C# file or project, the plugin requests workspace symbol updates with Roslyn LSP `textDocument/rename` and sends `workspace/didChangeWatchedFiles` notifications. When LSP is inactive, the plugin updates primary type names, namespace references, companion files, `.csproj` project references, and `.sln` or `.slnx` solution records directly on disk. The explorer blocks rename and delete on virtual metadata nodes and the solution root. Safe delete checks for references across projects, directories, and source files before it removes items. When you delete a project, the plugin cleans referencing solution and project files.
- **Namespace Synchronization**: Synchronizes C# namespace declarations to match directory paths when files move or paste. Preserves file encoding, byte order marks, and CRLF line endings. Injects matching `using` directives in referencing files across the solution, and leaves intentional domain namespaces untouched during file moves. Press `N` in the explorer or run `:CSharpExplorerSyncNamespace` on any folder or file to synchronize namespaces on demand.
- **Solution-Scoped Search**: Live grep with `s`, search symbols with `S`, and find files with `f` scoped strictly to referenced projects in the active solution. The search scope excludes unreferenced directories and build output in `bin` and `obj`. The search action integrates with `fzf-lua`, `snacks.picker`, `telescope.nvim`, or the built-in `vim.ui.select` picker.
- **Dependencies Tree**: Pins a virtual `Dependencies` node at the top of each expanded project with `Packages` (direct NuGet packages and resolved versions) and `Projects` (project-to-project references), backed by `obj/project.assets.json` and an MSBuild XML fallback.
- **Project Reference Navigation**: Press `<CR>` on an in-solution project reference to reveal and jump to that project in the explorer, or press `<C-v>` to open the target `.csproj` in the editor.
- **Project Properties Shortcut**: Press `P` in the explorer or run `:CSharpExplorerOpenProperties` from any C# buffer to edit the owning `.csproj` file.
- **Diagnostic Signs Rollup**: Right-aligned virtual extmarks display error, warning, info, and hint counts from `vim.diagnostic`. Diagnostics roll up cleanly across nested parent files, directories, projects, and the solution root without altering buffer lines.
- **Single-Level File Nesting**: Groups code-behind files (`.xaml.cs`, `.razor.cs`, `.cshtml.cs`), designer files (`.Designer.cs`, `.vi.resx`), environment settings (`appsettings.*.json`), Docker files (`Dockerfile.*`, `.dockerignore`), and same-directory partial C# classes (`<Stem>.*.cs`) under their parent file. Toggle child visibility with `<Tab>` while keeping `<CR>` bound to opening the parent file in the editor.
- **Dynamic Project Icons**: Renders distinct icons and highlights for Web, Console, Library, and Test project archetypes classified from `.csproj` XML without reading `project.assets.json`.
- **Item Properties Inspector**: Press `K` in the explorer or run `:CSharpExplorerItemProperties` from any active buffer to open a centered floating window showing file details, build actions, C# namespace declarations, drift warnings, project settings, or package versions.
- **File Parsing Integration**: Displays C# source files, Razor components, Razor pages, XAML pages, resource files, `appsettings*.json`, `Dockerfile` variants, `.dockerignore`, and `.http` files inside each project.
- **Live Metadata Sync**: Refreshes dependency nodes automatically on `BufWritePost` for `*.csproj`, `*.props`, `*.targets`, and `project.assets.json` while keeping expanded folders open.
- **Finding Files**: Locate the active source buffer or `.csproj` in the solution tree with `:CSharpExplorerFindFile`.
- **Git Status and Clean Filtering**: Tracks working tree changes, staged items, renames, deletions, untracked files, merge conflicts, and branch names asynchronously via `git status --porcelain=v1 -z` without blocking the editor. Rolls up status across nested parent files, folders, dual-identity `.csproj` projects, virtual solution folders, and multi-repository solutions. Toggle gitignored files with `I`, hide clean files with `gC`, and jump across dirty items with `]c` and `[c`.
- **Clipboard Operations**: Copy, cut, and paste project files or directories directly in the tree.
- **Run Profiles and Orchestration**: Run project targets with `u` or select launch profiles with `U`. Discovers `launchSettings.json` across project subdirectories, strips JSONC comments and UTF-8 byte order marks, and runs projects with `dotnet run --no-launch-profile`. Applies profile environment variables, URLs, arguments, and working directories. Supports `dotnet watch --non-interactive` hot reload from `U`.
- **Rider-Style Run Tool Window**: Toggle the bottom run tool window with `L` or `:CSharpExplorerRunWindow`. The window opens below the editor column and keeps the explorer sidebar at full height. Shows process tabs (`g1` to `g9`, `]`, `[`), status icons, bounded ring-buffer logs, detected listening URLs (`<CR>` or `gx` opens the browser), follow-tail toggle (`f`), and single or global stop and restart keys.
- **JetBrains Rider-Style Debugger**: Launch projects in `netcoredbg` with `D` or select launch profiles with `gD`. Toggle the Rider-style bottom debug tool window with `M` or `:CSharpExplorerDebugWindow`. Supports multi-session tabs, view switching between Debugger, Console, and Breakpoints views, exception banners on uncaught exceptions, expandable watch expressions, expandable scope variables with property inspection, and interactive call stack navigation.
- **Run-to-Attach Debugging**: Press `d` inside the Run Tool Window to attach `netcoredbg` to the active running process without restarting the service. Detaching leaves the service alive and serving requests.
- **Unit Test Debugging**: Debug the nearest test method or test class with `:CSharpExplorerTestDebugNearest` or debug target tests with `gT`. Uses `VSTEST_HOST_DEBUG=1` to attach to the test host and pause on breakpoints in test code.
- **Mixed Run and Debug Compounds**: Group background run services and foreground debugged services in `.csharp-explorer/compounds.json` or Lua configuration. Compounds serialize background builds and manage simultaneous processes with unified shutdown.
- **Sticky Winbars and Tool Window Chrome**: The explorer sidebar, run window, and debug window render sticky winbars with active session tabs, view tabs, process status badges, and shortcut hints. Floating dialogs use centered titles, sharp single borders, and footer shortcut hints.
- **Contextual Keymap Help**: Press `?` in the explorer sidebar, run tool window, or debug tool window to open a categorized modal cheatsheet showing active keybindings and shortcuts.
- **Theme Integration**: Manages ordered `CSharpExplorer*` highlight groups modeled on `nvim-tree.lua` with semantic links, window-local `winhighlight` isolation, authentic `nvim-web-devicons` file icons alongside neutral labels, live `ColorScheme` reload synchronization, OKLCH anti-violet chrome protection, and `:CSharpExplorerHiTest` inspection.
- **Tree Process Status Badges**: Projects with active processes show right-aligned badges in the explorer tree, such as `● :5189` for listening web services, `● debug` for debugged sessions, `⏸ L21` for paused breakpoints, `◐ building`, or `▲ exit 1` on failure.
- **Compound Run Configurations**: Group multiple runnable projects into compound bundles in `.csharp-explorer/compounds.json` or Lua setup config. Press `gc` or run `:CSharpExplorerCompoundManage` to open the interactive checklist editor where you can select member projects, configure launch profiles, run, edit, or delete compounds.
- **Project Reload and LSP Recovery**: Press `gR` or run `:CSharpExplorerReloadProjects` to reload all projects in the solution. Writes modified solution buffers, clears metadata and build diagnostics, re-parses the solution while keeping expanded folders open, rebuilds the diagnostic index, restarts active C# language servers, and resurrects crashed language servers across loaded C# buffers.

## Prerequisites

- Neovim 0.9.0+
- [.NET SDK](https://dotnet.microsoft.com/) 6.0+ (`dotnet` binary in `PATH` or configured via `orchestration.dotnet_cmd`)
- [mfussenegger/nvim-dap](https://github.com/mfussenegger/nvim-dap) (optional, required for debugging)
- [netcoredbg](https://github.com/Samsung/netcoredbg) (optional, required for debugging; discovered from `PATH` or Mason)
- [nvim-tree/nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) (optional)
- [nvim-tree/nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) (optional, for icons)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "dtrh95/csharp-explorer.nvim",
    dependencies = {
        "nvim-tree/nvim-web-devicons",
        "nvim-tree/nvim-tree.lua",
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
        launch_settings = " ",
        dependencies = "󰆧 ",
        package_group = "󰏗 ",
        package = "󰏗 ",
        project_reference_group = "󰌛 ",
        project_reference = "󰌛 ",
    },
    project_highlights = {
        web = "CSharpExplorerTreeProjectWeb",
        console = "CSharpExplorerTreeProjectConsole",
        library = "CSharpExplorerTreeProjectLib",
        test = "CSharpExplorerTreeProjectTest",
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
            error = "CSharpExplorerDiagnosticError",
            warn = "CSharpExplorerDiagnosticWarn",
            info = "CSharpExplorerDiagnosticInfo",
            hint = "CSharpExplorerDiagnosticHint",
        },
    },
    properties = {
        border = "single",
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
    run = {
        default_profile = nil,
        focus_on_run = false,
        window_height = 12,
        max_log_lines = 5000,
        auto_scroll = true,
        wrap = true,
        terminate_timeout_ms = 1500,
        compounds = {},
    },
    debug = {
        adapter_cmd = nil,
        just_my_code = true,
        stop_at_entry = false,
        auto_open_window = true,
        focus_on_break = false,
        window_height = 14,
        max_log_lines = 5000,
        auto_scroll = true,
        wrap = true,
        eval_timeout_ms = 5000,
        vstest_timeout_ms = 20000,
        exception_filters = { "user-unhandled" },
    },
    filter = {
        gitignored = true,
        git_clean = false,
    },
    git = {
        enable = true,
        timeout = 400,
        max_timeouts = 5,
        debounce_ms = 120,
        show_branch = true,
        show_on_dirs = true,
        show_on_open_dirs = false,
        show_on_nested_parents = true,
        placement = "right_align",
        icons = {
            conflict = "",
            staged = "✓",
            modified = "✗",
            renamed = "➜",
            deleted = "",
            untracked = "★",
            ignored = "◌",
        },
    },
    refactor = {
        lsp_rename = true,
        confirm_delete = true,
        sync_namespace_on_move = true,
        inject_usings_on_move = true,
        save_modified_buffers = true,
    },
    search = {
        picker = "auto",
        symbol_source = "hybrid",
    },
    ui = {
        width = 30,
        sync_nvim_tree_width = true,
        winbar = true,
        border = "single",
    },
    appearance = {
        border = "single",
        devicons = {
            enable = true,
            color = true,
        },
        highlight_clipboard = "all",
        highlight_diagnostics = "none",
        highlight_git = "none",
        highlight_project_names = false,
        sanitize_anti_violet = true,
        highlights = {},
    },
    keymaps = {
        help = "?",
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
        toggle_git_clean = "gC",
        next_git = "]c",
        prev_git = "[c",
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
        sync_namespace = "N",
        search_text = "s",
        search_symbols = "S",
        find_files = "f",
        run = "u",
        run_select = "U",
        run_window = "L",
        debug = "D",
        debug_select = "gD",
        debug_test = "gT",
        debug_window = "M",
        manage_compounds = "gc",
        reload_all = "gR",
    },
})
```

## Commands

- `:CSharpExplorer` or `:CSharpExplorerToggle`: Toggle the solution explorer window.
- `:CSharpExplorerHiTest`: Open the appearance highlight inspector showing link chains and resolved attributes.
- `:CSharpExplorerCreate`: Create a file or folder for the focused node or directory.
- `:CSharpExplorerRename`: Safely rename the focused item or project.
- `:CSharpExplorerDelete`: Safely delete the focused item or project.
- `:CSharpExplorerSyncNamespace`: Synchronize C# namespaces with the directory structure.
- `:CSharpExplorerSearchText`: Live grep text across projects in the active solution.
- `:CSharpExplorerSearchSymbols`: Search symbols across projects in the active solution.
- `:CSharpExplorerFindFiles`: Find files across projects in the active solution.
- `:CSharpExplorerFindFile`: Reveal the active source file or `.csproj` in the explorer.
- `:CSharpExplorerOpenProperties`: Open the owning `.csproj` for the focused explorer node or active buffer.
- `:CSharpExplorerItemProperties`: Open the floating item properties inspector for the focused explorer node or active buffer.
- `:CSharpExplorerBuild`: Build the focused target or owning project.
- `:CSharpExplorerRestore`: Restore dependencies for the focused target or owning project.
- `:CSharpExplorerClean`: Clean build outputs for the focused target or owning project.
- `:CSharpExplorerTest`: Run unit tests for the focused target or active file.
- `:CSharpExplorerTestNearest`: Run the nearest test method or test class enclosing the editor cursor.
- `:CSharpExplorerTestSelect`: Open an interactive selector to run specific tests in the current file.
- `:CSharpExplorerAdd`: Create a project or a C# item file for the focused target.
- `:CSharpExplorerAddItem`: Open the C# item template picker.
- `:CSharpExplorerAddProject`: Open the .NET project template wizard.
- `:CSharpExplorerActions`: Open the contextual actions menu.
- `:CSharpExplorerTaskOutput`: Toggle the floating task output log.
- `:CSharpExplorerCancel`: Cancel the running dotnet task.
- `:CSharpExplorerEnable`, `:CSharpExplorerDisable`, or `:CSharpExplorerTogglePlugin`: Enable, disable, or toggle plugin state.
- `:CSharpExplorerRefresh`: Re-parse the solution and refresh expanded nodes.
- `:CSharpExplorerGitRefresh`: Re-scan Git status across all repositories in the active solution.
- `:CSharpExplorerGitToggleClean`: Toggle hiding clean Git items in the explorer tree.
- `:CSharpExplorerGitNext` and `:CSharpExplorerGitPrev`: Jump to the next or previous modified Git item in the explorer tree.
- `:CSharpExplorerExpandAll`: Expand all solution and project folders.
- `:CSharpExplorerCollapseAll`: Collapse all nodes below the solution root.
- `:CSharpExplorerRun`: Run the project or profile for the focused target.
- `:CSharpExplorerRunSelect`: Select and run a project launch profile or compound configuration.
- `:CSharpExplorerRunStop`: Stop the active process for the focused project or current run window session.
- `:CSharpExplorerRunStopAll`: Stop all running processes across the solution.
- `:CSharpExplorerRunRestart`: Restart the active process for the focused project or current run window session.
- `:CSharpExplorerRunWindow`: Toggle the Rider-style bottom run tool window.
- `:CSharpExplorerCompound`: Run a compound launch configuration by name.
- `:CSharpExplorerCompoundManage`: Open the interactive compound configuration manager.
- `:CSharpExplorerReloadProjects`: Reload all projects, refresh solution tree expansion, and recover crashed C# language servers.
- `:CSharpExplorerDebug`: Launch the project or profile for the focused target in the debugger.
- `:CSharpExplorerDebugSelect`: Select a debug launch profile, compound, or attach to a running process.
- `:CSharpExplorerDebugCompound`: Launch a compound debug configuration by name.
- `:CSharpExplorerDebugAttach`: Attach the debugger to a running .NET process.
- `:CSharpExplorerDebugWindow`: Toggle the Rider-style bottom debug tool window.
- `:CSharpExplorerBreakpointToggle`: Toggle a breakpoint at the current cursor line.
- `:CSharpExplorerBreakpointCondition`: Set or edit a condition on the current line breakpoint.
- `:CSharpExplorerDebugContinue`: Continue execution in the active debug session.
- `:CSharpExplorerDebugStepOver`: Step over in the active debug session.
- `:CSharpExplorerDebugStepInto`: Step into in the active debug session.
- `:CSharpExplorerDebugStepOut`: Step out in the active debug session.
- `:CSharpExplorerDebugPause`: Pause execution in the active debug session.
- `:CSharpExplorerDebugRestart`: Restart the active debug session.
- `:CSharpExplorerDebugStop`: Stop or detach the active debug session.
- `:CSharpExplorerDebugStopAll`: Stop all active debug sessions.
- `:CSharpExplorerDebugEvaluate`: Prompt for a C# expression and evaluate it in the active frame.
- `:CSharpExplorerDebugAddWatch`: Add a watch expression to the debugger.
- `:CSharpExplorerTestDebug`: Debug unit tests for the focused target.
- `:CSharpExplorerTestDebugNearest`: Debug the nearest unit test enclosing the cursor.
- `:CSharpExplorerTestDebugSelect`: Select and debug a unit test in the current file.

## Events

Listen to Neovim `User` autocommands to react when projects reload or plugin state changes:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "CSharpExplorerProjectsReloaded",
    callback = function(ev)
        local data = ev.data
        print(string.format("Reloaded %d projects in %dms", data.projects_count, data.elapsed_ms))
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

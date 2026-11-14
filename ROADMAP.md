# Roadmap to IDE-Like Solution Explorer

This roadmap outlines the journey of `csharp-explorer.nvim` toward achieving feature parity with the solution trees in Visual Studio and JetBrains Rider.

## Phase 1: Project Metadata & Dependencies 📦

_Focus: Visibility into what makes up a project beyond just source files._

- [x] **NuGet Package Integration**:
  - Display a "Packages" node under each project.
  - List installed NuGet packages and versions.
- [x] **Project References**:
  - Display a "Dependencies" or "References" node.
  - Show links to other projects in the solution.
- [x] **Project Properties Access**:
  - Quick shortcut to open the `.csproj` file for editing.

## Phase 2: Enhanced UI & Visual Feedback 🎨

_Focus: Bringing the richness of IDE trees to the Neovim buffer._

- [x] **Diagnostic Signs**:
  - Show error/warning icons next to files/projects (integrated with `vim.diagnostic`).
- [x] **File Nesting**:
  - Logic to group related files (e.g., `App.xaml` -> `App.xaml.cs`).
- [x] **Dynamic Icon Themes**:
  - Support for project-specific icons (Web, Console, Library, Test).
- [x] **Item Metadata (Properties Window)**:
  - Floating window showing file details (Size, Type, Build Action, Namespace).

## Phase 3: Project Orchestration 🛠️

_Focus: Taking action on the solution directly from the explorer._

- [x] **Integrated Build Control**:
  - Bindings for `dotnet build`, `dotnet restore`, and `dotnet clean` on specific projects or the whole solution.
- [x] **Test Integration**:
  - Discover and run tests directly from a project/file node.
- [x] **Solution/Project Templates**:
  - Interface for `dotnet new` to add projects or classes via UI prompts.

## Phase 4: Intelligence & Refactoring 🧠

_Focus: Deep integration with LSP and build tools._

- [x] **Safe Refactoring**:
  - Rename and delete operations that update file and symbol references across the solution through LSP.
- [x] **Namespace Syncing**:
  - Automatically update namespace declarations when moving files between folders.
- [x] **Search Within Solution**:
  - Global symbol search scoped to the explorer tree.

## Phase 5: Run Orchestration & Environment Management

_Focus: Multi-project execution, launch profiles, compound runs, and project reload._

- [x] **Launch Settings Discovery and Execution**:
  - Recursive `launchSettings.json` discovery that skips build output and hidden directories.
  - Strips JSONC comments, trailing commas, and UTF-8 byte order marks.
  - Runs projects with `dotnet run --no-launch-profile` and applies profile environment variables, URLs, working directories, and arguments.
  - Supports `dotnet watch --non-interactive` hot reload.
- [x] **Multi-Process Runtime and Rider-Style Tool Window**:
  - Asynchronous process runtime with process-group termination and escalation timers.
  - Bottom tool window docked below the editor column with process tabs, status icons, listening URLs, and bounded ring-buffer logs.
  - Live tree status badges for listening ports and exit codes.
- [x] **Compound Run Configurations**:
  - Multi-project launch bundles stored in `.csharp-explorer/compounds.json` or Lua setup config.
  - Interactive manager to run, create, edit, or delete compound configurations.
- [x] **Project Reload and LSP Recovery**:
  - Re-parses solutions while keeping expanded folders open.
  - Writes modified solution buffers and clears metadata caches.
  - Restarts active C# language servers and resurrects crashed servers.

---

## Progress Tracking

Completed **Phase 0 (Foundation)**, **Phase 1 (Project Metadata & Dependencies)**, **Phase 2 (Enhanced UI & Visual Feedback)**, **Phase 3 (Project Orchestration)**, **Phase 4 (Intelligence & Refactoring)**, and **Phase 5 (Run Orchestration & Environment Management)**.

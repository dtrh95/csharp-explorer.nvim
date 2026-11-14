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

- [ ] **Safe Refactoring**:
  - Rename/Delete operations that update File & Symbol references across the whole solution via LSP.
- [ ] **Namespace Syncing**:
  - Automatically update `namespace` declarations when a file is moved between folders.
- [ ] **Search Within Solution**:
  - Global symbol search scoped to the explorer tree.

---

## Progress Tracking

Completed **Phase 0 (Foundation)**, **Phase 1 (Project Metadata & Dependencies)**, **Phase 2 (Enhanced UI & Visual Feedback)**, and **Phase 3 (Project Orchestration)**. Next up is **Phase 4 (Intelligence & Refactoring)**.

vim.opt.runtimepath:append(vim.fn.getcwd())

local cs = require("csharp-explorer")
local git = require("csharp-explorer.git")
local parser = require("csharp-explorer.git.parser")
local appearance = require("csharp-explorer.ui.appearance")
local clipboard = require("csharp-explorer.actions.clipboard")
local properties = require("csharp-explorer.actions.properties")
local renderer = require("csharp-explorer.renderer")

local function run_test(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        io.stderr:write(string.format("FAIL: %s\n%s\n", name, tostring(err)))
        vim.cmd("cquit 1")
    else
        io.stdout:write(string.format("PASS: %s\n", name))
    end
end

local function sh(cwd, cmd)
    local out = vim.fn.system("cd " .. vim.fn.shellescape(cwd) .. " && " .. cmd)
    assert(vim.v.shell_error == 0, "command failed: " .. cmd .. "\n" .. tostring(out))
    return out
end

local function write_text(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = io.open(path, "w")
    assert(f, "failed to open " .. path)
    f:write(content)
    f:close()
end

run_test("streaming porcelain -z parser handles chunk splits, renames, copies, and ignored dirs", function()
    local entries = {}
    local ignored_dirs = {}
    local stream = parser.new(function(e)
        entries[#entries + 1] = e
    end, function(d)
        ignored_dirs[#ignored_dirs + 1] = d
    end)

    local payload = table.concat({
        "UU src/Conflict.cs\0",
        "R  src/New Service.cs\0src/Old Service.cs\0",
        "C  src/Copy.cs\0src/Source.cs\0",
        "!! bin/\0",
        "!! src/secret.gen.cs\0",
        "MM src/Mixed.cs\0",
        " D src/Removed.cs\0",
        "?? src/Untracked.cs\0",
    })

    for i = 1, #payload, 5 do
        stream.push(payload:sub(i, math.min(#payload, i + 4)))
    end
    stream.finish()

    assert(#ignored_dirs == 1 and ignored_dirs[1] == "bin", "expected bin in ignored_dirs")
    assert(#entries == 7, "expected 7 file entries, got " .. #entries)

    assert(entries[1].kind == "conflict" and entries[1].prio == 1, "expected conflict prio 1")
    assert(
        entries[2].kind == "renamed"
            and entries[2].path == "src/New Service.cs"
            and entries[2].orig_path == "src/Old Service.cs",
        "expected rename with orig_path preserved"
    )
    assert(
        entries[3].kind == "staged" and entries[3].path == "src/Copy.cs" and entries[3].orig_path == "src/Source.cs",
        "expected copy with orig_path preserved"
    )
    assert(entries[4].kind == "ignored" and entries[4].path == "src/secret.gen.cs", "expected ignored file entry")
    assert(entries[5].kind == "modified" and entries[5].prio == 3, "expected mixed MM mapped to modified")
    assert(entries[6].kind == "deleted" and entries[6].is_deleted == true, "expected deleted entry with is_deleted")
    assert(entries[7].kind == "untracked" and entries[7].prio == 6, "expected untracked entry")
end)

run_test("real git repository 5-container rollup, filters, navigation, winbar branch, and properties", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")

    sh(root, "git init -b main")
    sh(root, "git config user.email 'test@example.com'")
    sh(root, "git config user.name 'Test Runner'")

    write_text(root .. "/.gitignore", "*.gen.cs\nignored_dir/\nbin/\nobj/\n")
    write_text(
        root .. "/Demo.slnx",
        table.concat({
            "<Solution>",
            '  <Folder Name="/Backend/">',
            '    <Project Path="src/App.Web/App.Web.csproj" />',
            '    <Project Path="src/App.Clean/App.Clean.csproj" />',
            "  </Folder>",
            "</Solution>\n",
        }, "\n")
    )

    write_text(
        root .. "/src/App.Web/App.Web.csproj",
        '<Project Sdk="Microsoft.NET.Sdk.Web"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>\n'
    )
    write_text(root .. "/src/App.Web/Program.cs", "var app = 1;\n")
    write_text(root .. "/src/App.Web/OldName.cs", "class OldName {}\n")
    write_text(root .. "/src/App.Web/appsettings.json", "{}\n")
    write_text(root .. "/src/App.Web/appsettings.Development.json", "{}\n")
    write_text(root .. "/src/App.Web/Sub/Worker.cs", "class Worker {}\n")
    write_text(root .. "/src/App.Web/Sub/ToDelete.cs", "class ToDelete {}\n")

    write_text(
        root .. "/src/App.Clean/App.Clean.csproj",
        '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>\n'
    )
    write_text(root .. "/src/App.Clean/CleanService.cs", "class CleanService {}\n")

    sh(root, "git add -A && git commit -m 'initial'")

    write_text(root .. "/src/App.Web/appsettings.Development.json", '{ "Logging": true }\n')
    sh(root, "git mv src/App.Web/OldName.cs src/App.Web/NewName.cs")
    os.remove(root .. "/src/App.Web/Sub/ToDelete.cs")
    write_text(root .. "/src/App.Web/Untracked.cs", "class Untracked {}\n")
    write_text(root .. "/src/App.Web/Skipped.gen.cs", "class Skipped {}\n")
    write_text(root .. "/src/App.Web/ignored_dir/Hidden.cs", "class Hidden {}\n")

    local orig_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    vim.cmd("colorscheme habamax")

    cs.setup({
        git = {
            enable = true,
            show_branch = true,
            show_on_dirs = true,
            show_on_open_dirs = false,
            show_on_nested_parents = true,
            placement = "right_align",
        },
        appearance = {
            highlight_git = "none",
        },
    })

    cs.toggle()
    local scan_done = false
    git.refresh(cs, {
        force = true,
        on_complete = function()
            scan_done = true
        end,
    })
    local ok_wait = vim.wait(3000, function()
        return scan_done and git.is_indexed(root)
    end, 20)
    assert(ok_wait, "timed out waiting for async git scan")

    assert(vim.wo[cs.win].winbar:find(" main", 1, true) ~= nil, "expected branch main in sidebar winbar")

    local sol_status = git.get_node_status(cs.tree)
    assert(sol_status and sol_status.is_dirty == true, "expected solution root dirty rollup")

    local backend_folder = cs.tree._children["Backend"]
    assert(backend_folder ~= nil and backend_folder._dir == nil, "expected virtual Backend solution folder")
    local backend_status = git.get_node_status(backend_folder)
    assert(backend_status and backend_status.is_dirty == true, "expected virtual solution_folder dirty rollup")

    backend_folder._expanded = true
    local web_proj = backend_folder._children["App.Web"]
    local clean_proj = backend_folder._children["App.Clean"]
    assert(web_proj ~= nil and clean_proj ~= nil, "expected App.Web and App.Clean projects")

    assert(git.get_node_status(web_proj).is_dirty == true, "expected collapsed App.Web dirty")
    assert(git.get_node_status(clean_proj) == nil, "expected App.Clean clean (nil status)")

    web_proj._expanded = true
    renderer.render(cs)

    assert(web_proj._children["Skipped.gen.cs"] == nil, "expected Skipped.gen.cs filtered by async gitignore index")
    assert(web_proj._children["ignored_dir"] == nil, "expected ignored_dir pruned by async gitignore index")

    local appsettings_node = web_proj._children["appsettings.json"]
    assert(appsettings_node ~= nil and appsettings_node._expanded == false, "expected collapsed appsettings.json")
    local nested_rollup = git.get_node_status(appsettings_node)
    assert(
        nested_rollup and nested_rollup.kind == "modified",
        "expected collapsed nested parent appsettings.json to roll up child modification"
    )

    appsettings_node._expanded = true
    assert(git.get_node_status(appsettings_node) == nil, "expected expanded clean parent appsettings.json to be nil")

    local sub_folder = web_proj._children["Sub"]
    assert(sub_folder ~= nil, "expected Sub folder")
    sub_folder._expanded = true
    renderer.render(cs)
    local open_sub_status = git.get_node_status(sub_folder)
    assert(
        open_sub_status and open_sub_status.kind == "deleted",
        "expected expanded Sub folder to preserve deleted child badge when show_on_open_dirs is false"
    )

    local renamed_node = web_proj._children["NewName.cs"]
    assert(renamed_node ~= nil, "expected NewName.cs in tree")
    local prop_model = properties.inspect_node(renamed_node, cs)
    local found_git_row = nil
    for _, row in ipairs(prop_model.rows) do
        if row.label == "Git status" then
            found_git_row = row.value
        end
    end
    assert(
        found_git_row and found_git_row:find("from OldName.cs", 1, true) ~= nil,
        "expected rename origin in Item properties Git status, got: " .. tostring(found_git_row)
    )

    local proj_prop = properties.inspect_node(clean_proj, cs)
    local found_branch, found_clean = nil, nil
    for _, row in ipairs(proj_prop.rows) do
        if row.label == "Git branch" then
            found_branch = row.value
        elseif row.label == "Git status" then
            found_clean = row.value
        end
    end
    assert(found_branch == "main" and found_clean == "Clean", "expected branch=main and status=Clean on App.Clean")

    write_text(
        root .. "/src/App.Clean/App.Clean.csproj",
        '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><Nullable>enable</Nullable></PropertyGroup></Project>\n'
    )
    sh(root, "git checkout -b feat/git-branch-check")

    scan_done = false
    git.refresh(cs, {
        force = true,
        on_complete = function()
            scan_done = true
        end,
    })
    assert(
        vim.wait(3000, function()
            return scan_done
        end, 20),
        "timed out refreshing after csproj edit and branch switch"
    )

    clean_proj._expanded = true
    renderer.render(cs)
    local dual_status = git.get_node_status(clean_proj)
    assert(
        dual_status and dual_status.kind == "modified",
        "expected dual-identity .csproj modification visible even when project is expanded"
    )
    assert(
        git.get_branch(cs.tree) == "feat/git-branch-check",
        "expected updated branch feat/git-branch-check on solution"
    )
    assert(
        vim.wo[cs.win].winbar:find(" feat", 1, true) ~= nil,
        "expected updated branch rendered (with width-budget truncation) in winbar"
    )

    local git_marks = vim.api.nvim_buf_get_extmarks(cs.buf, git.ns_id, 0, -1, { details = true })
    assert(#git_marks >= 4, "expected right-aligned git extmarks placed in buffer")

    cs.config.git.placement = "after"
    appearance.setup({ highlight_git = "all", highlight_clipboard = "name" })
    clipboard.cut(renamed_node)
    renderer.render(cs)

    local renamed_line = renamed_node._line_num - 1
    local rendered_line = vim.api.nvim_buf_get_lines(cs.buf, renamed_line, renamed_line + 1, false)[1]
    assert(rendered_line:find("NewName.cs ➜", 1, true) ~= nil, "expected inline 'after' git badge on NewName.cs")

    local tree_ns = vim.api.nvim_get_namespaces()["CSharpExplorer"]
    local r_marks = vim.api.nvim_buf_get_extmarks(
        cs.buf,
        tree_ns,
        { renamed_line, 0 },
        { renamed_line, -1 },
        { details = true }
    )
    for _, git_hl in ipairs({
        "CSharpExplorerGitConflictFileHL",
        "CSharpExplorerGitStagedFileHL",
        "CSharpExplorerGitModifiedFileHL",
        "CSharpExplorerGitRenamedFileHL",
        "CSharpExplorerGitDeletedFileHL",
        "CSharpExplorerGitUntrackedFileHL",
        "CSharpExplorerGitIgnoredFileHL",
    }) do
        assert(
            vim.api.nvim_get_hl(0, { name = git_hl, link = false }).bg == nil,
            "expected zero Diff background fill on " .. git_hl
        )
    end

    local has_combined_name = false
    local normal_bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
    local diag_info_fg = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false }).fg
    for _, m in ipairs(r_marks) do
        if tostring(m[4].hl_group):match("^CSharpExplorerCombinedHL") then
            local attrs = vim.api.nvim_get_hl(0, { name = m[4].hl_group, link = false })
            assert(attrs.bg == nil or attrs.bg == normal_bg, "expected no Diff background tint on combined highlight")
            if attrs.undercurl == true or attrs.underline == true then
                has_combined_name = true
                assert(attrs.fg == diag_info_fg, "expected git renamed foreground merged with cut underline")
            end
        end
    end
    assert(has_combined_name, "expected CSharpExplorerCombinedHL with cut underline + git fg on node name")

    vim.cmd("CSharpExplorerHiTest")
    local ht_buf = vim.api.nvim_get_current_buf()
    local ht_text = table.concat(vim.api.nvim_buf_get_lines(ht_buf, 0, -1, false), "\n")
    assert(ht_text:find("[Git]", 1, true) ~= nil, "expected [Git] domain in :CSharpExplorerHiTest")
    assert(
        ht_text:find("CSharpExplorerGitModifiedIcon", 1, true) ~= nil,
        "expected CSharpExplorerGitModifiedIcon in :CSharpExplorerHiTest"
    )
    vim.cmd("bdelete!")

    cs.toggle_git_clean()
    local filtered_lines = table.concat(vim.api.nvim_buf_get_lines(cs.buf, 0, -1, false), "\n")
    assert(filtered_lines:find("Program.cs", 1, true) == nil, "expected clean Program.cs hidden by gC filter")
    assert(filtered_lines:find("CleanService.cs", 1, true) == nil, "expected clean CleanService.cs hidden by gC filter")
    assert(filtered_lines:find("NewName.cs", 1, true) ~= nil, "expected dirty NewName.cs kept visible by gC filter")
    cs.toggle_git_clean()

    cs.collapse_all()
    vim.api.nvim_win_set_cursor(cs.win, { 1, 0 })
    cs.next_git()
    local cur1 = vim.api.nvim_win_get_cursor(cs.win)[1]
    local landed1 = renderer.line_to_node[cur1]
    assert(landed1 ~= nil and cur1 > 1, "expected ]c to auto-expand collapsed containers and land on dirty item")

    cs.prev_git()
    local cur_prev = vim.api.nvim_win_get_cursor(cs.win)[1]
    assert(cur_prev ~= cur1, "expected [c to wrap or move to previous dirty item")

    cs.toggle()
    git.detach()
    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    vim.fn.delete(root, "rf")
end)

run_test("multi-repo solution aggregates status and resolves per-project git branches independently", function()
    local workspace = vim.fn.tempname()
    local repo_a = workspace .. "/repo-a"
    local repo_b = workspace .. "/repo-b"
    vim.fn.mkdir(repo_a, "p")
    vim.fn.mkdir(repo_b, "p")

    sh(repo_a, "git init -b main && git config user.email 'a@example.com' && git config user.name 'Tester'")
    sh(repo_b, "git init -b develop && git config user.email 'b@example.com' && git config user.name 'Tester'")

    write_text(
        repo_a .. "/Multi.slnx",
        table.concat({
            "<Solution>",
            '  <Project Path="Core/Core.csproj" />',
            '  <Project Path="../repo-b/External/External.csproj" />',
            "</Solution>\n",
        }, "\n")
    )
    write_text(repo_a .. "/Core/Core.csproj", '<Project Sdk="Microsoft.NET.Sdk" />\n')
    write_text(repo_a .. "/Core/CoreService.cs", "class CoreService {}\n")
    sh(repo_a, "git add -A && git commit -m 'init repo-a'")

    write_text(repo_b .. "/External/External.csproj", '<Project Sdk="Microsoft.NET.Sdk" />\n')
    write_text(repo_b .. "/External/Adapter.cs", "class Adapter {}\n")
    sh(repo_b, "git add -A && git commit -m 'init repo-b'")

    write_text(repo_b .. "/External/Adapter.cs", "class Adapter { int X = 1; }\n")

    local orig_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(repo_a))

    cs.tree = nil
    cs.setup({ git = { enable = true, placement = "right_align" } })
    cs.toggle()

    local done = false
    git.refresh(cs, {
        force = true,
        on_complete = function()
            done = true
        end,
    })
    assert(
        vim.wait(3000, function()
            return done and git.is_indexed(repo_a) and git.is_indexed(repo_b)
        end, 20),
        "timed out indexing multi-repo solution"
    )

    local core_proj = cs.tree._children["Core"]
    local ext_proj = cs.tree._children["External"]
    assert(core_proj ~= nil and ext_proj ~= nil, "expected Core and External projects")

    assert(git.get_branch(core_proj) == "main", "expected Core project on branch main")
    assert(git.get_branch(ext_proj) == "develop", "expected External project on branch develop")
    assert(git.get_node_status(core_proj) == nil, "expected clean Core project in repo-a")

    local ext_stat = git.get_node_status(ext_proj)
    assert(ext_stat and ext_stat.kind == "modified", "expected dirty External project in repo-b")

    local sol_stat = git.get_node_status(cs.tree)
    assert(sol_stat and sol_stat.is_dirty == true, "expected Multi.slnx to aggregate dirty state from sibling repo-b")

    cs.toggle()
    git.detach()
    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    vim.fn.delete(workspace, "rf")
end)

io.stdout:write("ALL GIT INTEGRATION TESTS PASSED\n")
vim.cmd("qall!")

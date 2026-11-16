vim.opt.runtimepath:append(vim.fn.getcwd())

local cs = require("csharp-explorer")
local appearance = require("csharp-explorer.ui.appearance")
local window = require("csharp-explorer.ui.appearance.window")
local theme = require("csharp-explorer.ui.theme")
local clipboard = require("csharp-explorer.actions.clipboard")
local diagnostics = require("csharp-explorer.diagnostics")
local renderer = require("csharp-explorer.renderer")
local properties = require("csharp-explorer.actions.properties")
local run_window = require("csharp-explorer.ui.run_window")
local debug_window = require("csharp-explorer.ui.debug_window")
local keymap = require("csharp-explorer.keymap")

local function run_test(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        io.stderr:write(string.format("FAIL: %s\n%s\n", name, tostring(err)))
        vim.cmd("cquit 1")
    else
        io.stdout:write(string.format("PASS: %s\n", name))
    end
end

run_test("semantic highlight links, legacy alias adoption, and winbar facade", function()
    vim.cmd("highlight clear")
    vim.api.nvim_set_hl(0, "CSharpExplorerRoot", { fg = 0x1a4be0 })
    appearance.setup({})

    local legacy_bound = vim.api.nvim_get_hl(0, { name = "CSharpExplorerTreeRoot" })
    assert(legacy_bound.link == "CSharpExplorerRoot", "expected legacy CSharpExplorerRoot link")

    vim.cmd("colorscheme habamax")

    assert(
        vim.api.nvim_get_hl(0, { name = "CSharpExplorerNormalNC" }).link == "CSharpExplorerNormal",
        "expected CSharpExplorerNormalNC -> CSharpExplorerNormal"
    )
    assert(
        vim.api.nvim_get_hl(0, { name = "CSharpExplorerCut" }).link == "SpellBad",
        "expected CSharpExplorerCut -> SpellBad"
    )
    assert(
        vim.api.nvim_get_hl(0, { name = "CSharpExplorerCopied" }).link == "SpellRare",
        "expected CSharpExplorerCopied -> SpellRare"
    )
    assert(
        vim.api.nvim_get_hl(0, { name = "CSharpExplorerTabActive" }).link == "Title",
        "expected CSharpExplorerTabActive -> Title"
    )
    assert(
        vim.api.nvim_get_hl(0, { name = "CSharpExplorerPillActive" }).link == "Title",
        "expected CSharpExplorerPillActive -> Title"
    )
    assert(
        vim.api.nvim_get_hl(0, { name = "CSharpExplorerWinSeparator" }).link == "WinSeparator",
        "expected CSharpExplorerWinSeparator -> WinSeparator"
    )
    assert(
        vim.api.nvim_get_hl(0, { name = "CSharpExplorerEndOfBuffer" }).link == "EndOfBuffer",
        "expected CSharpExplorerEndOfBuffer -> EndOfBuffer"
    )

    local resolved_cut = vim.api.nvim_get_hl(0, { name = "CSharpExplorerCut", link = false })
    assert(resolved_cut.undercurl == true, "expected concrete undercurl from SpellBad")

    assert(theme.groups.TreeProject == "CSharpExplorerTreeProject", "expected theme.groups.TreeProject mapping")
    local compiled_wb = theme.format_winbar(
        { { "Left", "CSharpExplorerTitle" } },
        { { "Right", "CSharpExplorerMuted" } },
        30
    )
    assert(
        compiled_wb == "%*%#CSharpExplorerTitle#Left%*  %=%#CSharpExplorerMuted#Right%*%*",
        "unexpected winbar string: " .. tostring(compiled_wb)
    )
end)

run_test("OKLCH anti-violet boundary deflection and opt-out", function()
    cs.setup({
        appearance = {
            sanitize_anti_violet = true,
            highlights = {
                CSharpExplorerAccent = { fg = "#8b5cf6", bold = true },
                CSharpExplorerKey = { fg = "#c084fc" },
                CSharpExplorerBorder = { fg = "#2456d6" },
            },
        },
    })

    local accent_hl = vim.api.nvim_get_hl(0, { name = "CSharpExplorerAccent", link = false })
    assert(accent_hl.fg == 0x007ff5, string.format("expected deflected blue 0x007ff5, got 0x%06x", accent_hl.fg or 0))
    assert(accent_hl.bold == true, "expected bold attribute preserved on deflected override")

    local key_hl = vim.api.nvim_get_hl(0, { name = "CSharpExplorerKey", link = false })
    assert(key_hl.fg == 0xf072be, string.format("expected deflected rose 0xf072be, got 0x%06x", key_hl.fg or 0))

    local border_hl = vim.api.nvim_get_hl(0, { name = "CSharpExplorerBorder", link = false })
    assert(border_hl.fg == 0x2456d6, string.format("expected untouched 0x2456d6, got 0x%06x", border_hl.fg or 0))

    cs.setup({
        appearance = {
            sanitize_anti_violet = false,
            highlights = {
                CSharpExplorerAccent = { fg = "#8b5cf6" },
            },
        },
    })
    local raw_violet = vim.api.nvim_get_hl(0, { name = "CSharpExplorerAccent", link = false })
    assert(raw_violet.fg == 0x8b5cf6, "expected raw violet preserved when sanitize_anti_violet is false")
end)

run_test("end-to-end solution tree, devicons, combined decorators, ColorScheme sync, and HiTest", function()
    local root = vim.fn.tempname()
    local proj_dir = root .. "/src/App.Web"
    vim.fn.mkdir(proj_dir, "p")

    local slnx_file = io.open(root .. "/Sample.slnx", "w")
    assert(slnx_file, "failed to open Sample.slnx")
    slnx_file:write('<Solution>\n  <Project Path="src/App.Web/App.Web.csproj" />\n</Solution>\n')
    slnx_file:close()

    local csproj_file = io.open(proj_dir .. "/App.Web.csproj", "w")
    assert(csproj_file, "failed to open App.Web.csproj")
    csproj_file:write(
        '<Project Sdk="Microsoft.NET.Sdk.Web">\n  <PropertyGroup>\n    <TargetFramework>net8.0</TargetFramework>\n  </PropertyGroup>\n</Project>\n'
    )
    csproj_file:close()

    local cs_path = proj_dir .. "/Program.cs"
    local cs_file = io.open(cs_path, "w")
    assert(cs_file, "failed to open Program.cs")
    cs_file:write("var builder = WebApplication.CreateBuilder(args);\n")
    cs_file:close()

    vim.api.nvim_set_hl(0, "DevIconCs", { fg = 0x519aba })
    package.loaded["nvim-web-devicons"] = {
        get_icon = function(_name, ext)
            if ext == "cs" then
                return "󰌝", "DevIconCs"
            end
            return nil, nil
        end,
    }

    local orig_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(root))

    cs.setup({
        appearance = {
            border = "single",
            devicons = { enable = true, color = true },
            highlight_clipboard = "name",
            highlight_diagnostics = "name",
            highlights = {
                CSharpExplorerBorder = { fg = "#2456d6" },
            },
        },
    })

    vim.cmd("colorscheme habamax")
    cs.toggle()
    assert(cs.is_active == true, "expected explorer sidebar active")

    local sidebar_winhl = vim.wo[cs.win].winhighlight
    assert(
        sidebar_winhl:find("WinSeparator:CSharpExplorerWinSeparator", 1, true) ~= nil,
        "expected WinSeparator isolated in sidebar winhighlight"
    )
    assert(
        sidebar_winhl:find("EndOfBuffer:CSharpExplorerEndOfBuffer", 1, true) ~= nil,
        "expected EndOfBuffer isolated in sidebar winhighlight"
    )
    assert(sidebar_winhl:find("FloatBorder", 1, true) == nil, "unexpected FloatBorder in split winhighlight")

    local proj_node = nil
    for _, node in pairs(renderer.line_to_node) do
        if node._type == "project" then
            proj_node = node
            node._expanded = true
        end
    end
    assert(proj_node ~= nil, "expected App.Web project node in tree")
    renderer.render(cs)

    local file_line, file_node, proj_line = nil, nil, nil
    for lnum, node in pairs(renderer.line_to_node) do
        if node._name == "Program.cs" then
            file_line = lnum - 1
            file_node = node
        elseif node._type == "project" then
            proj_line = lnum - 1
        end
    end
    assert(file_node ~= nil and file_line ~= nil and proj_line ~= nil, "expected expanded Program.cs node")

    local tree_ns = vim.api.nvim_get_namespaces()["CSharpExplorer"]
    local proj_marks = vim.api.nvim_buf_get_extmarks(
        cs.buf,
        tree_ns,
        { proj_line, 0 },
        { proj_line, -1 },
        { details = true }
    )
    local proj_hls = {}
    for _, m in ipairs(proj_marks) do
        proj_hls[#proj_hls + 1] = m[4].hl_group
    end
    assert(vim.tbl_contains(proj_hls, "CSharpExplorerTreeProjectWeb"), "expected archetype highlight on project icon")
    assert(vim.tbl_contains(proj_hls, "CSharpExplorerTreeProject"), "expected neutral highlight on project name")

    local file_marks = vim.api.nvim_buf_get_extmarks(
        cs.buf,
        tree_ns,
        { file_line, 0 },
        { file_line, -1 },
        { details = true }
    )
    local file_hls = {}
    for _, m in ipairs(file_marks) do
        file_hls[#file_hls + 1] = m[4].hl_group
    end
    assert(vim.tbl_contains(file_hls, "DevIconCs"), "expected authentic DevIconCs on file icon")
    assert(vim.tbl_contains(file_hls, "CSharpExplorerTreeFile"), "expected neutral CSharpExplorerTreeFile on file name")

    local file_buf = vim.fn.bufadd(cs_path)
    vim.fn.bufload(file_buf)
    local diag_ns = vim.api.nvim_create_namespace("AppearanceTestDiag")
    vim.diagnostic.set(diag_ns, file_buf, {
        { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "CS1002" },
    })
    diagnostics.rebuild_index()
    clipboard.cut(file_node)
    renderer.render(cs)

    local decorated_marks = vim.api.nvim_buf_get_extmarks(
        cs.buf,
        tree_ns,
        { file_line, 0 },
        { file_line, -1 },
        { details = true }
    )
    local combined_group = nil
    for _, m in ipairs(decorated_marks) do
        if tostring(m[4].hl_group):match("^CSharpExplorerCombinedHL") then
            combined_group = m[4].hl_group
        end
    end
    assert(combined_group ~= nil, "expected CSharpExplorerCombinedHL group on cut + error file name")

    local habamax_diag = vim.api.nvim_get_hl(0, { name = "DiagnosticUnderlineError", link = false })
    local habamax_combined = vim.api.nvim_get_hl(0, { name = combined_group, link = false })
    assert(
        habamax_combined.undercurl == true or habamax_combined.underline == true,
        "expected underline/undercurl merged"
    )
    assert(habamax_combined.sp == habamax_diag.sp, "expected diagnostic error sp merged in habamax")

    vim.cmd("colorscheme morning")
    assert(
        vim.api.nvim_get_hl(0, { name = "CSharpExplorerBorder", link = false }).fg == 0x2456d6,
        "expected user highlight override preserved after colorscheme morning"
    )
    assert(
        vim.wo[cs.win].winhighlight == sidebar_winhl,
        "expected sidebar winhighlight preserved after colorscheme morning"
    )
    local morning_diag = vim.api.nvim_get_hl(0, { name = "DiagnosticUnderlineError", link = false })
    local morning_combined = vim.api.nvim_get_hl(0, { name = combined_group, link = false })
    assert(morning_combined.sp == morning_diag.sp, "expected combined group regenerated with morning palette")

    local _, prop_win = properties.show_node(file_node, cs)
    local prop_cfg = vim.api.nvim_win_get_config(prop_win)
    local top_left = type(prop_cfg.border) == "table" and prop_cfg.border[1] or prop_cfg.border
    if type(top_left) == "table" then
        top_left = top_left[1]
    end
    assert(
        top_left == "┌" or top_left == "single",
        "expected sharp single border on properties float, got " .. tostring(top_left)
    )
    assert(
        vim.wo[prop_win].winhighlight:find("FloatTitle:CSharpExplorerTitle", 1, true) ~= nil,
        "expected FloatTitle mapped on float window"
    )
    properties.close()
    vim.cmd("doautocmd WinClosed " .. prop_win)
    assert(window.get_tracked()[prop_win] == nil, "expected closed float evicted from window tracker")

    vim.cmd("CSharpExplorerHiTest")
    local hitest_win = vim.api.nvim_get_current_win()
    local hitest_buf = vim.api.nvim_win_get_buf(hitest_win)
    assert(vim.bo[hitest_buf].filetype == "csharpexplorer-hitest", "expected csharpexplorer-hitest buffer")
    assert(vim.bo[hitest_buf].modifiable == false, "expected non-modifiable hi-test buffer")

    local ht_lines = vim.api.nvim_buf_get_lines(hitest_buf, 0, -1, false)
    local cut_row = nil
    local found_domains = {}
    for idx, line in ipairs(ht_lines) do
        local dom = line:match("^  %[([%a]+)%]")
        if dom then
            found_domains[dom] = true
        end
        if line:find("  CSharpExplorerCut  ", 1, true) == 1 then
            cut_row = idx - 1
        end
    end
    for _, expected_dom in ipairs({ "Chrome", "Tree", "Decorations", "Winbar", "Diagnostics", "Debug" }) do
        assert(found_domains[expected_dom] == true, "missing domain section in HiTest: " .. expected_dom)
    end
    assert(cut_row ~= nil, "expected CSharpExplorerCut row in HiTest output")

    local ht_ns = vim.api.nvim_get_namespaces()["CSharpExplorerHiTest"]
    local row_marks = vim.api.nvim_buf_get_extmarks(
        hitest_buf,
        ht_ns,
        { cut_row, 0 },
        { cut_row, -1 },
        { details = true }
    )
    local preview_hls = {}
    for _, m in ipairs(row_marks) do
        preview_hls[#preview_hls + 1] = m[4].hl_group
    end
    assert(
        vim.tbl_contains(preview_hls, "CSharpExplorerCut"),
        "expected live CSharpExplorerCut highlight on HiTest column 1"
    )

    vim.api.nvim_win_close(hitest_win, true)

    local run_win = run_window.open(cs, { focus = false })
    assert(
        vim.wo[run_win].winhighlight:find("WinSeparator:CSharpExplorerWinSeparator", 1, true) ~= nil,
        "expected docked WinSeparator on run window"
    )
    assert(
        vim.wo[run_win].winbar:find("(no active processes)", 1, true) ~= nil,
        "expected sentence-case empty label on run window winbar"
    )
    run_window.close()

    local dbg_win = debug_window.open(cs, { focus = false })
    assert(
        vim.wo[dbg_win].winhighlight:find("WinSeparator:CSharpExplorerWinSeparator", 1, true) ~= nil,
        "expected docked WinSeparator on debug window"
    )
    assert(
        vim.wo[dbg_win].winbar:find("(no active sessions)", 1, true) ~= nil,
        "expected sentence-case empty label on debug window winbar"
    )
    debug_window.switch_view("breakpoints")
    local dbg_lines = vim.api.nvim_buf_get_lines(debug_window.buf, 0, -1, false)
    local joined_dbg = table.concat(dbg_lines, "\n")
    assert(joined_dbg:find(".NET exception filters", 1, true) ~= nil, "expected sentence-case exception filters header")
    assert(joined_dbg:find("Workspace breakpoints", 1, true) ~= nil, "expected sentence-case breakpoints header")
    debug_window.close()

    local help_float = keymap.open_help(cs)
    local help_lines = table.concat(vim.api.nvim_buf_get_lines(help_float.buf, 0, -1, false), "\n")
    assert(
        help_lines:find("Edit and refactor", 1, true) ~= nil,
        "expected sentence-case Edit and refactor help section"
    )
    assert(help_lines:find("Build and test", 1, true) ~= nil, "expected sentence-case Build and test help section")
    assert(help_lines:find("Run and debug", 1, true) ~= nil, "expected sentence-case Run and debug help section")
    help_float.close()

    cs.toggle()
    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    vim.fn.delete(root, "rf")
end)

io.stdout:write("ALL APPEARANCE TESTS PASSED\n")
vim.cmd("qall!")

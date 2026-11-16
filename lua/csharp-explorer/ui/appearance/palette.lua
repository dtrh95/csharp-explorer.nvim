local M = {}

local function to_linear(c)
    if c <= 0.04045 then
        return c / 12.92
    end
    return ((c + 0.055) / 1.055) ^ 2.4
end

local function from_linear(c)
    if c <= 0.0031308 then
        return 12.92 * c
    end
    return 1.055 * (c ^ (1 / 2.4)) - 0.055
end

local function parse_color_input(val)
    if type(val) == "number" then
        local n = math.floor(val)
        local r = math.floor(n / 65536) % 256
        local g = math.floor(n / 256) % 256
        local b = n % 256
        return r / 255.0, g / 255.0, b / 255.0
    elseif type(val) == "string" then
        local hex = val:gsub("^#", "")
        if #hex == 6 then
            local r = tonumber(hex:sub(1, 2), 16)
            local g = tonumber(hex:sub(3, 4), 16)
            local b = tonumber(hex:sub(5, 6), 16)
            if r and g and b then
                return r / 255.0, g / 255.0, b / 255.0
            end
        end
    end
    return nil
end

local function oklch_to_linear_rgb(L, C, H)
    local h_rad = math.rad(H)
    local a = C * math.cos(h_rad)
    local b_val = C * math.sin(h_rad)

    local l_ = L + 0.3963377774 * a + 0.2158037573 * b_val
    local m_ = L - 0.1055613458 * a - 0.0638541728 * b_val
    local s_ = L - 0.0894841775 * a - 1.2914855480 * b_val

    local l = l_ * l_ * l_
    local m = m_ * m_ * m_
    local s = s_ * s_ * s_

    local r_lin = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    local g_lin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    local b_lin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return r_lin, g_lin, b_lin
end

local function in_srgb_gamut(r_lin, g_lin, b_lin)
    return r_lin >= -1e-6
        and r_lin <= 1.0 + 1e-6
        and g_lin >= -1e-6
        and g_lin <= 1.0 + 1e-6
        and b_lin >= -1e-6
        and b_lin <= 1.0 + 1e-6
end

function M.hex_to_oklch(input)
    local r_srgb, g_srgb, b_srgb = parse_color_input(input)
    if not r_srgb then
        return 0, 0, 0
    end
    local r = to_linear(r_srgb)
    local g = to_linear(g_srgb)
    local b = to_linear(b_srgb)

    local l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    local m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    local s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

    local l_ = l > 0 and (l ^ (1 / 3)) or (l < 0 and -((-l) ^ (1 / 3)) or 0)
    local m_ = m > 0 and (m ^ (1 / 3)) or (m < 0 and -((-m) ^ (1 / 3)) or 0)
    local s_ = s > 0 and (s ^ (1 / 3)) or (s < 0 and -((-s) ^ (1 / 3)) or 0)

    local L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    local a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    local b_val = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_

    local C = math.sqrt(a * a + b_val * b_val)
    local H = math.deg(math.atan2(b_val, a))
    if H < 0 then
        H = H + 360
    end
    return L, C, H
end

function M.oklch_to_hex(L, C, H)
    local eff_c = C
    local r_lin, g_lin, b_lin = oklch_to_linear_rgb(L, eff_c, H)
    if not in_srgb_gamut(r_lin, g_lin, b_lin) then
        local lo, hi = 0.0, eff_c
        for _ = 1, 16 do
            local mid = (lo + hi) * 0.5
            local rl, gl, bl = oklch_to_linear_rgb(L, mid, H)
            if in_srgb_gamut(rl, gl, bl) then
                lo = mid
            else
                hi = mid
            end
        end
        r_lin, g_lin, b_lin = oklch_to_linear_rgb(L, lo, H)
    end

    local r = math.min(1.0, math.max(0.0, from_linear(math.max(0.0, r_lin))))
    local g = math.min(1.0, math.max(0.0, from_linear(math.max(0.0, g_lin))))
    local b = math.min(1.0, math.max(0.0, from_linear(math.max(0.0, b_lin))))

    return string.format(
        "#%02x%02x%02x",
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5)
    )
end

function M.sanitize_hex(val)
    local r, g, b = parse_color_input(val)
    if not r then
        return val
    end
    local L, C, H = M.hex_to_oklch(val)
    if H >= 270.0 and H <= 330.0 and C > 0.05 then
        local target_h = (H < 300.0) and 255.0 or 345.0
        return M.oklch_to_hex(L, C, target_h)
    end
    return string.format(
        "#%02x%02x%02x",
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5)
    )
end

function M.sanitize_spec(spec, sanitize_anti_violet)
    if sanitize_anti_violet == false or type(spec) ~= "table" then
        return spec
    end
    local out = vim.deepcopy(spec)
    for _, key in ipairs({ "fg", "bg", "sp" }) do
        if out[key] then
            out[key] = M.sanitize_hex(out[key])
        end
    end
    return out
end

M.HIGHLIGHT_GROUPS = {
    { group = "CSharpExplorerNormal", link = "Normal", domain = "Chrome", desc = "Tree normal background and text" },
    {
        group = "CSharpExplorerNormalNC",
        link = "CSharpExplorerNormal",
        domain = "Chrome",
        desc = "Tree inactive window text",
    },
    {
        group = "CSharpExplorerFloatNormal",
        link = "NormalFloat",
        domain = "Chrome",
        desc = "Floating window background",
    },
    { group = "CSharpExplorerBorder", link = "FloatBorder", domain = "Chrome", desc = "Floating window border" },
    {
        group = "CSharpExplorerCursorLine",
        link = "CursorLine",
        domain = "Chrome",
        desc = "Active tree line background",
    },
    {
        group = "CSharpExplorerWinSeparator",
        link = "WinSeparator",
        domain = "Chrome",
        desc = "Window vertical separator",
    },
    { group = "CSharpExplorerEndOfBuffer", link = "EndOfBuffer", domain = "Chrome", desc = "Buffer trailing area" },
    { group = "CSharpExplorerLineNr", link = "LineNr", domain = "Chrome", desc = "Line number column" },
    { group = "CSharpExplorerCursorLineNr", link = "CursorLineNr", domain = "Chrome", desc = "Active line number" },
    {
        group = "CSharpExplorerSignColumn",
        link = "CSharpExplorerNormal",
        domain = "Chrome",
        desc = "Sidebar sign column",
    },
    { group = "CSharpExplorerStatusLine", link = "StatusLine", domain = "Chrome", desc = "Window status line" },
    {
        group = "CSharpExplorerStatusLineNC",
        link = "StatusLineNC",
        domain = "Chrome",
        desc = "Inactive window status line",
    },
    { group = "CSharpExplorerTitle", link = "Title", domain = "Chrome", desc = "Section and window headers" },
    { group = "CSharpExplorerFooter", link = "Comment", domain = "Chrome", desc = "Footer keymap hints" },
    { group = "CSharpExplorerMuted", link = "Comment", domain = "Chrome", desc = "Secondary subtle text" },
    { group = "CSharpExplorerAccent", link = "Function", domain = "Chrome", desc = "Primary accent color" },
    { group = "CSharpExplorerKey", link = "Identifier", domain = "Chrome", desc = "Help modal shortcut keys" },
    { group = "CSharpExplorerSectionHeader", link = "Title", domain = "Chrome", desc = "View section header title" },

    { group = "CSharpExplorerTreeRoot", link = "Title", domain = "Tree", desc = "Solution root label" },
    { group = "CSharpExplorerTreeProject", link = "Title", domain = "Tree", desc = "Project label text" },
    { group = "CSharpExplorerTreeProjectWeb", link = "Function", domain = "Tree", desc = "Web project archetype icon" },
    {
        group = "CSharpExplorerTreeProjectConsole",
        link = "Type",
        domain = "Tree",
        desc = "Console project archetype icon",
    },
    {
        group = "CSharpExplorerTreeProjectLib",
        link = "Directory",
        domain = "Tree",
        desc = "Library project archetype icon",
    },
    {
        group = "CSharpExplorerTreeProjectTest",
        link = "DiagnosticOk",
        domain = "Tree",
        desc = "Test project archetype icon",
    },
    { group = "CSharpExplorerTreeFolder", link = "Directory", domain = "Tree", desc = "Folder label" },
    { group = "CSharpExplorerTreeDeps", link = "Comment", domain = "Tree", desc = "Dependencies node text" },
    { group = "CSharpExplorerTreeFile", link = "Normal", domain = "Tree", desc = "Source file label text" },
    { group = "CSharpExplorerFileIcon", link = "CSharpExplorerNormal", domain = "Tree", desc = "Fallback file icon" },
    { group = "CSharpExplorerFolderIcon", link = "CSharpExplorerTreeFolder", domain = "Tree", desc = "Folder icon" },
    { group = "CSharpExplorerIndentMarker", link = "Comment", domain = "Tree", desc = "Tree indent guide marker" },
    {
        group = "CSharpExplorerFolderArrowClosed",
        link = "CSharpExplorerIndentMarker",
        domain = "Tree",
        desc = "Collapsed arrow",
    },
    {
        group = "CSharpExplorerFolderArrowOpen",
        link = "CSharpExplorerIndentMarker",
        domain = "Tree",
        desc = "Expanded arrow",
    },

    { group = "CSharpExplorerCut", link = "SpellBad", domain = "Decorations", desc = "Cut item decoration" },
    { group = "CSharpExplorerCopied", link = "SpellRare", domain = "Decorations", desc = "Copied item decoration" },
    { group = "CSharpExplorerBadgeOk", link = "DiagnosticOk", domain = "Decorations", desc = "Process running badge" },
    {
        group = "CSharpExplorerBadgeWarn",
        link = "DiagnosticWarn",
        domain = "Decorations",
        desc = "Process building badge",
    },
    {
        group = "CSharpExplorerBadgeError",
        link = "DiagnosticError",
        domain = "Decorations",
        desc = "Process failed badge",
    },
    { group = "CSharpExplorerBadgeInfo", link = "DiagnosticInfo", domain = "Decorations", desc = "Process info badge" },
    { group = "CSharpExplorerBadgeMuted", link = "Comment", domain = "Decorations", desc = "Process stopped badge" },
    {
        group = "CSharpExplorerBuildSuccess",
        link = "DiagnosticOk",
        domain = "Decorations",
        desc = "Build completed badge",
    },
    {
        group = "CSharpExplorerBuildWarning",
        link = "DiagnosticWarn",
        domain = "Decorations",
        desc = "Build warning badge",
    },
    {
        group = "CSharpExplorerBuildError",
        link = "DiagnosticError",
        domain = "Decorations",
        desc = "Build error badge",
    },

    { group = "CSharpExplorerWinBar", link = "StatusLine", domain = "Winbar", desc = "Active winbar background" },
    { group = "CSharpExplorerWinBarNC", link = "StatusLineNC", domain = "Winbar", desc = "Inactive winbar background" },
    { group = "CSharpExplorerTabActive", link = "Title", domain = "Winbar", desc = "Selected process tab" },
    { group = "CSharpExplorerTabInactive", link = "Comment", domain = "Winbar", desc = "Inactive process tab" },
    { group = "CSharpExplorerPillActive", link = "Title", domain = "Winbar", desc = "Active view tab pill" },
    { group = "CSharpExplorerPillInactive", link = "Comment", domain = "Winbar", desc = "Inactive view tab pill" },

    {
        group = "CSharpExplorerDiagnosticError",
        link = "DiagnosticSignError",
        domain = "Diagnostics",
        desc = "Error count badge",
    },
    {
        group = "CSharpExplorerDiagnosticWarn",
        link = "DiagnosticSignWarn",
        domain = "Diagnostics",
        desc = "Warning count badge",
    },
    {
        group = "CSharpExplorerDiagnosticInfo",
        link = "DiagnosticSignInfo",
        domain = "Diagnostics",
        desc = "Info count badge",
    },
    {
        group = "CSharpExplorerDiagnosticHint",
        link = "DiagnosticSignHint",
        domain = "Diagnostics",
        desc = "Hint count badge",
    },
    {
        group = "CSharpExplorerDiagnosticErrorIcon",
        link = "CSharpExplorerDiagnosticError",
        domain = "Diagnostics",
        desc = "Error icon highlight",
    },
    {
        group = "CSharpExplorerDiagnosticWarnIcon",
        link = "CSharpExplorerDiagnosticWarn",
        domain = "Diagnostics",
        desc = "Warning icon highlight",
    },
    {
        group = "CSharpExplorerDiagnosticInfoIcon",
        link = "CSharpExplorerDiagnosticInfo",
        domain = "Diagnostics",
        desc = "Info icon highlight",
    },
    {
        group = "CSharpExplorerDiagnosticHintIcon",
        link = "CSharpExplorerDiagnosticHint",
        domain = "Diagnostics",
        desc = "Hint icon highlight",
    },
    {
        group = "CSharpExplorerDiagnosticErrorFileHL",
        link = "DiagnosticUnderlineError",
        domain = "Diagnostics",
        desc = "Error file name highlight",
    },
    {
        group = "CSharpExplorerDiagnosticWarnFileHL",
        link = "DiagnosticUnderlineWarn",
        domain = "Diagnostics",
        desc = "Warning file name highlight",
    },
    {
        group = "CSharpExplorerDiagnosticInfoFileHL",
        link = "DiagnosticUnderlineInfo",
        domain = "Diagnostics",
        desc = "Info file name highlight",
    },
    {
        group = "CSharpExplorerDiagnosticHintFileHL",
        link = "DiagnosticUnderlineHint",
        domain = "Diagnostics",
        desc = "Hint file name highlight",
    },

    {
        group = "CSharpExplorerGitConflictIcon",
        link = "DiagnosticError",
        domain = "Git",
        desc = "Merge conflict git status icon",
    },
    {
        group = "CSharpExplorerGitDeletedIcon",
        link = "DiagnosticError",
        domain = "Git",
        desc = "Deleted git status icon",
    },
    {
        group = "CSharpExplorerGitModifiedIcon",
        link = "DiagnosticWarn",
        domain = "Git",
        desc = "Modified git status icon",
    },
    {
        group = "CSharpExplorerGitStagedIcon",
        link = "DiagnosticOk",
        domain = "Git",
        desc = "Staged git status icon",
    },
    {
        group = "CSharpExplorerGitRenamedIcon",
        link = "DiagnosticInfo",
        domain = "Git",
        desc = "Renamed git status icon",
    },
    {
        group = "CSharpExplorerGitUntrackedIcon",
        link = "DiagnosticHint",
        domain = "Git",
        desc = "Untracked git status icon",
    },
    {
        group = "CSharpExplorerGitIgnoredIcon",
        link = "Comment",
        domain = "Git",
        desc = "Ignored git status icon",
    },
    {
        group = "CSharpExplorerGitBranch",
        link = "Comment",
        domain = "Git",
        desc = "Winbar git branch label",
    },
    {
        group = "CSharpExplorerGitConflictFileHL",
        link = "CSharpExplorerGitConflictIcon",
        domain = "Git",
        desc = "Merge conflict file label",
    },
    {
        group = "CSharpExplorerGitDeletedFileHL",
        link = "CSharpExplorerGitDeletedIcon",
        domain = "Git",
        desc = "Deleted file label",
    },
    {
        group = "CSharpExplorerGitModifiedFileHL",
        link = "CSharpExplorerGitModifiedIcon",
        domain = "Git",
        desc = "Modified file label",
    },
    {
        group = "CSharpExplorerGitStagedFileHL",
        link = "CSharpExplorerGitStagedIcon",
        domain = "Git",
        desc = "Staged file label",
    },
    {
        group = "CSharpExplorerGitRenamedFileHL",
        link = "CSharpExplorerGitRenamedIcon",
        domain = "Git",
        desc = "Renamed file label",
    },
    {
        group = "CSharpExplorerGitUntrackedFileHL",
        link = "CSharpExplorerGitUntrackedIcon",
        domain = "Git",
        desc = "Untracked file label",
    },
    {
        group = "CSharpExplorerGitIgnoredFileHL",
        link = "CSharpExplorerGitIgnoredIcon",
        domain = "Git",
        desc = "Ignored file label",
    },
    {
        group = "CSharpExplorerGitConflictFolderHL",
        link = "CSharpExplorerGitConflictFileHL",
        domain = "Git",
        desc = "Merge conflict folder or project label",
    },
    {
        group = "CSharpExplorerGitDeletedFolderHL",
        link = "CSharpExplorerGitDeletedFileHL",
        domain = "Git",
        desc = "Deleted folder or project label",
    },
    {
        group = "CSharpExplorerGitModifiedFolderHL",
        link = "CSharpExplorerGitModifiedFileHL",
        domain = "Git",
        desc = "Modified folder or project label",
    },
    {
        group = "CSharpExplorerGitStagedFolderHL",
        link = "CSharpExplorerGitStagedFileHL",
        domain = "Git",
        desc = "Staged folder or project label",
    },
    {
        group = "CSharpExplorerGitRenamedFolderHL",
        link = "CSharpExplorerGitRenamedFileHL",
        domain = "Git",
        desc = "Renamed folder or project label",
    },
    {
        group = "CSharpExplorerGitUntrackedFolderHL",
        link = "CSharpExplorerGitUntrackedFileHL",
        domain = "Git",
        desc = "Untracked folder or project label",
    },
    {
        group = "CSharpExplorerGitIgnoredFolderHL",
        link = "CSharpExplorerGitIgnoredFileHL",
        domain = "Git",
        desc = "Ignored folder or project label",
    },

    { group = "CSharpExplorerVarName", link = "Identifier", domain = "Debug", desc = "Variable identifier" },
    { group = "CSharpExplorerVarValue", link = "String", domain = "Debug", desc = "Variable value text" },
    { group = "CSharpExplorerVarType", link = "Type", domain = "Debug", desc = "Variable declared type" },
    { group = "CSharpExplorerStackCurrent", link = "Title", domain = "Debug", desc = "Active stack frame marker" },
    { group = "CSharpExplorerStackFrame", link = "Function", domain = "Debug", desc = "Stack frame method name" },
    { group = "CSharpExplorerStackLocation", link = "Comment", domain = "Debug", desc = "Stack frame source file" },
    {
        group = "CSharpExplorerBpVerified",
        link = "DiagnosticError",
        domain = "Debug",
        desc = "Active verified breakpoint",
    },
    { group = "CSharpExplorerBpUnverified", link = "Comment", domain = "Debug", desc = "Unverified breakpoint sign" },
    { group = "CSharpExplorerBpCondition", link = "Type", domain = "Debug", desc = "Conditional breakpoint sign" },
    { group = "CSharpExplorerFilterActive", link = "DiagnosticOk", domain = "Debug", desc = "Active exception filter" },
    { group = "CSharpExplorerFilterInactive", link = "Comment", domain = "Debug", desc = "Disabled exception filter" },
    {
        group = "CSharpExplorerExceptionBanner",
        link = "DiagnosticError",
        domain = "Debug",
        desc = "Uncaught exception banner",
    },
}

M.LEGACY_LINKS = {
    CSharpExplorerTreeRoot = "CSharpExplorerRoot",
    CSharpExplorerTreeProject = "CSharpExplorerProject",
    CSharpExplorerTreeFolder = "CSharpExplorerFolder",
    CSharpExplorerTreeFile = "CSharpExplorerFile",
    CSharpExplorerTreeDeps = "CSharpExplorerDeps",
}

function M.apply_all(cfg)
    cfg = cfg or {}
    for _, entry in ipairs(M.HIGHLIGHT_GROUPS) do
        if entry.def then
            local spec = vim.tbl_extend("force", entry.def, { default = true })
            vim.api.nvim_set_hl(0, entry.group, spec)
        end
    end

    for modern, legacy in pairs(M.LEGACY_LINKS) do
        local modern_hl = vim.api.nvim_get_hl(0, { name = modern })
        local legacy_hl = vim.api.nvim_get_hl(0, { name = legacy })
        if vim.tbl_isempty(modern_hl) and not vim.tbl_isempty(legacy_hl) then
            vim.api.nvim_set_hl(0, modern, { link = legacy })
        end
    end

    for _, entry in ipairs(M.HIGHLIGHT_GROUPS) do
        if entry.link then
            -- Neovim ignores style attributes when `link` is present in `nvim_set_hl`.
            vim.api.nvim_set_hl(0, entry.group, { link = entry.link, default = true })
        end
    end

    local overrides = cfg.highlights or {}
    for group, spec in pairs(overrides) do
        local sanitized = M.sanitize_spec(spec, cfg.sanitize_anti_violet)
        local final_spec = vim.tbl_extend("force", sanitized, { default = false })
        vim.api.nvim_set_hl(0, group, final_spec)
    end
end

return M

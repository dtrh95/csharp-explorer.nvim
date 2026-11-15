local M = {}

M.groups = {
    Normal = "CSharpExplorerNormal",
    NormalNC = "CSharpExplorerNormalNC",
    FloatNormal = "CSharpExplorerFloatNormal",
    Border = "CSharpExplorerBorder",
    CursorLine = "CSharpExplorerCursorLine",
    WinBar = "CSharpExplorerWinBar",
    WinBarNC = "CSharpExplorerWinBarNC",
    Title = "CSharpExplorerTitle",
    Footer = "CSharpExplorerFooter",
    Muted = "CSharpExplorerMuted",
    Accent = "CSharpExplorerAccent",
    Key = "CSharpExplorerKey",
    SectionHeader = "CSharpExplorerSectionHeader",
    TreeRoot = "CSharpExplorerTreeRoot",
    TreeProject = "CSharpExplorerTreeProject",
    TreeProjectWeb = "CSharpExplorerTreeProjectWeb",
    TreeProjectConsole = "CSharpExplorerTreeProjectConsole",
    TreeProjectLib = "CSharpExplorerTreeProjectLib",
    TreeProjectTest = "CSharpExplorerTreeProjectTest",
    TreeFolder = "CSharpExplorerTreeFolder",
    TreeDeps = "CSharpExplorerTreeDeps",
    TreeFile = "CSharpExplorerTreeFile",
    Cut = "CSharpExplorerCut",
    Copied = "CSharpExplorerCopied",
    TabActive = "CSharpExplorerTabActive",
    TabInactive = "CSharpExplorerTabInactive",
    PillActive = "CSharpExplorerPillActive",
    PillInactive = "CSharpExplorerPillInactive",
    BadgeOk = "CSharpExplorerBadgeOk",
    BadgeWarn = "CSharpExplorerBadgeWarn",
    BadgeError = "CSharpExplorerBadgeError",
    BadgeInfo = "CSharpExplorerBadgeInfo",
    BadgeMuted = "CSharpExplorerBadgeMuted",
    VarName = "CSharpExplorerVarName",
    VarValue = "CSharpExplorerVarValue",
    VarType = "CSharpExplorerVarType",
    StackCurrent = "CSharpExplorerStackCurrent",
    StackFrame = "CSharpExplorerStackFrame",
    StackLocation = "CSharpExplorerStackLocation",
    BpVerified = "CSharpExplorerBpVerified",
    BpUnverified = "CSharpExplorerBpUnverified",
    BpCondition = "CSharpExplorerBpCondition",
    FilterActive = "CSharpExplorerFilterActive",
    FilterInactive = "CSharpExplorerFilterInactive",
    ExceptionBanner = "CSharpExplorerExceptionBanner",
    BuildSuccess = "CSharpExplorerBuildSuccess",
    BuildWarning = "CSharpExplorerBuildWarning",
    BuildError = "CSharpExplorerBuildError",
}

local default_specs = {
    CSharpExplorerNormal = { link = "Normal", default = true },
    CSharpExplorerNormalNC = { link = "NormalNC", default = true },
    CSharpExplorerFloatNormal = { link = "NormalFloat", default = true },
    CSharpExplorerBorder = { link = "FloatBorder", default = true },
    CSharpExplorerCursorLine = { link = "CursorLine", default = true },
    CSharpExplorerWinBar = { link = "StatusLine", default = true },
    CSharpExplorerWinBarNC = { link = "StatusLineNC", default = true },
    CSharpExplorerTitle = { link = "Title", default = true },
    CSharpExplorerFooter = { link = "Comment", default = true },
    CSharpExplorerMuted = { link = "Comment", default = true },
    CSharpExplorerAccent = { link = "Function", default = true },
    CSharpExplorerKey = { link = "Identifier", default = true },
    CSharpExplorerSectionHeader = { link = "Title", default = true },
    CSharpExplorerTreeRoot = { link = "Title", default = true },
    CSharpExplorerTreeProject = { link = "Title", default = true },
    CSharpExplorerTreeProjectWeb = { link = "Function", default = true },
    CSharpExplorerTreeProjectConsole = { link = "Type", default = true },
    CSharpExplorerTreeProjectLib = { link = "Directory", default = true },
    CSharpExplorerTreeProjectTest = { link = "DiagnosticOk", default = true },
    CSharpExplorerTreeFolder = { link = "Directory", default = true },
    CSharpExplorerTreeDeps = { link = "Comment", default = true },
    CSharpExplorerTreeFile = { link = "Normal", default = true },
    CSharpExplorerCut = { undercurl = true, italic = true, sp = "#d19a66", default = true },
    CSharpExplorerCopied = { undercurl = true, sp = "#56b6c2", default = true },
    CSharpExplorerTabActive = { link = "TabLineSel", default = true },
    CSharpExplorerTabInactive = { link = "TabLine", default = true },
    CSharpExplorerPillActive = { link = "CursorLine", default = true },
    CSharpExplorerPillInactive = { link = "Comment", default = true },
    CSharpExplorerBadgeOk = { link = "DiagnosticOk", default = true },
    CSharpExplorerBadgeWarn = { link = "DiagnosticWarn", default = true },
    CSharpExplorerBadgeError = { link = "DiagnosticError", default = true },
    CSharpExplorerBadgeInfo = { link = "DiagnosticInfo", default = true },
    CSharpExplorerBadgeMuted = { link = "Comment", default = true },
    CSharpExplorerVarName = { link = "Identifier", default = true },
    CSharpExplorerVarValue = { link = "String", default = true },
    CSharpExplorerVarType = { link = "Type", default = true },
    CSharpExplorerStackCurrent = { link = "Title", default = true },
    CSharpExplorerStackFrame = { link = "Function", default = true },
    CSharpExplorerStackLocation = { link = "Comment", default = true },
    CSharpExplorerBpVerified = { link = "DiagnosticError", default = true },
    CSharpExplorerBpUnverified = { link = "Comment", default = true },
    CSharpExplorerBpCondition = { link = "Type", default = true },
    CSharpExplorerFilterActive = { link = "DiagnosticOk", default = true },
    CSharpExplorerFilterInactive = { link = "Comment", default = true },
    CSharpExplorerExceptionBanner = { link = "DiagnosticError", default = true },
    CSharpExplorerBuildSuccess = { link = "DiagnosticOk", default = true },
    CSharpExplorerBuildWarning = { link = "DiagnosticWarn", default = true },
    CSharpExplorerBuildError = { link = "DiagnosticError", default = true },
}

local initialized = false

function M.setup(_opts)
    initialized = true
    for group, spec in pairs(default_specs) do
        vim.api.nvim_set_hl(0, group, spec)
    end
    local group = vim.api.nvim_create_augroup("CSharpExplorerTheme", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = function()
            for g, spec in pairs(default_specs) do
                vim.api.nvim_set_hl(0, g, spec)
            end
        end,
    })
end

function M.ensure()
    if not initialized then
        M.setup()
    end
end

function M.escape_winbar(text)
    return tostring(text or ""):gsub("%%", "%%%%"):gsub("\r\n", " "):gsub("[\r\n]", " ")
end

local function compile_chunks(chunks)
    local parts = {}
    for _, chunk in ipairs(chunks or {}) do
        local text = chunk[1] or chunk.text or ""
        local hl = chunk[2] or chunk.hl
        local raw = chunk.raw or false
        local rendered = raw and tostring(text) or M.escape_winbar(text)
        if hl and hl ~= "" then
            parts[#parts + 1] = "%#" .. hl .. "#" .. rendered .. "%*"
        else
            parts[#parts + 1] = rendered
        end
    end
    return table.concat(parts)
end

function M.format_winbar(left_chunks, right_chunks)
    local left = compile_chunks(left_chunks)
    local right = compile_chunks(right_chunks)
    return "%*" .. left .. "%=" .. right .. "%*"
end

return M

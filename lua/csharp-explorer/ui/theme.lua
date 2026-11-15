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

local function sanitize_winbar_text(text)
    return tostring(text or ""):gsub("\r\n", " "):gsub("[\r\n]", " ")
end

function M.escape_winbar(text)
    return sanitize_winbar_text(text):gsub("%%", "%%%%")
end

local function truncate_display_text(text, max_width)
    local clean = sanitize_winbar_text(text)
    if max_width <= 0 then
        return ""
    end
    if vim.fn.strdisplaywidth(clean) <= max_width then
        return clean
    end
    if max_width == 1 then
        return "…"
    end
    local target = max_width - 1
    local total_chars = vim.fn.strchars(clean)
    local lo, hi, best = 0, total_chars, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local sub = vim.fn.strcharpart(clean, 0, mid)
        if vim.fn.strdisplaywidth(sub) <= target then
            best = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return vim.fn.strcharpart(clean, 0, best) .. "…"
end

function M.chunks_width(chunks)
    local width = 0
    for _, chunk in ipairs(chunks or {}) do
        local text = chunk[1] or chunk.text or ""
        width = width + vim.fn.strdisplaywidth(sanitize_winbar_text(text))
    end
    return width
end

function M.truncate_chunks(chunks, max_width)
    local budget = math.max(0, max_width or 0)
    if budget == 0 then
        return {}
    end
    local out = {}
    local used = 0
    for _, chunk in ipairs(chunks or {}) do
        local text = sanitize_winbar_text(chunk[1] or chunk.text or "")
        local hl = chunk[2] or chunk.hl
        local raw = chunk.raw or false
        local w = vim.fn.strdisplaywidth(text)
        if used + w <= budget then
            out[#out + 1] = { text, hl, raw = raw }
            used = used + w
        else
            local rem = budget - used
            if rem > 0 and not raw then
                local clipped = truncate_display_text(text, rem)
                if clipped ~= "" then
                    out[#out + 1] = { clipped, hl, raw = false }
                end
            end
            break
        end
    end
    return out
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

function M.format_winbar(left_chunks, right_chunks, max_width)
    if type(max_width) ~= "number" or max_width <= 0 then
        local left = compile_chunks(left_chunks)
        local right = compile_chunks(right_chunks)
        return "%*" .. left .. "%=" .. right .. "%*"
    end
    local eff_right = right_chunks or {}
    local right_w = M.chunks_width(eff_right)
    if right_w > max_width then
        eff_right = M.truncate_chunks(eff_right, max_width)
        right_w = M.chunks_width(eff_right)
    end
    local has_left = #(left_chunks or {}) > 0
    local gap = (has_left and right_w > 0 and max_width > right_w + 2) and 2 or 0
    local left_budget = math.max(0, max_width - right_w - gap)
    local eff_left = M.truncate_chunks(left_chunks or {}, left_budget)
    local sep = gap > 0 and "  %=" or "%="
    return "%*" .. compile_chunks(eff_left) .. sep .. compile_chunks(eff_right) .. "%*"
end

return M

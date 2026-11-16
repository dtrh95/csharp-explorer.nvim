local M = {}

M.WINDOW_PROFILES = {
    sidebar = table.concat({
        "Normal:CSharpExplorerNormal",
        "NormalNC:CSharpExplorerNormalNC",
        "EndOfBuffer:CSharpExplorerEndOfBuffer",
        "CursorLine:CSharpExplorerCursorLine",
        "CursorLineNr:CSharpExplorerCursorLineNr",
        "LineNr:CSharpExplorerLineNr",
        "WinSeparator:CSharpExplorerWinSeparator",
        "StatusLine:CSharpExplorerStatusLine",
        "StatusLineNC:CSharpExplorerStatusLineNC",
        "SignColumn:CSharpExplorerSignColumn",
        "FoldColumn:CSharpExplorerNormal",
        "WinBar:CSharpExplorerWinBar",
        "WinBarNC:CSharpExplorerWinBarNC",
    }, ","),
    docked = table.concat({
        "Normal:CSharpExplorerNormal",
        "NormalNC:CSharpExplorerNormalNC",
        "EndOfBuffer:CSharpExplorerEndOfBuffer",
        "CursorLine:CSharpExplorerCursorLine",
        "CursorLineNr:CSharpExplorerCursorLineNr",
        "LineNr:CSharpExplorerLineNr",
        "WinSeparator:CSharpExplorerWinSeparator",
        "StatusLine:CSharpExplorerStatusLine",
        "StatusLineNC:CSharpExplorerStatusLineNC",
        "SignColumn:CSharpExplorerSignColumn",
        "FoldColumn:CSharpExplorerNormal",
        "WinBar:CSharpExplorerWinBar",
        "WinBarNC:CSharpExplorerWinBarNC",
    }, ","),
    float = table.concat({
        "Normal:CSharpExplorerFloatNormal",
        "NormalNC:CSharpExplorerFloatNormal",
        "NormalFloat:CSharpExplorerFloatNormal",
        "FloatBorder:CSharpExplorerBorder",
        "FloatTitle:CSharpExplorerTitle",
        "FloatFooter:CSharpExplorerFooter",
        "CursorLine:CSharpExplorerCursorLine",
        "EndOfBuffer:CSharpExplorerFloatNormal",
        "SignColumn:CSharpExplorerFloatNormal",
        "FoldColumn:CSharpExplorerFloatNormal",
    }, ","),
    popup = table.concat({
        "Normal:CSharpExplorerFloatNormal",
        "NormalNC:CSharpExplorerFloatNormal",
        "NormalFloat:CSharpExplorerFloatNormal",
        "FloatBorder:CSharpExplorerBorder",
        "FloatTitle:CSharpExplorerTitle",
        "FloatFooter:CSharpExplorerFooter",
        "CursorLine:CSharpExplorerCursorLine",
        "EndOfBuffer:CSharpExplorerFloatNormal",
        "SignColumn:CSharpExplorerFloatNormal",
        "FoldColumn:CSharpExplorerFloatNormal",
    }, ","),
}

local tracked_windows = {}
local autocmd_ready = false

local function ensure_autocmd()
    if autocmd_ready then
        return
    end
    autocmd_ready = true
    local group = vim.api.nvim_create_augroup("CSharpExplorerWindowTracker", { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(ev)
            local win = tonumber(ev.match)
            if win then
                M.detach(win)
            end
        end,
    })
end

function M.get_winhl(role)
    return M.WINDOW_PROFILES[role] or M.WINDOW_PROFILES.docked
end

function M.attach(win, role, custom_winhl)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    ensure_autocmd()
    role = role or "docked"
    tracked_windows[win] = {
        role = role,
        custom_winhl = custom_winhl,
    }
    local base_hl = M.get_winhl(role)
    local full_hl = custom_winhl and (base_hl .. "," .. custom_winhl) or base_hl
    vim.wo[win].winhighlight = full_hl
end

function M.detach(win)
    tracked_windows[win] = nil
end

function M.sync_all()
    local save_ei = vim.o.eventignore
    vim.o.eventignore = "all"
    for win, info in pairs(tracked_windows) do
        if vim.api.nvim_win_is_valid(win) then
            local base_hl = M.get_winhl(info.role)
            local full_hl = info.custom_winhl and (base_hl .. "," .. info.custom_winhl) or base_hl
            vim.wo[win].winhighlight = full_hl
        else
            tracked_windows[win] = nil
        end
    end
    vim.o.eventignore = save_ei
end

function M.get_tracked()
    return tracked_windows
end

return M

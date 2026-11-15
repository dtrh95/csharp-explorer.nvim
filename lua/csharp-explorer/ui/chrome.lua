local config = require("csharp-explorer.config")
local theme = require("csharp-explorer.ui.theme")
local ViewBuilder = require("csharp-explorer.ui.view_builder")

local M = {}

local function resolve_sidebar_win(state)
    if state and state.win and vim.api.nvim_win_is_valid(state.win) then
        return state.win
    end
    local cs = package.loaded["csharp-explorer"]
    if cs and cs.win and vim.api.nvim_win_is_valid(cs.win) then
        return cs.win
    end
    return nil
end

function M.is_editor_window(win, sidebar_win)
    if not win or win == 0 or win == sidebar_win or not vim.api.nvim_win_is_valid(win) then
        return false
    end
    local ok_cfg, win_cfg = pcall(vim.api.nvim_win_get_config, win)
    if not ok_cfg or (win_cfg.relative and win_cfg.relative ~= "") then
        return false
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= "" then
        return false
    end
    local ft = vim.bo[buf].filetype or ""
    return not ft:match("^csharpexplorer")
end

function M.find_editor_window(state)
    local sidebar_win = resolve_sidebar_win(state)
    local alt = vim.fn.win_getid(vim.fn.winnr("#"))
    if M.is_editor_window(alt, sidebar_win) then
        return alt
    end
    local current_tab = vim.api.nvim_get_current_tabpage()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
        if M.is_editor_window(win, sidebar_win) then
            return win
        end
    end
    return nil
end

function M.resolve_editor_window(state)
    local found = M.find_editor_window(state)
    if found then
        return found
    end
    local sidebar_win = resolve_sidebar_win(state)
    if sidebar_win then
        local sb_w = vim.api.nvim_win_get_width(sidebar_win)
        vim.api.nvim_set_current_win(sidebar_win)
        vim.cmd("rightbelow vsplit")
        local new_win = vim.api.nvim_get_current_win()
        local new_buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(new_win, new_buf)
        pcall(vim.api.nvim_win_set_width, sidebar_win, sb_w)
        return new_win
    end
    local cur_win = vim.api.nvim_get_current_win()
    if not M.is_editor_window(cur_win, nil) then
        vim.cmd("aboveleft split")
        local new_win = vim.api.nvim_get_current_win()
        local new_buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(new_win, new_buf)
        return new_win
    end
    return cur_win
end

function M.apply_window_options(win, opts)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    theme.ensure()
    opts = opts or {}
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].cursorline = opts.cursorline ~= false
    vim.wo[win].fillchars = "eob: "
    if opts.winfixwidth ~= nil then
        vim.wo[win].winfixwidth = opts.winfixwidth == true
    end
    if opts.winfixheight ~= nil then
        vim.wo[win].winfixheight = opts.winfixheight == true
    end
    local hl_map = opts.winhighlight
        or "Normal:CSharpExplorerNormal,NormalNC:CSharpExplorerNormalNC,CursorLine:CSharpExplorerCursorLine,FloatBorder:CSharpExplorerBorder,WinBar:CSharpExplorerWinBar,WinBarNC:CSharpExplorerWinBarNC"
    vim.wo[win].winhighlight = hl_map
end

function M.set_winbar(win, left_chunks, right_chunks)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    if config.current.ui and config.current.ui.winbar == false then
        vim.wo[win].winbar = ""
        return
    end
    local formatted = theme.format_winbar(left_chunks, right_chunks)
    vim.wo[win].winbar = formatted
end

function M.open_docked_window(state, opts)
    opts = opts or {}
    local height = opts.height or 12
    local prev_win = vim.api.nvim_get_current_win()
    local sidebar_win = resolve_sidebar_win(state)
    local sb_w = sidebar_win and vim.api.nvim_win_get_width(sidebar_win) or nil
    local editor_win = M.resolve_editor_window(state)
    vim.api.nvim_set_current_win(editor_win)
    vim.cmd("belowright " .. height .. "split")
    local win = vim.api.nvim_get_current_win()
    local buf = opts.buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].undolevels = -1
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = opts.bufhidden or "hide"
        vim.bo[buf].swapfile = false
        if opts.filetype then
            vim.bo[buf].filetype = opts.filetype
        end
        if opts.bufname then
            pcall(vim.api.nvim_buf_set_name, buf, opts.bufname)
        end
    else
        vim.bo[buf].undolevels = -1
    end
    vim.api.nvim_win_set_buf(win, buf)
    M.apply_window_options(win, { winfixheight = true, cursorline = opts.cursorline ~= false })
    if sidebar_win and sb_w and vim.api.nvim_win_is_valid(sidebar_win) then
        pcall(vim.api.nvim_win_set_width, sidebar_win, sb_w)
    end
    if opts.focus == false and vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
    end
    return { win = win, buf = buf }
end

function M.should_auto_scroll(win, _buf, prev_line_count)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return false
    end
    if vim.api.nvim_get_current_win() == win and vim.fn.mode():match("^[vV\22]") then
        return false
    end
    local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
    local safe_prev = math.max(1, (prev_line_count or 1) - 1)
    return cursor_row >= safe_prev
end

function M.open_float(opts)
    opts = opts or {}
    local caller_win = vim.api.nvim_get_current_win()
    local border = opts.border
        or (config.current.ui and config.current.ui.border)
        or (config.current.properties and config.current.properties.border)
        or "rounded"
    local width = opts.width or math.floor(vim.o.columns * 0.7)
    local height = opts.height or math.floor(vim.o.lines * 0.6)
    width = math.max(20, math.min(width, vim.o.columns - 4))
    height = math.max(4, math.min(height, vim.o.lines - 4))
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local title = opts.title and (" " .. vim.trim(opts.title) .. " ") or nil
    local footer = opts.footer and (" " .. vim.trim(opts.footer) .. " ") or nil

    local buf = opts.buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].undolevels = -1
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = opts.bufhidden or "wipe"
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = opts.filetype or "csharpexplorer-float"
    else
        vim.bo[buf].undolevels = -1
    end

    local win_cfg = {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        border = border,
        style = "minimal",
        title = title,
        title_pos = title and "center" or nil,
    }
    if footer and vim.fn.has("nvim-0.10") == 1 then
        win_cfg.footer = footer
        win_cfg.footer_pos = "center"
    end

    local win = vim.api.nvim_open_win(buf, true, win_cfg)
    M.apply_window_options(win, {
        cursorline = opts.cursorline ~= false,
        winhighlight = "Normal:CSharpExplorerFloatNormal,FloatBorder:CSharpExplorerBorder,CursorLine:CSharpExplorerCursorLine,Title:CSharpExplorerTitle",
    })

    local closed = false
    local function close_fn()
        if closed then
            return
        end
        closed = true
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
        if opts.on_close then
            pcall(opts.on_close)
        end
        if vim.api.nvim_win_is_valid(caller_win) then
            pcall(vim.api.nvim_set_current_win, caller_win)
        end
    end

    local close_keys = { "q", "<Esc>" }
    if opts.close_keys then
        for _, k in ipairs(opts.close_keys) do
            close_keys[#close_keys + 1] = k
        end
    end
    for _, key in ipairs(close_keys) do
        vim.keymap.set("n", key, close_fn, { buffer = buf, silent = true, nowait = true })
    end
    if opts.keymaps then
        for key, handler in pairs(opts.keymaps) do
            vim.keymap.set("n", key, handler, { buffer = buf, silent = true, nowait = true })
        end
    end

    if opts.close_on_bufleave ~= false then
        vim.api.nvim_create_autocmd("BufLeave", {
            buffer = buf,
            once = true,
            callback = close_fn,
        })
    end

    return { win = win, buf = buf, close = close_fn }
end

function M.show_help_modal(title, sections)
    local vb = ViewBuilder.new()
    vb:add_line("")
    for _, sec in ipairs(sections or {}) do
        vb:add_section(sec.title)
        local rows = {}
        for _, item in ipairs(sec.items or {}) do
            rows[#rows + 1] = {
                key = item.key or "",
                desc = item.desc or "",
            }
        end
        vb:add_columns(rows, {
            { key = "key", hl = "CSharpExplorerKey", min_width = 12 },
            { key = "desc", hl = "CSharpExplorerNormal" },
        }, { left_pad = "    ", gap = "  " })
        vb:add_line("")
    end

    local max_line_len = 0
    for _, line in ipairs(vb.lines) do
        local len = vim.fn.strdisplaywidth(line)
        if len > max_line_len then
            max_line_len = len
        end
    end

    local width = math.min(math.floor(vim.o.columns * 0.85), math.max(54, max_line_len + 6))
    local height = math.min(math.floor(vim.o.lines * 0.85), math.max(6, #vb.lines + 1))

    local float_info = M.open_float({
        title = title or "Shortcuts",
        footer = "q / ? / <Esc> close",
        close_keys = { "?" },
        cursorline = true,
        width = width,
        height = height,
    })

    local help_ns = vim.api.nvim_create_namespace("CSharpExplorerHelpModal")
    vb:render(float_info.buf, help_ns)
    return float_info
end

return M

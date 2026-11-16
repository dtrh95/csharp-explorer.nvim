local config = require("csharp-explorer.config")
local appearance = require("csharp-explorer.ui.appearance")
local winbar = require("csharp-explorer.ui.winbar")
local ViewBuilder = require("csharp-explorer.ui.view_builder")

local M = {}

local winbar_registry = {}
local winbar_autocmd_ready = false

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
    appearance.ensure()
    opts = opts or {}
    local is_log = opts.mode == "log"
    local wrap = is_log
    if opts.wrap ~= nil then
        wrap = opts.wrap == true
    end
    vim.wo[win].wrap = wrap
    vim.wo[win].linebreak = is_log and wrap or false
    vim.wo[win].breakindent = is_log and wrap or false
    vim.wo[win].foldenable = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = opts.foldcolumn or (is_log and "1" or "0")
    vim.wo[win].cursorline = opts.cursorline ~= false
    vim.wo[win].fillchars = "eob: "
    if opts.winfixwidth ~= nil then
        vim.wo[win].winfixwidth = opts.winfixwidth == true
    end
    if opts.winfixheight ~= nil then
        vim.wo[win].winfixheight = opts.winfixheight == true
    end
    appearance.attach_window(win, opts.role or "docked", opts.winhighlight)
end

function M.reset_horizontal_scroll(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    pcall(vim.api.nvim_win_call, win, function()
        local view = vim.fn.winsaveview()
        if view and (view.leftcol or 0) > 0 then
            view.leftcol = 0
            vim.fn.winrestview(view)
        end
    end)
end

function M.build_tab_chunks(opts)
    opts = opts or {}
    local items = opts.items or {}
    local budget = math.max(0, opts.max_width or 0)
    if #items == 0 or budget == 0 then
        return {}
    end

    local widths = {}
    local total_w = 0
    local active_idx = 1
    for i, item in ipairs(items) do
        local w = vim.fn.strdisplaywidth(item.label or "")
        widths[i] = w
        total_w = total_w + w
        if opts.active_id ~= nil and item.id == opts.active_id then
            active_idx = i
        end
    end

    if total_w <= budget then
        local all = {}
        for _, item in ipairs(items) do
            all[#all + 1] = { item.label, item.hl }
        end
        return all
    end

    local function indicator_widths(lo, hi)
        local lw = lo > 1 and vim.fn.strdisplaywidth(string.format(" ‹ +%d ", lo - 1)) or 0
        local rw = hi < #items and vim.fn.strdisplaywidth(string.format(" +%d › ", #items - hi)) or 0
        return lw, rw
    end

    local lo, hi = active_idx, active_idx
    local sum_w = widths[active_idx]
    while lo > 1 or hi < #items do
        local progressed = false
        if lo > 1 then
            local cand_sum = sum_w + widths[lo - 1]
            local lw, rw = indicator_widths(lo - 1, hi)
            if cand_sum + lw + rw <= budget then
                lo = lo - 1
                sum_w = cand_sum
                progressed = true
            end
        end
        if hi < #items then
            local cand_sum = sum_w + widths[hi + 1]
            local lw, rw = indicator_widths(lo, hi + 1)
            if cand_sum + lw + rw <= budget then
                hi = hi + 1
                sum_w = cand_sum
                progressed = true
            end
        end
        if not progressed then
            break
        end
    end

    local lw, rw = indicator_widths(lo, hi)
    if lo == hi and (sum_w + lw + rw > budget) then
        local cl_ind = lo > 1 and string.format("‹%d", lo - 1) or ""
        local cr_ind = hi < #items and string.format("%d›", #items - hi) or ""
        local clw = vim.fn.strdisplaywidth(cl_ind)
        local crw = vim.fn.strdisplaywidth(cr_ind)
        local cand_label = items[lo].label or ""
        if vim.fn.strdisplaywidth(cand_label) + clw + crw > budget and items[lo].compact_label then
            cand_label = items[lo].compact_label
        end
        if vim.fn.strdisplaywidth(cand_label) + clw + crw <= budget then
            local out = {}
            if cl_ind ~= "" then
                out[#out + 1] = { cl_ind, "CSharpExplorerMuted" }
            end
            out[#out + 1] = { cand_label, items[lo].hl }
            if cr_ind ~= "" then
                out[#out + 1] = { cr_ind, "CSharpExplorerMuted" }
            end
            return out
        end
        local inner_budget = budget - clw - crw
        if inner_budget >= 8 then
            local out = {}
            if cl_ind ~= "" then
                out[#out + 1] = { cl_ind, "CSharpExplorerMuted" }
            end
            local clipped = winbar.truncate_chunks({ { cand_label, items[lo].hl } }, inner_budget)
            for _, c in ipairs(clipped) do
                out[#out + 1] = c
            end
            if cr_ind ~= "" then
                out[#out + 1] = { cr_ind, "CSharpExplorerMuted" }
            end
            return out
        end
        return winbar.truncate_chunks({ { cand_label, items[lo].hl } }, budget)
    end

    local out = {}
    if lo > 1 then
        out[#out + 1] = { string.format(" ‹ +%d ", lo - 1), "CSharpExplorerMuted" }
    end
    for i = lo, hi do
        out[#out + 1] = { items[i].label, items[i].hl }
    end
    if hi < #items then
        out[#out + 1] = { string.format(" +%d › ", #items - hi), "CSharpExplorerMuted" }
    end
    return out
end

local function render_registered_winbar(win)
    local entry = winbar_registry[win]
    if not entry then
        return
    end
    if not vim.api.nvim_win_is_valid(win) then
        winbar_registry[win] = nil
        return
    end
    if config.current.ui and config.current.ui.winbar == false then
        vim.wo[win].winbar = ""
        return
    end
    local win_w = vim.api.nvim_win_get_width(win)
    local left_chunks = entry.left
    local right_chunks = entry.right
    if type(entry.left) == "function" then
        left_chunks, right_chunks = entry.left(win_w)
    end
    vim.wo[win].winbar = winbar.format_winbar(left_chunks, right_chunks, win_w)
end

function M.refresh_winbars()
    for w, _ in pairs(winbar_registry) do
        if vim.api.nvim_win_is_valid(w) then
            render_registered_winbar(w)
        else
            winbar_registry[w] = nil
        end
    end
end

local function ensure_winbar_autocmd()
    if winbar_autocmd_ready then
        return
    end
    winbar_autocmd_ready = true
    local group = vim.api.nvim_create_augroup("CSharpExplorerWinBarResize", { clear = true })
    vim.api.nvim_create_autocmd("WinResized", {
        group = group,
        callback = function()
            local resized = (vim.v.event and vim.v.event.windows) or {}
            if #resized > 0 then
                for _, w in ipairs(resized) do
                    if winbar_registry[w] then
                        render_registered_winbar(w)
                    end
                end
            else
                for w, _ in pairs(winbar_registry) do
                    render_registered_winbar(w)
                end
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(ev)
            local closed_win = tonumber(ev.match)
            if closed_win then
                winbar_registry[closed_win] = nil
            end
        end,
    })
end

function M.set_winbar(win, left_chunks, right_chunks)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    ensure_winbar_autocmd()
    winbar_registry[win] = {
        left = left_chunks,
        right = right_chunks,
    }
    render_registered_winbar(win)
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
    M.apply_window_options(win, {
        role = "docked",
        winfixheight = true,
        cursorline = opts.cursorline ~= false,
        mode = opts.mode,
        wrap = opts.wrap,
        foldcolumn = opts.foldcolumn,
    })
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
    local border = opts.border or appearance.get_border()
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
        role = "float",
        cursorline = opts.cursorline ~= false,
        mode = opts.mode,
        wrap = opts.wrap,
        foldcolumn = opts.foldcolumn,
        winhighlight = opts.winhighlight,
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

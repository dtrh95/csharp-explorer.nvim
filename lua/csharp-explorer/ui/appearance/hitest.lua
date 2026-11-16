local palette = require("csharp-explorer.ui.appearance.palette")

local M = {}

function M.resolve_chain(group)
    local chain = { group }
    local visited = { [group] = true }
    local cur = group
    while true do
        local hl = vim.api.nvim_get_hl(0, { name = cur, link = true })
        if hl and hl.link and hl.link ~= "" then
            if visited[hl.link] then
                chain[#chain + 1] = hl.link .. " (cycle)"
                break
            end
            chain[#chain + 1] = hl.link
            visited[hl.link] = true
            cur = hl.link
        else
            break
        end
    end
    return table.concat(chain, " -> ")
end

local function format_attrs(attrs)
    if not attrs or vim.tbl_isempty(attrs) then
        return "cleared"
    end
    local parts = {}
    if attrs.fg then
        parts[#parts + 1] = string.format("fg=#%06x", attrs.fg)
    end
    if attrs.bg then
        parts[#parts + 1] = string.format("bg=#%06x", attrs.bg)
    end
    if attrs.sp then
        parts[#parts + 1] = string.format("sp=#%06x", attrs.sp)
    end
    for _, flag in ipairs({ "bold", "italic", "underline", "undercurl", "reverse", "standout" }) do
        if attrs[flag] then
            parts[#parts + 1] = flag
        end
    end
    return #parts > 0 and table.concat(parts, " ") or "cleared"
end

function M.build_rows()
    local domain_order = { "Chrome", "Tree", "Decorations", "Winbar", "Diagnostics", "Git", "Debug" }
    local grouped = {}
    for _, d in ipairs(domain_order) do
        grouped[d] = {}
    end

    for _, entry in ipairs(palette.HIGHLIGHT_GROUPS) do
        local dom = entry.domain or "Chrome"
        if not grouped[dom] then
            grouped[dom] = {}
        end
        local chain = M.resolve_chain(entry.group)
        local concrete = vim.api.nvim_get_hl(0, { name = entry.group, link = false })
        local def_str = format_attrs(concrete)
        grouped[dom][#grouped[dom] + 1] = {
            group = entry.group,
            chain = chain,
            def = def_str,
        }
    end

    local lines = {}
    local hl_spans = {}

    for _, dom in ipairs(domain_order) do
        local items = grouped[dom] or {}
        if #items > 0 then
            if #lines > 0 then
                lines[#lines + 1] = ""
            end
            lines[#lines + 1] = "  [" .. dom .. "]"
            hl_spans[#hl_spans + 1] = {
                line = #lines - 1,
                col_start = 2,
                col_end = #lines[#lines],
                hl = "CSharpExplorerTitle",
            }

            local max_group = 0
            local max_chain = 0
            for _, item in ipairs(items) do
                max_group = math.max(max_group, vim.fn.strdisplaywidth(item.group))
                max_chain = math.max(max_chain, vim.fn.strdisplaywidth(item.chain))
            end

            for _, item in ipairs(items) do
                local pad_group = string.rep(" ", max_group - vim.fn.strdisplaywidth(item.group) + 2)
                local pad_chain = string.rep(" ", max_chain - vim.fn.strdisplaywidth(item.chain) + 2)
                local line_text = "  " .. item.group .. pad_group .. item.chain .. pad_chain .. item.def
                lines[#lines + 1] = line_text
                hl_spans[#hl_spans + 1] = {
                    line = #lines - 1,
                    col_start = 2,
                    col_end = 2 + #item.group,
                    hl = item.group,
                }
                hl_spans[#hl_spans + 1] = {
                    line = #lines - 1,
                    col_start = 2 + #item.group + #pad_group,
                    col_end = 2 + #item.group + #pad_group + #item.chain,
                    hl = "CSharpExplorerMuted",
                }
            end
        end
    end

    return lines, hl_spans
end

function M.open(opts)
    opts = opts or {}
    local chrome = require("csharp-explorer.ui.chrome")
    local lines, _ = M.build_rows()

    local max_w = 0
    for _, l in ipairs(lines) do
        max_w = math.max(max_w, vim.fn.strdisplaywidth(l))
    end
    local width = math.min(math.floor(vim.o.columns * 0.9), math.max(70, max_w + 4))
    local height = math.min(math.floor(vim.o.lines * 0.85), math.max(10, #lines + 2))

    local float_info = chrome.open_float({
        title = "Appearance hi-test",
        footer = "q / <Esc> close · r refresh",
        border = opts.border or "single",
        width = width,
        height = height,
        filetype = "csharpexplorer-hitest",
    })

    local buf = float_info.buf
    local ns = vim.api.nvim_create_namespace("CSharpExplorerHiTest")

    local function apply_content()
        local cur_lines, cur_spans = M.build_rows()
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, cur_lines)
        vim.bo[buf].modifiable = false
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        for _, span in ipairs(cur_spans) do
            if vim.hl and vim.hl.range then
                vim.hl.range(buf, ns, span.hl, { span.line, span.col_start }, { span.line, span.col_end })
            else
                pcall(vim.api.nvim_buf_add_highlight, buf, ns, span.hl, span.line, span.col_start, span.col_end)
            end
        end
    end

    apply_content()
    vim.keymap.set("n", "r", apply_content, { buffer = buf, silent = true, nowait = true })

    return float_info
end

return M

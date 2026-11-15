local ViewBuilder = {}
ViewBuilder.__index = ViewBuilder

function ViewBuilder.new()
    return setmetatable({
        lines = {},
        spans = {},
        right_marks = {},
        line_items = {},
    }, ViewBuilder)
end

function ViewBuilder:add_line(text, hl, item_meta)
    local s = tostring(text or "")
    s = s:gsub("\r\n", "\n"):gsub("\r", "")
    local parts = vim.split(s, "\n", { plain = true })
    for _, part in ipairs(parts) do
        self.lines[#self.lines + 1] = part
        local line_idx = #self.lines
        if item_meta ~= nil then
            self.line_items[line_idx] = item_meta
        end
        if hl and #part > 0 then
            self.spans[#self.spans + 1] = {
                line = line_idx - 1,
                col_start = 0,
                col_end = #part,
                hl = hl,
            }
        end
    end
end

function ViewBuilder:add_chunks(chunks, item_meta, opts)
    local raw_pieces = {}
    local pending_spans = {}
    local col = 0
    for _, chunk in ipairs(chunks or {}) do
        local text = tostring(chunk[1] or chunk.text or "")
        text = text:gsub("\r\n", " "):gsub("[\r\n]", " ")
        local hl = chunk[2] or chunk.hl
        local col_start = col
        local col_end = col + #text
        if hl and hl ~= "" and col_end > col_start then
            pending_spans[#pending_spans + 1] = {
                col_start = col_start,
                col_end = col_end,
                hl = hl,
            }
        end
        raw_pieces[#raw_pieces + 1] = text
        col = col_end
    end

    local line = table.concat(raw_pieces)
    self.lines[#self.lines + 1] = line
    local line_idx = #self.lines

    if item_meta ~= nil then
        self.line_items[line_idx] = item_meta
    end

    for _, s in ipairs(pending_spans) do
        self.spans[#self.spans + 1] = {
            line = line_idx - 1,
            col_start = s.col_start,
            col_end = s.col_end,
            hl = s.hl,
        }
    end

    if opts and opts.right_chunks then
        self.right_marks[#self.right_marks + 1] = {
            line = line_idx - 1,
            chunks = opts.right_chunks,
        }
    end
end

function ViewBuilder:add_section(title, hint, width)
    local title_text = "  " .. tostring(title or "")
    local chunks = {
        { title_text, "CSharpExplorerSectionHeader" },
    }
    local rule_len = math.max(4, (width or 32) - #title_text - 4)
    local rule = " " .. string.rep("─", rule_len)
    chunks[#chunks + 1] = { rule, "CSharpExplorerMuted" }

    local opts = nil
    if hint and hint ~= "" then
        opts = {
            right_chunks = {
                { " " .. tostring(hint) .. " ", "CSharpExplorerMuted" },
            },
        }
    end
    self:add_chunks(chunks, nil, opts)
end

function ViewBuilder:add_columns(rows, col_specs, opts)
    opts = opts or {}
    local left_pad = opts.left_pad or "  "
    local gap = opts.gap or "  "

    local widths = {}
    for col_idx, spec in ipairs(col_specs) do
        if spec.width then
            widths[col_idx] = spec.width
        else
            local max_w = 0
            for _, row in ipairs(rows) do
                local val = spec.key and row[spec.key] or row[col_idx] or ""
                local len = vim.fn.strdisplaywidth(tostring(val))
                if len > max_w then
                    max_w = len
                end
            end
            if spec.min_width and max_w < spec.min_width then
                max_w = spec.min_width
            end
            if spec.max_width and max_w > spec.max_width then
                max_w = spec.max_width
            end
            widths[col_idx] = max_w
        end
    end

    for _, row in ipairs(rows) do
        local chunks = {}
        if #left_pad > 0 then
            chunks[#chunks + 1] = { left_pad, nil }
        end
        for col_idx, spec in ipairs(col_specs) do
            local val = spec.key and row[spec.key] or row[col_idx] or ""
            local str = tostring(val)
            local is_last = col_idx == #col_specs
            local hl = (row.hl_map and (row.hl_map[spec.key] or row.hl_map[col_idx])) or spec.hl
            chunks[#chunks + 1] = { str, hl }
            if not is_last and widths[col_idx] then
                local display_len = vim.fn.strdisplaywidth(str)
                local pad_len = widths[col_idx] - display_len
                if pad_len > 0 then
                    chunks[#chunks + 1] = { string.rep(" ", pad_len), nil }
                end
            end
            if not is_last and #gap > 0 then
                chunks[#chunks + 1] = { gap, nil }
            end
        end
        local meta = row.item_meta or row.meta
        self:add_chunks(chunks, meta)
    end
end

function ViewBuilder:render(buf, ns_id)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return self.line_items
    end

    local lines = #self.lines > 0 and self.lines or { "" }
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    if ns_id then
        vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
        for _, span in ipairs(self.spans) do
            if span.line < #lines then
                local line_len = #lines[span.line + 1]
                local col_start = math.min(span.col_start, line_len)
                local col_end = math.min(span.col_end, line_len)
                if col_end > col_start then
                    pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, span.line, col_start, {
                        end_col = col_end,
                        hl_group = span.hl,
                        priority = 100,
                    })
                end
            end
        end
        for _, rm in ipairs(self.right_marks) do
            if rm.line < #lines then
                pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, rm.line, 0, {
                    virt_text = rm.chunks,
                    virt_text_pos = "right_align",
                    priority = 100,
                })
            end
        end
    end

    return self.line_items
end

return ViewBuilder

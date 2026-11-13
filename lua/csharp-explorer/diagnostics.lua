local metadata = require("csharp-explorer.metadata")
local config = require("csharp-explorer.config")
local node_utils = require("csharp-explorer.node")
local renderer = require("csharp-explorer.renderer")
local uv = vim.uv or vim.loop

local M = {}

M.ns_id = vim.api.nvim_create_namespace("CSharpExplorerDiagnostics")
M._index = { by_path = {}, by_dir = {} }
M._initialized = false
M._dirty = true
M._timer = nil

local SEVERITY_NAMES = {
    [vim.diagnostic.severity.ERROR] = "error",
    [vim.diagnostic.severity.WARN] = "warn",
    [vim.diagnostic.severity.INFO] = "info",
    [vim.diagnostic.severity.HINT] = "hint",
}

function M.rebuild_index()
    local by_path = {}
    local by_dir = {}
    local buf_paths = {}

    local diags = vim.diagnostic.get(nil)
    for _, d in ipairs(diags) do
        local bufnr = d.bufnr
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            local path = buf_paths[bufnr]
            if path == nil then
                local bname = vim.api.nvim_buf_get_name(bufnr)
                if bname ~= "" and vim.bo[bufnr].buftype == "" then
                    path = metadata.normalize_path(bname)
                else
                    path = false
                end
                buf_paths[bufnr] = path
            end

            if path then
                local sev_name = SEVERITY_NAMES[d.severity]
                if sev_name then
                    if not by_path[path] then
                        by_path[path] = { error = 0, warn = 0, info = 0, hint = 0 }
                    end
                    by_path[path][sev_name] = by_path[path][sev_name] + 1
                end
            end
        end
    end

    for file_path, counts in pairs(by_path) do
        local anc_dir = metadata.normalize_path(vim.fn.fnamemodify(file_path, ":h"))
        while anc_dir and anc_dir ~= "" and anc_dir ~= "/" do
            if not by_dir[anc_dir] then
                by_dir[anc_dir] = { error = 0, warn = 0, info = 0, hint = 0 }
            end
            by_dir[anc_dir].error = by_dir[anc_dir].error + counts.error
            by_dir[anc_dir].warn = by_dir[anc_dir].warn + counts.warn
            by_dir[anc_dir].info = by_dir[anc_dir].info + counts.info
            by_dir[anc_dir].hint = by_dir[anc_dir].hint + counts.hint

            local parent = vim.fn.fnamemodify(anc_dir, ":h")
            if parent == anc_dir then
                break
            end
            anc_dir = parent
        end
    end

    M._index = {
        by_path = by_path,
        by_dir = by_dir,
    }
    M._initialized = true
    M._dirty = false
end

function M.get_file_summary(file_path)
    if not file_path or file_path == "" then
        return nil
    end
    if not M._initialized or M._dirty then
        M.rebuild_index()
    end
    return M._index.by_path[metadata.normalize_path(file_path)]
end

function M.get_dir_summary(dir_path)
    if not dir_path or dir_path == "" then
        return nil
    end
    if not M._initialized or M._dirty then
        M.rebuild_index()
    end
    return M._index.by_dir[metadata.normalize_path(dir_path)]
end

function M.get_subtree_summary(node)
    if not node then
        return nil
    end
    local dir_path = node._dir or (node._path and vim.fn.fnamemodify(node._path, ":h"))
    if dir_path then
        local dir_sum = M.get_dir_summary(dir_path)
        if not dir_sum or (dir_sum.error + dir_sum.warn + dir_sum.info + dir_sum.hint == 0) then
            return nil
        end
        return {
            error = dir_sum.error,
            warn = dir_sum.warn,
            info = dir_sum.info,
            hint = dir_sum.hint,
        }
    end

    local acc = { error = 0, warn = 0, info = 0, hint = 0 }
    local function collect_projects(n)
        if n._type == "project" and n._dir then
            local psum = M.get_dir_summary(n._dir)
            if psum then
                acc.error = acc.error + psum.error
                acc.warn = acc.warn + psum.warn
                acc.info = acc.info + psum.info
                acc.hint = acc.hint + psum.hint
            end
            return
        end
        if n._children then
            for _, child in pairs(n._children) do
                collect_projects(child)
            end
        end
    end
    collect_projects(node)

    if acc.error + acc.warn + acc.info + acc.hint == 0 then
        return nil
    end
    return acc
end

function M.get_node_display_summary(node, cfg)
    if not node or node._virtual then
        return nil
    end

    if node_utils.is_file(node) then
        local self_sum = M.get_file_summary(node._path)
        local total_err = self_sum and self_sum.error or 0
        local total_warn = self_sum and self_sum.warn or 0
        local total_info = self_sum and self_sum.info or 0
        local total_hint = self_sum and self_sum.hint or 0

        if node_utils.is_nested_parent(node) and not node._expanded and cfg.show_on_nested_parents ~= false then
            if node._children then
                for _, child in pairs(node._children) do
                    if child._path then
                        local child_sum = M.get_file_summary(child._path)
                        if child_sum then
                            total_err = total_err + child_sum.error
                            total_warn = total_warn + child_sum.warn
                            total_info = total_info + child_sum.info
                            total_hint = total_hint + child_sum.hint
                        end
                    end
                end
            end
        end

        if total_err + total_warn + total_info + total_hint == 0 then
            return nil
        end
        return {
            error = total_err,
            warn = total_warn,
            info = total_info,
            hint = total_hint,
        }
    end

    if node_utils.is_directory(node) then
        if cfg.show_on_dirs == false then
            return nil
        end
        if node._expanded and node._type ~= "solution" and cfg.show_on_open_dirs == false then
            return nil
        end
        return M.get_subtree_summary(node)
    end

    return nil
end

function M.render_extmarks(state)
    if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(state.buf, M.ns_id, 0, -1)

    local diag_cfg = config.current.diagnostics
    if not (diag_cfg and diag_cfg.enabled ~= false) then
        return
    end

    local order = { "error", "warn", "info", "hint" }
    local icons = diag_cfg.icons or {}
    local hls = diag_cfg.highlights or {}

    for line_num, node in pairs(renderer.line_to_node) do
        local summary = M.get_node_display_summary(node, diag_cfg)
        if summary then
            local chunks = {}
            for _, sev in ipairs(order) do
                local count = summary[sev]
                if count and count > 0 then
                    local icon = icons[sev] or ""
                    local hl = hls[sev] or "DiagnosticSignError"
                    table.insert(chunks, { icon .. count .. " ", hl })
                end
            end
            if #chunks > 0 then
                pcall(vim.api.nvim_buf_set_extmark, state.buf, M.ns_id, line_num - 1, 0, {
                    virt_text = chunks,
                    virt_text_pos = "right_align",
                    hl_mode = "combine",
                    priority = 150,
                })
            end
        end
    end
end

function M.attach(state)
    if M._timer then
        pcall(function()
            M._timer:stop()
            M._timer:close()
        end)
        M._timer = nil
    end

    M._timer = uv.new_timer()

    local group = vim.api.nvim_create_augroup("CSharpExplorerDiagnostics", { clear = true })
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
        group = group,
        callback = function()
            if not state.is_active then
                M._dirty = true
                return
            end
            if not M._timer then
                return
            end
            local debounce = (config.current.diagnostics and config.current.diagnostics.debounce_ms) or 80
            M._timer:stop()
            M._timer:start(
                debounce,
                0,
                vim.schedule_wrap(function()
                    if state.is_active and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
                        M.rebuild_index()
                        M.render_extmarks(state)
                    else
                        M._dirty = true
                    end
                end)
            )
        end,
    })
end

function M.detach()
    if M._timer then
        pcall(function()
            M._timer:stop()
            M._timer:close()
        end)
        M._timer = nil
    end
    pcall(vim.api.nvim_del_augroup_by_name, "CSharpExplorerDiagnostics")
end

return M

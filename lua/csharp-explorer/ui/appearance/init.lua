local palette = require("csharp-explorer.ui.appearance.palette")
local window = require("csharp-explorer.ui.appearance.window")
local combiner = require("csharp-explorer.ui.appearance.combiner")
local config = require("csharp-explorer.config")

local M = {}

M.HIGHLIGHT_GROUPS = palette.HIGHLIGHT_GROUPS
M.WINDOW_PROFILES = window.WINDOW_PROFILES

M.groups = {}
for _, entry in ipairs(palette.HIGHLIGHT_GROUPS) do
    local short = entry.group:gsub("^CSharpExplorer", "")
    if short ~= "" then
        M.groups[short] = entry.group
    end
    M.groups[entry.group] = entry.group
end

local DEFAULT_CONFIG = {
    border = "single",
    devicons = {
        enable = true,
        color = true,
    },
    highlight_clipboard = "all",
    highlight_diagnostics = "none",
    highlight_project_names = false,
    sanitize_anti_violet = true,
    highlights = {},
}

M.config = vim.deepcopy(DEFAULT_CONFIG)

local initialized = false

local function normalize_config(opts)
    local merged = vim.deepcopy(DEFAULT_CONFIG)
    if type(opts) == "table" then
        if type(opts.devicons) == "boolean" then
            local flag = opts.devicons
            local copy = vim.deepcopy(opts)
            copy.devicons = { enable = flag, color = flag }
            merged = vim.tbl_deep_extend("force", merged, copy)
        else
            merged = vim.tbl_deep_extend("force", merged, opts)
        end
    end
    return merged
end

function M.setup(opts)
    initialized = true
    local base_opts = opts
    if base_opts == nil and config.current and config.current.appearance then
        base_opts = config.current.appearance
    end
    M.config = normalize_config(base_opts)
    palette.apply_all(M.config)
    combiner.clear()

    local group = vim.api.nvim_create_augroup("CSharpExplorerAppearance", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = function()
            M.on_colorscheme()
        end,
    })
end

function M.ensure()
    if not initialized then
        M.setup(config.current and config.current.appearance or nil)
    end
end

function M.highlight()
    palette.apply_all(M.config)
end

function M.on_colorscheme()
    palette.apply_all(M.config)
    combiner.clear()
    window.sync_all()

    local cs = package.loaded["csharp-explorer"]
    if cs and cs.is_active and cs.buf and vim.api.nvim_buf_is_valid(cs.buf) then
        local renderer = require("csharp-explorer.renderer")
        renderer.render(cs)
    end

    local run_win = package.loaded["csharp-explorer.ui.run_window"]
    if run_win and run_win.win and vim.api.nvim_win_is_valid(run_win.win) then
        run_win.render()
    end

    local dbg_win = package.loaded["csharp-explorer.ui.debug_window"]
    if dbg_win and dbg_win.win and vim.api.nvim_win_is_valid(dbg_win.win) then
        dbg_win.render()
    end

    local chrome = package.loaded["csharp-explorer.ui.chrome"]
    if chrome and chrome.refresh_winbars then
        chrome.refresh_winbars()
    end
end

M.attach_window = window.attach
M.detach_window = window.detach
M.get_winhl = window.get_winhl
M.sync_all_windows = window.sync_all
M.combine = combiner.combine

function M.get_border(preferred)
    if preferred then
        return preferred
    end
    if M.config and M.config.border then
        return M.config.border
    end
    if config.current and config.current.ui and config.current.ui.border then
        return config.current.ui.border
    end
    return "single"
end

function M.resolve_node_style(node, context)
    M.ensure()
    context = context or {}
    local node_utils = require("csharp-explorer.node")
    local metadata = require("csharp-explorer.metadata")

    local arrow_icon = "  "
    local arrow_hl = "CSharpExplorerNormal"
    if node._has_children then
        arrow_icon = node._expanded and config.current.icons.arrow_open or config.current.icons.arrow_closed
        arrow_hl = node._expanded and "CSharpExplorerFolderArrowOpen" or "CSharpExplorerFolderArrowClosed"
    end

    local icon_str = ""
    local icon_hl = "CSharpExplorerFileIcon"
    local name_hl = "CSharpExplorerTreeFile"

    if node._type == "solution" then
        icon_str = config.current.icons.solution
        icon_hl = "CSharpExplorerTreeRoot"
        name_hl = "CSharpExplorerTreeRoot"
    elseif node._type == "folder" or node._type == "solution_folder" then
        icon_str = node._expanded and config.current.icons.folder_open or config.current.icons.folder_closed
        icon_hl = "CSharpExplorerFolderIcon"
        name_hl = "CSharpExplorerTreeFolder"
    elseif node._type == "project" then
        local arch = node._archetype
        if not arch and node._path then
            arch = metadata.get_project_profile(node._path).archetype
            node._archetype = arch
        end
        local dynamic = config.current.dynamic_icons and config.current.dynamic_icons.enabled ~= false
        if dynamic and arch then
            icon_str = config.current.icons["project_" .. arch] or config.current.icons.project
            local arch_hl = (config.current.project_highlights and config.current.project_highlights[arch])
                or "CSharpExplorerTreeProject"
            icon_hl = arch_hl
            name_hl = M.config.highlight_project_names == true and arch_hl or "CSharpExplorerTreeProject"
        else
            icon_str = config.current.icons.project
            icon_hl = "CSharpExplorerTreeProject"
            name_hl = "CSharpExplorerTreeProject"
        end
    elseif
        node._type == "dependencies"
        or node._type == "package_group"
        or node._type == "project_reference_group"
        or node._type == "package"
        or node._type == "project_reference"
    then
        icon_str = config.current.icons[node._type] or config.current.icons.dependencies
        icon_hl = "CSharpExplorerTreeDeps"
        name_hl = "CSharpExplorerTreeDeps"
    elseif node_utils.is_file(node) then
        local dev_cfg = M.config.devicons
        local dev_enabled = dev_cfg ~= false
            and (dev_cfg == true or (type(dev_cfg) == "table" and dev_cfg.enable ~= false))
        local dev_color = type(dev_cfg) ~= "table" or dev_cfg.color ~= false
        local resolved_dev = false
        if dev_enabled then
            local ok_dev, devicons = pcall(require, "nvim-web-devicons")
            if ok_dev and devicons and devicons.get_icon then
                local ext = vim.fn.fnamemodify(node._name, ":e")
                local icon, hl = devicons.get_icon(node._name, ext, { default = true })
                if icon then
                    icon_str = icon .. " "
                    icon_hl = (dev_color and hl and hl ~= "") and hl or "CSharpExplorerFileIcon"
                    resolved_dev = true
                end
            end
        end
        if not resolved_dev then
            icon_str = config.current.icons[node._type] or config.current.icons.cs_file
            icon_hl = "CSharpExplorerFileIcon"
        end
        name_hl = "CSharpExplorerTreeFile"
    end

    local clip_hl = nil
    if context.is_cut then
        clip_hl = "CSharpExplorerCut"
    elseif context.is_copied then
        clip_hl = "CSharpExplorerCopied"
    end

    local diag_icon_hl = nil
    local diag_file_hl = nil
    if context.diagnostics then
        local d = context.diagnostics
        if d.error and d.error > 0 then
            diag_icon_hl = "CSharpExplorerDiagnosticErrorIcon"
            diag_file_hl = "CSharpExplorerDiagnosticErrorFileHL"
        elseif d.warn and d.warn > 0 then
            diag_icon_hl = "CSharpExplorerDiagnosticWarnIcon"
            diag_file_hl = "CSharpExplorerDiagnosticWarnFileHL"
        elseif d.info and d.info > 0 then
            diag_icon_hl = "CSharpExplorerDiagnosticInfoIcon"
            diag_file_hl = "CSharpExplorerDiagnosticInfoFileHL"
        elseif d.hint and d.hint > 0 then
            diag_icon_hl = "CSharpExplorerDiagnosticHintIcon"
            diag_file_hl = "CSharpExplorerDiagnosticHintFileHL"
        end
    end

    local clip_mode = M.config.highlight_clipboard or "all"
    local diag_mode = M.config.highlight_diagnostics or "none"

    local icon_groups = { icon_hl }
    if clip_hl and (clip_mode == "icon" or clip_mode == "all") then
        icon_groups[#icon_groups + 1] = clip_hl
    end
    if diag_icon_hl and (diag_mode == "icon" or diag_mode == "all") then
        icon_groups[#icon_groups + 1] = diag_icon_hl
    end
    if #icon_groups > 1 then
        icon_hl = combiner.combine(icon_groups)
    end

    local name_groups = { name_hl }
    if clip_hl and (clip_mode == "name" or clip_mode == "all") then
        name_groups[#name_groups + 1] = clip_hl
    end
    if diag_file_hl and (diag_mode == "name" or diag_mode == "all") then
        name_groups[#name_groups + 1] = diag_file_hl
    end
    if #name_groups > 1 then
        name_hl = combiner.combine(name_groups)
    end

    return {
        arrow = arrow_icon,
        arrow_hl = arrow_hl,
        icon = icon_str,
        icon_hl = icon_hl,
        name_hl = name_hl,
    }
end

function M.hi_test(opts)
    local hitest = require("csharp-explorer.ui.appearance.hitest")
    return hitest.open(opts)
end

return M

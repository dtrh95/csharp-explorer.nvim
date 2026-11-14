local config = require("csharp-explorer.config")
local diagnostics = require("csharp-explorer.diagnostics")
local metadata = require("csharp-explorer.metadata")
local node_utils = require("csharp-explorer.node")
local renderer = require("csharp-explorer.renderer")
local uv = vim.uv or vim.loop

local M = {}

local KNOWN_CS_SERVERS = {
    csharp_ls = true,
    roslyn = true,
    roslyn_ls = true,
    omnisharp = true,
    omnisharp_mono = true,
}

local function flush_modified_buffers(solution_dir)
    if config.current.refactor and config.current.refactor.save_modified_buffers == false then
        return
    end
    local norm_sol = solution_dir and metadata.normalize_path(solution_dir):lower() or nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" and vim.bo[b].modified then
            local name = vim.api.nvim_buf_get_name(b)
            local in_sol = true
            if norm_sol and name ~= "" then
                local norm_name = metadata.normalize_path(name):lower()
                in_sol = norm_name == norm_sol or vim.startswith(norm_name, norm_sol .. "/")
            end
            if in_sol and name ~= "" then
                pcall(vim.api.nvim_buf_call, b, function()
                    vim.cmd("silent! write")
                end)
            end
        end
    end
end

local function is_csharp_client(client)
    if not client then
        return false
    end
    if KNOWN_CS_SERVERS[client.name] then
        return true
    end
    if client.config and client.config.filetypes then
        for _, ft in ipairs(client.config.filetypes) do
            if ft == "cs" or ft == "razor" then
                return true
            end
        end
    end
    return false
end

function M.reload_lsp_clients(_opts)
    local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
    local all_clients = get_clients and get_clients() or {}
    local active_cs_clients = {}

    for _, c in ipairs(all_clients) do
        if is_csharp_client(c) then
            active_cs_clients[#active_cs_clients + 1] = c
        end
    end

    local restarted = 0
    local resurrected = 0

    if #active_cs_clients > 0 then
        for _, client in ipairs(active_cs_clients) do
            if client.name and client.name:find("roslyn") and vim.fn.exists(":Roslyn") == 2 then
                pcall(vim.cmd, "Roslyn restart")
                restarted = restarted + 1
            elseif type(client._restart) == "function" then
                pcall(client._restart, client, client.exit_timeout or 1500)
                restarted = restarted + 1
            else
                local cfg = vim.deepcopy(client.config)
                local bufs = vim.lsp.get_buffers_by_client_id and vim.lsp.get_buffers_by_client_id(client.id) or {}
                pcall(client.stop, client)
                restarted = restarted + 1
                local attempts = 0
                local function poll_restart()
                    attempts = attempts + 1
                    local stopped = type(client.is_stopped) ~= "function" or client:is_stopped()
                    if not stopped and attempts < 30 then
                        vim.defer_fn(poll_restart, 100)
                        return
                    end
                    if not vim.lsp.start then
                        return
                    end
                    local valid_bufs = {}
                    for _, b in ipairs(bufs) do
                        if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
                            valid_bufs[#valid_bufs + 1] = b
                        end
                    end
                    if #valid_bufs == 0 then
                        for _, b in ipairs(vim.api.nvim_list_bufs()) do
                            if vim.api.nvim_buf_is_loaded(b) then
                                local ft = vim.bo[b].filetype
                                if ft == "cs" or ft == "razor" then
                                    valid_bufs[#valid_bufs + 1] = b
                                end
                            end
                        end
                    end
                    if #valid_bufs > 0 then
                        local new_id = vim.lsp.start(cfg, { bufnr = valid_bufs[1] })
                        if new_id then
                            for i = 2, #valid_bufs do
                                pcall(vim.lsp.buf_attach_client, valid_bufs[i], new_id)
                            end
                        end
                    end
                end
                vim.defer_fn(poll_restart, 100)
            end
        end
    else
        local candidates = {}
        local has_is_enabled = type(vim.lsp.is_enabled) == "function"

        for name in pairs(KNOWN_CS_SERVERS) do
            if has_is_enabled and vim.lsp.is_enabled(name) then
                candidates[#candidates + 1] = name
            end
        end

        if #candidates == 0 then
            for name in pairs(KNOWN_CS_SERVERS) do
                local ok, cfg = pcall(function()
                    return vim.lsp.config and vim.lsp.config[name]
                end)
                if ok and cfg and type(cfg.cmd) == "table" and type(cfg.cmd[1]) == "string" then
                    if vim.fn.executable(cfg.cmd[1]) == 1 then
                        candidates[#candidates + 1] = name
                    end
                end
            end
        end

        for _, name in ipairs(candidates) do
            if type(vim.lsp.enable) == "function" then
                pcall(vim.lsp.enable, name, false)
                pcall(vim.lsp.enable, name, true)
                resurrected = resurrected + 1
            end
        end

        if vim.fn.exists(":Roslyn") == 2 then
            pcall(vim.cmd, "Roslyn restart")
            resurrected = resurrected + 1
        end

        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then
                local ft = vim.bo[b].filetype
                if ft == "cs" or ft == "razor" then
                    vim.api.nvim_exec_autocmds("FileType", { buffer = b, modeline = false })
                end
            end
        end
    end

    return restarted, resurrected
end

function M.reload_all(state, opts)
    opts = opts or {}
    local start_hr = uv.hrtime()

    if state and not state.tree and type(state.ensure_tree) == "function" then
        state.ensure_tree()
    end

    local sol_dir = (state and state.tree and state.tree._dir) or vim.fn.getcwd()
    flush_modified_buffers(sol_dir)
    metadata.clear_cache()

    local ok_runner, runner = pcall(require, "csharp-explorer.runner")
    if ok_runner and runner.clear_build_diagnostics then
        runner.clear_build_diagnostics()
    end

    local snapshot = nil
    if state and state.tree then
        snapshot = node_utils.snapshot_tree_expansion(state.tree)
    end

    if state and type(state.reparse_solution) == "function" then
        state.reparse_solution()
    end

    if state and state.tree and snapshot then
        node_utils.restore_tree_expansion(state.tree, snapshot)
    end

    if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        renderer.render(state)
    end

    diagnostics.rebuild_index()
    if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        diagnostics.render_extmarks(state)
    end

    local restarted, resurrected = M.reload_lsp_clients(opts)

    local solution_path = (state and state.tree and state.tree._path) or ""
    local projects_count = (state and state.tree and #node_utils.get_solution_project_dirs(state.tree)) or 0
    local elapsed_ms = math.floor((uv.hrtime() - start_hr) / 1000000)

    local result = {
        solution_path = solution_path,
        projects_count = projects_count,
        restarted_clients = restarted,
        resurrected_clients = resurrected,
        elapsed_ms = elapsed_ms,
    }

    vim.api.nvim_exec_autocmds("User", { pattern = "CSharpExplorerProjectsReloaded", data = result })

    if not opts.silent then
        vim.notify(
            string.format(
                "Reloaded %d project(s) and %d C# LSP client(s) in %dms",
                projects_count,
                restarted + resurrected,
                elapsed_ms
            ),
            vim.log.levels.INFO
        )
    end

    return result
end

return M

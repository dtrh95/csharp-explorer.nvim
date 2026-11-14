local runner = require("csharp-explorer.runner")
local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local node_utils = require("csharp-explorer.node")
local renderer = require("csharp-explorer.renderer")
local navigation = require("csharp-explorer.actions.navigation")

local M = {}

function M.execute(state, action, opts)
    local target = runner.resolve_target(state, opts)
    if not target then
        vim.notify("Could not resolve target for " .. action, vim.log.levels.WARN)
        if opts and opts.on_complete then
            opts.on_complete({
                status = "failed",
                exit_code = 1,
                lines = { "Target not found" },
                output = "Target not found",
            })
        end
        return nil
    end

    local dotnet_bin = runner.resolve_dotnet()
    local action_title = action:sub(1, 1):upper() .. action:sub(2)
    local steps = {}

    if target.kind == "solution_folder" then
        if not target.project_paths or #target.project_paths == 0 then
            vim.notify(
                "No projects found under solution folder: " .. (target.solution_folder or target.name),
                vim.log.levels.WARN
            )
            if opts and opts.on_complete then
                opts.on_complete({
                    status = "succeeded",
                    exit_code = 0,
                    lines = {},
                    output = "",
                })
            end
            return nil
        end
        for _, proj_path in ipairs(target.project_paths) do
            local proj_name = vim.fn.fnamemodify(proj_path, ":t:r")
            local proj_dir = vim.fn.fnamemodify(proj_path, ":h")
            local cmd = (action == "restore") and { dotnet_bin, "restore", proj_path }
                or { dotnet_bin, action, proj_path, "--nologo" }
            table.insert(steps, {
                cmd = cmd,
                cwd = proj_dir,
                label = string.format("%s %s", action_title, proj_name),
            })
        end
    else
        local path = (target.kind == "solution" and (target.path or target.solution_path))
            or (target.kind == "project" and (target.path or (target.project_paths and target.project_paths[1])))
            or ((target.project_paths and target.project_paths[1]) or target.path or target.cwd)
        local cmd = (action == "restore") and { dotnet_bin, "restore", path }
            or { dotnet_bin, action, path, "--nologo" }
        table.insert(steps, {
            cmd = cmd,
            cwd = target.cwd,
            label = string.format("%s %s", action_title, target.name),
        })
    end

    local title = string.format("%s: %s", action_title, target.name)
    return runner.run_pipeline(steps, {
        title = title,
        on_complete = function(result)
            metadata.clear_cache()
            if state and state.tree then
                node_utils.reset_projects(state.tree)
                if state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
                    renderer.render(state)
                end
            end

            result.target = target

            if action == "clean" then
                runner.clear_build_diagnostics()
                vim.fn.setqflist({}, "r")
                pcall(function()
                    local diagnostics = require("csharp-explorer.diagnostics")
                    diagnostics.rebuild_index()
                    if state and state.is_active then
                        diagnostics.render_extmarks(state)
                    end
                end)

                local succeeded = (result.status == "succeeded" and result.exit_code == 0)
                result.succeeded = succeeded
                if not succeeded and result.status ~= "cancelled" then
                    result.status = "failed"
                end

                if result.status ~= "cancelled" then
                    if succeeded then
                        vim.notify(string.format("Clean succeeded: %s", target.name), vim.log.levels.INFO)
                    else
                        runner.open_output()
                        vim.notify(
                            string.format("Clean failed: %s (exit %d)", target.name, result.exit_code or 1),
                            vim.log.levels.ERROR
                        )
                    end
                end
            else
                local parsed = runner.parse_msbuild_output(result.output, target.cwd)
                runner.sync_build_diagnostics(parsed.diagnostics)
                vim.fn.setqflist(parsed.quickfix, "r")
                result.parsed = parsed

                local succeeded = (result.status == "succeeded" and result.exit_code == 0 and parsed.errors == 0)
                result.succeeded = succeeded
                if not succeeded and result.status ~= "cancelled" then
                    result.status = "failed"
                end

                pcall(function()
                    local diagnostics = require("csharp-explorer.diagnostics")
                    diagnostics.rebuild_index()
                    if state and state.is_active then
                        diagnostics.render_extmarks(state)
                    end
                end)

                local orch = (config.current and config.current.orchestration) or {}
                if result.status ~= "cancelled" then
                    if not succeeded then
                        if #parsed.quickfix > 0 then
                            if orch.open_quickfix_on_error ~= false then
                                navigation.focus_editor_window(state)
                                vim.cmd("botright copen")
                            end
                            if orch.open_output_on_error == true then
                                runner.open_output()
                            end
                        else
                            runner.open_output()
                        end
                        vim.notify(
                            string.format(
                                "%s failed: %s (%d error(s), %d warning(s))",
                                action_title,
                                target.name,
                                parsed.errors,
                                parsed.warnings
                            ),
                            vim.log.levels.ERROR
                        )
                    else
                        if orch.close_quickfix_on_success == true then
                            pcall(vim.cmd, "cclose")
                        end
                        vim.notify(
                            string.format(
                                "%s succeeded: %s (%d warning(s))",
                                action_title,
                                target.name,
                                parsed.warnings
                            ),
                            vim.log.levels.INFO
                        )
                    end
                end
            end

            if opts and opts.on_complete then
                opts.on_complete(result)
            end
        end,
    })
end

function M.build(state, opts)
    return M.execute(state, "build", opts)
end

function M.restore(state, opts)
    return M.execute(state, "restore", opts)
end

function M.clean(state, opts)
    return M.execute(state, "clean", opts)
end

function M.action(state, action)
    return function()
        M.execute(state, action)
    end
end

return M

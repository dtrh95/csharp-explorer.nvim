local runner = require("csharp-explorer.runner")
local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local node_utils = require("csharp-explorer.node")
local renderer = require("csharp-explorer.renderer")
local navigation = require("csharp-explorer.actions.navigation")
local uv = vim.uv or vim.loop

local M = {}

local function render_body(usings, ns, type_decl, file_scoped)
    local u_block = ""
    if usings and #usings > 0 then
        u_block = table.concat(usings, "\n") .. "\n\n"
    end
    if file_scoped ~= false then
        return string.format("%snamespace %s;\n\n%s\n", u_block, ns, type_decl)
    else
        local indented = {}
        for line in (type_decl .. "\n"):gmatch("(.-)\r?\n") do
            if line ~= "" then
                table.insert(indented, "    " .. line)
            else
                table.insert(indented, "")
            end
        end
        return string.format("%snamespace %s\n{\n%s\n}\n", u_block, ns, table.concat(indented, "\n"))
    end
end

M.ITEM_TEMPLATES = {
    {
        id = "class",
        label = "C# Class",
        default_name = "Class1",
        ext = ".cs",
        render = function(clean_name, ns, file_scoped)
            local body = string.format("public class %s\n{\n}", clean_name)
            return render_body({}, ns, body, file_scoped)
        end,
    },
    {
        id = "interface",
        label = "C# Interface",
        default_name = "IService",
        ext = ".cs",
        render = function(clean_name, ns, file_scoped)
            local sanitized = clean_name:match("^I[A-Z]") and clean_name or ("I" .. clean_name)
            local body = string.format("public interface %s\n{\n}", sanitized)
            return render_body({}, ns, body, file_scoped)
        end,
    },
    {
        id = "record",
        label = "C# Record",
        default_name = "Record1",
        ext = ".cs",
        render = function(clean_name, ns, file_scoped)
            local body = string.format("public record %s();", clean_name)
            return render_body({}, ns, body, file_scoped)
        end,
    },
    {
        id = "enum",
        label = "C# Enum",
        default_name = "Enum1",
        ext = ".cs",
        render = function(clean_name, ns, file_scoped)
            local body = string.format("public enum %s\n{\n}", clean_name)
            return render_body({}, ns, body, file_scoped)
        end,
    },
    {
        id = "struct",
        label = "C# Struct",
        default_name = "Struct1",
        ext = ".cs",
        render = function(clean_name, ns, file_scoped)
            local body = string.format("public struct %s\n{\n}", clean_name)
            return render_body({}, ns, body, file_scoped)
        end,
    },
    {
        id = "apicontroller",
        label = "API Controller",
        default_name = "ValuesController",
        ext = ".cs",
        render = function(clean_name, ns, file_scoped)
            local sanitized = clean_name:match("Controller$") and clean_name or (clean_name .. "Controller")
            local body = string.format(
                '[ApiController]\n[Route("api/[controller]")]\npublic class %s : ControllerBase\n{\n}',
                sanitized
            )
            return render_body({ "using Microsoft.AspNetCore.Mvc;" }, ns, body, file_scoped)
        end,
    },
    {
        id = "xunit-test",
        label = "xUnit Test Class",
        default_name = "UnitTest1",
        ext = ".cs",
        render = function(clean_name, ns, file_scoped)
            local sanitized = clean_name:match("Tests?$") and clean_name or (clean_name .. "Tests")
            local body = string.format(
                "public class %s\n{\n    [Fact]\n    public void Test1()\n    {\n        Assert.True(true);\n    }\n}",
                sanitized
            )
            return render_body({ "using Xunit;" }, ns, body, file_scoped)
        end,
    },
    {
        id = "nunit-test",
        label = "NUnit Test Class",
        default_name = "UnitTest1",
        ext = ".cs",
        render = function(clean_name, ns, file_scoped)
            local sanitized = clean_name:match("Tests?$") and clean_name or (clean_name .. "Tests")
            local body = string.format(
                "public class %s\n{\n    [Test]\n    public void Test1()\n    {\n        Assert.Pass();\n    }\n}",
                sanitized
            )
            return render_body({ "using NUnit.Framework;" }, ns, body, file_scoped)
        end,
    },
    {
        id = "mstest-class",
        label = "MSTest Test Class",
        default_name = "UnitTest1",
        ext = ".cs",
        render = function(clean_name, ns, file_scoped)
            local sanitized = clean_name:match("Tests?$") and clean_name or (clean_name .. "Tests")
            local body = string.format(
                "[TestClass]\npublic class %s\n{\n    [TestMethod]\n    public void TestMethod1()\n    {\n        Assert.IsTrue(true);\n    }\n}",
                sanitized
            )
            return render_body({ "using Microsoft.VisualStudio.TestTools.UnitTesting;" }, ns, body, file_scoped)
        end,
    },
}

M.PROJECT_TEMPLATES = {
    { id = "classlib", label = "Class Library", short_name = "classlib", default_dir = "src" },
    { id = "webapi", label = "Web API (ASP.NET Core)", short_name = "webapi", default_dir = "src" },
    { id = "console", label = "Console Application", short_name = "console", default_dir = "src" },
    { id = "worker", label = "Worker Service", short_name = "worker", default_dir = "src" },
    { id = "xunit", label = "xUnit Test Project", short_name = "xunit", default_dir = "tests" },
    { id = "nunit", label = "NUnit Test Project", short_name = "nunit", default_dir = "tests" },
    { id = "mstest", label = "MSTest Test Project", short_name = "mstest", default_dir = "tests" },
    { id = "blazor", label = "Blazor Web App", short_name = "blazor", default_dir = "src" },
    { id = "grpc", label = "gRPC Service", short_name = "grpc", default_dir = "src" },
    { id = "mvc", label = "ASP.NET Core MVC", short_name = "mvc", default_dir = "src" },
}

local function find_item_template(id_or_idx)
    if type(id_or_idx) == "number" then
        return M.ITEM_TEMPLATES[id_or_idx]
    end
    if type(id_or_idx) == "table" and id_or_idx.render then
        return id_or_idx
    end
    for _, t in ipairs(M.ITEM_TEMPLATES) do
        if t.id == id_or_idx or t.label == id_or_idx then
            return t
        end
    end
    return M.ITEM_TEMPLATES[1]
end

local function find_project_template(id_or_idx)
    if type(id_or_idx) == "number" then
        return M.PROJECT_TEMPLATES[id_or_idx]
    end
    if type(id_or_idx) == "table" and id_or_idx.short_name then
        return id_or_idx
    end
    for _, t in ipairs(M.PROJECT_TEMPLATES) do
        if t.id == id_or_idx or t.short_name == id_or_idx or t.label == id_or_idx then
            return t
        end
    end
    return M.PROJECT_TEMPLATES[1]
end

local function sanitize_item_name(tpl, leaf_name)
    local clean_name = (leaf_name or ""):gsub("%.cs$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean_name == "" then
        clean_name = tpl.default_name
    end

    if tpl.id == "interface" and not clean_name:match("^I[A-Z]") then
        clean_name = "I" .. clean_name
    elseif tpl.id == "apicontroller" and not clean_name:match("Controller$") then
        clean_name = clean_name .. "Controller"
    elseif
        (tpl.id == "xunit-test" or tpl.id == "nunit-test" or tpl.id == "mstest-class")
        and not clean_name:match("Tests?$")
    then
        clean_name = clean_name .. "Tests"
    end
    return clean_name
end

function M.render_item(template_id, raw_name, namespace, opts)
    local tpl = find_item_template(template_id)
    local norm_raw = metadata.normalize_path((raw_name or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    local leaf_raw = norm_raw:find("/", 1, true) and vim.fn.fnamemodify(norm_raw, ":t") or norm_raw
    local clean_name = sanitize_item_name(tpl, leaf_raw)
    local orch = (config.current and config.current.orchestration) or {}
    local file_scoped = orch.file_scoped_namespaces ~= false
    if opts and opts.file_scoped ~= nil then
        file_scoped = opts.file_scoped
    end
    local ns = (namespace and namespace ~= "" and namespace) or "MyNamespace"
    return tpl.render(clean_name, ns, file_scoped), clean_name .. tpl.ext
end

local function write_item_file(state, target, tpl, raw_name, opts)
    local dest_dir = target.dir or target.path or target.cwd
    if target.kind == "file" and target.path then
        dest_dir = vim.fn.fnamemodify(target.path, ":h")
    end

    local norm_raw = metadata.normalize_path((raw_name or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    local has_sep = norm_raw:find("/", 1, true) ~= nil
    local rel_dir = has_sep and vim.fn.fnamemodify(norm_raw, ":h") or nil
    local leaf_raw = has_sep and vim.fn.fnamemodify(norm_raw, ":t") or norm_raw
    local clean_name = sanitize_item_name(tpl, leaf_raw)
    local final_dir = (rel_dir and rel_dir ~= "" and rel_dir ~= ".")
            and metadata.normalize_path(dest_dir .. "/" .. rel_dir)
        or dest_dir
    vim.fn.mkdir(final_dir, "p")

    local file_name = clean_name .. tpl.ext
    local full_path = metadata.normalize_path(final_dir .. "/" .. file_name)

    if uv.fs_stat(full_path) then
        vim.notify("File already exists: " .. full_path, vim.log.levels.WARN)
        if opts and opts.on_complete then
            opts.on_complete(nil, "File already exists")
        end
        return nil
    end

    local ns = metadata.infer_expected_namespace(full_path, target.project_node) or "MyNamespace"
    local content = M.render_item(tpl, clean_name, ns, opts)
    local f = io.open(full_path, "wb")
    if not f then
        vim.notify("Failed to write file: " .. full_path, vim.log.levels.ERROR)
        if opts and opts.on_complete then
            opts.on_complete(nil, "Failed to open file for write")
        end
        return nil
    end
    f:write(content)
    f:close()

    metadata.clear_cache()
    if target.project_node then
        local dep_node = target.project_node._children and target.project_node._children["Dependencies"]
        local had_meta = target.project_node._meta_loaded
        node_utils.reset_projects(target.project_node)
        node_utils.populate_cs_files(target.project_node)
        if dep_node then
            target.project_node._children["Dependencies"] = dep_node
            target.project_node._meta_loaded = had_meta
        elseif state and state.tree then
            node_utils.populate_dependencies(target.project_node, state.tree)
        end
    end
    if state and state.tree and state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
        renderer.render(state)
    end

    navigation.focus_editor_window(state)
    vim.cmd("edit " .. vim.fn.fnameescape(full_path))

    if opts and opts.on_complete then
        opts.on_complete(full_path)
    end
    return full_path
end

function M.add_item(state, opts)
    local target = runner.resolve_target(state, opts)
    if not target then
        vim.notify("Could not resolve target for adding item", vim.log.levels.WARN)
        if opts and opts.on_complete then
            opts.on_complete(nil, "Target not found")
        end
        return nil
    end

    if opts and opts.template and opts.name then
        local tpl = find_item_template(opts.template)
        return write_item_file(state, target, tpl, opts.name, opts)
    end

    local items = {}
    for _, t in ipairs(M.ITEM_TEMPLATES) do
        table.insert(items, { kind = "template", tpl = t, label = t.label })
    end
    table.insert(items, { kind = "switch_project", label = "New .NET Project (add to solution)..." })

    vim.ui.select(items, {
        prompt = "Select C# Item Template:",
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if not choice then
            return
        end
        if choice.kind == "switch_project" then
            M.add_project(state, opts)
            return
        end

        local tpl = choice.tpl
        vim.ui.input({
            prompt = "Item Name: ",
            default = tpl.default_name,
        }, function(name)
            if not name or name == "" then
                return
            end
            write_item_file(state, target, tpl, name, opts)
        end)
    end)
end

local function execute_add_project(state, target, tpl, proj_name, parent_dir, opts)
    local sln_path = target.solution_path
    if not sln_path and state and state.tree and state.tree._path then
        sln_path = metadata.normalize_path(state.tree._path)
    end
    local sln_dir = (sln_path and vim.fn.fnamemodify(sln_path, ":h")) or target.cwd
    local proj_rel_dir = (parent_dir and parent_dir ~= "" and (parent_dir .. "/" .. proj_name)) or proj_name
    local proj_full_dir = metadata.normalize_path(sln_dir .. "/" .. proj_rel_dir)
    local csproj_path = metadata.normalize_path(proj_full_dir .. "/" .. proj_name .. ".csproj")

    local dotnet_bin = runner.resolve_dotnet()
    local steps = {
        {
            cmd = { dotnet_bin, "new", tpl.short_name, "-n", proj_name, "-o", proj_full_dir },
            cwd = sln_dir,
            label = string.format("dotnet new %s -n %s", tpl.short_name, proj_name),
        },
    }

    if sln_path and sln_path ~= "" then
        local add_cmd = { dotnet_bin, "sln", sln_path, "add", csproj_path }
        local sol_folder = target.solution_folder or (parent_dir ~= "" and parent_dir ~= "." and parent_dir)
        if sol_folder and sol_folder ~= "" then
            table.insert(add_cmd, "-s")
            table.insert(add_cmd, sol_folder)
        end
        table.insert(steps, {
            cmd = add_cmd,
            cwd = sln_dir,
            label = "dotnet sln add " .. proj_name,
        })
    end

    return runner.run_pipeline(steps, {
        title = "Add Project: " .. proj_name,
        on_complete = function(res)
            metadata.clear_cache()
            if state then
                local snapshot = state.tree and node_utils.snapshot_tree_expansion(state.tree) or nil
                if state.ensure_tree then
                    state.tree = nil
                    local fresh = state.ensure_tree()
                    if fresh and snapshot then
                        node_utils.restore_tree_expansion(fresh, snapshot)
                    end
                end
                if state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
                    if not navigation.reveal_project_in_tree(state, csproj_path) then
                        renderer.render(state)
                    end
                end
            end

            if res.status == "succeeded" then
                vim.notify("Added project: " .. proj_name, vim.log.levels.INFO)
            elseif res.status ~= "cancelled" then
                runner.open_output()
                vim.notify("Failed to add project: " .. proj_name, vim.log.levels.ERROR)
            end

            if opts and opts.on_complete then
                opts.on_complete(res)
            end
        end,
    })
end

function M.add_project(state, opts)
    local target = runner.resolve_target(state, opts)
    if not target then
        vim.notify("Could not resolve target for adding project", vim.log.levels.WARN)
        if opts and opts.on_complete then
            opts.on_complete({ status = "failed", exit_code = 1, lines = {}, output = "Target not found" })
        end
        return nil
    end

    if opts and opts.template and opts.name then
        local tpl = find_project_template(opts.template)
        local parent_dir = opts.dir or target.solution_folder or tpl.default_dir
        return execute_add_project(state, target, tpl, opts.name, parent_dir, opts)
    end

    vim.ui.select(M.PROJECT_TEMPLATES, {
        prompt = "Select .NET Project Template:",
        format_item = function(item)
            return string.format("%s (%s)", item.label, item.short_name)
        end,
    }, function(tpl)
        if not tpl then
            return
        end
        vim.ui.input({
            prompt = "Project Name: ",
        }, function(name)
            if not name or name == "" then
                return
            end
            local def_dir = target.solution_folder or tpl.default_dir
            vim.ui.input({
                prompt = "Parent Directory: ",
                default = def_dir,
            }, function(dir)
                if not dir or dir == "" then
                    dir = def_dir
                end
                execute_add_project(state, target, tpl, name, dir, opts)
            end)
        end)
    end)
end

function M.add(state, opts)
    local target = runner.resolve_target(state, opts)
    if target and (target.kind == "solution" or target.kind == "solution_folder") then
        M.add_project(state, opts)
    else
        M.add_item(state, opts)
    end
end

function M.action_menu(state)
    local target = runner.resolve_target(state)
    local target_name = target and target.name or "Workspace"
    local items = {
        {
            label = "Build (" .. target_name .. ")",
            action = function()
                require("csharp-explorer.actions.build").build(state)
            end,
        },
        {
            label = "Restore (" .. target_name .. ")",
            action = function()
                require("csharp-explorer.actions.build").restore(state)
            end,
        },
        {
            label = "Clean (" .. target_name .. ")",
            action = function()
                require("csharp-explorer.actions.build").clean(state)
            end,
        },
        {
            label = "Run Tests (" .. target_name .. ")",
            action = function()
                require("csharp-explorer.actions.test").run_target(state)
            end,
        },
    }

    if target and target.kind == "file" and target.path and target.path:match("%.cs$") then
        table.insert(items, {
            label = "Select Test in " .. target_name,
            action = function()
                require("csharp-explorer.actions.test").select_test(state)
            end,
        })
    end

    table.insert(items, {
        label = "Run Project (u)",
        action = function()
            require("csharp-explorer.actions.run").run_target(state)
        end,
    })
    table.insert(items, {
        label = "Select Run Profile / Compound (U)",
        action = function()
            require("csharp-explorer.actions.run").select_run_profile(state)
        end,
    })
    table.insert(items, {
        label = "Toggle Run Tool Window (L)",
        action = function()
            require("csharp-explorer.actions.run").toggle_run_window(state)
        end,
    })
    table.insert(items, {
        label = "Debug Project (D)",
        action = function()
            require("csharp-explorer.actions.debug").debug_target(state)
        end,
    })
    table.insert(items, {
        label = "Debug Profile / Compound... (gD)",
        action = function()
            require("csharp-explorer.actions.debug").select_debug_profile(state)
        end,
    })
    table.insert(items, {
        label = "Attach Debugger...",
        action = function()
            require("csharp-explorer.actions.debug").attach_debugger(state)
        end,
    })
    table.insert(items, {
        label = "Debug Unit Tests (gT)",
        action = function()
            require("csharp-explorer.actions.test").debug_test(state)
        end,
    })
    table.insert(items, {
        label = "Toggle Debug Window (M)",
        action = function()
            require("csharp-explorer.ui.debug_window").toggle(state)
        end,
    })
    table.insert(items, {
        label = "Manage Compounds (gc)",
        action = function()
            require("csharp-explorer.compound").manage_compounds(state)
        end,
    })
    table.insert(items, {
        label = "Reload All Projects & LSPs (gR)",
        action = function()
            require("csharp-explorer.reload").reload_all(state)
        end,
    })

    table.insert(items, {
        label = "Add C# Item...",
        action = function()
            M.add_item(state)
        end,
    })
    table.insert(items, {
        label = "Add .NET Project...",
        action = function()
            M.add_project(state)
        end,
    })
    table.insert(items, {
        label = "Task Output",
        action = function()
            runner.toggle_output()
        end,
    })

    if runner.is_running() then
        table.insert(items, {
            label = "Cancel Running Task",
            action = function()
                runner.cancel()
            end,
        })
    end

    if target and target.project_node and target.project_node._path then
        table.insert(items, {
            label = "Open .csproj",
            action = function()
                navigation.focus_editor_window(state)
                vim.cmd("edit " .. vim.fn.fnameescape(target.project_node._path))
            end,
        })
    end

    table.insert(items, {
        label = "Item Properties",
        action = function()
            require("csharp-explorer.actions.properties").open(state)()
        end,
    })
    table.insert(items, {
        label = "Safe Rename...",
        action = function()
            require("csharp-explorer.actions.refactor").rename(state)
        end,
    })
    table.insert(items, {
        label = "Safe Delete...",
        action = function()
            require("csharp-explorer.actions.refactor").delete(state)
        end,
    })
    table.insert(items, {
        label = "Sync Namespace",
        action = function()
            require("csharp-explorer.actions.namespace").sync_target(state)
        end,
    })
    table.insert(items, {
        label = "Search Text in Solution...",
        action = function()
            require("csharp-explorer.actions.search").grep(state)
        end,
    })
    table.insert(items, {
        label = "Search Symbols in Solution...",
        action = function()
            require("csharp-explorer.actions.search").symbols(state)
        end,
    })
    table.insert(items, {
        label = "Find Files in Solution...",
        action = function()
            require("csharp-explorer.actions.search").files(state)
        end,
    })

    vim.ui.select(items, {
        prompt = "CSharp Explorer Actions:",
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if choice and choice.action then
            choice.action()
        end
    end)
end

return M

local csharp_source = require("csharp-explorer.csharp_source")
local config = require("csharp-explorer.config")
local metadata = require("csharp-explorer.metadata")
local nesting = require("csharp-explorer.nesting")
local node_utils = require("csharp-explorer.node")
local renderer = require("csharp-explorer.renderer")
local namespace_actions = require("csharp-explorer.actions.namespace")
local uv = vim.uv or vim.loop

local M = {}

local function flush_dirty_buffers()
    local save_buf = not (config.current.refactor and config.current.refactor.save_modified_buffers == false)
    if not save_buf then
        return
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
            if vim.bo[b].buftype == "" and vim.bo[b].modified then
                vim.api.nvim_buf_call(b, function()
                    vim.cmd("silent! keepalt noautocmd update")
                end)
            end
        end
    end
end

local function migrate_path_and_buffers(old_path, new_path)
    local norm_old = metadata.normalize_path(old_path)
    local norm_new = metadata.normalize_path(new_path)
    if norm_old == norm_new then
        return true
    end
    vim.fn.mkdir(vim.fn.fnamemodify(norm_new, ":h"), "p")
    local ok, err = pcall(vim.lsp.util.rename, norm_old, norm_new, { overwrite = false })
    if not ok then
        local r_ok, r_err = uv.fs_rename(norm_old, norm_new)
        if not r_ok then
            return false, r_err or err
        end
    end

    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then
            local bname = metadata.normalize_path(vim.api.nvim_buf_get_name(b))
            if bname == norm_old or vim.startswith(bname, norm_old .. "/") then
                local remapped = norm_new .. bname:sub(#norm_old + 1)
                local existing = vim.fn.bufnr(remapped)
                if existing ~= -1 and existing ~= b then
                    pcall(vim.api.nvim_buf_delete, b, { force = true })
                else
                    pcall(vim.api.nvim_buf_set_name, b, remapped)
                    local phantom = vim.fn.bufnr(bname)
                    if phantom ~= -1 and phantom ~= b then
                        pcall(vim.api.nvim_buf_delete, phantom, { force = true })
                    end
                end
            end
        end
    end
    return true
end

local function wipe_buffers_under(target_path, skip_buf)
    local norm = metadata.normalize_path(target_path)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= skip_buf and vim.api.nvim_buf_is_valid(b) then
            local bname = metadata.normalize_path(vim.api.nvim_buf_get_name(b))
            if bname == norm or vim.startswith(bname, norm .. "/") then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end
    end
end

local function apply_and_flush_workspace_edit(edit, offset_encoding)
    if not edit then
        return
    end
    vim.lsp.util.apply_workspace_edit(edit, offset_encoding or "utf-16")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
            if vim.bo[b].buftype == "" and vim.bo[b].modified then
                vim.api.nvim_buf_call(b, function()
                    vim.cmd("silent! keepalt noautocmd update")
                end)
            end
        end
    end
end

local function lsp_rename_symbol(file_path, new_type_name, old_stem)
    if config.current.refactor and config.current.refactor.lsp_rename == false then
        return false, nil
    end
    local norm_path = metadata.normalize_path(file_path)
    local f = io.open(norm_path, "rb")
    if not f then
        return false, nil
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return false, nil
    end

    local pt = csharp_source.locate_primary_type(content, old_stem)
    if not pt or pt.name == new_type_name or not new_type_name:match("^[%a_][%w_]*$") then
        return false, pt and pt.name or nil
    end

    local bufnr = vim.fn.bufadd(norm_path)
    vim.fn.bufload(bufnr)

    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    if #clients == 0 then
        for _, c in ipairs(vim.lsp.get_clients()) do
            if c.server_capabilities and c.server_capabilities.renameProvider then
                if c.root_dir and vim.startswith(norm_path, metadata.normalize_path(c.root_dir)) then
                    pcall(vim.lsp.buf_attach_client, bufnr, c.id)
                    clients[#clients + 1] = c
                end
            end
        end
    end

    for _, client in ipairs(clients) do
        if client.server_capabilities and client.server_capabilities.renameProvider then
            local enc = client.offset_encoding or "utf-16"
            local fresh_pt = csharp_source.locate_primary_type(content, old_stem, enc)
            if fresh_pt then
                local params = {
                    textDocument = { uri = vim.uri_from_fname(norm_path) },
                    position = fresh_pt.lsp_pos,
                    newName = new_type_name,
                }
                local resp = client:request_sync("textDocument/rename", params, 5000, bufnr)
                if resp and resp.result then
                    apply_and_flush_workspace_edit(resp.result, enc)
                    return true, fresh_pt.name
                end
            end
        end
    end

    return false, pt.name
end

local function offline_sync_type_in_files(file_paths, old_name, new_name)
    if not old_name or not new_name or old_name == new_name then
        return
    end
    for _, p in ipairs(file_paths) do
        local norm = metadata.normalize_path(p)
        if vim.endswith(norm, ".cs") and uv.fs_stat(norm) then
            local f = io.open(norm, "rb")
            if f then
                local content = f:read("*a")
                f:close()
                if content and content ~= "" then
                    local updated, count = csharp_source.rename_type_identifier(content, old_name, new_name)
                    if count > 0 then
                        namespace_actions.write_file_or_buffer(norm, updated)
                    end
                end
            end
        end
    end
end

local function lsp_will_rename(renames)
    for _, client in ipairs(vim.lsp.get_clients()) do
        local caps = client.server_capabilities
        if caps and caps.workspace and caps.workspace.fileOperations and caps.workspace.fileOperations.willRename then
            pcall(function()
                client:request_sync("workspace/willRenameFiles", { files = renames }, 3000)
            end)
        end
    end
end

local function lsp_did_rename(renames)
    for _, client in ipairs(vim.lsp.get_clients()) do
        local caps = client.server_capabilities
        if caps and caps.workspace and caps.workspace.fileOperations and caps.workspace.fileOperations.didRename then
            pcall(function()
                client:notify("workspace/didRenameFiles", { files = renames })
            end)
        end
    end
end

local function lsp_will_delete(paths)
    local files = {}
    for _, p in ipairs(paths) do
        files[#files + 1] = { uri = vim.uri_from_fname(p) }
    end
    for _, client in ipairs(vim.lsp.get_clients()) do
        local caps = client.server_capabilities
        if caps and caps.workspace and caps.workspace.fileOperations and caps.workspace.fileOperations.willDelete then
            pcall(function()
                client:request_sync("workspace/willDeleteFiles", { files = files }, 3000)
            end)
        end
    end
end

local function lsp_did_delete(paths)
    local files = {}
    for _, p in ipairs(paths) do
        files[#files + 1] = { uri = vim.uri_from_fname(p) }
    end
    for _, client in ipairs(vim.lsp.get_clients()) do
        local caps = client.server_capabilities
        if caps and caps.workspace and caps.workspace.fileOperations and caps.workspace.fileOperations.didDelete then
            pcall(function()
                client:notify("workspace/didDeleteFiles", { files = files })
            end)
        end
    end
end

function M.notify_watched_files(raw_changes)
    if not raw_changes or #raw_changes == 0 then
        return
    end
    local changes = {}
    for _, item in ipairs(raw_changes) do
        local uri = item.uri or (item.path and vim.uri_from_fname(metadata.normalize_path(item.path)))
        if uri and item.type then
            changes[#changes + 1] = { uri = uri, type = item.type }
        end
    end
    if #changes == 0 then
        return
    end
    for _, client in ipairs(vim.lsp.get_clients()) do
        pcall(function()
            client:notify("workspace/didChangeWatchedFiles", { changes = changes })
        end)
    end
end

local function resolve_refactor_node(state, opts, allow_virtual_walk)
    opts = opts or {}
    local navigation = require("csharp-explorer.actions.navigation")
    local node = opts.node
    if not node then
        local in_explorer = state
            and state.win
            and vim.api.nvim_win_is_valid(state.win)
            and vim.api.nvim_get_current_win() == state.win
        if in_explorer then
            node = navigation.get_node(state)
        else
            local cur_buf = vim.api.nvim_get_current_buf()
            local bname = vim.api.nvim_buf_get_name(cur_buf)
            if bname and bname ~= "" and vim.bo[cur_buf].buftype == "" then
                local norm = metadata.normalize_path(bname)
                if state and state.ensure_tree then
                    state.ensure_tree()
                end
                if vim.endswith(norm, ".csproj") then
                    local pnode = state and state.tree and metadata.find_owning_project(norm, state.tree)
                    if pnode and metadata.normalize_path(pnode._path):lower() == norm:lower() then
                        node = pnode
                    else
                        node = {
                            _type = "project",
                            _path = norm,
                            _dir = vim.fn.fnamemodify(norm, ":h"),
                            _name = vim.fn.fnamemodify(norm, ":t:r"),
                        }
                    end
                elseif not norm:match("%.slnx?$") then
                    local fname = vim.fn.fnamemodify(norm, ":t")
                    node = {
                        _type = node_utils.classify_file_type(fname),
                        _path = norm,
                        _name = fname,
                    }
                end
            end
        end
    end
    if allow_virtual_walk then
        while node and node._virtual and node._parent do
            node = node._parent
        end
    end
    return node
end

local function check_destructive_target(node, verb)
    if not node then
        vim.notify("No target node selected to " .. verb, vim.log.levels.WARN)
        return false
    end
    if node._virtual then
        vim.notify("Cannot " .. verb .. " virtual metadata nodes", vim.log.levels.WARN)
        return false
    end
    if node._type == "solution" then
        vim.notify("Cannot " .. verb .. " solution root node", vim.log.levels.WARN)
        return false
    end
    if node._type == "folder" and not node._dir then
        vim.notify("Cannot " .. verb .. " virtual solution folders", vim.log.levels.WARN)
        return false
    end
    return true
end

local function scan_directory_simple(dir)
    local names = {}
    local handle = uv.fs_scandir(dir)
    if handle then
        while true do
            local name = uv.fs_scandir_next(handle)
            if not name then
                break
            end
            names[#names + 1] = name
        end
    end
    return names
end

local function find_external_references(file_paths, type_names, tree)
    local exclusion_set = {}
    for _, p in ipairs(file_paths) do
        exclusion_set[metadata.normalize_path(p)] = true
    end

    local lsp_filtered = {}
    local seen_loc = {}
    local any_lsp_ok = false
    for _, fp in ipairs(file_paths) do
        if vim.endswith(fp, ".cs") and uv.fs_stat(fp) then
            local bufnr = vim.fn.bufadd(fp)
            vim.fn.bufload(bufnr)
            local clients = vim.lsp.get_clients({ bufnr = bufnr })
            for _, client in ipairs(clients) do
                if client.server_capabilities and client.server_capabilities.referencesProvider then
                    local f = io.open(fp, "rb")
                    local content = f and f:read("*a") or ""
                    if f then
                        f:close()
                    end
                    local types = csharp_source.extract_declared_types(content, client.offset_encoding or "utf-16")
                    for _, dt in ipairs(types) do
                        local params = {
                            textDocument = { uri = vim.uri_from_fname(fp) },
                            position = dt.lsp_pos,
                            context = { includeDeclaration = false },
                        }
                        local resp = client:request_sync("textDocument/references", params, 3000, bufnr)
                        if resp and resp.result and type(resp.result) == "table" then
                            any_lsp_ok = true
                            for _, loc in ipairs(resp.result) do
                                local fname = vim.uri_to_fname(loc.uri)
                                local norm_fn = metadata.normalize_path(fname)
                                local lnum = loc.range.start.line + 1
                                local col = loc.range.start.character + 1
                                local key = norm_fn .. ":" .. lnum .. ":" .. col
                                if not exclusion_set[norm_fn] and not seen_loc[key] then
                                    seen_loc[key] = true
                                    lsp_filtered[#lsp_filtered + 1] = {
                                        filename = fname,
                                        lnum = lnum,
                                        col = col,
                                        text = "reference (" .. dt.name .. ")",
                                    }
                                end
                            end
                        end
                    end
                    break
                end
            end
        end
    end
    if any_lsp_ok then
        return { count = #lsp_filtered, locations = lsp_filtered, source = "lsp" }
    end

    local pdirs = node_utils.get_solution_project_dirs(tree)
    local matches = {}
    for _, pdir in ipairs(pdirs) do
        local cs_files = namespace_actions.collect_cs_files_in_dir(pdir)
        for _, fpath in ipairs(cs_files) do
            if not exclusion_set[fpath] then
                local f = io.open(fpath, "rb")
                if f then
                    local content = f:read("*a")
                    f:close()
                    if content and content ~= "" and csharp_source.references_any_type(content, type_names) then
                        local enc = csharp_source.detect_encoding(content)
                        local cleaned = csharp_source.strip_csharp_lexical_noise(enc.raw:gsub("\r\n", "\n"))
                        local lnum = 1
                        for line in (cleaned .. "\n"):gmatch("(.-)\n") do
                            for _, name in ipairs(type_names) do
                                local esc = name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
                                local col = line:find("%f[%w_]" .. esc .. "%f[^%w_]")
                                if col then
                                    matches[#matches + 1] = {
                                        filename = fpath,
                                        lnum = lnum,
                                        col = col,
                                        text = line:gsub("^%s+", ""):gsub("%s+$", ""),
                                    }
                                    break
                                end
                            end
                            lnum = lnum + 1
                        end
                    end
                end
            end
        end
    end

    return { count = #matches, locations = matches, source = "scanner" }
end

local function refresh_after_fs(state, target_node)
    metadata.clear_cache()
    if target_node then
        local pnode = target_node._type == "project" and target_node
            or metadata.find_owning_project(target_node._path or target_node._dir, state and state.tree)
        if pnode then
            local dep_node = pnode._children and pnode._children["Dependencies"]
            local had_meta = pnode._meta_loaded
            node_utils.reset_projects(pnode)
            node_utils.populate_cs_files(pnode)
            if dep_node then
                pnode._children["Dependencies"] = dep_node
                pnode._meta_loaded = had_meta
            elseif state and state.tree then
                node_utils.populate_dependencies(pnode, state.tree)
            end
        end
    end
    if state and state.tree and state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
        renderer.render(state)
    end
end

local function find_project_csproj_references(target_csproj, tree)
    local norm_target = metadata.normalize_path(target_csproj)
    local pdirs = node_utils.get_solution_project_dirs(tree)
    local locations = {}
    for _, dir in ipairs(pdirs) do
        local sfiles = scan_directory_simple(dir)
        for _, fn in ipairs(sfiles) do
            if vim.endswith(fn, ".csproj") then
                local cp = metadata.normalize_path(dir .. "/" .. fn)
                if cp:lower() ~= norm_target:lower() then
                    local f = io.open(cp, "rb")
                    if f then
                        local xml = f:read("*a")
                        f:close()
                        local _, changed = csharp_source.rewrite_project_references(xml, cp, norm_target, nil)
                        if changed then
                            local lnum = 1
                            local target_leaf = vim.fn.fnamemodify(norm_target, ":t"):lower()
                            local matched_line = 1
                            local matched_text = "ProjectReference"
                            for line in (xml .. "\n"):gmatch("(.-)\r?\n") do
                                if
                                    line:lower():find("projectreference", 1, true)
                                    and line:lower():find(target_leaf, 1, true)
                                then
                                    matched_line = lnum
                                    matched_text = line:gsub("^%s+", ""):gsub("%s+$", "")
                                    break
                                end
                                lnum = lnum + 1
                            end
                            locations[#locations + 1] = {
                                filename = cp,
                                lnum = matched_line,
                                col = 1,
                                text = matched_text,
                            }
                        end
                    end
                end
            end
        end
    end
    return locations
end

function M.create(state, opts)
    opts = opts or {}
    local navigation = require("csharp-explorer.actions.navigation")
    local node = resolve_refactor_node(state, opts, true)

    local dest_dir = nil
    if node then
        if node._type == "folder" and node._dir then
            dest_dir = node._dir
        elseif node._type == "project" and node._dir then
            dest_dir = node._dir
        elseif node._path then
            dest_dir = vim.fn.fnamemodify(node._path, ":h")
        end
    end
    if not dest_dir then
        dest_dir = (state and state.tree and state.tree._dir) or vim.fn.getcwd()
    end
    dest_dir = metadata.normalize_path(dest_dir)

    local function execute_create(name)
        if not name or name == "" then
            return
        end
        local is_dir = vim.endswith(name, "/")
        local clean_name = name:gsub("/+$", "")
        local final_path = metadata.normalize_path(dest_dir .. "/" .. clean_name)

        if uv.fs_stat(final_path) then
            vim.notify("Path already exists: " .. final_path, vim.log.levels.WARN)
            if opts.on_complete then
                opts.on_complete(nil, "Already exists")
            end
            return
        end

        if is_dir then
            vim.fn.mkdir(final_path, "p")
            refresh_after_fs(state, node)
            if opts.on_complete then
                opts.on_complete(final_path)
            end
            return
        end

        vim.fn.mkdir(vim.fn.fnamemodify(final_path, ":h"), "p")
        if vim.endswith(final_path, ".cs") then
            local pnode = node
                and (node._type == "project" and node or metadata.find_owning_project(final_path, state and state.tree))
            local ns = metadata.infer_expected_namespace(final_path, pnode) or "MyNamespace"
            local fname = vim.fn.fnamemodify(final_path, ":t")
            local stem = fname:match("^([%w_]+)") or "NewType"
            local is_partial = fname:match("%..+%.cs$") ~= nil
            local kind = stem:match("^I[A-Z]") and "interface" or "class"
            local modifier = is_partial and "public partial" or "public"
            local body = string.format("namespace %s;\n\n%s %s %s\n{\n}\n", ns, modifier, kind, stem)
            local f = io.open(final_path, "wb")
            if f then
                f:write(body)
                f:close()
            end
        else
            local f = io.open(final_path, "wb")
            if f then
                f:close()
            end
        end

        M.notify_watched_files({ { path = final_path, type = 1 } })
        refresh_after_fs(state, node)
        navigation.focus_editor_window(state)
        vim.cmd("edit " .. vim.fn.fnameescape(final_path))
        if opts.on_complete then
            opts.on_complete(final_path)
        end
    end

    if opts.name then
        execute_create(opts.name)
    else
        vim.ui.input({ prompt = "Create (end with / for directory): " }, function(input)
            if input and input ~= "" then
                execute_create(input)
            end
        end)
    end
end

function M.rename(state, opts)
    opts = opts or {}
    flush_dirty_buffers()
    local node = resolve_refactor_node(state, opts, false)
    if not check_destructive_target(node, "rename") then
        return
    end

    local old_name = node._name
    local function execute_rename(new_name)
        if not new_name or new_name == "" or new_name == old_name then
            return
        end

        if node._type == "project" then
            local old_csproj = metadata.normalize_path(node._path)
            local p_dir = vim.fn.fnamemodify(old_csproj, ":h")
            local actual_new_name = vim.endswith(new_name, ".csproj") and new_name or (new_name .. ".csproj")
            local new_csproj = metadata.normalize_path(p_dir .. "/" .. actual_new_name)
            if new_csproj == old_csproj then
                return
            end
            if uv.fs_stat(new_csproj) then
                vim.notify("Target already exists: " .. new_csproj, vim.log.levels.WARN)
                return
            end
            local new_stem = vim.fn.fnamemodify(new_csproj, ":t:r")

            migrate_path_and_buffers(old_csproj, new_csproj)
            local watched = {
                { path = old_csproj, type = 3 },
                { path = new_csproj, type = 1 },
            }

            local pdirs = node_utils.get_solution_project_dirs(state and state.tree)
            for _, dir in ipairs(pdirs) do
                local sfiles = scan_directory_simple(dir)
                for _, fn in ipairs(sfiles) do
                    if vim.endswith(fn, ".csproj") then
                        local cp = dir .. "/" .. fn
                        local f = io.open(cp, "rb")
                        if f then
                            local xml = f:read("*a")
                            f:close()
                            local mod, changed =
                                csharp_source.rewrite_project_references(xml, cp, old_csproj, new_csproj)
                            if changed then
                                namespace_actions.write_file_or_buffer(cp, mod)
                                watched[#watched + 1] = { path = cp, type = 2 }
                            end
                        end
                    end
                end
            end

            if state and state.tree and state.tree._path then
                local sln_p = metadata.normalize_path(state.tree._path)
                local s_dir = vim.fn.fnamemodify(sln_p, ":h")
                local f = io.open(sln_p, "rb")
                if f then
                    local stext = f:read("*a")
                    f:close()
                    local sln_mod, schanged
                    if vim.endswith(sln_p, ".slnx") then
                        sln_mod, schanged = csharp_source.rewrite_slnx_content(stext, old_csproj, new_csproj, s_dir)
                    else
                        sln_mod, schanged =
                            csharp_source.rewrite_sln_content(stext, old_csproj, new_csproj, new_stem, s_dir)
                    end
                    if schanged then
                        namespace_actions.write_file_or_buffer(sln_p, sln_mod)
                        watched[#watched + 1] = { path = sln_p, type = 2 }
                    end
                end
            end

            M.notify_watched_files(watched)

            if state and state.ensure_tree then
                local snap = node_utils.snapshot_tree_expansion(state.tree)
                local rekeyed = node_utils.rekey_expansion_snapshot(snap, {
                    old_proj_csproj = old_csproj,
                    new_proj_csproj = new_csproj,
                })
                state.tree = nil
                local fresh = state.ensure_tree()
                if fresh and not state.tree then
                    state.tree = fresh
                end
                if fresh and rekeyed then
                    node_utils.restore_tree_expansion(fresh, rekeyed)
                end
                if state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
                    renderer.render(state)
                end
            end

            if opts.on_complete then
                opts.on_complete({ old_path = old_csproj, new_path = new_csproj })
            end
            return
        end

        if node._type == "folder" then
            local old_dir = metadata.normalize_path(node._dir)
            local parent_dir = vim.fn.fnamemodify(old_dir, ":h")
            local new_dir = metadata.normalize_path(parent_dir .. "/" .. new_name)
            if new_dir == old_dir then
                return
            end
            if uv.fs_stat(new_dir) then
                vim.notify("Target already exists: " .. new_dir, vim.log.levels.WARN)
                return
            end

            local old_cs = namespace_actions.collect_cs_files_in_dir(old_dir)
            local proj = metadata.find_owning_project(old_dir, state and state.tree)
            migrate_path_and_buffers(old_dir, new_dir)

            namespace_actions.sync_directory(new_dir, state and state.tree, {
                old_dir = old_dir,
                old_project_node = proj,
            })

            local watched = {}
            for _, ofp in ipairs(old_cs) do
                watched[#watched + 1] = { path = ofp, type = 3 }
                watched[#watched + 1] = { path = new_dir .. ofp:sub(#old_dir + 1), type = 1 }
            end
            M.notify_watched_files(watched)

            if proj and proj._dir then
                local norm_pdir = metadata.normalize_path(proj._dir)
                if vim.startswith(old_dir, norm_pdir .. "/") and vim.startswith(new_dir, norm_pdir .. "/") then
                    local old_rel = old_dir:sub(#norm_pdir + 2)
                    local new_rel = new_dir:sub(#norm_pdir + 2)
                    local dep_node = proj._children and proj._children["Dependencies"]
                    local had_meta = proj._meta_loaded
                    node_utils.reset_projects(proj)
                    proj._saved_expanded = node_utils.rekey_relative_map(proj._saved_expanded, old_rel, new_rel)
                    node_utils.populate_cs_files(proj)
                    if dep_node then
                        proj._children["Dependencies"] = dep_node
                        proj._meta_loaded = had_meta
                    elseif state and state.tree then
                        node_utils.populate_dependencies(proj, state.tree)
                    end
                    metadata.clear_cache()
                    if
                        state
                        and state.tree
                        and state.is_active
                        and state.win
                        and vim.api.nvim_win_is_valid(state.win)
                    then
                        renderer.render(state)
                    end
                else
                    refresh_after_fs(state, proj)
                end
            else
                refresh_after_fs(state, node)
            end

            if opts.on_complete then
                opts.on_complete({ old_path = old_dir, new_path = new_dir })
            end
            return
        end

        local old_file = metadata.normalize_path(node._path)
        local f_dir = vim.fn.fnamemodify(old_file, ":h")
        local new_file = metadata.normalize_path(f_dir .. "/" .. new_name)
        if new_file == old_file then
            return
        end
        local siblings = scan_directory_simple(f_dir)
        local companions = nesting.resolve_companions(old_name, siblings)

        if uv.fs_stat(new_file) then
            vim.notify("Target already exists: " .. new_file, vim.log.levels.WARN)
            return
        end
        for _, comp in ipairs(companions) do
            local new_comp_name = nesting.rename_companion_name(old_name, new_name, comp)
            local old_comp = f_dir .. "/" .. comp
            local new_comp = f_dir .. "/" .. new_comp_name
            if new_comp ~= old_comp and uv.fs_stat(new_comp) then
                vim.notify("Companion target already exists: " .. new_comp, vim.log.levels.WARN)
                return
            end
        end

        local old_stem = old_name:match("^(.+)%.cs$")
        local new_stem = new_name:match("^(.+)%.cs$")
        if old_stem and new_stem and old_stem ~= new_stem then
            local lsp_ok, old_type = lsp_rename_symbol(old_file, new_stem, old_stem)
            if not lsp_ok and old_type then
                local all_paths = { old_file }
                for _, c in ipairs(companions) do
                    all_paths[#all_paths + 1] = f_dir .. "/" .. c
                end
                offline_sync_type_in_files(all_paths, old_type, new_stem)
            elseif lsp_ok and old_type and #companions > 0 then
                local comp_paths = {}
                for _, c in ipairs(companions) do
                    comp_paths[#comp_paths + 1] = f_dir .. "/" .. c
                end
                offline_sync_type_in_files(comp_paths, old_type, new_stem)
            end
        elseif not old_stem then
            local old_cb_stem = old_name:match("^(.+)%.[^.]+$")
            local new_cb_stem = new_name:match("^(.+)%.[^.]+$")
            if old_cb_stem and new_cb_stem and old_cb_stem ~= new_cb_stem and new_cb_stem:match("^[%a_][%w_]*$") then
                for _, c in ipairs(companions) do
                    if c == old_name .. ".cs" then
                        local cb_path = f_dir .. "/" .. c
                        local lsp_ok, old_type = lsp_rename_symbol(cb_path, new_cb_stem, old_cb_stem)
                        if not lsp_ok and old_type then
                            offline_sync_type_in_files({ cb_path }, old_type, new_cb_stem)
                        end
                    end
                end
            end
        end

        local renames = { { oldUri = vim.uri_from_fname(old_file), newUri = vim.uri_from_fname(new_file) } }
        local watched = {
            { path = old_file, type = 3 },
            { path = new_file, type = 1 },
        }
        local planned_comp = {}
        for _, comp in ipairs(companions) do
            local new_comp_name = nesting.rename_companion_name(old_name, new_name, comp)
            local old_comp = f_dir .. "/" .. comp
            local new_comp = f_dir .. "/" .. new_comp_name
            planned_comp[#planned_comp + 1] = { old_comp = old_comp, new_comp = new_comp }
            renames[#renames + 1] = { oldUri = vim.uri_from_fname(old_comp), newUri = vim.uri_from_fname(new_comp) }
            if old_comp ~= new_comp then
                watched[#watched + 1] = { path = old_comp, type = 3 }
                watched[#watched + 1] = { path = new_comp, type = 1 }
            end
        end

        lsp_will_rename(renames)
        migrate_path_and_buffers(old_file, new_file)
        for _, pc in ipairs(planned_comp) do
            migrate_path_and_buffers(pc.old_comp, pc.new_comp)
        end
        lsp_did_rename(renames)
        M.notify_watched_files(watched)

        refresh_after_fs(state, node)
        if opts.on_complete then
            opts.on_complete({ old_path = old_file, new_path = new_file })
        end
    end

    if opts.new_name then
        execute_rename(opts.new_name)
    else
        vim.ui.input({ prompt = "Rename to: ", default = old_name }, function(input)
            if input and input ~= "" then
                execute_rename(input)
            end
        end)
    end
end

function M.delete(state, opts)
    opts = opts or {}
    flush_dirty_buffers()
    local navigation = require("csharp-explorer.actions.navigation")
    local node = resolve_refactor_node(state, opts, false)
    if not check_destructive_target(node, "delete") then
        return
    end

    local function execute_delete()
        if node._type == "project" then
            local old_csproj = metadata.normalize_path(node._path)
            local p_dir = metadata.normalize_path(node._dir or vim.fn.fnamemodify(old_csproj, ":h"))
            local sln_root_dir = state
                and state.tree
                and (
                    state.tree._dir and metadata.normalize_path(state.tree._dir)
                    or (state.tree._path and metadata.normalize_path(vim.fn.fnamemodify(state.tree._path, ":h")))
                )
            local is_flat_root = sln_root_dir ~= nil and p_dir == sln_root_dir
            local deleted_cs = is_flat_root and {} or namespace_actions.collect_cs_files_in_dir(p_dir)
            local watched = { { path = old_csproj, type = 3 } }
            for _, dp in ipairs(deleted_cs) do
                watched[#watched + 1] = { path = dp, type = 3 }
            end

            local pdirs = node_utils.get_solution_project_dirs(state and state.tree)
            for _, dir in ipairs(pdirs) do
                local sfiles = scan_directory_simple(dir)
                for _, fn in ipairs(sfiles) do
                    if vim.endswith(fn, ".csproj") then
                        local cp = dir .. "/" .. fn
                        local f = io.open(cp, "rb")
                        if f then
                            local xml = f:read("*a")
                            f:close()
                            local mod, changed = csharp_source.rewrite_project_references(xml, cp, old_csproj, nil)
                            if changed then
                                namespace_actions.write_file_or_buffer(cp, mod)
                                watched[#watched + 1] = { path = cp, type = 2 }
                            end
                        end
                    end
                end
            end

            if state and state.tree and state.tree._path then
                local sln_p = metadata.normalize_path(state.tree._path)
                local s_dir = vim.fn.fnamemodify(sln_p, ":h")
                local f = io.open(sln_p, "rb")
                if f then
                    local stext = f:read("*a")
                    f:close()
                    local sln_mod, schanged
                    if vim.endswith(sln_p, ".slnx") then
                        sln_mod, schanged = csharp_source.rewrite_slnx_content(stext, old_csproj, nil, s_dir)
                    else
                        sln_mod, schanged = csharp_source.rewrite_sln_content(stext, old_csproj, nil, nil, s_dir)
                    end
                    if schanged then
                        namespace_actions.write_file_or_buffer(sln_p, sln_mod)
                        watched[#watched + 1] = { path = sln_p, type = 2 }
                    end
                end
            end

            lsp_will_delete({ old_csproj })
            if is_flat_root then
                wipe_buffers_under(old_csproj)
                vim.fn.delete(old_csproj)
            else
                wipe_buffers_under(p_dir)
                vim.fn.delete(p_dir, "rf")
            end
            lsp_did_delete({ old_csproj })
            M.notify_watched_files(watched)

            if state and state.ensure_tree then
                local snap = node_utils.snapshot_tree_expansion(state.tree)
                state.tree = nil
                local fresh = state.ensure_tree()
                if fresh and not state.tree then
                    state.tree = fresh
                end
                if fresh and snap then
                    node_utils.restore_tree_expansion(fresh, snap)
                end
                if state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
                    renderer.render(state)
                end
            end

            if opts.on_complete then
                opts.on_complete({ p_dir })
            end
            return
        end

        if node._type == "folder" then
            local f_dir = metadata.normalize_path(node._dir)
            local deleted_cs = namespace_actions.collect_cs_files_in_dir(f_dir)
            local watched = {}
            for _, dp in ipairs(deleted_cs) do
                watched[#watched + 1] = { path = dp, type = 3 }
            end
            lsp_will_delete(deleted_cs)
            wipe_buffers_under(f_dir)
            vim.fn.delete(f_dir, "rf")
            lsp_did_delete(deleted_cs)
            M.notify_watched_files(watched)
            refresh_after_fs(state, node)
            if opts.on_complete then
                opts.on_complete({ f_dir })
            end
            return
        end

        local old_file = metadata.normalize_path(node._path)
        local f_dir = vim.fn.fnamemodify(old_file, ":h")
        local siblings = scan_directory_simple(f_dir)
        local companions = nesting.resolve_companions(node._name, siblings)
        local all_paths = { old_file }
        local watched = { { path = old_file, type = 3 } }
        for _, c in ipairs(companions) do
            local cp = f_dir .. "/" .. c
            all_paths[#all_paths + 1] = cp
            watched[#watched + 1] = { path = cp, type = 3 }
        end

        lsp_will_delete(all_paths)
        for _, p in ipairs(all_paths) do
            wipe_buffers_under(p)
            vim.fn.delete(p)
        end
        lsp_did_delete(all_paths)
        M.notify_watched_files(watched)

        refresh_after_fs(state, node)
        if opts.on_complete then
            opts.on_complete(all_paths)
        end
    end

    local skip_confirm = opts.confirm == true
        or (config.current.refactor and config.current.refactor.confirm_delete == false)
    if skip_confirm then
        execute_delete()
        return
    end

    local refs = { count = 0, locations = {} }
    if node._type == "project" and node._path then
        local proj_locs = find_project_csproj_references(node._path, state and state.tree)
        refs = { count = #proj_locs, locations = proj_locs, source = "csproj" }
    elseif node._type == "folder" and node._dir then
        local folder_cs = namespace_actions.collect_cs_files_in_dir(node._dir)
        local type_names = {}
        local seen_t = {}
        for _, fp in ipairs(folder_cs) do
            local f = io.open(fp, "rb")
            if f then
                local content = f:read("*a")
                f:close()
                local types = content and csharp_source.extract_declared_types(content) or {}
                for _, t in ipairs(types) do
                    if not seen_t[t.name] then
                        seen_t[t.name] = true
                        type_names[#type_names + 1] = t.name
                    end
                end
            end
        end
        if #type_names > 0 then
            refs = find_external_references(folder_cs, type_names, state and state.tree)
        end
    elseif node._path ~= nil then
        local old_file = metadata.normalize_path(node._path)
        local f_dir = vim.fn.fnamemodify(old_file, ":h")
        local siblings = scan_directory_simple(f_dir)
        local companions = nesting.resolve_companions(node._name, siblings)
        local paths_to_check = { old_file }
        for _, c in ipairs(companions) do
            paths_to_check[#paths_to_check + 1] = f_dir .. "/" .. c
        end
        local type_names = {}
        local seen_t = {}
        for _, fp in ipairs(paths_to_check) do
            if vim.endswith(fp, ".cs") then
                local f = io.open(fp, "rb")
                if f then
                    local content = f:read("*a")
                    f:close()
                    local types = content and csharp_source.extract_declared_types(content) or {}
                    for _, t in ipairs(types) do
                        if not seen_t[t.name] then
                            seen_t[t.name] = true
                            type_names[#type_names + 1] = t.name
                        end
                    end
                end
            end
        end
        if #type_names > 0 then
            refs = find_external_references(paths_to_check, type_names, state and state.tree)
        end
    end

    local items = { "Delete" }
    if refs.count > 0 then
        table.insert(items, 1, "Show references in quickfix (" .. refs.count .. " references)")
    end
    table.insert(items, "Cancel")

    local prompt_msg = refs.count > 0 and string.format("Delete %s? (%d references found)", node._name, refs.count)
        or string.format("Delete %s?", node._name)

    vim.ui.select(items, { prompt = prompt_msg }, function(choice)
        if choice and choice:find("^Show references") then
            navigation.focus_editor_window(state)
            vim.fn.setqflist(refs.locations, "r")
            vim.cmd("botright copen")
        elseif choice == "Delete" then
            execute_delete()
        end
    end)
end

function M.move_entries(entries, dest_dir, state, opts)
    opts = opts or {}
    flush_dirty_buffers()
    local norm_dest = metadata.normalize_path(dest_dir)

    for _, entry in ipairs(entries) do
        local ep = metadata.normalize_path(entry.path)
        if entry.is_dir and (norm_dest == ep or vim.startswith(norm_dest, ep .. "/")) then
            vim.notify("Cannot move folder into itself or subfolder: " .. entry.name, vim.log.levels.WARN)
            return false
        end
    end

    local all_moves = {}
    for _, entry in ipairs(entries) do
        local ep = metadata.normalize_path(entry.path)
        local target_ep = metadata.normalize_path(norm_dest .. "/" .. entry.name)
        if ep ~= target_ep then
            all_moves[#all_moves + 1] = {
                old_path = ep,
                new_path = target_ep,
                is_dir = entry.is_dir,
                name = entry.name,
            }
            if not entry.is_dir then
                local parent_dir = vim.fn.fnamemodify(ep, ":h")
                local siblings = scan_directory_simple(parent_dir)
                local companions = nesting.resolve_companions(entry.name, siblings)
                for _, c in ipairs(companions) do
                    all_moves[#all_moves + 1] = {
                        old_path = metadata.normalize_path(parent_dir .. "/" .. c),
                        new_path = metadata.normalize_path(norm_dest .. "/" .. c),
                        is_dir = false,
                        name = c,
                    }
                end
            end
        end
    end

    if #all_moves == 0 then
        return true
    end

    for _, mv in ipairs(all_moves) do
        if mv.old_path ~= mv.new_path and uv.fs_stat(mv.new_path) then
            vim.notify("Target already exists: " .. mv.new_path, vim.log.levels.WARN)
            return false
        end
    end

    local watched = {}
    for _, mv in ipairs(all_moves) do
        if mv.is_dir then
            mv.old_proj = metadata.find_owning_project(mv.old_path, state and state.tree)
            local dir_cs = namespace_actions.collect_cs_files_in_dir(mv.old_path)
            for _, dfp in ipairs(dir_cs) do
                watched[#watched + 1] = { path = dfp, type = 3 }
                watched[#watched + 1] = { path = mv.new_path .. dfp:sub(#mv.old_path + 1), type = 1 }
            end
        else
            watched[#watched + 1] = { path = mv.old_path, type = 3 }
            watched[#watched + 1] = { path = mv.new_path, type = 1 }
            if vim.endswith(mv.old_path, ".cs") then
                local old_proj = metadata.find_owning_project(mv.old_path, state and state.tree)
                mv.old_expected_ns = metadata.infer_expected_namespace(mv.old_path, old_proj)
                mv.old_proj = old_proj
            end
        end
    end

    local renames = {}
    for _, mv in ipairs(all_moves) do
        renames[#renames + 1] = {
            oldUri = vim.uri_from_fname(mv.old_path),
            newUri = vim.uri_from_fname(mv.new_path),
        }
    end
    lsp_will_rename(renames)

    for _, mv in ipairs(all_moves) do
        migrate_path_and_buffers(mv.old_path, mv.new_path)
    end

    local moved_csproj_pairs = {}
    for _, mv in ipairs(all_moves) do
        if not mv.is_dir and vim.endswith(mv.new_path, ".csproj") then
            moved_csproj_pairs[#moved_csproj_pairs + 1] = { old_p = mv.old_path, new_p = mv.new_path }
        elseif mv.is_dir then
            for _, fn in ipairs(scan_directory_simple(mv.new_path)) do
                if vim.endswith(fn, ".csproj") then
                    moved_csproj_pairs[#moved_csproj_pairs + 1] = {
                        old_p = mv.old_path .. "/" .. fn,
                        new_p = mv.new_path .. "/" .. fn,
                    }
                end
            end
        end
    end

    for _, pair in ipairs(moved_csproj_pairs) do
        local old_cdir = vim.fn.fnamemodify(pair.old_p, ":h")
        local new_cdir = vim.fn.fnamemodify(pair.new_p, ":h")
        local f_moved = io.open(pair.new_p, "rb")
        if f_moved then
            local mxml = f_moved:read("*a")
            f_moved:close()
            local rebased, rchanged = csharp_source.rebase_outgoing_project_references(mxml, old_cdir, new_cdir)
            if rchanged then
                namespace_actions.write_file_or_buffer(pair.new_p, rebased)
                watched[#watched + 1] = { path = pair.new_p, type = 2 }
            end
        end
        local pdirs = node_utils.get_solution_project_dirs(state and state.tree)
        for _, dir in ipairs(pdirs) do
            for _, fn in ipairs(scan_directory_simple(dir)) do
                if vim.endswith(fn, ".csproj") then
                    local cp = dir .. "/" .. fn
                    if metadata.normalize_path(cp) ~= metadata.normalize_path(pair.new_p) and uv.fs_stat(cp) then
                        local fc = io.open(cp, "rb")
                        if fc then
                            local xml = fc:read("*a")
                            fc:close()
                            local mod, changed =
                                csharp_source.rewrite_project_references(xml, cp, pair.old_p, pair.new_p)
                            if changed then
                                namespace_actions.write_file_or_buffer(cp, mod)
                                watched[#watched + 1] = { path = cp, type = 2 }
                            end
                        end
                    end
                end
            end
        end
        if state and state.tree and state.tree._path then
            local sln_p = metadata.normalize_path(state.tree._path)
            local s_dir = vim.fn.fnamemodify(sln_p, ":h")
            local fs = io.open(sln_p, "rb")
            if fs then
                local stext = fs:read("*a")
                fs:close()
                local sln_mod, schanged
                if vim.endswith(sln_p, ".slnx") then
                    sln_mod, schanged = csharp_source.rewrite_slnx_content(stext, pair.old_p, pair.new_p, s_dir)
                else
                    sln_mod, schanged = csharp_source.rewrite_sln_content(stext, pair.old_p, pair.new_p, nil, s_dir)
                end
                if schanged then
                    namespace_actions.write_file_or_buffer(sln_p, sln_mod)
                    watched[#watched + 1] = { path = sln_p, type = 2 }
                end
            end
        end
    end

    local sync_ns = not (config.current.refactor and config.current.refactor.sync_namespace_on_move == false)
    if sync_ns then
        for _, mv in ipairs(all_moves) do
            if mv.is_dir then
                namespace_actions.sync_directory(mv.new_path, state and state.tree, {
                    old_dir = mv.old_path,
                    old_project_node = mv.old_proj,
                })
            elseif vim.endswith(mv.new_path, ".cs") then
                namespace_actions.sync_file(mv.new_path, state and state.tree, {
                    old_expected_ns = mv.old_expected_ns,
                })
            end
        end
    end

    lsp_did_rename(renames)
    M.notify_watched_files(watched)

    if #moved_csproj_pairs > 0 and state and state.ensure_tree then
        local snap = node_utils.snapshot_tree_expansion(state.tree)
        state.tree = nil
        local fresh = state.ensure_tree()
        if fresh and not state.tree then
            state.tree = fresh
        end
        if fresh and snap then
            node_utils.restore_tree_expansion(fresh, snap)
        end
        if state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
            renderer.render(state)
        end
    elseif state and state.tree then
        node_utils.reset_projects(state.tree)
        if state.is_active and state.win and vim.api.nvim_win_is_valid(state.win) then
            renderer.render(state)
        end
    end

    if opts.on_complete then
        opts.on_complete(all_moves)
    end
    return true
end

return M

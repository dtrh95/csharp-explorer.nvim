local uv = vim.uv or vim.loop

local M = {}

local WATCH_FILENAMES = {
    ["HEAD"] = true,
    ["HEAD.lock"] = true,
    ["index"] = true,
    ["FETCH_HEAD"] = true,
    ["ORIG_HEAD"] = true,
    ["packed-refs"] = true,
    ["config"] = true,
}

local _fs_events = {}
local _timer = nil
local _on_change_cb = nil
local _debounce_ms = 120

function M.trigger_debounced()
    if not _on_change_cb then
        return
    end
    if not _timer then
        _timer = uv.new_timer()
    end
    _timer:stop()
    _timer:start(
        _debounce_ms,
        0,
        vim.schedule_wrap(function()
            if _on_change_cb then
                _on_change_cb()
            end
        end)
    )
end

function M.watch_gitdir(gitdir, on_change)
    if not gitdir or gitdir == "" then
        return
    end
    if on_change then
        _on_change_cb = on_change
    end
    if _fs_events[gitdir] then
        return
    end

    local handle = uv.new_fs_event()
    if not handle then
        return
    end

    local ok = pcall(function()
        handle:start(gitdir, {}, function(err, filename, _events)
            if err then
                return
            end
            if filename and not WATCH_FILENAMES[filename] then
                return
            end
            M.trigger_debounced()
        end)
    end)

    if ok then
        _fs_events[gitdir] = handle
    elseif not handle:is_closing() then
        handle:close()
    end
end

function M.attach(on_change, opts)
    _on_change_cb = on_change
    if opts and type(opts.debounce_ms) == "number" then
        _debounce_ms = opts.debounce_ms
    end

    local augroup = vim.api.nvim_create_augroup("CSharpExplorerGit", { clear = true })

    vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "ShellCmdPost" }, {
        group = augroup,
        callback = function()
            M.trigger_debounced()
        end,
    })

    vim.api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = { "FugitiveChanged", "GitSignsUpdate", "NeogitStatusRefreshed" },
        callback = function()
            M.trigger_debounced()
        end,
    })
end

function M.detach()
    for _, handle in pairs(_fs_events) do
        if not handle:is_closing() then
            handle:stop()
            handle:close()
        end
    end
    _fs_events = {}

    if _timer then
        if not _timer:is_closing() then
            _timer:stop()
            _timer:close()
        end
        _timer = nil
    end

    _on_change_cb = nil
    pcall(vim.api.nvim_del_augroup_by_name, "CSharpExplorerGit")
end

return M

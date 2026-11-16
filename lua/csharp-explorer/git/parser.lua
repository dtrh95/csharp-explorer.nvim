local M = {}

local STATUS_SPECS = {
    ["UU"] = { kind = "conflict", prio = 1, desc = "Merge conflict (both modified)", is_deleted = false },
    ["AA"] = { kind = "conflict", prio = 1, desc = "Merge conflict (both added)", is_deleted = false },
    ["UD"] = { kind = "conflict", prio = 1, desc = "Merge conflict (deleted by them)", is_deleted = true },
    ["DU"] = { kind = "conflict", prio = 1, desc = "Merge conflict (deleted by us)", is_deleted = false },
    ["DD"] = { kind = "conflict", prio = 1, desc = "Merge conflict (both deleted)", is_deleted = true },
    ["AU"] = { kind = "conflict", prio = 1, desc = "Merge conflict (added by us)", is_deleted = false },
    ["UA"] = { kind = "conflict", prio = 1, desc = "Merge conflict (added by them)", is_deleted = false },
    ["M "] = { kind = "staged", prio = 2, desc = "Staged (modified)", is_deleted = false },
    ["A "] = { kind = "staged", prio = 2, desc = "Staged (added)", is_deleted = false },
    ["C "] = { kind = "staged", prio = 2, desc = "Staged (copied)", is_deleted = false },
    ["T "] = { kind = "staged", prio = 2, desc = "Staged (type changed)", is_deleted = false },
    ["MM"] = { kind = "modified", prio = 3, desc = "Staged and unstaged changes", is_deleted = false },
    ["AM"] = { kind = "modified", prio = 3, desc = "Staged addition with unstaged changes", is_deleted = false },
    ["CM"] = { kind = "modified", prio = 3, desc = "Staged copy with unstaged changes", is_deleted = false },
    [" M"] = { kind = "modified", prio = 3, desc = "Modified (unstaged)", is_deleted = false },
    [" T"] = { kind = "modified", prio = 3, desc = "Type changed (unstaged)", is_deleted = false },
    ["R "] = { kind = "renamed", prio = 4, desc = "Renamed (staged)", is_deleted = false },
    ["RM"] = { kind = "renamed", prio = 4, desc = "Renamed with unstaged changes", is_deleted = false },
    ["D "] = { kind = "deleted", prio = 5, desc = "Deleted (staged)", is_deleted = true },
    [" D"] = { kind = "deleted", prio = 5, desc = "Deleted (unstaged)", is_deleted = true },
    ["RD"] = { kind = "deleted", prio = 5, desc = "Renamed then deleted", is_deleted = true },
    ["AD"] = { kind = "deleted", prio = 5, desc = "Staged addition deleted in worktree", is_deleted = true },
    ["MD"] = { kind = "deleted", prio = 5, desc = "Staged change deleted in worktree", is_deleted = true },
    ["??"] = { kind = "untracked", prio = 6, desc = "Untracked", is_deleted = false },
    ["!!"] = { kind = "ignored", prio = 7, desc = "Ignored", is_deleted = false },
}

local function resolve_spec(xy)
    local spec = STATUS_SPECS[xy]
    if spec then
        return spec
    end
    local x = xy:sub(1, 1)
    local y = xy:sub(2, 2)
    if x == "U" or y == "U" then
        spec = { kind = "conflict", prio = 1, desc = "Merge conflict", is_deleted = (y == "D" or x == "D") }
    elseif y == "D" or x == "D" then
        spec = { kind = "deleted", prio = 5, desc = "Deleted", is_deleted = true }
    elseif y == "M" or x == "M" then
        spec = { kind = "modified", prio = 3, desc = "Modified", is_deleted = false }
    elseif x == "R" or y == "R" then
        spec = { kind = "renamed", prio = 4, desc = "Renamed", is_deleted = false }
    elseif x == "A" or y == "A" or x == "C" or y == "C" then
        spec = { kind = "staged", prio = 2, desc = "Staged", is_deleted = false }
    else
        spec = { kind = "modified", prio = 3, desc = "Modified", is_deleted = false }
    end
    STATUS_SPECS[xy] = spec
    return spec
end

function M.new(on_entry, on_ignored_dir)
    local mode = "RECORD"
    local leftover = ""
    local pending_entry = nil

    local function process_token(token)
        if mode == "OLD_PATH" then
            if pending_entry then
                pending_entry.orig_path = token
                on_entry(pending_entry)
                pending_entry = nil
            end
            mode = "RECORD"
            return
        end

        if #token < 4 then
            return
        end

        local xy = token:sub(1, 2)
        local path = token:sub(4)
        if xy == "!!" then
            if path:sub(-1) == "/" then
                on_ignored_dir(path:sub(1, -2))
            else
                local spec = resolve_spec(xy)
                on_entry({
                    path = path,
                    xy = xy,
                    kind = spec.kind,
                    prio = spec.prio,
                    desc = spec.desc,
                    is_deleted = false,
                })
            end
            return
        end

        local clean_path = path:sub(-1) == "/" and path:sub(1, -2) or path
        local x = xy:sub(1, 1)
        local spec = resolve_spec(xy)
        local entry = {
            path = clean_path,
            xy = xy,
            kind = spec.kind,
            prio = spec.prio,
            desc = spec.desc,
            is_deleted = spec.is_deleted,
        }
        if x == "R" or x == "C" then
            pending_entry = entry
            mode = "OLD_PATH"
        else
            on_entry(entry)
        end
    end

    local stream = {}

    function stream.push(chunk)
        if not chunk or chunk == "" then
            return
        end
        local buffer = leftover .. chunk
        local pos = 1
        while true do
            local nul_idx = buffer:find("\0", pos, true)
            if not nul_idx then
                leftover = buffer:sub(pos)
                break
            end
            local token = buffer:sub(pos, nul_idx - 1)
            pos = nul_idx + 1
            process_token(token)
        end
    end

    function stream.finish()
        if leftover ~= "" then
            process_token(leftover)
            leftover = ""
        end
        if pending_entry then
            on_entry(pending_entry)
            pending_entry = nil
        end
        mode = "RECORD"
    end

    return stream
end

M.resolve_spec = resolve_spec

return M

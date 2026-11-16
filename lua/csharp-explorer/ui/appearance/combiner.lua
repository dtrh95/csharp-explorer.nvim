local M = {}

local epoch = 0
local cache = {}

function M.combine(groups)
    if type(groups) == "string" then
        groups = { groups }
    end
    if not groups or #groups == 0 then
        return "CSharpExplorerNormal"
    end
    if #groups == 1 then
        return groups[1]
    end

    local key = table.concat(groups, "+")
    if cache[key] then
        return cache[key]
    end

    local combined = {}
    local combined_cterm = {}
    for _, g in ipairs(groups) do
        local attrs = vim.api.nvim_get_hl(0, { name = g, link = false })
        if attrs and not vim.tbl_isempty(attrs) then
            for k, v in pairs(attrs) do
                if k == "cterm" and type(v) == "table" then
                    combined_cterm = vim.tbl_extend("force", combined_cterm, v)
                elseif k ~= "default" and k ~= "link" then
                    combined[k] = v
                end
            end
        end
    end

    if not vim.tbl_isempty(combined_cterm) then
        combined.cterm = combined_cterm
    end

    local hash = vim.fn.sha256(key):sub(1, 16)
    local synth_name = "CSharpExplorerCombinedHL" .. hash
    vim.api.nvim_set_hl(0, synth_name, combined)
    cache[key] = synth_name
    return synth_name
end

function M.clear()
    epoch = epoch + 1
    cache = {}
end

function M.get_epoch()
    return epoch
end

return M

local M = {}

local function blank_non_newlines(seg)
    if not seg:find("\n", 1, true) then
        return string.rep(" ", #seg)
    end
    return (seg:gsub("[^\n]", " "))
end

function M.strip_csharp_lexical_noise(src)
    local out = {}
    local i = 1
    local len = #src
    while i <= len do
        local hit = src:find("[/\"'@$]", i)
        if not hit then
            out[#out + 1] = src:sub(i)
            break
        end
        if hit > i then
            out[#out + 1] = src:sub(i, hit - 1)
            i = hit
        end

        local c = src:sub(i, i)
        local c2 = src:sub(i, i + 1)

        if c2 == "//" then
            local nl = src:find("\n", i + 2, true)
            if nl then
                out[#out + 1] = string.rep(" ", nl - i)
                i = nl
            else
                out[#out + 1] = string.rep(" ", len - i + 1)
                break
            end
        elseif c2 == "/*" then
            local end_c = src:find("*/", i + 2, true)
            if end_c then
                out[#out + 1] = blank_non_newlines(src:sub(i, end_c + 1))
                i = end_c + 2
            else
                out[#out + 1] = blank_non_newlines(src:sub(i))
                break
            end
        elseif src:sub(i, i + 2) == '"""' then
            local qcount = 3
            while src:sub(i + qcount, i + qcount) == '"' do
                qcount = qcount + 1
            end
            local closing = string.rep('"', qcount)
            local end_r = src:find(closing, i + qcount, true)
            if end_r then
                local last_q = end_r + qcount - 1
                while src:sub(last_q + 1, last_q + 1) == '"' do
                    last_q = last_q + 1
                end
                out[#out + 1] = blank_non_newlines(src:sub(i, last_q))
                i = last_q + 1
            else
                out[#out + 1] = blank_non_newlines(src:sub(i))
                break
            end
        elseif
            (c == "@" and src:sub(i + 1, i + 1) == '"')
            or (c == "$" and src:sub(i + 1, i + 2) == '@"')
            or (c == "@" and src:sub(i + 1, i + 2) == '$"')
        then
            local q_start = (c == "@" and src:sub(i + 1, i + 1) == '"') and (i + 2) or (i + 3)
            local j = q_start
            while j <= len do
                local q = src:find('"', j, true)
                if not q then
                    j = len + 1
                    break
                end
                if src:byte(q + 1) == 34 then
                    j = q + 2
                else
                    j = q + 1
                    break
                end
            end
            out[#out + 1] = blank_non_newlines(src:sub(i, math.min(j - 1, len)))
            i = j
        elseif c == '"' then
            local j = i + 1
            while j <= len do
                local hit_q = src:find('[\\"\n]', j)
                if not hit_q then
                    j = len + 1
                    break
                end
                local b = src:byte(hit_q)
                if b == 92 then
                    j = hit_q + 2
                elseif b == 34 then
                    j = hit_q + 1
                    break
                else
                    j = hit_q
                    break
                end
            end
            out[#out + 1] = blank_non_newlines(src:sub(i, math.min(j - 1, len)))
            i = j
        elseif c == "'" then
            local j = i + 1
            while j <= len do
                local hit_q = src:find("[\\'\n]", j)
                if not hit_q then
                    j = len + 1
                    break
                end
                local b = src:byte(hit_q)
                if b == 92 then
                    j = hit_q + 2
                elseif b == 39 then
                    j = hit_q + 1
                    break
                else
                    j = hit_q
                    break
                end
            end
            out[#out + 1] = blank_non_newlines(src:sub(i, math.min(j - 1, len)))
            i = j
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

function M.detect_encoding(content)
    local has_bom = content:sub(1, 3) == "\239\187\191"
    local raw = has_bom and content:sub(4) or content
    local has_crlf = raw:find("\r\n", 1, true) ~= nil
    return {
        has_bom = has_bom,
        has_crlf = has_crlf,
        raw = raw,
    }
end

function M.apply_encoding(text, enc)
    local out = text
    if enc.has_crlf then
        out = out:gsub("\r?\n", "\r\n")
    else
        out = out:gsub("\r\n", "\n")
    end
    if enc.has_bom then
        out = "\239\187\191" .. out
    end
    return out
end

local function compute_col_index(line_str, byte_col0, offset_encoding)
    local char_col0 = byte_col0
    if (offset_encoding or "utf-16") ~= "utf-8" and vim.str_utfindex then
        local ok, res = pcall(vim.str_utfindex, line_str, offset_encoding or "utf-16", byte_col0)
        if ok and res then
            char_col0 = res
        else
            local ok2, _, u16 = pcall(vim.str_utfindex, line_str, byte_col0)
            if ok2 and u16 then
                char_col0 = u16
            end
        end
    end
    return char_col0
end

local TYPE_PATTERNS = {
    { kind = "record", pat = "%f[%w_]record%s+class%s+()([%w_%z\128-\255]+)" },
    { kind = "record", pat = "%f[%w_]record%s+struct%s+()([%w_%z\128-\255]+)" },
    { kind = "class", pat = "%f[%w_]class%s+()([%w_%z\128-\255]+)" },
    { kind = "interface", pat = "%f[%w_]interface%s+()([%w_%z\128-\255]+)" },
    { kind = "struct", pat = "%f[%w_]struct%s+()([%w_%z\128-\255]+)" },
    { kind = "record", pat = "%f[%w_]record%s+()([%w_%z\128-\255]+)" },
    { kind = "enum", pat = "%f[%w_]enum%s+()([%w_%z\128-\255]+)" },
    { kind = "delegate", pat = "%f[%w_]delegate%s+[%w_<>%[%]%?%.\128-\255]+%s+()([%w_%z\128-\255]+)%s*[<(]" },
}

function M.locate_primary_type(content, stem, offset_encoding)
    if not content or content == "" then
        return nil
    end
    local enc = M.detect_encoding(content)
    local norm = enc.raw:gsub("\r\n", "\n")
    local cleaned = M.strip_csharp_lexical_noise(norm)
    local target_stem = stem and stem:gsub("%.cs$", "") or nil

    local best = nil
    for _, entry in ipairs(TYPE_PATTERNS) do
        local start_pos = 1
        while true do
            local s, e, name_pos, name = cleaned:find(entry.pat, start_pos)
            if not s then
                break
            end
            if not (entry.kind == "record" and (name == "class" or name == "struct")) then
                if target_stem == nil or name == target_stem then
                    if not best or name_pos < best.name_pos then
                        best = { kind = entry.kind, name = name, name_pos = name_pos }
                    end
                    break
                end
            end
            start_pos = e + 1
        end
    end

    if not best then
        return nil
    end

    local line = 1
    local line_start = 1
    for nl in norm:sub(1, best.name_pos - 1):gmatch("()\n") do
        line = line + 1
        line_start = nl + 1
    end
    local byte_col0 = best.name_pos - line_start
    local line_end = norm:find("\n", line_start, true) or (#norm + 1)
    local line_str = norm:sub(line_start, line_end - 1)
    local char_col0 = compute_col_index(line_str, byte_col0, offset_encoding)

    return {
        name = best.name,
        kind = best.kind,
        line = line,
        col = byte_col0 + 1,
        lsp_pos = { line = line - 1, character = char_col0 },
    }
end

function M.extract_declared_types(content, offset_encoding)
    if not content or content == "" then
        return {}
    end
    local enc = M.detect_encoding(content)
    local norm = enc.raw:gsub("\r\n", "\n")
    local cleaned = M.strip_csharp_lexical_noise(norm)

    local matched = {}
    local seen_positions = {}
    for _, entry in ipairs(TYPE_PATTERNS) do
        local start_pos = 1
        while true do
            local s, e, name_pos, name = cleaned:find(entry.pat, start_pos)
            if not s then
                break
            end
            if not (entry.kind == "record" and (name == "class" or name == "struct")) then
                if not seen_positions[name_pos] then
                    seen_positions[name_pos] = true
                    matched[#matched + 1] = {
                        kind = entry.kind,
                        name = name,
                        name_pos = name_pos,
                    }
                end
            end
            start_pos = e + 1
        end
    end

    table.sort(matched, function(a, b)
        return a.name_pos < b.name_pos
    end)

    local results = {}
    for _, item in ipairs(matched) do
        local line = 1
        local line_start = 1
        for nl in norm:sub(1, item.name_pos - 1):gmatch("()\n") do
            line = line + 1
            line_start = nl + 1
        end
        local byte_col0 = item.name_pos - line_start
        local line_end = norm:find("\n", line_start, true) or (#norm + 1)
        local line_str = norm:sub(line_start, line_end - 1)
        local char_col0 = compute_col_index(line_str, byte_col0, offset_encoding)

        results[#results + 1] = {
            name = item.name,
            kind = item.kind,
            line = line,
            col = byte_col0 + 1,
            lsp_pos = { line = line - 1, character = char_col0 },
        }
    end

    return results
end

function M.extract_namespace(content)
    local enc = M.detect_encoding(content)
    local text = enc.raw:gsub("\r\n", "\n")
    local cleaned = M.strip_csharp_lexical_noise(text)

    local id_s, ns_file, id_e = cleaned:match("%f[%w_]namespace%s+()([%w_%.]+)()%s*;")
    if ns_file then
        return ns_file, "file-scoped", id_s, id_e - 1
    end
    local bid_s, ns_block, bid_e = cleaned:match("%f[%w_]namespace%s+()([%w_%.]+)()%s*[\n{]")
    if ns_block then
        return ns_block, "block-scoped", bid_s, bid_e - 1
    end
    return nil, nil, nil, nil
end

function M.rewrite_namespace(content, new_ns, old_expected_ns)
    local enc = M.detect_encoding(content)
    local text = enc.raw:gsub("\r\n", "\n")
    local declared_ns, style, id_s, id_e = M.extract_namespace(content)
    if not declared_ns or not id_s or not id_e then
        return content, false, "no_namespace"
    end
    if declared_ns == new_ns then
        return content, false, "unchanged"
    end

    local target_ns = new_ns
    if old_expected_ns and declared_ns ~= old_expected_ns then
        if vim.startswith(declared_ns, old_expected_ns .. ".") then
            target_ns = new_ns .. declared_ns:sub(#old_expected_ns + 1)
        else
            return content, false, "divergent"
        end
    end

    local rewritten = text:sub(1, id_s - 1) .. target_ns .. text:sub(id_e + 1)
    return M.apply_encoding(rewritten, enc), true, style
end

function M.rename_type_identifier(content, old_name, new_name)
    if not content or content == "" or not old_name or old_name == "" or old_name == new_name then
        return content, 0
    end
    local enc = M.detect_encoding(content)
    local text = enc.raw:gsub("\r\n", "\n")
    local cleaned = M.strip_csharp_lexical_noise(text)

    local esc_old = old_name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    local pat = "%f[%w_]" .. esc_old .. "%f[^%w_]"

    local matches = {}
    local init = 1
    while true do
        local s, e = cleaned:find(pat, init)
        if not s then
            break
        end
        matches[#matches + 1] = { s = s, e = e }
        init = e + 1
    end

    if #matches == 0 then
        return content, 0
    end

    local cur = text
    for i = #matches, 1, -1 do
        local m = matches[i]
        cur = cur:sub(1, m.s - 1) .. new_name .. cur:sub(m.e + 1)
    end

    return M.apply_encoding(cur, enc), #matches
end

function M.references_any_type(content, type_names)
    if not content or content == "" or not type_names or #type_names == 0 then
        return false
    end
    local matched_candidates = nil
    for _, name in ipairs(type_names) do
        if name and name ~= "" and content:find(name, 1, true) then
            if not matched_candidates then
                matched_candidates = {}
            end
            matched_candidates[#matched_candidates + 1] = name
        end
    end
    if not matched_candidates then
        return false
    end

    local enc = M.detect_encoding(content)
    local text = enc.raw:gsub("\r\n", "\n")
    local cleaned = M.strip_csharp_lexical_noise(text)

    for _, name in ipairs(matched_candidates) do
        local esc = name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        if cleaned:find("%f[%w_]" .. esc .. "%f[^%w_]") then
            return true
        end
    end
    return false
end

function M.inject_using(content, namespace_to_use)
    if not content or content == "" or not namespace_to_use or namespace_to_use == "" then
        return content, false
    end
    local enc = M.detect_encoding(content)
    local text = enc.raw:gsub("\r\n", "\n")
    local cleaned = M.strip_csharp_lexical_noise(text)

    local esc_ns = namespace_to_use:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    if cleaned:match("%f[%w_]using%s+" .. esc_ns .. "%s*;") then
        return content, false
    end
    if cleaned:match("%f[%w_]global%s+using%s+" .. esc_ns .. "%s*;") then
        return content, false
    end

    local target_line = "using " .. namespace_to_use .. ";"
    local ns_pos = cleaned:find("%f[%w_]namespace%s+")
    local search_limit = ns_pos and (ns_pos - 1) or #cleaned
    local header = cleaned:sub(1, search_limit)

    local last_using_end = nil
    local init = 1
    while true do
        local s, e = header:find("%f[%w_]using%s+[^;\n]+;", init)
        if not s then
            break
        end
        last_using_end = e
        init = e + 1
    end

    local rewritten
    if last_using_end then
        local nl_after = text:find("\n", last_using_end, true)
        if nl_after then
            rewritten = text:sub(1, nl_after) .. target_line .. "\n" .. text:sub(nl_after + 1)
        else
            rewritten = text .. "\n" .. target_line
        end
    elseif ns_pos then
        local line_start = ns_pos
        while line_start > 1 and text:sub(line_start - 1, line_start - 1) ~= "\n" do
            line_start = line_start - 1
        end
        rewritten = text:sub(1, line_start - 1) .. target_line .. "\n\n" .. text:sub(line_start)
    else
        rewritten = target_line .. "\n\n" .. text
    end

    return M.apply_encoding(rewritten, enc), true
end

function M.canonical_slash_path(path)
    local norm = path:gsub("\\", "/")
    local leading = norm:sub(1, 1) == "/" and "/" or ""
    local segs = {}
    for s in norm:gmatch("[^/]+") do
        if s == ".." then
            if #segs > 0 and segs[#segs] ~= ".." then
                segs[#segs] = nil
            else
                segs[#segs + 1] = ".."
            end
        elseif s ~= "." and s ~= "" then
            segs[#segs + 1] = s
        end
    end
    return leading .. table.concat(segs, "/")
end

function M.compute_relative_path(from_dir, to_path)
    local from_norm = M.canonical_slash_path(from_dir)
    local to_norm = M.canonical_slash_path(to_path)
    local from_segs = {}
    for s in from_norm:gmatch("[^/]+") do
        from_segs[#from_segs + 1] = s
    end
    local to_segs = {}
    for s in to_norm:gmatch("[^/]+") do
        to_segs[#to_segs + 1] = s
    end

    local common = 0
    while common < #from_segs and common < #to_segs and from_segs[common + 1] == to_segs[common + 1] do
        common = common + 1
    end

    local rel_segs = {}
    for _ = common + 1, #from_segs do
        rel_segs[#rel_segs + 1] = ".."
    end
    for i = common + 1, #to_segs do
        rel_segs[#rel_segs + 1] = to_segs[i]
    end
    return #rel_segs > 0 and table.concat(rel_segs, "/") or "."
end

function M.rewrite_project_references(xml_content, referencing_csproj_path, old_target_path, new_target_path)
    local ref_dir = vim.fn.fnamemodify(M.canonical_slash_path(referencing_csproj_path), ":h")
    local norm_old_target = M.canonical_slash_path(old_target_path):lower()

    if new_target_path == nil then
        local function maybe_strip(inc)
            local inc_forward = inc:gsub("\\", "/")
            local resolved = inc_forward:sub(1, 1) == "/" and inc_forward or (ref_dir .. "/" .. inc_forward)
            if M.canonical_slash_path(resolved):lower() == norm_old_target then
                return ""
            end
            return nil
        end
        local removed =
            xml_content:gsub('[ \t]*<ProjectReference%s+[^>]*Include="([^"]+)"[^>]*/>[ \t]*\r?\n?', maybe_strip)
        removed = removed:gsub(
            '[ \t]*<ProjectReference%s+[^>]*Include="([^"]+)"[^>]*>.-</ProjectReference>[ \t]*\r?\n?',
            maybe_strip
        )
        return removed, removed ~= xml_content
    end

    local rewritten = xml_content:gsub(
        '(<ProjectReference%s+[^>]*Include=")([^"]+)("[^>]*>)',
        function(prefix, inc, suffix)
            local inc_forward = inc:gsub("\\", "/")
            local resolved = inc_forward:sub(1, 1) == "/" and inc_forward or (ref_dir .. "/" .. inc_forward)
            if M.canonical_slash_path(resolved):lower() == norm_old_target then
                local new_rel = M.compute_relative_path(ref_dir, new_target_path)
                if inc:find("\\", 1, true) or not inc:find("/", 1, true) then
                    new_rel = new_rel:gsub("/", "\\")
                end
                return prefix .. new_rel .. suffix
            end
            return prefix .. inc .. suffix
        end
    )

    return rewritten, rewritten ~= xml_content
end

function M.rebase_outgoing_project_references(moved_xml_content, old_csproj_dir, new_csproj_dir)
    if M.canonical_slash_path(old_csproj_dir) == M.canonical_slash_path(new_csproj_dir) then
        return moved_xml_content, false
    end
    local rewritten = moved_xml_content:gsub(
        '(<ProjectReference%s+[^>]*Include=")([^"]+)("[^>]*>)',
        function(prefix, inc, suffix)
            local inc_forward = inc:gsub("\\", "/")
            if inc_forward:sub(1, 1) == "/" or inc_forward:match("^%a:") then
                return prefix .. inc .. suffix
            end
            local abs_target = M.canonical_slash_path(old_csproj_dir .. "/" .. inc_forward)
            local new_rel = M.compute_relative_path(new_csproj_dir, abs_target)
            if inc:find("\\", 1, true) or not inc:find("/", 1, true) then
                new_rel = new_rel:gsub("/", "\\")
            end
            return prefix .. new_rel .. suffix
        end
    )
    return rewritten, rewritten ~= moved_xml_content
end

function M.rewrite_slnx_content(slnx_text, old_proj_path, new_proj_path, solution_dir)
    local norm_old = M.canonical_slash_path(old_proj_path):lower()
    if new_proj_path == nil then
        local removed = slnx_text:gsub('[ \t]*<Project%s+[^>]*Path="([^"]+)"[^>]*/>[ \t]*\r?\n?', function(p)
            local resolved = M.canonical_slash_path(solution_dir .. "/" .. p:gsub("\\", "/"))
            if resolved:lower() == norm_old then
                return ""
            end
            return nil
        end)
        return removed, removed ~= slnx_text
    end

    local new_rel = M.compute_relative_path(solution_dir, new_proj_path)
    local rewritten = slnx_text:gsub('(<Project%s+[^>]*Path=")([^"]+)(")', function(p1, p, p2)
        local resolved = M.canonical_slash_path(solution_dir .. "/" .. p:gsub("\\", "/"))
        if resolved:lower() == norm_old then
            local formatted = p:find("\\", 1, true) and new_rel:gsub("/", "\\") or new_rel
            return p1 .. formatted .. p2
        end
        return p1 .. p .. p2
    end)
    return rewritten, rewritten ~= slnx_text
end

function M.rewrite_sln_content(sln_text, old_proj_path, new_proj_path, new_name, solution_dir)
    local norm_old = M.canonical_slash_path(old_proj_path):lower()
    if new_proj_path == nil then
        local removed_guids = {}
        local stripped = sln_text:gsub(
            'Project%("[^"]+"%)%s*=%s*"[^"]+"%s*,%s*"([^"]+)"%s*,%s*"({[^}]+})".-\r?\nEndProject\r?\n?',
            function(rel_p, guid)
                local resolved = M.canonical_slash_path(solution_dir .. "/" .. rel_p:gsub("\\", "/"))
                if resolved:lower() == norm_old then
                    removed_guids[guid:lower()] = true
                    return ""
                end
                return nil
            end
        )
        if next(removed_guids) then
            local kept_lines = {}
            for line in (stripped .. "\n"):gmatch("(.-)\n") do
                local drop = false
                for g, _ in pairs(removed_guids) do
                    if line:lower():find(g, 1, true) then
                        drop = true
                        break
                    end
                end
                if not drop then
                    kept_lines[#kept_lines + 1] = line
                end
            end
            stripped = table.concat(kept_lines, "\n")
            if not sln_text:match("\n$") then
                stripped = stripped:gsub("\n$", "")
            end
        end
        return stripped, stripped ~= sln_text
    end

    local new_rel = M.compute_relative_path(solution_dir, new_proj_path):gsub("/", "\\")
    local rewritten = sln_text:gsub(
        '(Project%("[^"]+"%)%s*=%s*")([^"]+)("%s*,%s*")([^"]+)(")',
        function(p1, cur_name, p2, cur_rel, p3)
            local resolved = M.canonical_slash_path(solution_dir .. "/" .. cur_rel:gsub("\\", "/"))
            if resolved:lower() == norm_old then
                return p1 .. (new_name or cur_name) .. p2 .. new_rel .. p3
            end
            return p1 .. cur_name .. p2 .. cur_rel .. p3
        end
    )
    return rewritten, rewritten ~= sln_text
end

local SCAN_KEYWORDS = {
    ["if"] = true,
    ["for"] = true,
    ["foreach"] = true,
    ["while"] = true,
    ["switch"] = true,
    ["catch"] = true,
    ["using"] = true,
    ["lock"] = true,
    ["return"] = true,
    ["new"] = true,
    ["throw"] = true,
    ["get"] = true,
    ["set"] = true,
    ["init"] = true,
    ["nameof"] = true,
    ["typeof"] = true,
    ["sizeof"] = true,
    ["await"] = true,
    ["base"] = true,
    ["this"] = true,
    ["when"] = true,
    ["where"] = true,
}

function M.scan_csharp_symbols(content, file_path)
    local enc = M.detect_encoding(content)
    local norm = enc.raw:gsub("\r\n", "\n")
    local cleaned = M.strip_csharp_lexical_noise(norm)

    local symbols = {}
    local current_ns = nil
    local current_container = nil
    local container_depth = 0
    local brace_depth = 0

    local len = #cleaned
    local pos = 1
    local idx = 0

    while pos <= len + 1 do
        local nl = cleaned:find("\n", pos, true)
        local line
        if nl then
            line = cleaned:sub(pos, nl - 1)
            pos = nl + 1
        else
            line = cleaned:sub(pos)
            pos = len + 2
        end
        idx = idx + 1

        if line ~= "" and line:find("%S") then
            if line:find("namespace", 1, true) then
                local ns_decl = line:match("^%s*namespace%s+([%w_%.]+)")
                if ns_decl then
                    current_ns = ns_decl
                end
            end

            local has_record = line:find("record", 1, true) ~= nil
            local type_kind, type_name
            if has_record then
                local rc = line:match("%f[%w_]record%s+class%s+([%w_]+)")
                if rc then
                    type_kind, type_name = "record", rc
                else
                    local rs = line:match("%f[%w_]record%s+struct%s+([%w_]+)")
                    if rs then
                        type_kind, type_name = "record", rs
                    end
                end
            end
            if not type_name and line:find("class", 1, true) then
                type_kind, type_name = line:match("%f[%w_](class)%s+([%w_]+)")
            end
            if not type_name and line:find("interface", 1, true) then
                type_kind, type_name = line:match("%f[%w_](interface)%s+([%w_]+)")
            end
            if not type_name and line:find("struct", 1, true) then
                type_kind, type_name = line:match("%f[%w_](struct)%s+([%w_]+)")
            end
            if not type_name and has_record then
                local rname = line:match("%f[%w_]record%s+([%w_]+)")
                if rname and rname ~= "class" and rname ~= "struct" then
                    type_kind, type_name = "record", rname
                end
            end
            if not type_name and line:find("enum", 1, true) then
                type_kind, type_name = line:match("%f[%w_](enum)%s+([%w_]+)")
            end

            if type_name and not SCAN_KEYWORDS[type_name] then
                local col = line:find(type_name, 1, true) or 1
                local fqn = (current_ns and (current_ns .. ".") or "") .. type_name
                symbols[#symbols + 1] = {
                    name = type_name,
                    kind = type_kind,
                    file = file_path,
                    line = idx,
                    col = col,
                    container = current_container or current_ns,
                    fqn = fqn,
                }
                current_container = type_name
                container_depth = brace_depth + 1
            elseif current_container and brace_depth == container_depth then
                local handled_method = false
                if line:find("(", 1, true) and line:find(")", 1, true) then
                    local without_brackets = line:find("[", 1, true) and line:gsub("%b[]", " ") or line
                    local before_paren = without_brackets:match("^(.-)%s*%((.-)%)(.*)$")
                    if
                        before_paren
                        and not line:find("=", 1, true)
                        and not (line:find("new", 1, true) and line:find("%f[%w_]new%s+"))
                        and not (line:find("delegate", 1, true) and line:find("%f[%w_]delegate%s+"))
                    then
                        handled_method = true
                        local words = {}
                        for w in before_paren:gmatch("[%w_]+") do
                            words[#words + 1] = w
                        end
                        local mname = words[#words]
                        if mname and not SCAN_KEYWORDS[mname] and mname ~= current_container and #words >= 2 then
                            local col = line:find(mname, 1, true) or 1
                            local fqn = (current_ns and (current_ns .. ".") or "") .. current_container .. "." .. mname
                            symbols[#symbols + 1] = {
                                name = mname,
                                kind = "method",
                                file = file_path,
                                line = idx,
                                col = col,
                                container = current_container,
                                fqn = fqn,
                            }
                        end
                    end
                end
                if not handled_method and line:find("{", 1, true) and line:find("get", 1, true) then
                    local _, prop_name = line:match("%s+([%w_<>%[%]%?%.]+)%s+([%w_]+)%s*{%s*get[;%s]")
                    if prop_name and not SCAN_KEYWORDS[prop_name] then
                        local col = line:find(prop_name, 1, true) or 1
                        local fqn = (current_ns and (current_ns .. ".") or "") .. current_container .. "." .. prop_name
                        symbols[#symbols + 1] = {
                            name = prop_name,
                            kind = "property",
                            file = file_path,
                            line = idx,
                            col = col,
                            container = current_container,
                            fqn = fqn,
                        }
                    end
                end
            end

            if line:find("{", 1, true) or line:find("}", 1, true) then
                for ch in line:gmatch("[{}]") do
                    if ch == "{" then
                        brace_depth = brace_depth + 1
                    elseif ch == "}" then
                        if brace_depth == container_depth then
                            current_container = nil
                            container_depth = 0
                        end
                        if brace_depth > 0 then
                            brace_depth = brace_depth - 1
                        end
                    end
                end
            end
        end
    end

    return symbols
end

return M

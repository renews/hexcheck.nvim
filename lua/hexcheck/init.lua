local fn = vim.fn
local notify = vim.notify
local notify_once = vim.notify_once

-- Scan the mix.exs file for dependency tuples and record their line numbers.
local function parse_mix_exs(filepath)
	local deps = {}
	local file = io.open(filepath, "r")
	if not file then
		notify("mix.exs not found: " .. filepath, vim.log.levels.WARN)
		return deps
	end

	local line_no = 0
	for line in file:lines() do
		line_no = line_no + 1
		local name, version = line:match('{:%s*([%w_]+)%s*,%s*"([^"]+)"')
		if name and version then
			table.insert(deps, { name = name, version = version, line = line_no - 1 })
		end
	end

	file:close()
	return deps
end

local function fetch_latest_version(dep, callback)
	local package = dep.name
	local url = "https://hex.pm/api/packages/" .. package
	local output = {}

	-- Run curl in the background so we do not block the editor.
	local job_id = fn.jobstart({
		"curl",
		"-fsSL",
		"--connect-timeout",
		"5",
		"--max-time",
		"10",
		url,
	}, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if not data then
				return
			end
			for _, chunk in ipairs(data) do
				if chunk ~= "" then
					table.insert(output, chunk)
				end
			end
		end,
	on_exit = function(_, code)
		-- Marshal the callback back onto the main thread before touching Neovim APIs.
		vim.schedule(function()
			if code ~= 0 then
				notify_once(string.format("Failed to fetch %s from hex.pm", package), vim.log.levels.WARN)
				callback(nil)
					return
				end

				local result = table.concat(output, "\n")
				if result == "" then
					notify_once("No result returned for " .. package, vim.log.levels.WARN)
					callback(nil)
					return
				end

				local ok, data = pcall(vim.json.decode, result)
				if not ok or not data or not data.releases then
					notify_once("Invalid JSON response for " .. package, vim.log.levels.ERROR)
					callback(nil)
					return
				end

				if #data.releases == 0 then
					callback(nil)
					return
				end

				table.sort(data.releases, function(a, b)
					return a.version > b.version
				end)

				callback(data.releases[1].version)
			end)
		end,
	})

	if job_id <= 0 then
		notify_once("Failed to start curl job for " .. package, vim.log.levels.ERROR)
		callback(nil)
	end
end

local function is_newer(a, b)
	local function split(v)
		local parts = {}
		for part in v:gmatch("%d+") do
			table.insert(parts, tonumber(part))
		end
		return parts
	end

	local va, vb = split(a), split(b)
	for i = 1, math.max(#va, #vb) do
		local x, y = va[i] or 0, vb[i] or 0
		if x < y then
			return true
		end
		if x > y then
			return false
		end
	end
	return false
end

local ns = vim.api.nvim_create_namespace("hexcheck_updates")
local highlight_group = "HexCheckVirtualText"
local hl_initialized = false

local function ensure_highlight()
	if hl_initialized then
		return
	end

	local defined = false
	if vim.api.nvim_get_hl then
		local ok, existing = pcall(vim.api.nvim_get_hl, 0, { name = highlight_group, link = false })
		defined = ok and existing and next(existing) ~= nil
	else
		local ok, existing = pcall(vim.api.nvim_get_hl_by_name, highlight_group, true)
		defined = ok and existing and existing.foreground ~= nil
	end

	if not defined then
		vim.api.nvim_set_hl(0, highlight_group, { fg = "#8ec07c", italic = true })
	end

	hl_initialized = true
end

local function show_virtual_text(buf, line, text)
	ensure_highlight() -- define the highlight group the first time we need it
	vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
		virt_text = { { text, highlight_group } },
		virt_text_pos = "eol",
	})
end

local function resolve_mix_path(buf)
	local bufname = vim.api.nvim_buf_get_name(buf)
	if bufname ~= "" and bufname:sub(-7) == "mix.exs" and fn.filereadable(bufname) == 1 then
		return bufname
	end

	local cwd = fn.getcwd()
	if cwd and cwd ~= "" then
		local candidate = cwd .. "/mix.exs"
		if fn.filereadable(candidate) == 1 then
			return candidate
		end
	end

	return nil
end

local M = {}

function M.check_updates()
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

	local mix_path = resolve_mix_path(buf)
	if not mix_path then
		notify("Could not locate mix.exs for this buffer", vim.log.levels.WARN)
		return
	end

	local deps = parse_mix_exs(mix_path)
	if #deps == 0 then
		notify("No dependencies found in " .. mix_path, vim.log.levels.INFO)
		return
	end

	for _, dep in ipairs(deps) do
		fetch_latest_version(dep, function(latest)
			if not latest then
				return
			end

			if is_newer(dep.version, latest) then
				-- Only draw annotations if the buffer is still around.
				if vim.api.nvim_buf_is_valid(buf) then
					show_virtual_text(buf, dep.line, "new version available " .. latest)
				end
			end
		end)
	end
end

return M

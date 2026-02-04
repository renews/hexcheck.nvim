local fn = vim.fn
local notify = vim.notify
local notify_once = vim.notify_once

local defaults = {
	highlight_color = "#123716",
	italic = true,
	bold = false,
	message_prefix = "new version available ",
	goto_hexdocs_key = "gd",
}

local function copy(tbl)
	local result = {}
	for key, value in pairs(tbl) do
		result[key] = value
	end
	return result
end

local config = copy(defaults)

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
			table.insert(deps, { name = name, requirement = version, line = line_no - 1 })
		end
	end

	file:close()
	return deps
end

local function parse_mix_lock(filepath, requested)
	local versions = {}
	local file = io.open(filepath, "r")
	if not file then
		return versions
	end

	local content = file:read("*a")
	file:close()

	if not content then
		return versions
	end

	for name, _, version in
		content:gmatch('["\']([^"\']+)["\']%s*([:=])%>?%s*{:%s*hex%s*,%s*:%s*[%w_]+%s*,%s*"([^"]+)"')
	do
		if not requested or requested[name] then
			versions[name] = version
		end
	end

	return versions
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

local augroup = vim.api.nvim_create_augroup("HexCheck", { clear = true })
local ns = vim.api.nvim_create_namespace("hexcheck_updates")
local highlight_group = "HexCheckVirtualText"
local hl_initialized = false

local function apply_highlight()
	local opts = {}
	if config.highlight_color then
		opts.fg = config.highlight_color
	end
	if config.italic ~= nil then
		opts.italic = config.italic
	end
	if config.bold ~= nil then
		opts.bold = config.bold
	end

	if next(opts) == nil then
		return
	end

	vim.api.nvim_set_hl(0, highlight_group, opts)
end

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

	if config.highlight_color or config.italic ~= nil or config.bold ~= nil or not defined then
		apply_highlight()
	end

	hl_initialized = true
end

local function show_virtual_text(buf, line, version)
	ensure_highlight() -- define the highlight group the first time we need it
	local prefix = config.message_prefix or ""
	vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
		virt_text = { { prefix .. version, highlight_group } },
		virt_text_pos = "eol",
	})
end

local function resolve_mix_path(buf)
	local bufname = vim.api.nvim_buf_get_name(buf)
	if bufname ~= "" then
		if bufname:sub(-7) == "mix.exs" and fn.filereadable(bufname) == 1 then
			return bufname
		end

		local start_dir = fn.fnamemodify(bufname, ":h")
		local found = fn.findfile("mix.exs", start_dir .. ";")
		if found and found ~= "" then
			return found
		end
	end

	local cwd = fn.getcwd()
	if cwd and cwd ~= "" then
		local found = fn.findfile("mix.exs", cwd .. ";")
		if found and found ~= "" then
			return found
		end
	end

	return nil
end

local function resolve_lock_path(mix_path)
	if not mix_path or mix_path == "" then
		return nil
	end

	local dir = mix_path:match("(.+)/[^/]+$")
	if not dir or dir == "" then
		dir = "."
	end

	local lock_path = dir .. "/mix.lock"
	if fn.filereadable(lock_path) == 1 then
		return lock_path
	end

	return nil
end

local function open_hexdocs()
	local line = vim.api.nvim_get_current_line()
	-- Look for :package_name or "package_name" or 'package_name'
	-- Specifically targeting the dependency tuple format { :package, "version" }
	local package = line:match('{:%s*([%w_]+)') or line:match('["\']([^"\']+)["\']%s*[:=]%>?')

	if not package then
		-- Fallback to word under cursor if pattern match fails
		package = fn.expand("<cword>")
	end

	-- Clean up potential leading colon if it came from <cword> or general match
	package = package:gsub("^:", "")

	if package and package ~= "" then
		package = package:lower()
		local url = "https://hexdocs.pm/" .. package
		notify("Opening HexDocs for " .. package .. "...", vim.log.levels.INFO)
		if vim.ui and vim.ui.open then
			vim.ui.open(url)
		else
			-- Fallback for older Neovim versions
			local opener
			if fn.has("mac") == 1 then
				opener = "open"
			elseif fn.has("win32") == 1 then
				opener = "start"
			else
				opener = "xdg-open"
			end
			fn.jobstart({ opener, url }, { detach = true })
		end
	else
		notify("Could not identify package name under cursor", vim.log.levels.WARN)
	end
end

local M = {}

function M.setup(opts)
	opts = opts or {}

	if opts.highlight_color ~= nil then
		if opts.highlight_color == false then
			config.highlight_color = nil
		elseif type(opts.highlight_color) == "string" then
			config.highlight_color = opts.highlight_color
		else
			notify("hexcheck: highlight_color must be a string", vim.log.levels.WARN)
		end
	end

	if opts.italic ~= nil then
		if type(opts.italic) == "boolean" then
			config.italic = opts.italic
		else
			notify("hexcheck: italic must be true or false", vim.log.levels.WARN)
		end
	end

	if opts.bold ~= nil then
		if type(opts.bold) == "boolean" then
			config.bold = opts.bold
		else
			notify("hexcheck: bold must be true or false", vim.log.levels.WARN)
		end
	end

	if opts.message_prefix ~= nil then
		if type(opts.message_prefix) == "string" then
			config.message_prefix = opts.message_prefix
		else
			notify("hexcheck: message_prefix must be a string", vim.log.levels.WARN)
		end
	end

	if opts.goto_hexdocs_key ~= nil then
		if type(opts.goto_hexdocs_key) == "string" or opts.goto_hexdocs_key == false then
			config.goto_hexdocs_key = opts.goto_hexdocs_key
		else
			notify("hexcheck: goto_hexdocs_key must be a string or false", vim.log.levels.WARN)
		end
	end

	local function apply_mappings(buf)
		if not config.goto_hexdocs_key then
			return
		end

		local bufname = vim.api.nvim_buf_get_name(buf)
		local is_mix = bufname:match("mix%.exs$")

		-- force gd to open the docs ignore lsp config in the mix.exs		
		if is_mix then
			vim.keymap.set("n", config.goto_hexdocs_key, open_hexdocs, {
				buffer = buf,
				silent = true,
				desc = "Open HexDocs for package under cursor",
			})
		end
	end

	vim.api.nvim_clear_autocmds({ group = augroup })

	if config.goto_hexdocs_key ~= false then
		vim.api.nvim_create_autocmd("FileType", {
			group = augroup,
			pattern = { "elixir" },
			callback = function(args)
				apply_mappings(args.buf)
			end,
		})

		vim.api.nvim_create_autocmd("LspAttach", {
			group = augroup,
			callback = function(args)
				local buf = args.buf
				if vim.bo[buf].filetype == "elixir" then
					-- add the necessary delay for our key to take precedence over the lsp
					vim.defer_fn(function()
						if vim.api.nvim_buf_is_valid(buf) then
							apply_mappings(buf)
						end
					end, 100)
				end
			end,
		})
		
		local current_buf = vim.api.nvim_get_current_buf()
		if vim.bo[current_buf].filetype == "elixir" then
			apply_mappings(current_buf)
		end
	end

	hl_initialized = false
	ensure_highlight()
end

function M.open_hexdocs()
	open_hexdocs()
end

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

	local requested = {}
	for _, dep in ipairs(deps) do
		requested[dep.name] = true
	end

	local lock_versions = {}
	local lock_path = resolve_lock_path(mix_path)
	if lock_path then
		lock_versions = parse_mix_lock(lock_path, requested)
	else
		notify_once("mix.lock not found; using requirements from mix.exs", vim.log.levels.INFO)
	end

	local outstanding = #deps

	local function mark_done()
		outstanding = outstanding - 1
		if outstanding == 0 then
			notify("HexCheck is done!", vim.log.levels.INFO)
		end
	end

	for _, dep in ipairs(deps) do
		fetch_latest_version(dep, function(latest)
			if not latest then
				mark_done()
				return
			end

			local current_version = lock_versions[dep.name] or dep.requirement
			if not current_version then
				mark_done()
				return
			end

			if is_newer(current_version, latest) then
				-- Only draw annotations if the buffer is still around.
				if vim.api.nvim_buf_is_valid(buf) then
					show_virtual_text(buf, dep.line, latest)
				end
			end

			mark_done()
		end)
	end
end

return M

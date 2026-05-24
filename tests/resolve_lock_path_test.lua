local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s\nexpected: %s\nactual:   %s", message or "assert_eq failed", tostring(expected), tostring(actual)))
	end
end

local function make_vim_stub()
	local bo_mt = {
		__index = function()
			return { filetype = "" }
		end,
	}

	return {
		fn = {
			filereadable = function()
				return 0
			end,
			jobstart = function()
				return 1
			end,
			findfile = function()
				return ""
			end,
			fnamemodify = function(path)
				return path
			end,
			getcwd = function()
				return ""
			end,
			expand = function()
				return ""
			end,
			has = function()
				return 0
			end,
		},
		api = {
			nvim_create_augroup = function()
				return 1
			end,
			nvim_create_namespace = function()
				return 1
			end,
			nvim_set_hl = function()
			end,
			nvim_get_hl = function()
				return {}
			end,
			nvim_get_hl_by_name = function()
				return { foreground = 1 }
			end,
			nvim_get_current_line = function()
				return ""
			end,
			nvim_buf_set_extmark = function()
			end,
			nvim_buf_get_name = function()
				return ""
			end,
			nvim_clear_autocmds = function()
			end,
			nvim_create_autocmd = function()
			end,
			nvim_get_current_buf = function()
				return 1
			end,
			nvim_buf_clear_namespace = function()
			end,
			nvim_buf_is_valid = function()
				return true
			end,
		},
		notify = function()
		end,
		notify_once = function()
		end,
		log = {
			levels = {
				WARN = 1,
				INFO = 2,
				ERROR = 3,
			},
		},
		json = {
			decode = function()
				return {}
			end,
		},
		schedule = function(callback)
			callback()
		end,
		ui = {},
		bo = setmetatable({}, bo_mt),
		defer_fn = function(callback)
			callback()
		end,
	}
end

local function get_upvalue(fn, target)
	local index = 1
	while true do
		local name, value = debug.getupvalue(fn, index)
		if not name then
			return nil
		end
		if name == target then
			return value
		end
		index = index + 1
	end
end

local function load_module()
	_G.vim = make_vim_stub()
	local module = dofile("lua/hexcheck/init.lua")
	local resolve_lock_path = get_upvalue(module.check_updates, "resolve_lock_path")
	if not resolve_lock_path then
		error("failed to locate resolve_lock_path upvalue")
	end
	return module, resolve_lock_path
end

local function test_unix_path_lock_resolution()
	local _, resolve_lock_path = load_module()

	vim.fn.filereadable = function(path)
		if path == "/tmp/demo/mix.lock" then
			return 1
		end
		return 0
	end

	local lock_path = resolve_lock_path("/tmp/demo/mix.exs")
	assert_eq(lock_path, "/tmp/demo/mix.lock", "unix lock path should be resolved")
end

local function test_windows_path_lock_resolution()
	local _, resolve_lock_path = load_module()
	local checked = {}

	vim.fn.filereadable = function(path)
		table.insert(checked, path)
		if path == "C:/Users/rene/project/mix.lock" then
			return 1
		end
		return 0
	end

	local lock_path = resolve_lock_path("C:\\Users\\rene\\project\\mix.exs")
	assert_eq(lock_path, "C:/Users/rene/project/mix.lock", "windows lock path should be resolved")

	if checked[1] ~= "C:/Users/rene/project/mix.lock" then
		error("windows lock path probe should normalize separators")
	end
end

return {
	test_unix_path_lock_resolution,
	test_windows_path_lock_resolution,
}

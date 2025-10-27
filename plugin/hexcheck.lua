vim.api.nvim_create_user_command("HexCheck", function()
	require("hexcheck").check_updates()
end, {})

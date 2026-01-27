vim.api.nvim_create_user_command("HexCheck", function()
	require("hexcheck").check_updates()
end, {})

-- for the key to work we have to force initialize here
require("hexcheck").setup()

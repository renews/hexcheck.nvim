local tests = require("tests.resolve_lock_path_test")
local passed = 0
local failed = 0

for index, test in ipairs(tests) do
	local ok, err = pcall(test)
	if ok then
		passed = passed + 1
		io.write(string.format("ok %d\n", index))
	else
		failed = failed + 1
		io.write(string.format("not ok %d - %s\n", index, err))
	end
end

io.write(string.format("\n%d passed; %d failed\n", passed, failed))
if failed > 0 then
	os.exit(1)
end

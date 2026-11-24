local LrStringUtils = import 'LrStringUtils'

local M = {}

local function base64(value)
	return (LrStringUtils.encodeBase64(value):gsub('%s', ''))
end

-- Lightroom hands this command to cmd.exe. Keep every filename inside the
-- encoded PowerShell script so cmd never expands percent signs or metacharacters.
function M.capture_command(binary, args, log_path)
	local function decoded(value)
		return "(Decode '" .. base64(tostring(value)) .. "')"
	end

	local encoded_args = {}
	for i, arg in ipairs(args) do
		encoded_args[i] = decoded(arg)
	end

	local script = [=[
function Decode([string]$s) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) }
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
]=] .. '\n$exe = ' .. decoded(binary)
		.. '\n$argv = @(' .. table.concat(encoded_args, ',') .. ')'
		.. '\n$log = ' .. decoded(log_path) .. [=[

try {
    $LASTEXITCODE = 1
    $lines = @(& $exe @argv 2>&1 | ForEach-Object { $_.ToString() })
    $status = $LASTEXITCODE
} catch {
    $lines = @($_.Exception.Message)
    $status = 1
}
[IO.File]::WriteAllLines($log, [string[]]$lines, $utf8)
exit $status
]=]
	-- All non-ASCII text is Base64 inside the script. The remaining ASCII
	-- characters need one zero byte each for PowerShell's UTF-16LE argument.
	local utf16 = script:gsub('.', function(character) return character .. '\0' end)
	return 'powershell.exe -NoProfile -NonInteractive -EncodedCommand ' .. base64(utf16)
end

return M

--[[----------------------------------------------------------------------

ExportServiceProvider.lua

The export service itself: takes the file Lightroom rendered for each photo,
runs `tohdr convert` on it, and puts the resulting gain-map HEIC where the
user asked for it.

The 16-bit TIFF intermediate is forced, not offered: JPEG and 8-bit exports
have already clipped the above-SDR highlights a gain map is derived from, so
they would yield a structurally valid file carrying no HDR.

------------------------------------------------------------------------]]

local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local TohdrCli = require 'TohdrCli'
local TohdrExportDialog = require 'TohdrExportDialog'
local TohdrWindows = WIN_ENV and require 'TohdrWindows'
local LrExportSession = WIN_ENV and import 'LrExportSession'
local LrFunctionContext = WIN_ENV and import 'LrFunctionContext'

local export_service_provider = {}

-- `supportsIncrementalPublish` is absent on purpose -- do not reinstate it.
-- Copied as `= 'only'` from Adobe's flickr sample once, which hid the plugin
-- from File > Export entirely. This design is export-shaped: no publish
-- callback exists in this file.
export_service_provider.hideSections = { 'fileNaming', 'fileSettings', 'imageSettings' }
if WIN_ENV then
	export_service_provider.hideSections = { 'fileSettings', 'imageSettings' }
	export_service_provider.canExportToTemporaryLocation = false
end
export_service_provider.allowFileFormats = { 'TIFF' }
export_service_provider.allowColorSpaces = nil
export_service_provider.canExportVideo = false

export_service_provider.exportPresetFields = {
	{ key = 'tohdr_flavor',           default = 'both' },
	{ key = 'tohdr_engine',           default = 'apple' },
	{ key = 'tohdr_maxSizeEnabled',   default = false },
	{ key = 'tohdr_maxSizeValue',     default = 4 },
	{ key = 'tohdr_maxSizeUnit',      default = 'MB' },
	{ key = 'tohdr_quality',          default = 85 },
	{ key = 'tohdr_minQuality',       default = 40 },
	{ key = 'tohdr_toneMap',          default = 'reinhard' },
	{ key = 'tohdr_gainSubsample',    default = 2 },
	{ key = 'tohdr_makerNote',        default = true },
	{ key = 'tohdr_binaryPath',       default = '' },
}

export_service_provider.startDialog = TohdrExportDialog.start_dialog
export_service_provider.sectionsForTopOfDialog = TohdrExportDialog.sections_for_top_of_dialog

--- Force the intermediate to something `tohdr` can read with headroom intact.
---
--- None of these keys are documented -- the SDK guide never mentions HDR. They
--- were read out of LrC's own prefs (`AgExport_*`, delivered here as `LR_*`)
--- after driving the dialog by hand. See lightroom/README.md.
--- Two traps: `LR_export_useHDR` does not exist (an invented key, silently
--- ignored), and TIFF takes its depth from `bitDepthOthers`, not `bitDepth`.
function export_service_provider.updateExportSettings(export_settings)
	export_settings.LR_format = 'TIFF'
	-- Makes LrC write a *pair* into one TIFF: SDR rendition in IFD0, plus a
	-- full-res gain map in a SubIFD with ISO 21496-1 metadata. `tohdr`
	-- transcodes that pair rather than deriving anything.
	export_settings.LR_enableHDRDisplay = true
	-- LrC's own undocumented token (same `<space>_hdr` spelling it writes to
	-- `EditInPs_hdr_colorSpace`). P3 not sRGB: Rec.709 clips 12% of a real
	-- frame. Safe to ask for -- if a future LrC ignores it, `tohdr` reads the
	-- embedded profile and reports the mismatch instead of mislabelling.
	export_settings.LR_export_colorSpace = 'p3_hdr'
	export_settings.LR_export_colorSpaceNonJPEG = 'p3_hdr'
	-- 16, not 32: the float variant carries the same map with the roles
	-- reversed (HDR base, downward map) at 1.5x the bytes.
	export_settings.LR_export_bitDepth = 16
	export_settings.LR_export_bitDepthOthers = 16
	export_settings.LR_tiff_compressionMethod = 'compressionMethod_None'
	if WIN_ENV then
		export_settings.LR_maximumCompatibility = true
		-- Lightroom applies this to the intermediate TIFF, before the plug-in
		-- checks for a collision on the final HEIC.
		export_settings.LR_collisionHandling = 'rename'
		export_settings.LR_reimportExportedPhoto = false
	end
end

--- Locate the binary using the pure-Lua policy in TohdrCli, supplying it the
--- filesystem access it deliberately does not take itself.
---
--- No PATH search: a `.lrplugin` is self-contained, and the sandbox could not
--- read PATH anyway.
local function find_binary(property_table)
	local plugin_dir = _PLUGIN and _PLUGIN.path or nil
	local executable = WIN_ENV and 'tohdr.exe' or 'tohdr'
	local bundled = plugin_dir and LrPathUtils.child(plugin_dir, executable) or nil

	return TohdrCli.locate_binary {
		user_binary_path = property_table.tohdr_binaryPath,
		plugin_binary_path = bundled,
		file_exists = function(p)
			return p ~= nil and p ~= '' and LrFileUtils.exists(p) ~= false
		end,
	}
end

--- Run one command, capturing stdout+stderr into a temp file so a failure can
--- be reported with the CLI's own words instead of just an exit code.
---
--- The log name must be unguessable: unseeded `math.random` repeats across
--- interpreter states, and shell `>` follows symlinks, so a predictable path in
--- shared temp could be pre-placed by anyone. Clock is `LrDate.currentTime()`
--- (seconds since 2001, fractional) because the sandbox is missing parts of
--- `os` -- `os.getenv` crashed an export here.
local log_counter = 0
local function temp_path(directory, extension)
	log_counter = log_counter + 1
	local entropy = tostring({}):gsub('%W', '')
	return LrPathUtils.child(
		directory,
		string.format('.tohdr-%s-%d-%d.%s',
			entropy, log_counter, math.floor(LrDate.currentTime()), extension)
	)
end

--- Formats that plausibly carry a MakerNote. PSD and TIFF masters are scans and
--- composites; asking would earn a "no MakerNote to take" warning per photo.
local function takes_a_maker_note(format)
	return format == 'RAW' or format == 'DNG' or format == 'JPG'
end

--- The original camera file behind a rendition, or nil and the reason why not.
---
--- The reason is why there is a second return value: without it a requested
--- MakerNote that cannot be found is a silent no-op indistinguishable from
--- success. Reasons are worded identically across photos so 200 renditions with
--- one cause collapse to one line with a count.
local function original_path(rendition)
	local photo = rendition.photo
	if not photo then
		return nil, 'Lightroom did not say which photo this rendition came from'
	end
	-- `LrTasks.pcall`, never the built-in: `getRawMetadata` yields, and in Lua
	-- 5.1 a yield cannot cross a C function, so plain `pcall` *causes* the
	-- failure it was meant to contain ("Yielding is not allowed within a C or
	-- metamethod call"). Protected at all because a photo can be removed
	-- mid-export and losing one MakerNote must not fail the conversion.
	local ok, path, format = LrTasks.pcall(function()
		local subject = photo
		if photo:getRawMetadata('isVirtualCopy') then
			subject = photo:getRawMetadata('masterPhoto') or photo
		end
		local fmt = subject:getRawMetadata('fileFormat')
		if not takes_a_maker_note(fmt) then
			return nil, fmt
		end
		return subject:getRawMetadata('path'), fmt
	end)
	if not ok then
		-- `path` holds the error. Verbatim, not summarised -- this is the only
		-- channel that can explain an API contract we got wrong.
		return nil, 'the catalog would not answer (' .. tostring(path) .. ')'
	end
	if not takes_a_maker_note(format) then
		return nil, 'the master is a ' .. tostring(format or 'file of unknown format')
			.. ', which carries no MakerNote'
	end
	if path == nil or path == '' then
		return nil, 'the catalog holds no path for the master file'
	end
	-- `path` is documented as the *last known* path, so it can name a file on an
	-- unmounted volume or one backed only by a smart preview.
	if LrFileUtils.exists(path) == false then
		return nil, 'the original file is no longer where the catalog expects it'
	end
	return path
end

local function run_capturing(binary, args)
	local log_path = temp_path(LrPathUtils.getStandardFilePath('temp'), 'log')
	local command
	if WIN_ENV then
		command = TohdrWindows.capture_command(binary, args, log_path)
	else
		command = TohdrCli.build_command_line(binary, args)
			.. ' >' .. TohdrCli.quote_arg(log_path) .. ' 2>&1'
	end
	local ok, status = LrTasks.pcall(LrTasks.execute, command)

	local output = ''
	if LrFileUtils.exists(log_path) then
		output = LrFileUtils.readFile(log_path) or ''
		LrFileUtils.delete(log_path)
	end
	if not ok then
		return 1, tostring(status)
	end
	return status, output
end

local function heic_path(rendition)
	return LrPathUtils.removeExtension(rendition.destinationPath) .. '.heic'
end

local function convert_on_windows(binary, rendered_path, destination, quality, progress)
	if LrFileUtils.exists(destination) then
		return 'A file already exists at ' .. destination
	end
	local directory = LrPathUtils.parent(destination)
	if LrFileUtils.exists(directory) ~= 'directory' then
		local created, reason = LrFileUtils.createAllDirectories(directory)
		if not created then
			return 'Could not create the HEIC export directory: ' .. tostring(reason)
		end
	end
	local staged = temp_path(directory, 'tmp')
	local args = TohdrCli.build_convert_args({
		tohdr_engine = 'hpvca',
		tohdr_flavor = 'iso',
		tohdr_quality = quality or 85,
		tohdr_gainSubsample = 2,
	}, rendered_path, staged)
	table.insert(args, '--require-lightroom-gain-map')

	local ok, failure, advisories = LrTasks.pcall(function()
		local status, output = run_capturing(binary, args)
		if progress:isCanceled() then
			return
		end
		if status ~= 0 then
			return TohdrCli.summarize_failure(status, output)
		end
		if LrFileUtils.exists(staged) ~= 'file'
			or TohdrCli.gain_map_source(output) ~= 'lightroom-embedded' then
			return 'tohdr did not produce a HEIC from the Lightroom HDR gain map.'
		end
		if progress:isCanceled() then
			return
		end
		local moved, reason = LrFileUtils.move(staged, destination)
		if not moved then
			if LrFileUtils.exists(destination) then
				return 'A file already exists at ' .. destination
			end
			return 'Could not move the HEIC to ' .. destination .. ': ' .. tostring(reason)
		end
		return nil, TohdrCli.advisories(output)
	end)
	if LrFileUtils.exists(staged) == 'file' then
		LrFileUtils.delete(staged)
	end
	if not ok then
		return tostring(failure)
	end
	return failure, advisories
end

local function render_in_scratch(context, property_table, photo)
	local scratch = temp_path(LrPathUtils.getStandardFilePath('temp'), 'render')
	local created, reason = LrFileUtils.createAllDirectories(scratch)
	if not created then
		return nil, 'Could not create the temporary render directory: ' .. tostring(reason)
	end
	context:addCleanupHandler(function() LrFileUtils.delete(scratch) end)

	local settings = {}
	-- Lightroom stores export choices in an observable table. Its iterator
	-- exposes metadata settings, including the option to remove GPS.
	local iterate = property_table.pairs or pairs
	for key, value in iterate(property_table) do
		if type(key) == 'string' and key:sub(1, 3) == 'LR_' then
			settings[key] = value
		end
	end
	export_service_provider.updateExportSettings(settings)
	settings.LR_export_destinationType = 'specificFolder'
	settings.LR_export_destinationPathPrefix = scratch
	settings.LR_export_useSubfolder = false
	settings.LR_renamingTokensOn = false
	local session = LrExportSession { photosToExport = { photo }, exportSettings = settings }
	session:doExportOnCurrentTask()
	for _, rendition in session:renditions() do
		local ok, path_or_error = rendition:waitForRender()
		if ok then return path_or_error end
		return nil, path_or_error
	end
	return nil, 'Lightroom did not render this photo.'
end

local function process_windows(export_context, progress, binary, locate_err)
	local advisories = {}
	local failures = {}
	local jobs = {}
	-- Let the main session resolve Lightroom's names and destination, but render
	-- one photo at a time elsewhere. A canceled native renderer can leave TIFFs
	-- on disk even for renditions it reported as canceled.
	for _, rendition in export_context.exportSession:renditions() do
		if not rendition.wasSkipped then
			jobs[#jobs + 1] = { rendition = rendition, destination = heic_path(rendition) }
			rendition:skipRender()
		end
	end
	progress:setCancelable(true)
	local property_table = export_context.propertyTable
	for i, job in ipairs(jobs) do
		if progress:isCanceled() then break end
		local rendition = job.rendition
		local completed, failure, notes = LrFunctionContext.pcallWithContext('tohdr render', function(context)
			if not binary then return locate_err or 'tohdr.exe not found' end
			if LrFileUtils.exists(job.destination) then
				return 'A file already exists at ' .. job.destination
			end
			local rendered_path, reason = render_in_scratch(context, property_table, rendition.photo)
			if progress:isCanceled() then return end
			if not rendered_path then return reason or 'Lightroom failed to render this photo' end
			return convert_on_windows(binary, rendered_path, job.destination, property_table.tohdr_quality, progress)
		end)
		if not progress:isCanceled() then
			if not completed or failure then
				failures[#failures + 1] = LrPathUtils.leafName(job.destination) .. '\n' .. tostring(failure)
			elseif notes then
				TohdrCli.merge_advisories(advisories, notes)
			end
			progress:setPortionComplete(i, #jobs)
		end
	end
	progress:done()
	local summary = TohdrCli.summarize_advisories(advisories)
	if #failures > 0 then
		-- The primary renditions were skipped, so Lightroom does not collect
		-- their uploadFailed results for the Export Results dialog.
		if summary then failures[#failures + 1] = summary end
		LrDialogs.message('Some photos could not be exported', table.concat(failures, '\n\n'), 'warning')
	elseif summary then
		LrDialogs.message('tohdr', summary, 'info')
	end
end

function export_service_provider.processRenderedPhotos(_function_context, export_context)
	local export_session = export_context.exportSession
	local property_table = export_context.propertyTable
	local n_photos = export_session:countRenditions()

	local progress = export_context:configureProgress {
		title = n_photos > 1
			and ('Converting ' .. n_photos .. ' photos to gain-map HEIC')
			or 'Converting one photo to gain-map HEIC',
	}

	local binary, locate_err = find_binary(property_table)
	if WIN_ENV then
		return process_windows(export_context, progress, binary, locate_err)
	end

	-- Collected, not reported per photo: LrC has no per-photo channel for
	-- "succeeded, but you should know", and 200 modal dialogs is not a design.
	local advisories = {}

	for _, rendition in export_context:renditions { stopIfCanceled = true } do
		-- Fail renditions individually rather than aborting the export, so the
		-- user sees which photos failed.
		if not binary then
			rendition:uploadFailed(locate_err or 'tohdr binary not found')
		else
			local ok, path_or_message = rendition:waitForRender()
			if not ok then
				rendition:uploadFailed(path_or_message or 'Lightroom failed to render this photo')
			else
				local rendered_path = path_or_message
				local dest_dir = LrPathUtils.parent(rendition.destinationPath)
				local out_name = LrPathUtils.removeExtension(
					LrPathUtils.leafName(rendition.destinationPath)
				) .. '.heic'
				local out_path = LrPathUtils.child(dest_dir, out_name)

				-- Looked up only when used, so an unchecked box costs no
				-- catalog access.
				local raw_path, no_raw_because
				if property_table.tohdr_makerNote then
					raw_path, no_raw_because = original_path(rendition)
				end

				local args = TohdrCli.build_convert_args(
					property_table, rendered_path, out_path, raw_path
				)
				local status, output = run_capturing(binary, args)

				if status ~= 0 then
					rendition:uploadFailed(TohdrCli.summarize_failure(status, output))
				elseif not LrFileUtils.exists(out_path) then
					rendition:uploadFailed(
						'tohdr reported success but wrote no file to ' .. out_path
					)
				elseif TohdrCli.gain_map_source(output) == 'derived' then
					-- No gain map in the intermediate, so `tohdr` derived one
					-- from Lightroom's already-clipped SDR pixels. That output
					-- passes every structural check and still renders washed
					-- out, which is the failure this project exists to prevent.
					-- Two causes the user can tell apart, hence the wording.
					LrFileUtils.delete(out_path)
					rendition:uploadFailed(
						'Lightroom rendered an SDR intermediate with no gain map, so the HEIC '
							.. 'would have carried no HDR. Check that this photo is in HDR edit '
							.. 'mode in Develop; if it is, this Lightroom version may not accept '
							.. 'the HDR export settings the plugin requests.'
					)
				else
					-- Keep what `tohdr` said, so a silent fallback (above all a
					-- guessed colour space) reaches the user.
					TohdrCli.merge_advisories(advisories, TohdrCli.advisories(output))

					-- `tohdr` warns about MakerNotes it refuses, but cannot warn
					-- about a file it was never handed. Only the plugin sees it.
					if no_raw_because then
						TohdrCli.merge_advisories(advisories, {
							{
								text = "warning: the camera's MakerNote was requested, but "
									.. no_raw_because,
								count = 1,
							},
						})
					end
				end

				-- On EVERY path, not just success: this is a full-res
				-- uncompressed 16-bit TIFF (hundreds of MB) nobody asked for.
				if rendered_path ~= out_path then
					LrFileUtils.delete(rendered_path)
				end
			end
		end
	end

	if progress then
		progress:done()
	end

	-- Only when non-empty. A dialog that always appears is always dismissed
	-- unread, which would defeat collecting these at all.
	local summary = TohdrCli.summarize_advisories(advisories)
	if summary then
		LrDialogs.message('tohdr', summary, 'info')
	end
end

return export_service_provider

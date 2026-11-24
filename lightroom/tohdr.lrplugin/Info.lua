--[[----------------------------------------------------------------------

Info.lua
Plugin manifest for the "HDR Gain-Map HEIC" Lightroom Classic export service.

------------------------------------------------------------------------]]

local plugin_name = WIN_ENV and 'HDR Gain Map HEIC' or 'HDR Gain-Map HEIC'

return {

	-- 13.0 is where LrC gained HDR Output, which is the only mode that feeds
	-- this plugin usable pixels. A product floor, not an API one -- every Lua
	-- call here is far older.
	LrSdkVersion = 13.0,
	LrSdkMinimumVersion = 13.0,

	LrToolkitIdentifier = 'com.tohdr.lightroom-export',
	LrPluginName = plugin_name,

	-- `build` must be a number: Plug-in Manager renders a string as nothing, so
	-- two installs would look identical. install-lrplugin.sh stamps YYMMDDHHMM;
	-- a checkout stays 0 so a stamp cannot be committed.
	-- **Bump `revision` on every change that ships.**
	VERSION = { major = 0, minor = 1, revision = 3, build = 0 },
	-- installed-from: checkout

	LrExportServiceProvider = {
		title = plugin_name,
		file = 'ExportServiceProvider.lua',
	},
}

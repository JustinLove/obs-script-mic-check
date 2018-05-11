obs = obslua
bit = require("bit")
os = require("os")

function script_log(message)
	obs.script_log(obs.LOG_INFO, message)
end

dofile(script_path() .. "obs-script-mic-check-common.lua")

function source_mute(calldata)
	local source = obs.calldata_source(calldata, "source")
	local status = audio_status(obs.obs_source_muted(source))
	local name = obs.obs_source_get_name(source)
	--script_log(name .. " " .. status .. " " .. obs.obs_source_get_id(source))
	audio_sources[name] = {
		name = name,
	}
end

function request_rules()
	script_log("got request")
	for id,rule in pairs(source_rules) do
		send_source_rule(id, rule)
	end
end

function send_source_rule(id, rule)
	local sh = obs.obs_get_signal_handler()
	local calldata = obs.calldata()
	obs.calldata_init(calldata)
	obs.calldata_set_int(calldata, "id", id)
	script_log(serialize_rule(rule))
	obs.calldata_set_string(calldata, "rule_json", serialize_rule(rule))
	obs.signal_handler_signal(sh, "lua_mic_check_source_rule", calldata)
	obs.calldata_free(calldata)
end

-- A function named script_description returns the description shown to
-- the user
local description = [[Provides per-source mic check settings via filter properties.

Attach rules to video sources ("BRB", "Starting Soon", etc) using the "Mic Check Settings" filter. (Right-click on a source and select filters.) The first active video source with attached settings will be used to trigger alarms instead of the defaults.

Non-functional without obs-script-mic-check.lua.]]
function script_description()
	return description
end

function add_audio_rule_properties(props)
	local to = obs.obs_properties_add_int(props, "timeout", "For this many seconds", 0, 60 * 60, 5) 
	obs.obs_property_set_long_description(to, "Alarm if audio is in alarm state for this many seconds.")

	local op = obs.obs_properties_add_list(props, "operator", "Operator", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(op, "Any", "any")
	obs.obs_property_list_add_string(op, "All", "all")
	obs.obs_property_set_long_description(op, "If multiple audio sources are selected below, how should they be combined.")

	for _,source in pairs(audio_sources) do
		local s = obs.obs_properties_add_list(props, source.name, source.name, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
		obs.obs_property_list_add_string(s, "N/A", "disabled")
		obs.obs_property_list_add_string(s, "Mute", audio_status(true))
		obs.obs_property_list_add_string(s, "Live", audio_status(false))
		obs.obs_property_set_long_description(s, "Alarm will trigger if this audio source is in the specified state.")
	end
end

-- a function named script_load will be called on startup
function script_load(settings)
	script_log("script filter load")

	local sh = obs.obs_get_signal_handler()
	-- signals received
	obs.signal_handler_add(sh, "void lua_mic_check_source_mute(ptr source)")
	obs.signal_handler_connect(sh, "lua_mic_check_source_mute", source_mute)

	-- signals sent
	obs.signal_handler_add(sh, "void lua_mic_check_source_rule(int id, string rule_json)")
	obs.signal_handler_add(sh, "void lua_mic_check_request_audio_sources()")

	obs.signal_handler_signal(sh, "lua_mic_check_request_audio_sources", nil)
end

local next_filter_id = 0

function update_filter_info(filter)
	--script_log("update filter info")
	local parent = obs.obs_filter_get_parent(filter.context)
	if parent ~= nil then
		local name = obs.obs_source_get_name(parent)
		if source_rules[filter.id].name ~= name then
			source_rules[filter.id].name = name

			send_source_rule(filter.id, source_rules[filter.id])
		end
	end
end

filter_def = {}
filter_def.id = "lua_mic_check_properties_filter"
filter_def.type = obs.OBS_SOURCE_TYPE_FILTER
filter_def.output_flags = obs.OBS_SOURCE_VIDEO

filter_def.get_name = function()
	return "Mic Check Settings"
end

filter_def.create = function(settings, source)
	script_log("filter create")
	local filter = {
		id = next_filter_id,
		context = source,
		width = 100,
		height = 100,
	}
	filter.bootstrap = function()
		update_filter_info(filter)
		obs.remove_current_callback()
	end
	filter.update = function()
		update_filter_info(filter)
	end
	next_filter_id = next_filter_id + 1

	if source_rules[filter.id] == nil then
		source_rules[filter.id] = {}
	end
	bootstrap_rule_settings(source_rules[filter.id], settings)

	obs.timer_add(filter.bootstrap, 100)
	obs.timer_add(filter.update, 10000)

	return filter
end

filter_def.destroy = function(filter)
	source_rules[filter.id] = nil
end

filter_def.get_defaults = function(settings)
	script_log("filter defaults")
	obs.obs_data_set_default_string(settings, "label_filter", "Alarm if in this state.")
	audio_default_settings(settings)
end

filter_def.get_properties = function(filter)
	script_log("filter properties")
	local props = obs.obs_properties_create()

	local label = obs.obs_properties_add_text(props, "label_filter", "Source Checks:", 0)
	obs.obs_property_set_enabled(label, false)

	add_audio_rule_properties(props)

	return props
end

filter_def.update = function(filter, settings)
	script_log("filter update")
	if source_rules[filter.id] == nil then
		source_rules[filter.id] = {}
	end
	update_rule_settings(source_rules[filter.id], settings)
end

filter_def.get_width = function(filter)
	return filter.width
end

filter_def.get_height = function(filter)
	return filter.height
end

filter_def.video_render = function(filter, effect)
	local target = obs.obs_filter_get_target(filter.context)
	if target ~= nil then
		filter.width = obs.obs_source_get_base_width(target)
		filter.height = obs.obs_source_get_base_height(target)
	end
	obs.obs_source_skip_video_filter(filter.context)
end

-- video tick holds the sources mutex, which can conflict with property enumeration in the script
--filter_def.video_tick = function(filter, seconds) end

obs.obs_register_source(filter_def)

obs = obslua
bit = require("bit")

function script_log(message)
	obs.script_log(obs.LOG_INFO, message)
end

local sample_rate = 1000

local alarm_source = ""

local alarm_active = false
local audio_sources = {}
local video_sources = {}
local default_rule = {
	operator = "all",
	audio_states = {
		{["Mic/Aux"] = "mute"}
	}
}

function enum_sources(callback)
	local sources = obs.obs_enum_sources()
	if sources ~= nil then
		for _,source in ipairs(sources) do
			callback(source)
		end
	end
	obs.source_list_release(sources)
end

function set_alarm_visible(visible)
	if alarm_source ~= nil then
		local current_source = obs.obs_frontend_get_current_scene()
		local current_scene = obs.obs_scene_from_source(current_source)
		local item = obs.obs_scene_find_source(current_scene, alarm_source)
		if item ~= nil then
			obs.obs_sceneitem_set_visible(item, visible)
		end
		obs.obs_source_release(current_source)
	end
end

function activate_alarm()
	set_alarm_visible(true)
	obs.remove_current_callback()
end

function play_alarm()
	script_log("alarm")
	set_alarm_visible(false)
	obs.timer_add(activate_alarm, 500)
end

function set_alarm(alarming)
	if alarming then
		if not alarm_active then
			play_alarm()
			alarm_active = true
			obs.timer_add(play_alarm, 60*1000)
		end
	else
		if alarm_active then
			alarm_active = false
			obs.timer_remove(play_alarm)
		end
	end
end

function run_default_rule()
	-- just default now
	for name,status in pairs(default_rule.audio_states) do
		local cache = audio_sources[name]
		if cache then
			if cache.status == status then
				if default_rule.operator == "any" then
					return true
				end
			else
				if default_rule.operator == "all" then
					return false
				end
			end
		end
	end

	if default_rule.operator == "any" then
		return false
	else
		return true
	end
end

function check_alarm()
	set_alarm(run_default_rule())
end

function test_alarm(props, p, set)
	play_alarm()
	return true
end

function audio_status(muted)
	if muted then
		return "muted"
	else
		return "live"
	end
end

function video_status(active)
	if active then
		return "active"
	else
		return "hidden"
	end
end

function examine_source_states()
	audio_sources = {}
	enum_sources(function(source)
		local name = obs.obs_source_get_name(source)
		local status = audio_status(obs.obs_source_muted(source))
		local active = video_status(obs.obs_source_active(source))
		local flags = obs.obs_source_get_output_flags(source)
		--script_log(name .. " " .. active .. " " .. status .. " " .. obs.obs_source_get_id(source) .. " " .. bit.tohex(flags))
		local info = {
			name = name,
			status = status,
			active = active,
			flags = flags,
		}
		if bit.band(flags, obs.OBS_SOURCE_AUDIO) ~= 0 then
			audio_sources[name] = info
		end
		if bit.band(flags, obs.OBS_SOURCE_VIDEO) ~= 0 then
			video_sources[name] = info
		end
	end)
	--return true
end

function source_mute(calldata)
	local source = obs.calldata_source(calldata, "source")
	local status = audio_status(obs.obs_source_muted(source))
	local active = video_status(obs.obs_source_active(source))
	script_log(obs.obs_source_get_name(source) .. " " .. active .. " " .. status .. " " .. obs.obs_source_get_id(source))
	local cache = audio_sources[obs.obs_source_get_name(source)]
	if cache then
		cache.status = status
		check_alarm()
	end
end

function source_activate(calldata)
	source_mute(calldata)
end

function source_deactivate(calldata)
	source_mute(calldata)
end

function source_create(calldata)
	local source = obs.calldata_source(calldata, "source")
	hook_source(source)
	examine_source_states()
end

function source_destroy(calldata)
	examine_source_states()
end

function hook_source(source)
	if source ~= nil then
		local handler = obs.obs_source_get_signal_handler(source)
		if handler ~= nil then
			local flags = obs.obs_source_get_output_flags(source)
			if bit.band(flags, obs.OBS_SOURCE_AUDIO) ~= 0 then
				obs.signal_handler_connect(handler, "mute", source_mute)
			end
			if bit.band(flags, obs.OBS_SOURCE_VIDEO) ~= 0 then
				obs.signal_handler_connect(handler, "activate", source_activate)
				obs.signal_handler_connect(handler, "deactivate", source_deactivate)
			end
		end
	end
end

function dump_obs()
	local keys = {}
	for key,value in pairs(obs) do
		keys[#keys+1] = key
	end
	table.sort(keys)
	local output = {}
	for i,key in ipairs(keys) do
		local value = type(obs[key])
		if value == 'number' then
			value = obs[key]
		elseif value == 'string' then
			value = '"' .. obs[key] .. '"'
		end
		output[i] = key .. " : " .. value
	end
	script_log(table.concat(output, "\n"))
end

-- A function named script_description returns the description shown to
-- the user
local description = [[Play an alarm if mic state not appropriate foru souces shown
]]
function script_description()
	return description
end

-- A function named script_properties defines the properties that the user
-- can change for the entire script module itself
function script_properties()
	script_log("props")

	local props = obs.obs_properties_create()

	local p = obs.obs_properties_add_list(props, "alarm_source", "Alarm Media Source", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
	enum_sources(function(source)
		local source_id = obs.obs_source_get_id(source)
		if source_id == "ffmpeg_source" then
			local name = obs.obs_source_get_name(source)
			obs.obs_property_list_add_string(p, name, name)
		end
	end)
	obs.obs_property_set_long_description(p, "See above for how to create an appropriate media source.")

	local ref = obs.obs_properties_add_button(props, "test_alarm", "Test Alarm", test_alarm)
	obs.obs_property_set_long_description(ref, "Test activating selected media sources")

	local label = obs.obs_properties_add_text(props, "label_default", "Default Checks:", 0)
	obs.obs_property_set_enabled(label, false)

	local op = obs.obs_properties_add_list(props, "default_operator", "Operator", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(op, "Any", "any")
	obs.obs_property_list_add_string(op, "All", "all")

	for _,source in pairs(audio_sources) do
		local s = obs.obs_properties_add_list(props, "default-" .. source.name, source.name, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
		obs.obs_property_list_add_string(s, "N/A", "disabled")
		obs.obs_property_list_add_string(s, "Mute", audio_status(true))
		obs.obs_property_list_add_string(s, "Live", audio_status(false))
	end

	return props
end

-- A function named script_defaults will be called to set the default settings
function script_defaults(settings)
	script_log("defaults")

	obs.obs_data_set_default_string(settings, "alarm_source", "")
	obs.obs_data_set_default_string(settings, "label_default", "Alarm if in this state.")
end

--
-- A function named script_update will be called when settings are changed
function script_update(settings)
	script_log("update")
	my_settings = settings

	alarm_source = obs.obs_data_get_string(settings, "alarm_source")

	default_rule.operator = obs.obs_data_get_string(settings, "default_operator")
	default_rule.audio_states = {}
	for _,source in pairs(audio_sources) do
		local state = obs.obs_data_get_string(settings, "default-" .. source.name)
		if state ~= "disabled" then
			default_rule.audio_states[source.name] = state
		end
	end
end

-- a function named script_load will be called on startup
function script_load(settings)
	script_log("load")
	obs.obs_data_set_string(settings, "label_default", "Alarm if in this state.")
	---dump_obs()
	examine_source_states()
	enum_sources(hook_source)

	local sh = obs.obs_get_signal_handler()
	obs.signal_handler_connect(sh, "source_create", source_create)
	obs.signal_handler_connect(sh, "source_destroy", source_destroy)
	--obs.timer_add(update_frames, sample_rate)
end

function script_unload()
	set_alarm_visible(false)
	-- these crash OBS
	--obs.timer_remove(update_frames)
end

source_def = {}
source_def.id = "lua_mic_check_properties_filter"
source_def.type = obs.OBS_SOURCE_TYPE_FILTER
source_def.output_flags = bit.bor(obs.OBS_SOURCE_VIDEO)

source_def.get_name = function()
	return "Mic Check Settings"
end

source_def.create = function(source, settings)
	return {}
end

source_def.destroy = function(data)
end

source_def.get_defaults = function(settings)
end

--source_def.get_properties = function(data)
--end

source_def.update = function(data, settings)
end

source_def.activate = function(data)
end

source_def.deactivate = function(data)
end

source_def.video_render = function(data, effect)
end

source_def.load = function(data, settings)
end

obs.obs_register_source(source_def)

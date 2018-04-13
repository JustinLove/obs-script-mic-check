obs = obslua
bit = require("bit")

function script_log(message)
	obs.script_log(obs.LOG_INFO, message)
end

local sample_rate = 1000

local alarm_source = ""

local alarm_active = false

function set_alarm_visible(visible)
	if alarm_source ~= nil then
		local current_source = obs.obs_frontend_get_current_scene()
		local current_scene = obs.obs_scene_from_source(current_source)
		obs.obs_source_release(current_source)
		local item = obs.obs_scene_find_source(current_scene, alarm_source)
		if item ~= nil then
			obs.obs_sceneitem_set_visible(item, visible)
		end
	end
end

function activate_alarm()
	set_alarm_visible(true)
	obs.remove_current_callback()
end

function play_alarm()
	set_alarm_visible(false)
	obs.timer_add(activate_alarm, 500)
end

function check_alarm()
	if false then
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

function special_sources(callback)
	if not callback then
		script_log("no callback")
		return
	end
	for i = 1,5 do
		local source = obs.obs_get_output_source(i)
		if source then
			callback(source)
			obs.obs_source_release(source)
		end
	end
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

function check_audio(props, p, set)
	local sources = obs.obs_enum_sources()
	for _,source in ipairs(sources) do
		local status = audio_status(obs.obs_source_muted(source))
		script_log(obs.obs_source_get_name(source) .. " " .. status)
	end
	obs.source_list_release(sources)
	--return true
end

function source_mute(calldata)
	local source = obs.calldata_source(calldata, "source")
	local status = audio_status(obs.obs_source_muted(source))
	script_log(obs.obs_source_get_name(source) .. " " .. status)
end

function hook_source(source)
	if source ~= nil then
		local handler = obs.obs_source_get_signal_handler(source)
		if handler ~= nil then
			obs.signal_handler_connect(handler, "mute", source_mute)
		end
	end
end

function unhook_source(source)
	if source ~= nil then
		local handler = obs.obs_source_get_signal_handler(source)
		if handler ~= nil then
			obs.signal_handler_disconnect(handler, "mute", source_mute)
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
	local sources = obs.obs_enum_sources()
	if sources ~= nil then
		for _, source in ipairs(sources) do
			source_id = obs.obs_source_get_id(source)
			if source_id == "ffmpeg_source" then
				local name = obs.obs_source_get_name(source)
				obs.obs_property_list_add_string(p, name, name)
			end
		end
	end
	obs.source_list_release(sources)
	obs.obs_property_set_long_description(p, "See above for how to create an appropriate media source.")

	local ref = obs.obs_properties_add_button(props, "test_alarm", "Test Alarm", test_alarm)
	obs.obs_property_set_long_description(ref, "Test activating selected media sources")

	local ref = obs.obs_properties_add_button(props, "check_audio", "Check Audio", check_audio)

	return props
end

-- A function named script_defaults will be called to set the default settings
function script_defaults(settings)
	script_log("defaults")

	obs.obs_data_set_default_string(settings, "alarm_source", "")
end

--
-- A function named script_update will be called when settings are changed
function script_update(settings)
	script_log("update")
	my_settings = settings

	alarm_source = obs.obs_data_get_string(settings, "alarm_source")
end

-- a function named script_load will be called on startup
function script_load(settings)
	script_log("load")
	---dump_obs()
	special_sources(hook_source)
	--obs.timer_add(update_frames, sample_rate)
end

function script_unload()
	set_alarm_visible(false)
	-- these crash OBS
	--special_sources(unhook_source)
	--obs.timer_remove(update_frames)
end

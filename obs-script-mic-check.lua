local obs = obslua
local bit = require("bit")
local os = require("os")

function script_log(message) -- luacheck: no unused args
	-- unreachable code
	-- luacheck: push ignore
	if true then
		obs.script_log(obs.LOG_INFO, message)
	end
	-- luacheck: pop
end

local sample_rate = 1000

local alarm_source = ""

local obs_events = {}

dofile(script_path() .. "lib/obs-script-mic-check-common.lua")

local function enum_sources(callback)
	local sources = obs.obs_enum_sources()
	if sources ~= nil then
		for _,source in ipairs(sources) do
			callback(source)
		end
	end
	obs.source_list_release(sources)
end

local function set_alarm_visible(visible)
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

local function activate_alarm()
	set_alarm_visible(true)
	obs.remove_current_callback()
end

local function play_alarm()
	script_log("alarm")
	set_alarm_visible(false)
	obs.timer_add(activate_alarm, 500)
end

local function set_alarm(alarming)
	if alarming then
		if not alarm_active then
			play_alarm()
			alarm_active = true
			obs.timer_add(play_alarm, 60*1000)
		end
	else
		if alarm_active then
			alarm_active = false
			set_alarm_visible(false)
			obs.timer_remove(play_alarm)
		end
	end
end

local function trigger_alarm(violation, timeout)
	if violation then
		if trigger_active then
			trigger_timeout = timeout
			if os.difftime(os.time(), trigger_time) > timeout then
				set_alarm(true)
				local sh = obs.obs_get_signal_handler()
				obs.signal_handler_signal(sh, "lua_mic_check_alarm_activate", nil)
			end
		else
			script_log("trigger")
			trigger_active = true
			trigger_time = os.time()
			trigger_timeout = timeout
			local sh = obs.obs_get_signal_handler()
			local calldata = obs.calldata()
			obs.calldata_init(calldata)
			obs.calldata_set_int(calldata, "time", trigger_time)
			obs.calldata_set_int(calldata, "timeout", trigger_timeout)
			obs.signal_handler_signal(sh, "lua_mic_check_trigger_activate", calldata)
			obs.calldata_free(calldata)
		end
	else
		--script_log("no violation")
		if alarm_active or trigger_active then
			local sh = obs.obs_get_signal_handler()
			obs.signal_handler_signal(sh, "lua_mic_check_alarm_reset", nil)
		end
		trigger_active = false
		set_alarm(false)
	end
end

local function check_alarm()
	for _,rule in pairs(source_rules) do
		if rule.name then
			local source = video_sources[rule.name]
			if source and source.active == 'active' then
				trigger_alarm(run_rule(rule), rule.timeout)
				return
			end
		end
	end
	trigger_alarm(run_rule(default_rule), default_rule.timeout)
end

local function examine_source_state(source)
	local current_source = obs.obs_frontend_get_current_scene()
	local current_scene = obs.obs_scene_from_source(current_source)
	local sh = obs.obs_get_signal_handler()
	local name = obs.obs_source_get_name(source)
	local status = audio_status(obs.obs_source_muted(source))
	local active = video_status(obs.obs_source_active(source))
	local flags = obs.obs_source_get_output_flags(source)
	local item = obs.obs_scene_find_source(current_scene, name)
	local in_current_scene = item ~= nil
	--script_log(name .. " " .. active .. " " .. status .. " " .. obs.obs_source_get_id(source) .. " " .. bit.tohex(flags))
	local info = {
		name = name,
		status = status,
		active = active,
		flags = flags,
		in_current_scene = in_current_scene,
	}
	if bit.band(flags, obs.OBS_SOURCE_AUDIO) ~= 0 then
		audio_sources[name] = info
		local audiodata = obs.calldata()
		obs.calldata_init(audiodata)
		obs.calldata_set_ptr(audiodata, "source", source)
		obs.signal_handler_signal(sh, "lua_mic_check_source_mute", audiodata)
		obs.calldata_free(audiodata)
	end
	if bit.band(flags, obs.OBS_SOURCE_VIDEO) ~= 0 then
		video_sources[name] = info
		local videodata = obs.calldata()
		obs.calldata_init(videodata)
		obs.calldata_set_string(videodata, "name", name)
		obs.calldata_set_bool(videodata, "active", obs.obs_source_active(source))
		obs.calldata_set_bool(videodata, "in_current_scene", in_current_scene)
		obs.signal_handler_signal(sh, "lua_mic_check_video_source_status", videodata)
		obs.calldata_free(videodata)
	end
	obs.obs_source_release(current_source)
end

local function examine_source_states()
	enum_sources(examine_source_state)
	check_alarm()
	--return true
end

local function send_default_rule()
	local sh = obs.obs_get_signal_handler()
	local calldata = obs.calldata()
	obs.calldata_init(calldata)
	obs.calldata_set_string(calldata, "rule_json", serialize_rule(default_rule))
	obs.signal_handler_signal(sh, "lua_mic_check_default_rule", calldata)
	obs.calldata_free(calldata)
end

local function process_events()
	for _,event in ipairs(obs_events) do
		script_log("event " .. event.event)
		if event.event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
			examine_source_states()
		elseif event.event == 'request_audio_sources' then
			examine_source_states()
		elseif event.event == 'request_rules' then
			send_default_rule()
		end
	end
	obs_events = {}
end

local function tick()
	process_events()
	check_alarm()
end

local function test_alarm(props, p, set) -- luacheck: no unused args
	play_alarm()
	return true
end

local function source_mute(calldata)
	local source = obs.calldata_source(calldata, "source")
	local status = audio_status(obs.obs_source_muted(source))
	--script_log(obs.obs_source_get_name(source) .. " " .. status .. " " .. obs.obs_source_get_id(source))
	local cache = audio_sources[obs.obs_source_get_name(source)]
	if cache then
		cache.status = status
		check_alarm()
		local sh = obs.obs_get_signal_handler()
		obs.signal_handler_signal(sh, "lua_mic_check_source_mute", calldata)
	end
end

local function hook_source(source)
	if source ~= nil then
		local handler = obs.obs_source_get_signal_handler(source)
		if handler ~= nil then
			local flags = obs.obs_source_get_output_flags(source)
			if bit.band(flags, obs.OBS_SOURCE_AUDIO) ~= 0 then
				obs.signal_handler_connect(handler, "mute", source_mute)
			end
		end
	end
end

local function source_create(calldata)
	local source = obs.calldata_source(calldata, "source")
	hook_source(source)
	examine_source_state(source)
end

local function source_destroy(calldata)
	local source = obs.calldata_source(calldata, "source")
	examine_source_state(source)
end

local function request_audio_sources()
	obs_events[#obs_events+1] = {
		event = 'request_audio_sources'
	}
end

local function request_rules()
	obs_events[#obs_events+1] = {
		event = 'request_rules'
	}
end

local function frontend_event(event, private_data) -- luacheck: no unused args
	script_log("frontend event " .. event)
	if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
		obs_events[#obs_events+1] = {
			event = event
		}

		-- deadlocks OBS on startup
		--examine_source_states()
	end
end

-- A function named script_description returns the description shown to
-- the user
-- luacheck: push no max line length
local description = [[Play an alarm if mic state not appropriate for sources shown.

Add a media source for the alarm. A suitable sound file is provided with the script. Open Advanced Audio Properties for the source and change Audio Monitoring to Monitor Only (mute output).

Add a copy of the alarm source to every scene where you want to hear it.

Use obs-script-mic-check-source-settings-filter.lua to add rules to video sources.
Use obs-script-mic-check-status-monitor.lua to get a visible source to monitor alarm status.

If no filtered video source is active, then the default rules below will be used.]]
-- luacheck: pop
function script_description()
	return description
end

local function add_audio_rule_properties(props)
	local to = obs.obs_properties_add_int(props,
		"timeout", "For this many seconds", 0, 60 * 60, 5)
	obs.obs_property_set_long_description(to,
		"Alarm if audio is in alarm state for this many seconds.")

	local op = obs.obs_properties_add_list(props,
		"operator", "Operator", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(op, "Any", "any")
	obs.obs_property_list_add_string(op, "All", "all")
	obs.obs_property_set_long_description(op,
		"If multiple audio sources are selected below, how should they be combined.")

	for _,source in pairs(audio_sources) do
		local s = obs.obs_properties_add_list(props,
			source.name, source.name, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
		obs.obs_property_list_add_string(s, "N/A", "disabled")
		obs.obs_property_list_add_string(s, "Mute", audio_status(true))
		obs.obs_property_list_add_string(s, "Live", audio_status(false))
		obs.obs_property_set_long_description(s,
			"Alarm will trigger if this audio source is in the specified state.")
	end
end

-- A function named script_properties defines the properties that the user
-- can change for the entire script module itself
function script_properties()
	script_log("props")

	local props = obs.obs_properties_create()

	local p = obs.obs_properties_add_list(props,
		"alarm_source", "Alarm Media Source",
		obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
	enum_sources(function(source)
		local source_id = obs.obs_source_get_id(source)
		if source_id == "ffmpeg_source" then
			local name = obs.obs_source_get_name(source)
			obs.obs_property_list_add_string(p, name, name)
		end
	end)
	obs.obs_property_set_long_description(p,
		"See above for how to create an appropriate media source.")

	local ref = obs.obs_properties_add_button(props,
		"test_alarm", "Test Alarm", test_alarm)
	obs.obs_property_set_long_description(ref,
		"Test activating selected media sources")

	local label = obs.obs_properties_add_text(props,
		"label_default", "Default Checks:", 0)
	obs.obs_property_set_enabled(label, false)

	add_audio_rule_properties(props)

	return props
end

-- A function named script_defaults will be called to set the default settings
function script_defaults(settings)
	script_log("defaults")

	obs.obs_data_set_default_string(settings, "label_default", "Alarm if in this state.")
	obs.obs_data_set_default_string(settings, "alarm_source", "")
	obs.obs_data_set_default_string(settings, "label_default", "Alarm if in this state.")
	audio_default_settings(settings)
end

--
-- A function named script_update will be called when settings are changed
function script_update(settings)
	script_log("update")

	alarm_source = obs.obs_data_get_string(settings, "alarm_source")

	update_rule_settings(default_rule, settings)

	send_default_rule()
end

-- a function named script_load will be called on startup
function script_load(settings)
	script_log("script load")

	obs.obs_frontend_add_event_callback(frontend_event)

	bootstrap_rule_settings(default_rule, settings)

	examine_source_states()
	enum_sources(hook_source)

	local sh = obs.obs_get_signal_handler()
	-- signals received
	obs.signal_handler_connect(sh, "source_create", source_create)
	obs.signal_handler_connect(sh, "source_destroy", source_destroy)
	obs.signal_handler_connect(sh, "source_activate", source_activate)
	obs.signal_handler_connect(sh, "source_deactivate", source_deactivate)
	obs.signal_handler_add(sh, "void lua_mic_check_request_audio_sources()")
	obs.signal_handler_connect(sh, "lua_mic_check_request_audio_sources", request_audio_sources)
	obs.signal_handler_add(sh, "void lua_mic_check_source_rule(int id, string rule_json)")
	obs.signal_handler_connect(sh, "lua_mic_check_source_rule", update_source_rule)

	-- sent and received
	obs.signal_handler_add(sh, "void lua_mic_check_request_rules()")
	obs.signal_handler_connect(sh, "lua_mic_check_request_rules", request_rules)

	-- signals sent
	obs.signal_handler_add(sh, "void lua_mic_check_source_mute(ptr source)")
	obs.signal_handler_add(sh, "void lua_mic_check_default_rule(string rule_json)")
	obs.signal_handler_add(sh, "void lua_mic_check_video_source_status(string name, bool active, bool in_current_scene)")
	obs.signal_handler_add(sh, "void lua_mic_check_trigger_activate(int time, int timeout)")
	obs.signal_handler_add(sh, "void lua_mic_check_alarm_activate()")
	obs.signal_handler_add(sh, "void lua_mic_check_alarm_reset()")

	obs.signal_handler_signal(sh, "lua_mic_check_request_rules", nil)
	obs.signal_handler_signal(sh, "lua_mic_check_alarm_reset", nil)

	obs.timer_add(tick, sample_rate)
end

function script_unload()
	set_alarm_visible(false)
	-- these crash OBS
	--obs.timer_remove(update_frames)
end

obs = obslua
bit = require("bit")
os = require("os")

function script_log(message)
	obs.script_log(obs.LOG_INFO, message)
end

local sample_rate = 1000

local status_margin = 10
local status_width = 500
local status_height = 500
local status_font_size = 40
local status_indent = 100

local alarm_source = ""

local alarm_active = false
local trigger_active = false
local trigger_time = os.time()
local audio_sources = {}
local video_sources = {}
local default_rule = {
	timeout = 5,
	operator = "all",
	audio_states = {
		{["Mic/Aux"] = "mute"}
	}
}
local source_rules = {}

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

function trigger_alarm(violation, timeout)
	if violation then
		if trigger_active then
			if os.difftime(os.time(), trigger_time) > timeout then
				set_alarm(true)
			end
		else
			script_log("trigger")
			trigger_active = true
			trigger_time = os.time()
		end
	else
		--script_log("no violation")
		trigger_active = false
		set_alarm(false)
	end
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
			set_alarm_visible(false)
			obs.timer_remove(play_alarm)
		end
	end
end

function dump_rule(rule)
	local items = {}
	for source,state in pairs(rule.audio_states) do
		table.insert(items, source .. "=" .. state)
	end
	script_log(rule.operator .. "(" .. table.concat(items, ",") .. ")")
end

function bootstrap_rule_settings(rule, settings)
	if rule == nil then
		script_log("bootstrap_rule_settings no rule")
	end
	if settings == nil then
		script_log("bootstrap_rule_settings no settings")
	end
	rule.timeout = obs.obs_data_get_int(settings, "timeout")
	rule.operator = obs.obs_data_get_string(settings, "operator")

	rule.audio_states = {}
	local index = 1
	while index < 200 do
		local name = obs.obs_data_get_string(settings, "audio" .. index)
		if name == nil or name == "" then
			break
		end
		index = index + 1

		local state = obs.obs_data_get_string(settings, name)
		if state == audio_status(true) or state == audio_status(false) then
			rule.audio_states[name] = state
			if audio_sources[name] == nil then
				audio_sources[name] = {
					name = name,
					status = audio_status(false),
					active = video_status(false),
					flags = 0,
				}
			end
		end
	end

	dump_rule(rule)
end

function update_rule_settings(rule, settings)
	if rule == nil then
		script_log("update_rule_settings no rule")
	end
	if settings == nil then
		script_log("update_rule_settings no settings")
	end
	rule.timeout = obs.obs_data_get_int(settings, "timeout")
	rule.operator = obs.obs_data_get_string(settings, "operator")
	rule.audio_states = {}
	local index = 1
	for _,source in pairs(audio_sources) do
		local state = obs.obs_data_get_string(settings, source.name)
		if state == audio_status(true) or state == audio_status(false) then
			rule.audio_states[source.name] = state
			obs.obs_data_set_string(settings, "audio" .. index, source.name)
			index = index + 1
		end
	end
	obs.obs_data_erase(settings, "audio" .. index)
	dump_rule(rule)
	check_alarm()
end

function audio_default_settings(settings)
	obs.obs_data_set_default_int(settings, "timeout", 5)
	obs.obs_data_set_default_string(settings, "operator", "any")
	for _,source in pairs(audio_sources) do
		obs.obs_data_set_default_string(settings, source.name, "disabled")
	end
end

function run_rule(rule)
	for name,status in pairs(rule.audio_states) do
		local cache = audio_sources[name]
		if cache then
			if cache.status == status then
				if rule.operator == "any" then
					return true, rule.timeout
				end
			else
				if rule.operator == "all" then
					return false, rule.timeout
				end
			end
		end
	end

	if rule.operator == "any" then
		return false, rule.timeout
	else
		return true, rule.timeout
	end
end

function check_alarm()
	for _,rule in pairs(source_rules) do
		if rule.name then
			local source = video_sources[rule.name]
			if source and source.active == 'active' then
				trigger_alarm(run_rule(rule))
				return
			end
		end
	end
	trigger_alarm(run_rule(default_rule))
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
	check_alarm()
	--return true
end

function source_active(calldata, source_active)
	local source = obs.calldata_source(calldata, "source")
	local active = video_status(source_active)
	--script_log(obs.obs_source_get_name(source) .. " " .. active .. " " .. obs.obs_source_get_id(source))
	local cache = video_sources[obs.obs_source_get_name(source)]
	if cache then
		cache.active = active
		check_alarm()
	end
end

function source_mute(calldata)
	local source = obs.calldata_source(calldata, "source")
	local status = audio_status(obs.obs_source_muted(source))
	--script_log(obs.obs_source_get_name(source) .. " " .. status .. " " .. obs.obs_source_get_id(source))
	local cache = audio_sources[obs.obs_source_get_name(source)]
	if cache then
		cache.status = status
		check_alarm()
	end
end

function source_activate(calldata)
	source_active(calldata, true)
end

function source_deactivate(calldata)
	source_active(calldata, false)
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
local description = [[Play an alarm if mic state not appropriate for sources shown.

Add a media source for the alarm. A suitable sound file is provided with the script. Open Advanced Audio Properties for the source and change Audio Monitoring to Monitor Only (mute output).

Add a copy of the alarm source to every scene where you want to hear it.

Attach rules to video sources ("BRB", "Starting Soon", etc) using the "Mic Check Settings" filter. (Right-click on a source and select filters.) The first active video source with attached settings will be used to trigger alarms instead of the defaults.

If no such video source is active, then the default rules below will be used.
]]
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
	my_settings = settings

	alarm_source = obs.obs_data_get_string(settings, "alarm_source")

	update_rule_settings(default_rule, settings)
end

-- a function named script_load will be called on startup
function script_load(settings)
	script_log("load")
	--dump_obs()

	bootstrap_rule_settings(default_rule, settings)

	examine_source_states()
	enum_sources(hook_source)

	local sh = obs.obs_get_signal_handler()
	obs.signal_handler_connect(sh, "source_create", source_create)
	obs.signal_handler_connect(sh, "source_destroy", source_destroy)
	obs.timer_add(check_alarm, sample_rate)
end

function script_unload()
	set_alarm_visible(false)
	-- these crash OBS
	--obs.timer_remove(update_frames)
end

local next_filter_id = 0

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
	next_filter_id = next_filter_id + 1

	if source_rules[filter.id] == nil then
		source_rules[filter.id] = {}
	end
	bootstrap_rule_settings(source_rules[filter.id], settings)

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
	obs.obs_source_skip_video_filter(filter.context)
end

filter_def.video_tick = function(filter, seconds)
	local target = obs.obs_filter_get_target(filter.context)
	if target ~= nil then
		filter.width = obs.obs_source_get_base_width(target)
		filter.height = obs.obs_source_get_base_height(target)
	end
	local parent = obs.obs_filter_get_parent(filter.context)
	if parent ~= nil then
		local name = obs.obs_source_get_name(parent)
		source_rules[filter.id].name = name
	end
end

obs.obs_register_source(filter_def)

local create_label = function(name, size)
	local settings = obs.obs_data_create()
	local font = obs.obs_data_create()

	obs.obs_data_set_string(font, "face", "Monospace")
	obs.obs_data_set_int(font, "flags", 0)
	obs.obs_data_set_int(font, "size", size)
	obs.obs_data_set_string(font, "style", "Regular")

	obs.obs_data_set_obj(settings, "font", font)
	obs.obs_data_set_string(settings, "text", " " .. name .. " ")
	obs.obs_data_set_bool(settings, "outline", false)

	local source = obs.obs_source_create_private("text_gdiplus", name .. "-label", settings)
	--local source = obs.obs_source_create_private("text_ft2_source", name .. "-label", settings)
	obs.obs_data_release(font)
	obs.obs_data_release(settings)

	return source
end

source_def = {}
source_def.id = "lua_mic_check_status_source"
source_def.output_flags = bit.bor(obs.OBS_SOURCE_VIDEO, obs.OBS_SOURCE_CUSTOM_DRAW)

source_def.get_name = function()
	return "Mic Check Status Monitor"
end

source_def.create = function(source, settings)
	local data = {
		labels = {}
	}
	data.labels['any'] = create_label('Any', status_font_size)
	data.labels['all'] = create_label('All', status_font_size)
	data.labels['mute'] = create_label('<X', status_font_size)
	data.labels['live'] = create_label('<))', status_font_size)
	return data
end

source_def.destroy = function(data)
	if data == nil then
		return
	end

	for key,label in pairs(data.labels) do
		obs.obs_source_release(label)
		data.labels[key] = nil
	end
end

function fill(color)
	local effect_solid = obs.obs_get_base_effect(obs.OBS_EFFECT_SOLID)
	local color_param = obs.gs_effect_get_param_by_name(effect_solid, "color");

	obs.gs_effect_set_color(color_param, color)

	while obs.gs_effect_loop(effect_solid, "Solid") do
		obs.gs_draw(obs.GS_TRISTRIP, 0, 0)
	end
end

function stroke(color)
	local effect_solid = obs.obs_get_base_effect(obs.OBS_EFFECT_SOLID)
	local color_param = obs.gs_effect_get_param_by_name(effect_solid, "color");

	obs.gs_effect_set_color(color_param, color)

	while obs.gs_effect_loop(effect_solid, "Solid") do
		obs.gs_draw(obs.GS_LINESTRIP, 0, 0)
	end
end

source_def.video_render = function(data, effect)
	if data == nil then
		return
	end

	obs.gs_blend_state_push()
	obs.gs_reset_blend_state()

	local effect_solid = obs.obs_get_base_effect(obs.OBS_EFFECT_SOLID)
	local color_param = obs.gs_effect_get_param_by_name(effect_solid, "color");

	obs.gs_effect_set_color(color_param, 0xff444444)
	while obs.gs_effect_loop(effect_solid, "Solid") do
		obs.gs_draw_sprite(nil, 0, status_width, status_height)
	end

	obs.gs_matrix_push()

	obs.gs_matrix_translate3f(status_margin, status_margin, 0)
	--obs.gs_matrix_scale3f(status_width - status_margin*2, status_height - status_margin*2, 1)

	for _,rule in pairs(source_rules) do
		obs.gs_effect_set_color(color_param, 0xff666666)
		while obs.gs_effect_loop(effect_solid, "Solid") do
			obs.gs_draw_sprite(nil, 0, status_width - status_margin*2, status_font_size)
		end
		if rule.name then
			if data.labels[rule.name] == nil then
				script_log("create " .. rule.name)
				data.labels[rule.name] = create_label(rule.name, status_font_size)
			end
			if data.labels[rule.name] ~= nil then
				--script_log("draw " .. rule.name)
				obs.obs_source_video_render(data.labels[rule.name])
			end
		end
		obs.gs_matrix_translate3f(0, status_font_size, 0)
		if rule.operator == 'any' or rule.operator == 'all' then
			obs.obs_source_video_render(data.labels[rule.operator])
		end
		obs.gs_matrix_push()
		obs.gs_matrix_translate3f(status_indent, 0, 0)
		local items = 0
		for name,state in pairs(rule.audio_states) do
			if data.labels[name] == nil then
				script_log("create " .. name)
				data.labels[name] = create_label(name, status_font_size)
			end
			if data.labels[name] ~= nil then
				--script_log("draw " .. rule.name)
				obs.obs_source_video_render(data.labels[state])
				obs.gs_matrix_push()
				obs.gs_matrix_translate3f(50, 0, 0)
				obs.obs_source_video_render(data.labels[name])
				obs.gs_matrix_pop()
			end
			obs.gs_matrix_translate3f(0, status_font_size, 0)
			items = items + 1
		end
		obs.gs_matrix_pop()
		obs.gs_matrix_translate3f(0, status_font_size * math.max(1, items), 0)
	end

	obs.gs_matrix_pop()

	obs.gs_blend_state_pop()
end

source_def.get_width = function(data)
	return status_width
end

source_def.get_height = function(data)
	return status_height
end

obs.obs_register_source(source_def)

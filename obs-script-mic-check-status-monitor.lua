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

local status_margin = 10
local status_width = 500
local status_height = 500
local status_font_size = 40
local status_indent = 100

local text_white = 0xffffffff
local text_yellow = 0xff44ffff
local text_gray = 0xffaaaaaa

dofile(script_path() .. "obs-script-mic-check-common.lua")

local function source_mute(calldata)
	--script_log("receive mute")
	local source = obs.calldata_source(calldata, "source")
	local status = audio_status(obs.obs_source_muted(source))
	local name = obs.obs_source_get_name(source)
	--script_log(name .. " " .. status .. " " .. obs.obs_source_get_id(source))
	local cache = audio_sources[name]
	if cache then
		cache.status = status
	else
		audio_sources[name] = {
			name = name,
			status = status,
		}
	end
end

local update_default_rule = function(calldata)
	script_log('receive default')
	local json = obs.calldata_string(calldata, 'rule_json')
	default_rule = deserialize_rule(json)
	dump_rule(default_rule)
end

local video_source_status = function(calldata)
	script_log('receive video status')
	local name = obs.calldata_string(calldata, 'name')
	local active = obs.calldata_bool(calldata, 'active')
	local in_current_scene = obs.calldata_bool(calldata, 'in_current_scene')
	video_sources[name] = {
		name = name,
		active = video_status(active),
		in_current_scene = in_current_scene,
	}
end

local trigger_activate = function(calldata)
	trigger_active = true
	trigger_time = obs.calldata_int(calldata, 'time')
	trigger_timeout = obs.calldata_int(calldata, 'timeout')
end

local alarm_activate = function()
	alarm_active = true
end

local alarm_reset = function()
	alarm_active = false
	trigger_active = false
end

local bootstrap = function()
	local sh = obs.obs_get_signal_handler()
	obs.signal_handler_signal(sh, "lua_mic_check_request_rules", nil)
	obs.remove_current_callback()
end

-- A function named script_description returns the description shown to
-- the user
-- luacheck: push no max line length
local description = [[OBS Source which visually displays mic check alarm status.

Add to your sources, it may be most usefull hidden and used with window projector so it is not visible on stream.

Displays the default rule and a section for each source with a attached settings filter. Only one set of rules is active at any given time, the associated rule set will have a colored bar.

Yellow audio sources indicated they are currently in violation of the rule.

A countup timer will be shown when a rule is triggered and the alarm will be activated soon. The entire source is red when the alarm is active.

Without obs-script-mic-check.lua functionality will be limited to list the sources with attached settings filters.]]
-- luacheck: pop
function script_description()
	return description
end

-- a function named script_load will be called on startup
function script_load(settings) -- luacheck: no unused args
	script_log("script status load")

	local sh = obs.obs_get_signal_handler()
	-- signals received
	obs.signal_handler_connect(sh, "source_activate", source_activate)
	obs.signal_handler_connect(sh, "source_deactivate", source_deactivate)
	obs.signal_handler_add(sh, "void lua_mic_check_source_mute(ptr source)")
	obs.signal_handler_connect(sh, "lua_mic_check_source_mute", source_mute)
	obs.signal_handler_add(sh, "void lua_mic_check_default_rule(string rule_json)")
	obs.signal_handler_connect(sh, "lua_mic_check_default_rule", update_default_rule)
	obs.signal_handler_add(sh, "void lua_mic_check_source_rule(int id, string rule_json)")
	obs.signal_handler_connect(sh, "lua_mic_check_source_rule", update_source_rule)
	obs.signal_handler_add(sh, "void lua_mic_check_video_source_status(string name, bool active, bool in_current_scene)")
	obs.signal_handler_connect(sh, "lua_mic_check_video_source_status", video_source_status)
	obs.signal_handler_add(sh, "void lua_mic_check_trigger_activate(int time, int timeout)")
	obs.signal_handler_connect(sh, "lua_mic_check_trigger_activate", trigger_activate)
	obs.signal_handler_add(sh, "void lua_mic_check_alarm_activate()")
	obs.signal_handler_connect(sh, "lua_mic_check_alarm_activate", alarm_activate)
	obs.signal_handler_add(sh, "void lua_mic_check_alarm_reset()")
	obs.signal_handler_connect(sh, "lua_mic_check_alarm_reset", alarm_reset)

	-- signals sent
	obs.signal_handler_add(sh, "void lua_mic_check_request_audio_sources()")
	obs.signal_handler_add(sh, "void lua_mic_check_request_rules()")

	obs.signal_handler_signal(sh, "lua_mic_check_request_audio_sources", nil)

	obs.timer_add(bootstrap, 1000)
end

local create_label = function(name, size, color)
	local settings = obs.obs_data_create()
	local font = obs.obs_data_create()

	obs.obs_data_set_string(font, "face", "Arial")
	obs.obs_data_set_int(font, "size", size * 0.90) -- freetype is larger than gdiplus

	obs.obs_data_set_obj(settings, "font", font)
	obs.obs_data_set_string(settings, "text", " " .. name .. " ")
	obs.obs_data_set_int(settings, "color", color) -- gdiplus
	obs.obs_data_set_int(settings, "color1", color) -- freetype
	obs.obs_data_set_int(settings, "color2", color) -- freetype

	obs.obs_enter_graphics();
	--local source = obs.obs_source_create_private("text_gdiplus", name .. "-label", settings)
	local source = obs.obs_source_create_private("text_ft2_source", name .. "-label", settings)
	obs.obs_leave_graphics();
	obs.obs_data_release(font)
	obs.obs_data_release(settings)

	return source
end

local set_label_text = function(source, text)
	local settings = obs.obs_source_get_settings(source)
	obs.obs_data_set_string(settings, "text", " " .. text .. " ")
	obs.obs_source_update(source, settings)
	obs.obs_data_release(settings)
end

local draw_label = function(data, key, name, size, color)
	if data.labels[key] == nil then
		script_log("create " .. key)
		data.labels[key] = create_label(name, size, color)
	end
	obs.obs_source_video_render(data.labels[key])
end

local data_paths = {
	"../../data/",
	"../data/",
}

local function image_source_load(image, file)
	for _,data in ipairs(data_paths) do
		obs.obs_enter_graphics();
		obs.gs_image_file_free(image);
		obs.obs_leave_graphics();

		obs.gs_image_file_init(image, data .. file);

		obs.obs_enter_graphics();
		obs.gs_image_file_init_texture(image);
		obs.obs_leave_graphics();

		if image.loaded then
			break
		end
	end

	if not image.loaded then
		print("failed to load texture " .. file);
	end
end

local source_def = {}
source_def.id = "lua_mic_check_status_source"
source_def.output_flags = bit.bor(obs.OBS_SOURCE_VIDEO, obs.OBS_SOURCE_CUSTOM_DRAW)

source_def.get_name = function()
	return "Mic Check Status Monitor"
end

source_def.create = function(source, settings) -- luacheck: no unused args
	script_log("source status create")
	local data = {
		labels = {},
		live_image = obs.gs_image_file(),
		mute_image = obs.gs_image_file(),
		height = status_height,
	}

	image_source_load(data.live_image, "obs-studio/themes/Dark/unmute.png")
	image_source_load(data.mute_image, "obs-studio/themes/Dark/mute.png")

	return data
end

source_def.destroy = function(data)
	if data == nil then
		return
	end

	obs.obs_enter_graphics();

	for key,_ in pairs(data.labels) do
		-- frequently deadlocks OBS when reloading (unloading in general?)
		--obs.obs_source_release(label)
		data.labels[key] = nil
	end

	obs.gs_image_file_free(data.live_image)
	obs.gs_image_file_free(data.mute_image)

	obs.obs_leave_graphics()
end

local function status_item(data, title, rule, controlling)
	local effect_default = obs.obs_get_base_effect(obs.OBS_EFFECT_DEFAULT)
	local effect_solid = obs.obs_get_base_effect(obs.OBS_EFFECT_SOLID)
	local color_param = obs.gs_effect_get_param_by_name(effect_solid, "color");

	local violation = run_rule(rule)
	local source = video_sources[rule.name]
	local in_current_scene = title == 'Default' or (source ~= nil and source.in_current_scene)
	local height = 0

	if controlling then
		if violation then
			obs.gs_effect_set_color(color_param, 0xff888800)
		else
			obs.gs_effect_set_color(color_param, 0xff008800)
		end
	elseif in_current_scene then
		obs.gs_effect_set_color(color_param, 0xff666666)
	else
		obs.gs_effect_set_color(color_param, 0xff777777)
	end
	while obs.gs_effect_loop(effect_solid, "Solid") do
		obs.gs_draw_sprite(nil, 0, status_width - status_margin*2, status_font_size)
	end
	local heading = title.."-white"
	local text_color = text_white
	if not in_current_scene then
		heading = title.."-gray"
		text_color = text_gray
	end
	if title then
		draw_label(data, heading, title, status_font_size, text_color)
	end
	obs.gs_matrix_translate3f(0, status_font_size, 0)
	height = height + status_font_size
	if rule.operator == 'any' or rule.operator == 'all' then
		if violation then
			draw_label(data, rule.operator..'-yellow', rule.operator, status_font_size, text_yellow)
		else
			draw_label(data, rule.operator..'-white', rule.operator, status_font_size, text_white)
		end
	end
	obs.gs_matrix_push()
	obs.gs_matrix_translate3f(status_indent, 0, 0)
	local items = 0
	for name,status in pairs(rule.audio_states) do
		local image = data.live_image
		if status == 'muted' then
			image = data.mute_image
		end

		obs.gs_matrix_push()
		obs.gs_matrix_translate3f(0.1 * status_font_size, 0.1 * status_font_size, 0)
		obs.gs_matrix_scale3f(0.8 * status_font_size / image.cy, 0.8 * status_font_size / image.cy, 0)
		while obs.gs_effect_loop(effect_default, "Draw") do
			obs.obs_source_draw(image.texture, 0, 0, image.cx, image.cy, false);
		end
		obs.gs_matrix_pop()

		obs.gs_matrix_push()
		obs.gs_matrix_translate3f(50, 0, 0)
		if audio_sources[name] ~= nil and audio_sources[name].status == status then
			draw_label(data, name..'-yellow', name, status_font_size, text_yellow)
		else
			draw_label(data, name..'-white', name, status_font_size, text_white)
		end
		obs.gs_matrix_pop()

		obs.gs_matrix_translate3f(0, status_font_size, 0)
		items = items + 1
	end
	obs.gs_matrix_pop()
	local offset = status_font_size * math.max(1, items)
	obs.gs_matrix_translate3f(0, offset, 0)
	height = height + offset
	return height
end

source_def.video_render = function(data, effect) -- luacheck: no unused args
	if data == nil then
		return
	end

	obs.gs_blend_state_push()
	obs.gs_reset_blend_state()

	local effect_solid = obs.obs_get_base_effect(obs.OBS_EFFECT_SOLID)
	local color_param = obs.gs_effect_get_param_by_name(effect_solid, "color");

	if alarm_active then
		obs.gs_effect_set_color(color_param, 0xffaa4444)
	else
		obs.gs_effect_set_color(color_param, 0xff444444)
	end
	while obs.gs_effect_loop(effect_solid, "Solid") do
		obs.gs_draw_sprite(nil, 0, status_width, data.height)
	end

	obs.gs_matrix_push()

	obs.gs_matrix_translate3f(status_margin, status_margin, 0)


	if trigger_active then
		local duration = os.difftime(os.time(), trigger_time)
		local progress = math.min(1, duration / trigger_timeout)
		obs.gs_effect_set_color(color_param, 0xffaa4444)
		while obs.gs_effect_loop(effect_solid, "Solid") do
			obs.gs_draw_sprite(nil, 0, (status_width - status_margin*2) * progress, status_font_size)
		end

		if data.labels['duration'] == nil then
			script_log("create duration")
			data.labels['duration'] = create_label('duration', status_font_size, text_white)
		end

		set_label_text(data.labels['duration'], string.format("%d", duration))
		obs.obs_source_video_render(data.labels['duration'])
	end

	obs.gs_matrix_translate3f(0, status_font_size, 0)
	local height = status_font_size

	local found_first_active = false

	for _,rule in pairs(source_rules) do
		local controlling = false
		local source = video_sources[rule.name]
		local title = rule.name
		if title == nil then
			title = "--"
		end
		if not found_first_active and rule.name then
			if source and source.active == 'active' then
				found_first_active = true
				controlling = true
			end
		end
		if source and source.in_current_scene then
			height = height + status_item(data, title, rule, controlling)
		end
	end

	for _,rule in pairs(source_rules) do
		local controlling = false
		local source = video_sources[rule.name]
		local title = rule.name
		if title == nil then
			title = "--"
		end
		if not found_first_active and rule.name then
			if source and source.active == 'active' then
				found_first_active = true
				controlling = true
			end
		end
		if not (source and source.in_current_scene) then
			height = height + status_item(data, title, rule, controlling)
		end
	end
	height = height + status_item(data, "Default", default_rule, not found_first_active)

	data.height = height + status_margin * 2

	obs.gs_matrix_pop()

	obs.gs_blend_state_pop()
end

source_def.get_width = function(data) -- luacheck: no unused args
	return status_width
end

source_def.get_height = function(data)
	return data.height
end

obs.obs_register_source(source_def)

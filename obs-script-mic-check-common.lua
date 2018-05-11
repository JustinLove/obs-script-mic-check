
alarm_active = false
trigger_active = false
trigger_time = os.time()
trigger_timeout = 0
obs_events = {}
audio_sources = {}
video_sources = {}
default_rule = {
	timeout = 5,
	operator = "all",
	audio_states = {
		["Mic/Aux"] = "muted"
	}
}
source_rules = {}

function dump_rule(rule)
	local items = {}
	for source,state in pairs(rule.audio_states) do
		table.insert(items, source .. "=" .. state)
	end
	script_log(rule.operator .. "(" .. table.concat(items, ",") .. ")")
end

function serialize_rule(rule)
	local data = obs.obs_data_create()
	local states = obs.obs_data_create()

	obs.obs_data_set_int(data, 'timeout', rule.timeout)
	obs.obs_data_set_string(data, 'operator', rule.operator)
	if rule.name then
		obs.obs_data_set_string(data, 'name', rule.name)
	end
	obs.obs_data_set_obj(data, 'audio_states', states)

	for name,state in pairs(rule.audio_states) do
		obs.obs_data_set_string(states, name, state)
	end

	local json = obs.obs_data_get_json(data)

	obs.obs_data_release(data)
	obs.obs_data_release(states)

	return json
end

function deserialize_rule(json)
	local data = obs.obs_data_create_from_json(json)
	local rule = {audio_states = {}}

	rule.timeout = obs.obs_data_get_int(data, 'timeout')
	rule.operator = obs.obs_data_get_string(data, 'operator')
	local name = obs.obs_data_get_string(data, 'name')
	if name ~= '' then
		rule.name = name
	end

	local states = obs.obs_data_get_obj(data, 'audio_states')

	for name,audio in pairs(audio_sources) do
		local state = obs.obs_data_get_string(states, name)
		if state ~= '' then
			rule.audio_states[name] = state
		end
	end

	obs.obs_data_release(data)
	obs.obs_data_release(states)

	return rule
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
					in_current_scene = false,
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

function source_active(calldata, source_active)
	local source = obs.calldata_source(calldata, "source")
	local active = video_status(source_active)
	local name = obs.obs_source_get_name(source)
	--script_log(name .. " " .. active .. " " .. obs.obs_source_get_id(source))
	local cache = video_sources[name]
	if cache then
		cache.active = active
	end
end

function source_activate(calldata)
	source_active(calldata, true)
end

function source_deactivate(calldata)
	source_active(calldata, false)
end



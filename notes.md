[obs-script-mic-check.lua] Starting hidden live scene 000080c9
[obs-script-mic-check.lua] Failed to call calldata_signal_callback for calldata_signal_callback: attempt to call a number value

- check actual volume levels to try and detect speaking into mute

- remaining deadlock
  - with video tick checks (before seeing if script has a video_tick)
  - removeing a script source context during reload
  - scene change on obs load
    - main thread: firing scene change event; obs_scene_find_source attempting to get video_mutex, holding script mutex
    - video thread: obs_lua_source_get_width; attempting to get script mutex, holding source definition_mutex, source filter_mutex, video_mutex, channels_mutex
  - video thread doing startup activation signals, while main thread is enumerating sources in source_create. conflict with script mutex (via signal) and sources mutex

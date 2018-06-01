- source name text width

- check actual volume levels to try and detect speaking into mute
- font/icon portabililty check
  - could depend on text-pango in a pinch

- remaining deadlock
  - with video tick checks (before seeing if script has a video_tick)
  - removeing a script source context during reload
  - scene change on obs load
    - main thread: firing scene change event; obs_scene_find_source attempting to get video_mutex, holding script mutex
    - video thread: obs_lua_source_get_width; attempting to get script mutex, holding source definition_mutex, source filter_mutex, video_mutex, channels_mutex
  - video thread doing startup activation signals, while main thread is enumerating sources in source_create. conflict with script mutex (via signal) and sources mutex

# OBS Mic Check Changelog

## 1.2.0

- Remove references to monitoring type, which was depreciated in OBS 33.
- Updated graphics API.
- Embedded mute/unmute images. OBS themes now use SVG, which can not be loaded by the graphics library.

## 1.1.0

- Only alarm if the audio source is sending to output; it can be active if monitoring is enabled.
- Unmute alarm on load

## 1.0.1

- Status monitor was trying to use source active status, but not actually reading the source active status
- Status monitor was not considering inactive sources as muted
- Rule evaluation was not considering inactive sources as muted

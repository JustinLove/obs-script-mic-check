# OBS Mic Check

Plays a audio alarm (media source) when [OBS Studio](https://obsproject.com/) Audio mute state does not match with displayed sources (BRB, Starting Soon, etc)

## Requirements

- [OBS Studio](https://obsproject.com/)

## Installation

There are three scripts which cooperate:

- obs-script-mic-check.lua: Core monitoring and script dialog settings, The other scripts expect to interact with this.
- obs-script-mic-check-source-settings-filter.lua: Provides a filter used to do per-source rules. Technically optional, though source-aware filters are a core feature.
- obs-script-mic-check-status-monitor.lua: Provides a custom source that displays which sources have attached rules filters, and the status of the alarm triggers. Intended primarily for window projector. Optional.

## Usage

Add a media source for the alarm. A suitable sound file is provided with the script. Open Advanced Audio Properties for the source and change Audio Monitoring to Monitor Only (mute output).

Add a copy of the alarm source to every scene where you want to hear it.

Attach rules to video sources ("BRB", "Starting Soon", etc) using the "Mic Check Settings" filter. (Right-click on a source and select filters.) The first active video source with attached settings will be used to trigger alarms instead of the defaults.

If no such video source is active, then the default rules on the script dialog will be used.

## Credits

Alert sounds: [`pup_alert.mp3`](https://freesound.org/people/willy_ineedthatapp_com/sounds/167337/) by `willy_ineedthatapp_com`

# Changelog

## 1.0.0 — 2026-11-19

First public release.

- Keeps output, system sounds and microphone on your USB headphones and restores the sample rate if an app changes it.
- Automatically detects apps that connect to the headphones' USB device (no built-in list).
- Pauses interfering apps (never closes them) while the headphones reconnect; the pause never lasts longer than 30 seconds.
- Optional strict mode that also pauses all Chromium/Electron apps.
- Works with any USB headphones ("Auto (USB)") or a specific device.
- Menu bar panel in English and Russian, switchable in the app.
- Universal build for Apple Silicon and Intel, macOS 13+.

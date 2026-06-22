# Roadmap

## Phase 1: Core + CLI

- Enumerate online displays.
- Identify built-in vs external displays.
- Provide user-friendly control status.
- Implement software dimming fallback.
- Add JSON output for automation.

## Phase 2: Hardware Brightness

- Add DDC/CI backend over IOKit framebuffer I2C.
- Probe brightness read/write support safely.
- Cache working backend per display.
- Add monitor quirk profiles for retry delays and unsupported commands.

## Phase 3: Menu-Bar App

- SwiftUI/AppKit status item.
- Display sliders.
- Global slider.
- Sync-all toggle.
- Launch-at-login support.

## Phase 4: Keyboard Brightness

- Capture brightness keys with Accessibility permission.
- Route changes to the display under cursor or all synced displays.
- Show native-feeling OSD.

## Phase 5: Compatibility UX

- One-line fixes for blocked hardware control.
- Local compatibility profile database.
- Optional anonymous compatibility report export.

## Phase 6: Advanced Backends

- Vendor/network control for smart monitors.
- Overlay dimming fallback.
- LumenBridge for DisplayLink, bad docks, and impossible DDC paths.
- Shortcuts, CLI JSON API, and local HTTP/MCP integration.

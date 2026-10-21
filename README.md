# Keyboard Backlight

An Omarchy shell plugin for ThinkPad keyboard backlights.

- Hides the bar icon when the backlight is off.
- Uses the theme’s normal foreground color at Low or High brightness.
- Left-click opens the Off / Low / High picker; right-click cycles levels.
- Optional day/night scheduling continues while the icon is hidden.
- Detects compatible Linux `*kbd_backlight*` LED devices automatically.

The plugin waits for events instead of polling session or display state.
It subscribes to Wayland output-power notifications, Omarchy's lock-state
journal messages, and the kernel's keyboard LED notifications (when available).
Use your keyboard backlight key to turn lighting on manually while the icon
is hidden, or let the schedule turn it on.

Locking the session or turning off all enabled displays forces the keyboard
backlight off, even with scheduling disabled. The backlight stays off if session
state cannot be read. Losing the event subscription disables automatic lighting
until reload, including when an older state read completes afterward. A failed
brightness write stops automatic writes; use the manual brightness controls to
retry once, or reload the plugin. There is no polling fallback or automatic
retry. With multiple monitors, one awake display is
sufficient while the session is unlocked.
When unlocked with a display awake again, the current schedule is reapplied,
including when the scheduled hour passed while locked. With scheduling disabled,
the backlight remains off until you turn it on manually.

## Install

Requires Omarchy with shell plugin support, `brightnessctl`, and a compatible
keyboard backlight device. Session detection uses `omarchy-shell`, `hyprctl`,
`jq`, and `timeout` (included with Omarchy).
The event subscriber requires the Wayland output-power protocol, access to the
current user's journal, and `cc`, `pkg-config`, `wayland`, and `systemd` to build
its small native helper. On first use (and after its source changes), the helper
is compiled once into `~/.cache/keyboard-backlight/`.

```bash
omarchy plugin add https://github.com/pomartel/keyboard-backlight.git --enable --yes
```

The plugin can also be dragged into the collapsible tray.

Lock notifications currently follow the native Omarchy lock's `lock-requested`,
`session-locked`, `secure`, and `unlocked` journal messages. Other lockers are not
supported. The journal listener filters out authentication and fingerprint chatter.

## Schedule

Scheduling is disabled by default. When enabled, the defaults are Low at
20:00 and Off at 07:00. Configure it in the panel or with:

```bash
omarchy bar set keyboard-backlight scheduleEnabled true --json
omarchy bar set keyboard-backlight nightStartHour 18 --json
omarchy bar set keyboard-backlight dayStartHour 7 --json
```

A one-shot timer targets the next configured day/night transition, then arms
the following one. No periodic clock checks run. While the session is blocked,
the timer is stopped; unlocking with a display awake reapplies the current
period and arms the next transition. Changing the settings also recalculates
the deadline. System clock steps and changes to `/etc/localtime` or
`/etc/timezone` also recalculate the deadline using kernel notifications, without
periodic checks. A transition that is already due is applied before rearming.
Equal day/night hours mean permanent night mode, without a timer.
Session state is read once when subscribing, then only in response to events
or just before an explicit lighting action.

## Tests

Run `node --test tests/*.test.cjs` for session detection, guarded writes,
scheduling, clock notifications, and process-race regression tests. QML
integration tests use an isolated offscreen shell with mock hardware commands
(and require a local Omarchy/Quickshell installation). Clock tests simulate a
kernel cancellation and use temporary timezone files. The tests do not change
hardware state or the system clock.

## Credits

Based on [ThinkPad Keyboard Backlight](https://github.com/alexanderpuschkinberlin/omarchy-keyboard-backlight)
by Alexander Puschkin. Distributed under the original MIT license.

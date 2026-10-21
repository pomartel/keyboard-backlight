# Keyboard Backlight

An Omarchy shell plugin for ThinkPad keyboard backlights.

- Hides the bar icon when the backlight is off.
- Uses the theme’s normal foreground color at Low or High brightness.
- Left-click opens the Off / Low / High picker; right-click cycles levels.
- Optional day/night scheduling continues while the icon is hidden.
- Detects compatible Linux `*kbd_backlight*` LED devices automatically.

The plugin polls every second. Use your keyboard backlight key to turn
lighting on manually while the icon is hidden, or let the schedule turn it on.

Locking the session or turning off all enabled displays forces the keyboard
backlight off, even with scheduling disabled. Detection normally takes up to
one second. The backlight stays off if session state cannot be read. With
multiple monitors, one awake display is sufficient while the session is unlocked.
When unlocked with a display awake again, the current schedule is reapplied,
including when the scheduled hour passed while locked. With scheduling disabled,
the backlight remains off until you turn it on manually.

## Install

Requires Omarchy with shell plugin support, `brightnessctl`, and a compatible
keyboard backlight device. Session detection uses `omarchy-shell`, `hyprctl`,
`jq`, and `timeout` (included with Omarchy).

```bash
omarchy plugin add https://github.com/pomartel/keyboard-backlight.git --enable --yes
```

The plugin can also be dragged into the collapsible tray.

## Schedule

Scheduling is disabled by default. When enabled, the defaults are Low at
20:00 and Off at 07:00. Configure it in the panel or with:

```bash
omarchy bar set keyboard-backlight scheduleEnabled true --json
omarchy bar set keyboard-backlight nightStartHour 18 --json
omarchy bar set keyboard-backlight dayStartHour 7 --json
```

## Tests

Run `node --test tests/session.test.cjs` for session detection, guarded writes,
and lock/wake scheduling regression tests. The tests do not change hardware state.

## Credits

Based on [ThinkPad Keyboard Backlight](https://github.com/alexanderpuschkinberlin/omarchy-keyboard-backlight)
by Alexander Puschkin. Distributed under the original MIT license.

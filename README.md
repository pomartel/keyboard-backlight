# Keyboard Backlight

An Omarchy shell plugin for ThinkPad keyboard backlights.

- Hides the bar icon when the backlight is off.
- Uses the theme’s normal foreground color at Low or High brightness.
- Left-click opens the Off / Low / High picker; right-click cycles levels.
- Optional day/night scheduling continues while the icon is hidden.
- Detects compatible Linux `*kbd_backlight*` LED devices automatically.

The plugin polls every five seconds. Use your keyboard backlight key to turn
lighting on manually while the icon is hidden, or let the schedule turn it on.

## Install

Requires Omarchy with shell plugin support, `brightnessctl`, and a compatible
keyboard backlight device.

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

## Credits

Based on [ThinkPad Keyboard Backlight](https://github.com/alexanderpuschkinberlin/omarchy-keyboard-backlight)
by Alexander Puschkin. Distributed under the original MIT license.

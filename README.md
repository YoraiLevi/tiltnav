# tiltnav

Turn a mouse wheel's **horizontal tilt** into a keystroke on macOS, chosen per application.

Tilt left goes Back, tilt right goes Forward — in local Mac apps, and inside remote-desktop
sessions where side buttons do not survive the trip.

## Why this exists

A tilt wheel does not send a mouse button. It sends **horizontal scroll**. That single fact rules
out the obvious tools:

- **Karabiner-Elements** cannot see it at all. Its `from` accepts `key_code`,
  `consumer_key_code` and `pointing_button` — horizontal scroll is none of them. Karabiner remains
  the right place for every real mouse *button*; tiltnav deliberately never touches buttons.
- **Vendor mouse software** can bind the tilt to a keystroke, but the keystroke it synthesizes is
  rejected by Microsoft's Windows App (`com.microsoft.rdc.macos`), which drops the modifier and
  leaves you with a bare arrow key.
- **Jump Desktop** cannot forward mouse buttons 4/5 at all in shipping builds, so moving the
  function to a thumb button is not a workaround there either.

tiltnav does one thing: it watches horizontal scroll, works out which application is frontmost,
and emits a key chord that the frontmost application actually honours.

## What makes the keystroke work

Emitting `⌥←` is not enough. Windows App accepts a synthesized key only when it looks like real
hardware:

- event source `hidSystemState`
- a monotonic timestamp
- a non-zero `keyboardEventKeyboardType`, read from the event source
- **device-specific modifier masks** (`NX_DEVICELALTKEYMASK` and friends) alongside the generic
  `CGEventFlags` — with the generic mask alone, the key arrives and the modifier does not
- modifiers delivered as real `flagsChanged` events
- posted at `kCGHIDEventTap`

This recipe is derived from [LinearMouse](https://github.com/linearmouse/linearmouse) (MIT).

Scoping uses `NSWorkspace.frontmostApplication`, which keeps working when an app is **full
screen**. Tools that hit-test the window under the pointer instead lose per-app scoping in full
screen — that limitation is the reason this program was written rather than configured.

## Requirements

- macOS 13 or later (developed on macOS 26, Apple Silicon)
- Xcode command line tools (`swiftc`)
- An Accessibility grant, because a modifying event tap requires one

## Build and install

```sh
git clone https://github.com/YoraiLevi/tiltnav.git
cd tiltnav
./build.sh
```

That compiles `tiltnav.swift`, installs `~/Applications/Tiltnav.app`, ad-hoc signs it, and links
`~/.local/bin/tiltnav`.

Then:

1. `open -a Tiltnav` — a `⇄` appears in the menu bar.
2. The icon will be a warning triangle until Accessibility is granted. Click it and choose
   **Open Accessibility Settings…**, then add `~/Applications/Tiltnav.app` and switch it on.
3. `tiltnav --status` — expect `state: healthy`, `self-test PASSED`, exit code `0`.
4. Turn on **Start at Login** from the menu if you want it after a reboot.

### Re-granting after a rebuild

An ad-hoc signature pins the Accessibility grant to the binary's **cdhash**, so every rebuild
silently revokes it while the System Settings row still looks ticked. tiltnav detects this and
says which of the two happened:

```
THE APP WAS REBUILT since the grant (stored 14c47dd7… ≠ current 594f160d…)
```

The fix is always: **remove the existing Tiltnav entry** in Accessibility (select it, click `−`),
then add the app again. Adding it without removing the stale row does not work.

A Developer ID signature would make the grant identity-based and survive rebuilds. Ad-hoc signing
is the tradeoff for not requiring a paid certificate.

## Configuration

`~/.config/tiltnav.json`. Hand-edited — **tiltnav never writes it**, except to create a starter
file if it is missing. Saving the file reloads it within two seconds; a file that fails to parse
is rejected and the last good configuration stays live.

```json
{
  "debounceSeconds": 0.3,
  "discreteWheelOnly": true,
  "default": {
    "tiltLeft":  ["command", "["],
    "tiltRight": ["command", "]"]
  },
  "apps": {
    "com.microsoft.rdc.macos": {
      "tiltLeft":  ["option", "arrowLeft"],
      "tiltRight": ["option", "arrowRight"]
    },
    "com.mitchellh.ghostty": "passthrough"
  }
}
```

- `tiltLeft` / `tiltRight` are **physical** tilt directions. You never reason about the sign of a
  scroll delta. If they come out swapped for your hardware, use **Swap tilt directions** in the
  menu; the choice is saved and reported by `--status`.
- A chord is an array whose **last element is the key** and whose earlier elements are modifiers
  (`command`, `option`, `control`, `shift`).
- `"passthrough"` leaves real horizontal scrolling alone for that app — use it for spreadsheets
  and terminals.
- `debounceSeconds` collapses the repeats a held tilt produces into one action.
- `discreteWheelOnly` (default `true`) keeps the **trackpad** out of this. A two-finger
  horizontal swipe arrives as the same `scrollWheel` event a wheel tilt does, so without this
  filter a slight sideways drift while scrolling navigates Back. macOS marks a trackpad's
  scroll *continuous* — pixel-precise and phased — and a notched wheel *discrete*; tiltnav acts
  only on the discrete ones and passes the rest through untouched. `--status` counts what it
  declined, so a mouse that is simply not being heard never looks like a swipe being ignored.
  Set it to `false` only for a high-resolution wheel that reports itself continuous — and accept
  that the trackpad then fires chords too.
- Unknown keys or modifiers are rejected per entry and named in `--status`, rather than being
  silently ignored.

Why `⌘[` locally but `⌥←` remotely: `⌘[` is Back in Mac browsers and Finder, while remote-desktop
clients deliver Mac **Option** to the guest as **Alt**, making `⌥←` into Windows' `Alt+Left`.

### Finding a bundle identifier

Focus the app, then use **Copy mapping snippet for this app** in the tiltnav menu and paste it
into the `apps` object. Or `osascript -e 'id of app "Safari"'`.

## Usage

Everything lives in the menu bar item. The icon has four distinct shapes so state is legible at a
glance:

| Icon | State |
|---|---|
| `⇄` arrows | healthy |
| arrows with a slash, dimmed | paused |
| warning triangle | **deaf** — running but not seeing events |
| arrows in a circle | degraded, or a configuration problem |

The menu shows the mapping that applies to the **frontmost** app, live counters, the calibration,
and every problem state links to its own fix.

### Command line

```sh
tiltnav --status      # ask the running process; see below
tiltnav --uninstall   # remove app, agent, config, state and log (prompts first)
tiltnav --help
```

`--status` talks to the running process over a Unix socket rather than reading a file, so it
cannot report a healthy tool that has actually stopped working:

```
tiltnav 1.1   cdhash 594f160d…  built 2026-09-20
  state       : healthy
  process     : running, pid 90286, up 0h9m
  launched by : launchd (com.m5air.tiltnav)
  permissions : Accessibility GRANTED
  tap         : created at HID point, enabled
  proof       : self-test PASSED 2026-09-20 17:21:19 (round-trip 1ms)
  activity    : 412 horizontal-scroll events seen, 118 chords sent, 294 passthrough
  calibration : deltaAxis2 -1 = tiltLeft (calibrated)
  at login    : enabled
  frontmost   : com.p5sys.jump.mac.viewer → tilt← ⌥←   tilt→ ⌥→  (override)
```

Exit codes, so a check script can branch without parsing prose:

| Code | Meaning |
|---|---|
| 0 | healthy |
| 1 | deaf — running but not functioning |
| 2 | configuration problem, running on last-good config |
| 3 | not running |
| 4 | paused deliberately |
| 5 | degraded |

`paused` is deliberately **not** `0`: a check must not report green on a tool that was switched
off weeks ago.

### The self-test, and what it does not prove

`proof:` is the only line permitted to make the icon green. tiltnav posts a synthetic horizontal
scroll tagged with a magic value and requires its own callback to receive it. A tap that exists
but delivers nothing therefore reads as **deaf**, not as healthy.

**It only proves the inbound half.** Nothing inside the process can prove that an emitted `⌥←`
was *accepted* by the target application — a keystroke can be delivered to a remote-desktop client
and silently discarded. No green light will ever claim otherwise; only your own keypress can.

## Logging

`~/Library/Logs/tiltnav.log`, written by the process itself so it records however the app was
started. Quiet by default: startup, configuration changes, tap problems, state changes. Turn on
**Watch tilts in the log** from the menu to log every event while debugging.

## Uninstall

```sh
tiltnav --uninstall
```

Removes the app, the LaunchAgent, the config, the state directory and the log. It cannot remove
the Accessibility entry — delete that yourself in System Settings › Privacy & Security ›
Accessibility.

## Scope, and what will not be added

tiltnav handles **horizontal scroll only**. Mouse buttons belong in Karabiner-Elements, which
already does them properly in every application including full-screen remote-desktop sessions.
Keeping that boundary is the point: a second tool with overlapping responsibility is how input
configuration becomes unmaintainable.

Also declined: a GUI configuration editor, which would make tiltnav a second writer of a
hand-edited file.

## Credits

Key-injection technique from [LinearMouse](https://github.com/linearmouse/linearmouse) (MIT).

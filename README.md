# edid-override

A small, self-contained replacement for BetterDisplay's **custom EDID** feature on
Apple Silicon.

It applies a 128-byte EDID directly to the display's `DCPAVServiceProxy` through
the private `IOAVServiceSetVirtualEDIDMode` API, then selects the resulting mode
with CoreGraphics. No privileged helper and no `/Library/Displays` override is
required.

This exists because a KVM in front of the monitor does not return an EDID, so
macOS only sees 1920x1080 instead of the monitor's 2560x1080 mode. The built-in
EDID in this repo is for the author's **UW 2560x1080** (vendor `DNS` / `0x11d3`,
product `0x0a80`, DTD 2560x1080@59.98).

## Build

```sh
make
```

Requires macOS with the Command Line Tools (clang + SDK). The binary is
`./edid-override`.

## Quick start

Inspect what macOS currently sees (read-only):

```sh
./edid-override list
./edid-override status --all-modes
./edid-override edid-info
```

Preview the apply without touching the display:

```sh
./edid-override apply --dry-run
```

Apply the EDID and select 2560x1080 @ 60 Hz, HiDPI off:

```sh
./edid-override apply
```

The apply causes the display to renegotiate; expect a brief flicker or blank.

Reset back to the factory EDID:

```sh
./edid-override reset
```

Keep it applied after display reconnects, KVM switches, sleep/wake, and login:

```sh
./edid-override watch
```

Install that watcher as a LaunchAgent:

```sh
./edid-override install-agent
```

Remove it:

```sh
./edid-override uninstall-agent
# also delete the copied binary/EDID:
./edid-override uninstall-agent --purge
```

Logs for the agent go to `~/Library/Logs/edid-override.log`.

## Why the override is volatile

`IOAVServiceSetVirtualEDIDMode` injects the EDID into the live display service.
It is not persisted. When the display is unplugged, the KVM switches away, or
the machine wakes, macOS may re-read the KVM's (missing) EDID and fall back to
1920x1080. `watch` polls for that condition and re-applies the EDID; it also
listens for CoreGraphics display reconfiguration and system wake notifications.

`install-agent` copies the binary and EDID to
`~/Library/Application Support/EDIDOverride/` and installs
`~/Library/LaunchAgents/local.edid-override.plist`, so the watcher keeps working
even if the repo is moved.

If BetterDisplay is still installed, quit it (or disable its custom EDID and
auto-apply settings) before relying on this tool. Two programs trying to own the
same display EDID will fight each other.

## How it works

1. Find the external `DCPAVServiceProxy` in the IORegistry.
2. `IOAVServiceCreateWithService()` on that node.
3. `IOAVServiceSetVirtualEDIDMode(service, &mode, edid)` with `mode = 1` and the
   128-byte EDID as `CFData`.
4. Wait for the new mode to appear, then `CGDisplaySetDisplayMode()` to select
   2560x1080 @ 60 Hz with HiDPI off.
5. Reset uses `IOAVServiceSetVirtualEDIDMode(service, NULL, NULL)`.

The same call sequence was recovered from BetterDisplay 5.2.1 (build 54014):
the apply call site passes a pointer to `uint32_t 1` plus a `CFDataRef`, and the
reset call site passes `NULL, NULL`.

## Options

```
--edid <base64|hex|path>    EDID to apply (default: built-in UW 2560x1080)
--edid-file <path>          Read EDID from a file (base64, hex, or raw)
--location <name>           DCPAVServiceProxy location (default: External)
--display-id <id>           CGDirectDisplayID (default: match EDID vendor/product)
--width <n>                 Mode width (default: 2560)
--height <n>                Mode height (default: 1080)
--refresh <hz>              Mode refresh rate (default: 60)
--hidpi                     Select a HiDPI mode (default: off)
--no-mode                   Apply EDID only; do not set a display mode
--dry-run                   Show what apply would do
--all-modes                 List every mode
--interval <seconds>        watch poll interval (default: 3)
```

Examples:

```sh
# Use a different EDID file
./edid-override apply --edid-file edids/uw-2560x1080.b64

# Target a specific CG display
./edid-override apply --display-id 3

# Apply only; leave the current mode alone
./edid-override apply --no-mode

# Watch a different mode
./edid-override watch --width 2560 --height 1080 --refresh 59.98
```

## Legacy `/Library/Displays` plist

`legacy-plist` generates the old-style override plist. On Apple Silicon this
file is generally ignored by the display stack (which is why the existing
BetterDisplay plist in `/Library/Displays/Contents/Resources/Overrides/` does not
produce 2560x1080 modes on this machine). It is included only as a fallback for
Intel Macs or older macOS versions.

```sh
./edid-override legacy-plist --vendor 0 --product 0 --out /tmp/DisplayProductID-0
```

Writing it into `/Library/Displays` requires root and is not done automatically.

## Safety

- Applying an EDID renegotiates the display. Save your work and expect a
  flicker.
- If the display ends up in a bad state, run `./edid-override reset`, unplug and
  replug the display, or reboot.
- The tool only touches the external `DCPAVServiceProxy` by default. It does not
  modify BetterDisplay, its preferences, or any system files.
- No sudo, SIP change, or code-signing entitlement is needed for the runtime
  EDID injection.

## Layout

```
src/main.m                 CLI, EDID parsing, IOAVService calls, watcher
edids/uw-2560x1080.b64     The 128-byte EDID (base64)
Makefile                   Build
```

## License

MIT

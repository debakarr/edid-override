# edid-override

Apply a custom EDID to an external display on macOS, without a privileged
helper or a `/Library/Displays` override.

`edid-override` talks to the display's `DCPAVServiceProxy` through the private
`IOAVServiceSetVirtualEDIDMode` API, then selects the resulting mode with
CoreGraphics. It is useful when a KVM, dock, or adapter does not pass the
monitor's EDID and macOS falls back to a lower resolution.

> This is an independent project. It is not affiliated with Apple or
> BetterDisplay. The private API used here is undocumented and may change or be
> removed in a future macOS release.

## Why

Some KVMs, docking stations, and adapters do not forward the display's EDID.
macOS then sees a generic display and offers only fallback modes — for example
1920x1080 instead of 2560x1080. Injecting the EDID at runtime restores the modes
the panel actually supports.

The override is volatile. It is lost when the display is unplugged, the KVM
switches away, or the machine wakes. `watch` re-applies it automatically.

## Requirements

- macOS on Apple Silicon (tested on macOS 27)
- Xcode Command Line Tools (clang + SDK)
- An external display that macOS can see

## Build

```sh
make
```

The binary is `./edid-override`. To install it into `~/.local/bin`:

```sh
make install
```

## Quick start

Inspect the current display and mode list (read-only):

```sh
./edid-override list
./edid-override list --all-modes
./edid-override edid-info
```

Preview an apply without touching the display:

```sh
./edid-override apply --dry-run
```

Apply the example EDID and select 2560x1080 @ 60 Hz, HiDPI off:

```sh
./edid-override apply --edid-file edids/uw-2560x1080.b64
```

The display renegotiates, so expect a brief flicker or blank screen.

Reset back to the factory EDID:

```sh
./edid-override reset
```

Keep the EDID applied across display reconnects, KVM switches, sleep/wake, and
login:

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
# also delete the copied binary and EDID:
./edid-override uninstall-agent --purge
```

Agent logs are written to `~/Library/Logs/edid-override.log`.

## Using your own EDID

The repository ships an example EDID for a UW 2560x1080 panel
(vendor `DNS` / `0x11d3`, product `0x0a80`, DTD 2560x1080@59.98). Do not apply
it to a different display.

Pass your own EDID as a raw binary, base64, or hex file:

```sh
./edid-override apply --edid-file /path/to/your-display.edid
./edid-override apply --edid-file /path/to/your-display.b64
```

You can also pass base64 or hex directly:

```sh
./edid-override apply --edid "AP///////w..."
```

Validate an EDID before applying it:

```sh
./edid-override edid-info --edid-file /path/to/your-display.edid
```

The tool accepts 128-byte EDID blocks (and 256-byte extensions) and checks the
header and checksums.

## How it works

1. Find the external `DCPAVServiceProxy` in the IORegistry.
2. Create an `IOAVService` for that node with `IOAVServiceCreateWithService()`.
3. Call `IOAVServiceSetVirtualEDIDMode(service, &mode, edid)` with `mode = 1`
   and the EDID as `CFData`.
4. Wait for the new mode to appear, then select it with
   `CGDisplaySetDisplayMode()`.
5. Reset uses `IOAVServiceSetVirtualEDIDMode(service, NULL, NULL)`.

The same private call sequence is used by other custom-EDID tools. This project
contains an independent implementation and does not modify or bypass any other
application.

## Auto-apply

`watch` does three things:

- checks the external display every few seconds;
- listens for CoreGraphics display reconfiguration and system wake;
- re-applies the EDID and target mode when the mode disappears.

`install-agent` copies the binary and EDID to
`~/Library/Application Support/EDIDOverride/` and installs
`~/Library/LaunchAgents/local.edid-override.plist`. The agent runs as your user
and starts at login.

Do not run another custom-EDID tool at the same time. Two programs trying to own
the same display EDID can fight each other.

Check the agent:

```sh
launchctl print gui/$(id -u)/local.edid-override
tail -f ~/Library/Logs/edid-override.log
```

After rebuilding, rerun `./edid-override install-agent` so the installed copy is
updated.

## Options

```
--edid <base64|hex|path>    EDID to apply (default: built-in example)
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
# Target a specific CG display
./edid-override apply --display-id 3

# Apply the EDID but leave the current mode alone
./edid-override apply --no-mode

# Watch a 59.98 Hz mode
./edid-override watch --refresh 59.98
```

## Legacy `/Library/Displays` plist

`legacy-plist` generates the old-style display override plist. On Apple Silicon
this file is generally ignored by the display stack, so it is included only as a
fallback for Intel Macs or older macOS versions.

```sh
./edid-override legacy-plist --vendor 0 --product 0 --out /tmp/DisplayProductID-0
```

Writing it into `/Library/Displays` requires root and is not done automatically.

## Troubleshooting

**`no External DCPAVServiceProxy found`**

The external display is not connected or the KVM is switched away. Connect it
and run `./edid-override list` again.

**`IOAVServiceSetVirtualEDIDMode failed: 0x...`**

The private API may not be available on this macOS version, or the service is in
an unexpected state. Reconnect the display and try `./edid-override reset`
first.

**EDID applies but the mode does not appear**

Run `./edid-override edid-info --edid-file <file>` to check the EDID. Confirm the
requested width, height, and refresh rate with `./edid-override list
--all-modes`. Some EDIDs expose 59.98 Hz rather than 60.00 Hz; the default
tolerance accepts both.

**The agent is not running**

```sh
launchctl print gui/$(id -u)/local.edid-override
tail -50 ~/Library/Logs/edid-override.log
```

Reinstall with `./edid-override install-agent` if the plist or copied binary is
missing.

## Safety

- Applying an EDID renegotiates the display. Save your work and expect a
  flicker.
- A wrong EDID can leave a display in an unusable mode. If that happens, run
  `./edid-override reset`, unplug and replug the display, or reboot.
- The tool only touches the external `DCPAVServiceProxy` by default. It does not
  modify any application, its preferences, or system files.
- No sudo, SIP change, or code-signing entitlement is needed for the runtime
  EDID injection.
- Use this at your own risk. There is no warranty.

## Layout

```
src/main.m                 CLI, EDID parsing, IOAVService calls, watcher
edids/uw-2560x1080.b64     Example 128-byte EDID (base64)
Makefile                   Build
```

## License

MIT. See [LICENSE](LICENSE).

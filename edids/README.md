# EDID files

`uw-2560x1080.b64` is an **example** EDID for a 2560x1080 ultrawide panel:

- manufacturer: `DNS` (`0x11d3`)
- product: `0x0a80`
- preferred timing: 2560x1080 @ 59.98 Hz

Do not apply it to a different display. Use `edid-override apply --edid-file`
with an EDID dumped from your own monitor instead.

The tool accepts:

- raw 128-byte (or 256-byte) EDID binary files
- base64 text files
- hex text files

Validate a file before applying it:

```sh
./edid-override edid-info --edid-file path/to/edid.bin
```

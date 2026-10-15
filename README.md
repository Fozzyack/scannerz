# Scannerz

A lightweight Linux CLI that actively discovers IPv4 devices on a local network
using `arp-scan`. Prints IP addresses, MAC addresses, and vendor names after each
scan. Only scan networks you own or have permission to scan.

## Requirements

- Zig 0.17.0 (the standard-library API used by this project).
- `arp-scan` installed and available on `PATH` (for example, `sudo apt install arp-scan`
  on Debian/Ubuntu).
- Raw-packet permissions. The examples use `sudo`; alternatively, use the
  least-privilege setup recommended by your distribution's `arp-scan` package.

## Build and run

```sh
zig build
ip -br addr
sudo ./zig-out/bin/scannerz --interface wlp0s20f3 --once
sudo ./zig-out/bin/scannerz --interface wlp0s20f3 --interval 30s
```

Replace `wlp0s20f3` with your connected Ethernet or Wi-Fi interface. The interface
is required; it is not hardcoded or automatically selected.

Options:

| Option | Meaning |
| --- | --- |
| `-i`, `--interface NAME` | Interface whose local IPv4 network to scan |
| `-t`, `--interval TIME` | Positive integer with `ms`, `s`, `m`, or `h`; default `30s` |
| `--once` | Scan once and exit |
| `-h`, `--help` | Print usage |

Scans run immediately, then wait the interval **after completion** before starting
again; they never overlap. Each scan frees its temporary memory. An initial
failure exits nonzero so setup problems are visible; later failures are logged
and retried at the chosen interval. Press Ctrl+C to stop foreground monitoring.
An empty successful scan reports zero responding devices.

`zig build run` prints usage; use the compiled executable for active scans.

## Run in the background

Build as your normal user, then launch the compiled executable:

```sh
sudo -v
sudo -n nohup ./zig-out/bin/scannerz --interface wlp0s20f3 --interval 1m >scannerz.log 2>&1 &
echo $!
```

The printed PID is the background job's PID. Inspect output with
`tail -f scannerz.log`. To stop it, use `sudo kill PID` (replace `PID` with the
printed number). Check that it stopped with `ps -p PID`. If your sudo setup wraps
the command in a separate process, find the scanner's PID with
`pgrep -a -x scannerz` and stop that PID. Never put `sudo` in the per-scan command:
an unattended password prompt would interrupt monitoring.

For unattended operation across reboots, configure a service manager such as
systemd instead of relying on a terminal background job.

## Limitations

- ARP discovery covers IPv4 on the selected local network segment, not IPv6 or
  devices behind routers.
- A non-response does not prove a device is offline. Sleeping devices and network
  isolation can prevent responses. Vendor identification may be unknown.
- Output is a fresh snapshot each time, not a persistent device inventory.
- `arp-scan` stderr is preserved, including warnings about vendor databases.

## Tests

```sh
zig build test
```

Unit tests cover duration parsing, command-line validation, and device-row parsing;
they do not send network traffic.

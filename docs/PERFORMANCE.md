# Performance and Startup Baseline

This document records what FluorineOS starts, what it keeps resident, and why.
It exists so a later change that adds work back to the boot path or to a polling
loop shows up in review instead of being discovered as a slow machine.

Two labels are used throughout:

- **Measured** means a number produced by a command, with the command and the
  machine reported here.
- **Anticipated** means a change whose effect follows from the design (a daemon
  that is no longer started, a timer that no longer fires) but that has not been
  timed on FluorineOS hardware. Nothing in this document claims a stopwatch
  improvement that was not actually run.

No ISO was built, no image was booted, and no target hardware was available for
this pass. Every statement about the installed system is static: it comes from
the configuration in this repository and from the Debian trixie package contents
fetched from `deb.debian.org` and inspected (unit files, `[Install]` sections,
maintainer scripts, `/etc/default` files).

## How the numbers in this document were produced

Micro-benchmarks of the two Waybar poll commands ran on a Debian trixie userland
in WSL2 (`Linux 6.18.33.2-microsoft-standard-WSL2`, 12 vCPU), 100 runs each,
scripts copied to the local filesystem:

| Command | Cost per call |
| --- | --- |
| `bash -c :` (fork baseline) | 1795 us |
| `flr-mode status` | 2464 us |
| `flr-power waybar` (stub `powerprofilesctl`) | 3539 us |

A real `powerprofilesctl get` adds a D-Bus round trip, roughly another 1-3 ms.
These are the only timings in this document; everything else is reasoning from
what the unit files and scripts do.

## What runs at boot

| Unit | Purpose | State |
| --- | --- | --- |
| `NetworkManager.service` | Network links and Wi-Fi | enabled |
| `bluetooth.service` | Bluetooth stack | enabled |
| `greetd.service` | Session login on vt 7 | enabled |
| `ufw.service` | Applies the firewall policy (one-shot) | enabled |
| `power-profiles-daemon.service` | Backs `flr-power` and the Waybar power module | enabled |
| `avahi-daemon.service` | mDNS printer discovery and `.local` names | enabled |
| `cups.socket` | Printing, started on the first request | enabled |
| `cups.service` | The print scheduler itself | disabled |
| `cups.path` | Starts cupsd when its cache marker appears | disabled |
| `zramswap.service` | Compressed swap (one-shot, no daemon) | enabled by `zram-tools` |
| `snapper-boot.timer` | Snapshot of `/` at every boot | disabled |
| `snapper-timeline.timer` | Hourly timeline snapshots | disabled |
| `snapper-cleanup.timer` | Prunes snapshots to `NUMBER_LIMIT=50` | enabled |
| `snapperd.service` | Snapper D-Bus API | enabled (packaged default) |

The desktop session is not systemd-managed: `waybar`, `swaync`, `lxpolkit`,
`hypridle`, and `kanshi` are each started exactly once from the
`hyprland.start` handler in `hyprland.lua`, and none of them is also enabled as
a unit. `hypridle` and `kanshi` ship their own user units, but neither package
enables them (`deb-systemd-helper enable` is absent from both maintainer
scripts), so there is no second copy of either process.

## Changes made in this pass

### Printing no longer runs at boot (anticipated)

`cups-daemon` enables `cups.service`, `cups.socket`, and `cups.path`, and
`cups.service` is `WantedBy=multi-user.target`. The build hook also enabled the
service while its comment claimed printing was socket activated, so a print
scheduler was resident from boot whether or not anything ever printed.

`config/hooks/normal/0200-services.hook.chroot` now disables `cups.service` and
`cups.path`, then enables `cups.socket`. A print dialog, `lpstat`, or
`cups-pk-helper` connects to `/run/cups/cups.sock` and systemd starts `cupsd`
for that request, which is the mechanism `cups.socket` exists for.

`cups.path` has to go with it: it watches for `/var/cache/cups/org.cups.cupsd`,
a file `cupsd` writes itself, so leaving it enabled would start `cupsd` at every
boot again after the first print.

Trade-off: the first print after boot waits for `cupsd` to start. Nothing else
changes; the printer list, driverless discovery, and `cups-pk-helper` all reach
the scheduler through the same socket.

### Snapper boot and timeline timers disabled (anticipated)

`snapper` enables three timers. `snapper-init` already turns timeline snapshots
off (`TIMELINE_CREATE="no"`), because on a desktop they grow without bound and
compete with the pre-update snapshots `flr-update` takes. With that setting:

- `snapper-timeline.timer` fires hourly and has nothing to create.
- `snapper-boot.timer` runs `snapper create` for root at every boot, so a
  machine that reboots daily fills the fifty-snapshot limit with boot entries
  that no rollback target needs.

`snapper-init` now disables both with `systemctl --root`, which edits the
enablement symlinks offline inside the install chroot. `snapper-cleanup.timer`
stays: `NUMBER_CLEANUP="yes"` in the template is what keeps pre-update
snapshots bounded. The units are disabled rather than masked, so
`systemctl enable --now snapper-boot.timer` remains the documented way to get
boot snapshots back.

## Deliberate trade-offs kept

These were examined and left alone, because the current choice is either a
design decision or already the cheap option.

- **GRUB menu timeout of 3 s.** Dual-boot is supported and `os-prober` runs, so
  a hidden menu would hide other operating systems. The three seconds buy a
  visible, navigable menu.
- **zram at 50 % with zstd.** `zramswap.service` is a one-shot unit: it sets up
  the device and exits, so there is no resident process. zstd was chosen for
  compression ratio over lz4's speed; the setup cost is paid once at boot.
- **Blur only on layer surfaces.** `decoration.blur` is enabled for Waybar,
  Fuzzel, and SwayNC panels and disabled for window surfaces, which is the
  design system's rule. Removing it would change the look, not fix a cost.
- **Waybar polling.** `custom/power` polls every 10 s and `custom/mode` every
  30 s. Measured above at 3.5 ms and 2.5 ms per call, which is about 0.035 % and
  0.008 % of one core. Shortening the interval is not worth a code change, and
  lengthening it would make a profile change take longer to appear.
- **`snapperd` at boot.** It is the D-Bus API for snapper. The `flr-*` tools
  pass `--no-dbus`, so nothing in the image needs it resident, but it is small,
  it is Debian's packaged default, and a user running `snapper` without
  `--no-dbus` expects it to answer.
- **`plymouth-themes`.** The package is 1.1 MB installed and provides the theme
  set Plymouth falls back to. Not worth the risk of a missing theme at boot.
- **Portals via Recommends.** `hyprland` recommends `xdg-desktop-portal-hyprland`
  and `flatpak` recommends `xdg-desktop-portal`, and live-build keeps
  Recommends (`LB_APT_RECOMMENDS` defaults to `true` in trixie's live-build).
  They are therefore installed. They are not named explicitly, which is the one
  place a change to `--apt-recommends` would silently remove Flatpak integration.

## Candidates examined and rejected

- **Duplicate `kanshi` or `hypridle` daemons.** Neither package enables its own
  unit, so the compositor is the only starter. No change.
- **Duplicate `waybar`, `swaync`, or policy agent.** One `hl.exec_cmd` each, and
  no packaged unit is enabled for them.
- **XDG autostart duplication.** `/etc/xdg/autostart` entries are not executed
  by Hyprland, so the explicit `xdg-user-dirs-update` call in the session is the
  only place that runs.
- **Missing initramfs tuning.** No kernel parameters were added and
  `MODULES=most` was left as Debian configures it; a narrower module set is a
  boot-time win only until the target hardware needs one of the modules it left
  out.
- **`.deb` payload and ISO size.** Handled as release actions, not tuned here.

## Verification requirements

Run on real hardware, with the tools named:

| Check | Command | Expected |
| --- | --- | --- |
| Boot time, by unit | `systemd-analyze blame` | No snapper timer or `cups.service` in the list |
| Boot critical chain | `systemd-analyze critical-chain` | No wait on `cups.service` |
| Printing is on demand | `systemctl is-enabled cups.socket cups.service cups.path` | `enabled`, `disabled`, `disabled` |
| Scheduler starts on request | `systemctl stop cups` then `lpstat -r` | `cupsd` starts, printer status prints |
| Snapper timers | `systemctl list-timers --all 'snapper*'` | Only `snapper-cleanup.timer` active |
| Snapshot list is not boot noise | `snapper --no-dbus -c root list` | No `boot` entries accumulating |
| Resident memory | `ps -eo rss,comm --sort=-rss \| head -20` | No `cupsd` before printing |
| Session process count | `pgrep -a -x 'waybar\|swaync\|hypridle\|kanshi'` | One of each |

## After a package upgrade

Disabling a unit is not permanent against a package that re-enables it in its
maintainer script: a `cups` or `snapper` upgrade can restore the packaged
default. This is accepted rather than worked around with a dpkg hook, because a
re-enabled daemon costs memory and a re-enabled timer costs a snapshot; neither
breaks printing, snapshotting, or the session. Re-check after an upgrade with:

```sh
systemctl is-enabled cups.service cups.path
systemctl list-timers --all 'snapper*'
```

and apply the same `disable` calls documented above if the packaged default is
back.

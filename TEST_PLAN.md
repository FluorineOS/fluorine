# FluorineOS Test Plan

Release validation checklist for FluorineOS 0.0.x / 0.x on Debian 13 (`trixie`), amd64,
built around Hyprland.

Every test below has the status **NOT TESTED**. This document records procedures and
expected behaviour, not results. Do not mark a test PASS without the evidence named in its
procedure stored alongside the release record.

## How to use this document

- Run the plan against one identified build. Record for every run: ISO filename, byte
  size, SHA-256, the `fluorine` commit, and the `fluorine-desktop`,
  `fluorine-artwork`, and `fluorine-keyring` versions from `dpkg-query`.
- Work top to bottom. Subsystem 1 through 18 apply to the live image; 19 through 28 apply
  to the installed system; 29 checks artifact identity and applies to both.
- Attach evidence per test: the exact command and its output, a journal excerpt, or a
  screenshot path. A short "looks fine" is not evidence.
- Every non-dry run of `run-qemu-live.sh` or `run-qemu-install.sh` writes
  `<evidence>/manifest.json` with the actual runtime values and per-stage status.
  Every shared boot-gate run writes `<evidence>/gate.txt` instead. This document remains
  the canonical source of test IDs and procedures; both files are run metadata, not a
  second test plan.
- Record results with `scripts/validation/record-result.sh`. The default ledger is
  `~/.local/share/fluorineos/validation/results.jsonl`, outside Git. Results recorded as
  PASS or FAIL must point at existing evidence outside the source repository.
- Use disposable VM disks. Never run partitioning, formatting, `lb clean`, or recursive
  deletion against the host or a real disk. See `AGENTS.md` section 6.
- Build only on the native ext4 workspace, never under `/mnt/c`. Start from a fresh build
  tree; do not resume a failed `live-build` tree (gotcha 10).

### Shared boot gate

`scripts/qemu-boot-gate.sh` is the single authoritative implementation of the two
automated boot checks in this plan. It replaced the inline QEMU logic that used to
live in `.github/workflows/build-iso.yml`. Do not add a second copy of those checks
to a workflow, a launcher, or another script.

The gate sources `scripts/lib/qemu-common.sh` for ISO resolution, checksum
verification, evidence placement, OVMF discovery, acceleration selection, and
serial logging. Every run uses the same QEMU argument builder: `q35`, explicit
`--accel auto|kvm|tcg`, 2048 MiB RAM and 2 vCPUs by default, headless
`virtio-vga`, a read-only ISO cdrom, a serial file log, and `-no-reboot`.

CI invokes the gate twice from `.github/workflows/build-iso.yml`:

```sh
bash scripts/qemu-boot-gate.sh --mode firmware \
  --iso "FluorineOS-${VERSION}-amd64.iso" \
  --sha256-file "FluorineOS-${VERSION}-amd64.iso.sha256" \
  --evidence-dir "${RUNNER_TEMP}/fluorine-boot-gate/firmware" \
  --timeout 60 --memory 2048 --cpus 2 --accel auto

bash scripts/qemu-boot-gate.sh --mode live \
  --iso "FluorineOS-${VERSION}-amd64.iso" \
  --sha256-file "FluorineOS-${VERSION}-amd64.iso.sha256" \
  --evidence-dir "${RUNNER_TEMP}/fluorine-boot-gate/live" \
  --timeout 90 --memory 2048 --cpus 2 --accel auto
```

Run the same gate locally without a graphical desktop:

```sh
bash scripts/qemu-boot-gate.sh --mode firmware \
  --iso /path/to/FluorineOS-<version>-amd64.iso \
  --evidence-dir /var/tmp/fluorine-boot-gate/firmware --accel tcg

bash scripts/qemu-boot-gate.sh --mode live \
  --iso /path/to/FluorineOS-<version>-amd64.iso \
  --kernel /path/to/vmlinuz --initrd /path/to/initrd.img \
  --evidence-dir /var/tmp/fluorine-boot-gate/live --accel tcg
```

Without `--kernel` and `--initrd`, live mode mounts the ISO read-only, requires
exactly one `live/vmlinuz-*` and one `live/initrd.img-*`, copies them into a
temporary directory, and unmounts the ISO. That path needs `sudo` and is not used
by the non-destructive test harness. Interactive `run-qemu-live.sh` and
`run-qemu-install.sh` launchers are unchanged in behaviour; local automation
invokes the gate directly and both use the same helper library.

Each run writes `<evidence>/gate.txt`, `<evidence>/serial.log`, and
`<evidence>/<mode>.qemu.log`. `gate.txt` records the status, exit code, timeout,
acceleration, firmware mode, resolved ISO and SHA-256, and the exact required and
forbidden marker patterns. Failures print the serial and QEMU log tails. A timeout
is always a failure and is never silently counted as a pass.

| Exit code | Meaning |
| --- | --- |
| 0 | PASS: all required markers found and no forbidden marker found. |
| 2 | Usage error, such as an invalid mode, timeout, acceleration, or option pair. |
| 3 | Preflight error, such as a missing ISO, checksum mismatch, missing OVMF, or missing tool. |
| 4 | QEMU exited nonzero before the gate completed. |
| 5 | Stage timeout expired before the final marker was observed. |
| 6 | Boot assertion failure: a required marker is missing or a forbidden marker is present. |

What the gates prove:

- Firmware mode proves that OVMF started an ISO boot entry and that the firmware
  log contains no `Boot Failed`, `No bootable option`, or `Failed to load image`.
  It does not prove that GRUB rendered correctly, that the kernel started, or that
  a desktop loaded.
- Live mode proves that the directly booted kernel and initrd mounted squashfs
  and reached `multi-user.target` and `graphical.target` without a kernel panic,
  `SQUASHFS error`, missing live medium, or failed mount. It does not exercise
  firmware, GRUB, Secure Boot, the safe-graphics entry, the installer, or an
  interactive desktop session.

`FLUORINEOS_OVMF_CODE`, `FLUORINEOS_OVMF_VARS`, and `FLUORINEOS_OVMF_BIOS` override
firmware discovery for local runs and non-destructive tests. OVMF discovery covers
the 4M pflash pair, the regular pflash pair, and the combined `OVMF.fd`.

### Status values

| Status | Meaning |
| --- | --- |
| NOT TESTED | Default. No execution recorded. |
| PASS | Procedure executed in the stated environment and all pass criteria met. |
| FAIL | Executed and at least one pass criterion failed. |
| BLOCKED | Could not be executed. Record the exact reason and what is missing. |
| N/A | Not applicable to this build; record why. |
| SKIP | Deliberately not executed; record why. The result ledger uses SKIP for both N/A and SKIP. |

### Severity

| Severity | Meaning |
| --- | --- |
| Critical | Blocks release. Boot, install, data safety, or release integrity. |
| High | Blocks subsystem sign-off. A documented feature is broken or unsafe. |
| Medium | Degrades usability or contradicts documentation; release may proceed with a
  recorded exception. |
| Low | Cosmetic or documentation-level. |

### Test environments

| ID | Environment |
| --- | --- |
| E1 | Static inspection of the ISO, packages, repository, or source tree. No boot. |
| E2 | QEMU live boot: KVM, OVMF UEFI firmware, ISO attached, serial console captured. Interactive launchers use 4 GB RAM and 4 vCPU; the shared boot gate uses 2048 MiB and 2 vCPU. Record the actual values from `manifest.json` or `gate.txt`. |
| E3 | QEMU installed system: a blank qcow2 target on the same virtual hardware, Calamares run from E2, then boot from the installed disk. |
| E4 | Physical UEFI x86_64 machine with a real GPU, Wi-Fi, Bluetooth, backlight, and battery. Required for the hardware-specific tests. |
| E5 | Networked virtual machine or container using the live APT archive at `https://fluorineos.github.io/apt-repo`. |

### Baseline inspected while writing this plan

These are source and artifact facts, not test results.

- Latest published image: `v0.2.0`, `FluorineOS-0.2.0-amd64.iso`, 1390624768 bytes,
  SHA-256 `9b8c045e0a5d27cfd7d148a5ca720d7e59533c6eaa9d0b51f93ae3abd7fed780`.
- Build tree label: `0.4.0` (unreleased). Staged packages: `fluorine-desktop 0.15.1`,
  `fluorine-artwork 0.8.0`, `fluorine-keyring 0.0.2`.
- Archive serves the same three versions; `Release.gpg` and `InRelease` verify against the
  packaged key, fingerprint `DCF8 D117 1411 43E6 5F93 0B55 206E 4955 40B3 6253`.
- Hyprland `0.55.x` from `trixie-backports`, pinned at priority 900 with the
  `libxkbcommon` family.
- Calamares sequence: welcome, locale, keyboard, partition, users, summary; then the exec
  phase with `update_db: false`, Btrfs default, LUKS2 automated partitioning.
- Idle policy: dim 300 s, lock 600 s, suspend 1200 s on battery only. No DPMS-off listener
  ships.
- Automation: `.github/workflows/build-iso.yml` invokes `scripts/qemu-boot-gate.sh`
  twice before publishing: the ISO-03 firmware handoff gate and the ISO-04 headless
  boot gate to `graphical.target`. The same shared gate is available locally. Those
  two gates cover part of ISO-03 and ISO-04 only; nothing else in this plan is
  automated.

### Known issues that affect execution

- `fluorine-desktop` CI currently fails shellcheck on its three Python utilities;
  `fluorine-artwork` CI fails on missing build dependencies. Do not treat CI status as
  evidence for this plan.
- The Calamares branding and `VERSION` carry `0.4.0` while the published image is `0.2.0`.
  Record which artifact each run used.
- `auto/config` currently appends `-amd64` while live-build appends the architecture
  again. Record the exact produced filename; do not rename by hand for a release.

## 1. ISO integrity and boot

### ISO-01 Verify the published checksum
Subsystem: ISO integrity and boot | Failure severity: Critical | Test environment: E1 Static | Result status: NOT TESTED

- Preconditions: ISO and its `.sha256` downloaded from the release page.
- Test procedure: run `sha256sum -c FluorineOS-<version>-amd64.iso.sha256`, then `sha256sum`
  the ISO and compare with the release notes, `README.md`, and the organization profile.
- Expected result: the sidecar prints `OK`; size and digest match every published copy.
- Pass criteria: no mismatch; sidecar digest equals the computed digest and the release text.

### ISO-02 Inspect ISO metadata and boot records
Subsystem: ISO integrity and boot | Failure severity: High | Test environment: E1 Static | Result status: NOT TESTED

- Preconditions: `xorriso` and `isoinfo` installed on the inspection host.
- Test procedure: run `xorriso -indev <iso> -pvd_info` and
  `xorriso -indev <iso> -report_el_torito as_mkisofs`.
- Expected result: volume label `FLUORINEOS_<version with underscores>`, application
  `FluorineOS <version>`, publisher containing `https://github.com/FluorineOS`, and one
  UEFI El Torito entry pointing at `/boot/grub/efi.img`.
- Pass criteria: all four values correct and no legacy BIOS/isolinux entry is required.

### ISO-03 UEFI firmware handoff
Subsystem: ISO integrity and boot | Failure severity: Critical | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: OVMF firmware and a writable `OVMF_VARS` copy available.
- Automated procedure: `scripts/qemu-boot-gate.sh --mode firmware` with a 60 second
  stage timeout. CI and local runs use the same command and markers.
- Manual test procedure: boot the ISO with `-bios` or the OVMF code/vars pair, capture the
  serial or firmware log, and let the boot menu appear.
- Expected result: `BdsDxe: starting Boot<NN>` appears and the GRUB menu is reached.
- Pass criteria: boot entry started; no `Boot Failed`, `No bootable option`, or
  `Failed to load image`.
- Gate evidence: `<evidence>/gate.txt`, `<evidence>/serial.log`, and
  `<evidence>/firmware.qemu.log`. The gate proves firmware handoff only, not GRUB
  rendering or a successful kernel boot.

### ISO-04 Headless live boot to graphical target
Subsystem: ISO integrity and boot | Failure severity: Critical | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: same as ISO-03; serial console captured to a file.
- Automated procedure: `scripts/qemu-boot-gate.sh --mode live` with a 90 second stage
  timeout. Direct-kernel mode bypasses firmware and GRUB; supply `--kernel` and
  `--initrd` locally to avoid mounting the ISO, or let the gate extract them.
- Manual test procedure: boot with `console=ttyS0,115200
  systemd.journald.forward_to_console=1` and wait up to 120 seconds.
- Expected result: kernel banner, squashfs mount, `multi-user.target`, then
  `Reached target graphical.target`.
- Pass criteria: graphical target reached within the limit; no kernel panic, squashfs
  error, "unable to find a medium", or failed mount.
- Gate evidence: `<evidence>/gate.txt`, `<evidence>/serial.log`, and
  `<evidence>/live.qemu.log`. The gate proves the direct-kernel live path reached a
  graphical target, not that GRUB, Secure Boot, the safe-graphics entry, or an
  interactive desktop session worked.

### ISO-05 Interactive live desktop
Subsystem: ISO integrity and boot | Failure severity: High | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: graphical QEMU display (or VNC) at 1920x1080.
- Test procedure: boot normally and observe the first 60 seconds; do not log in manually.
- Expected result: the live session reaches Hyprland with Waybar and the
  `Install FluorineOS` desktop shortcut, with no greeter prompt.
- Pass criteria: desktop is interactive; no greeter, no login prompt on tty1, no crash loop.

## 2. GRUB and Plymouth

### GRUB-01 Verify the live menu and theme
Subsystem: GRUB and Plymouth | Failure severity: High | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: ISO booted to the GRUB menu.
- Test procedure: inspect the rendered menu and both entries; wait for the 3-second timeout.
- Expected result: the FluorineOS theme renders on a black canvas with carbon entry
  panels; entries are the default live entry and
  `FluorineOS (Safe Graphics / VM Software Render)`; no version is embedded in the
  safe-graphics label.
- Pass criteria: theme loads, both entries present, default entry starts on timeout.

### GRUB-02 Safe graphics entry boots software rendering
Subsystem: GRUB and Plymouth | Failure severity: High | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: VM without VirGL 3D acceleration.
- Test procedure: select the safe-graphics entry, then inspect
  `cat /proc/cmdline` inside the live session.
- Expected result: the command line contains
  `systemd.setenv=WLR_RENDERER_ALLOW_SOFTWARE=1` and the session starts.
- Pass criteria: desktop reached without a Mesa/D3D12 crash or black screen.

### GRUB-03 Plymouth splash covers the boot transition
Subsystem: GRUB and Plymouth | Failure severity: High | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: the `fluorine` Plymouth theme is installed and selected.
- Test procedure: boot and watch from GRUB handoff to the greeter/desktop; verify
  `plymouth-set-default-theme` reports `fluorine` in the live session.
- Expected result: black canvas, lime hexagon emblem and progress bar, no boot text on the
  primary entry.
- Pass criteria: theme name is `fluorine`, animation renders, and no text splash appears.

### GRUB-04 Installed system GRUB configuration and theme
Subsystem: GRUB and Plymouth | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: completed installation from CAL-01 through CAL-05.
- Test procedure: inspect `/etc/default/grub`, `/boot/grub/grub.cfg`, and
  `/boot/grub/themes/fluorine/theme.txt`; reboot and select the primary and recovery
  entries.
- Expected result: `quiet splash` on the primary entry only, recovery verbose, theme staged
  under `/boot`, and the primary entry boots the installed system.
- Pass criteria: all three files present and correct; both entries boot as described.

## 3. Live environment

### LIVE-01 Live autologin starts the desktop on tty1
Subsystem: Live environment | Failure severity: Critical | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: ISO booted normally.
- Test procedure: after boot, check `systemctl status greetd`, `tty`, and
  `echo "$WAYLAND_DISPLAY"` from the live session.
- Expected result: greetd is skipped on live media by its drop-in
  (`ConditionPathExists=!/run/live`), the live user is on tty1, and
  `start-hyprland` has replaced the shell.
- Pass criteria: desktop starts without typing credentials; greetd is not competing for
  tty1.

### LIVE-02 ZRAM swap is active with the configured policy
Subsystem: Live environment | Failure severity: Medium | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: live session with 4 GB RAM.
- Test procedure: run `zramctl`, `swapon --show`, and `cat /etc/default/zramswap`.
- Expected result: a zram device using zstd at roughly 50 percent of RAM, active as swap.
- Pass criteria: algorithm `zstd`, `PERCENT=50`, and the device is in use.

### LIVE-03 Firewall default policy
Subsystem: Live environment | Failure severity: Medium | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: live session.
- Test procedure: run `ufw status verbose`.
- Expected result: status active, default deny incoming, default allow outgoing.
- Pass criteria: exact policy match; no unexpected allow rules.

### LIVE-04 Installer shortcut launches without a password
Subsystem: Live environment | Failure severity: High | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: live session, no installer running.
- Test procedure: double-click `Install FluorineOS` on the desktop; confirm the
  `/etc/sudoers.d/99-fluorine-live-installer` rule exists before launching.
- Expected result: Calamares opens with no password prompt.
- Pass criteria: installer window appears within 10 seconds and no polkit/sudo prompt is
  shown.

## 4. Login manager

### DM-01 greetd owns vt7 without getty conflict
Subsystem: Login manager | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system booted.
- Test procedure: check `/etc/greetd/config.toml`, `systemctl status greetd`, and
  `systemctl status getty@tty7`; switch to vt7.
- Expected result: `vt = 7`, `user = "_greetd"`, greetd active, no getty on tty7, greeter
  visible and accepting input.
- Pass criteria: no restart loop and no competing login prompt.

### DM-02 Greeter theme and text
Subsystem: Login manager | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: greeter visible on vt7.
- Test procedure: inspect the screen and the wrapper
  `/usr/local/bin/fluorineos-greeter`; press a key to confirm input focus.
- Expected result: tuigreet with clock, greeting `FluorineOS  //  sign in`, asterisk
  password input, AMOLED palette from `/etc/vtrgb`, ASCII only.
- Pass criteria: palette correct, input responsive, no mojibake or missing glyphs.

### DM-03 Valid and invalid authentication
Subsystem: Login manager | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: user account created during installation.
- Test procedure: attempt a wrong password twice, then the correct password; confirm the
  session command.
- Expected result: wrong password returns to the prompt with an error; correct password
  starts Hyprland through `start-hyprland`.
- Pass criteria: no login bypass, no direct `Hyprland` exec, session reaches the desktop.

### DM-04 Session exit returns to the greeter
Subsystem: Login manager | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: logged into a working session.
- Test procedure: log out through `flr-ctl`, then reboot and repeat once through
  `systemctl restart greetd`.
- Expected result: greeter returns cleanly each time; no black screen or frozen vt.
- Pass criteria: greeter usable after logout and after service restart.

## 5. Hyprland session

### HYPR-01 Configuration loads without errors
Subsystem: Hyprland session | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: logged-in session.
- Test procedure: run `hyprctl configerrors` and inspect
  `journalctl --user -b -u hyprland` (or the compositor log) for option warnings.
- Expected result: no config errors; native Lua configuration loaded; no deprecated 0.55
  key warnings.
- Pass criteria: empty `configerrors` and no "unknown option" lines.

### HYPR-02 Keybinding matrix
Subsystem: Hyprland session | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: at least one terminal and one GUI application installed.
- Test procedure: exercise Return, D, E, S, Q, V, F, C, Shift+S, Shift+N, W, slash, Escape,
  comma, M, L, arrow keys, H/J/K/semicolon, 1-9, and Shift+1-9.
- Expected result: every chord performs its documented action; `SUPER + L` locks and
  `SUPER + ;` moves focus right.
- Pass criteria: all chords behave as documented in `README.md`; no dead or conflicting bind.

### HYPR-03 Window borders, gaps, and floating rules
Subsystem: Hyprland session | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: two windowed applications.
- Test procedure: focus between windows; open galculator and File Roller; toggle float and
  fullscreen.
- Expected result: lime active border and `#1c2229` inactive border at 2 px, 4 px rounding,
  black shadow, gaps 4 in / 6 out, calculator and File Roller float at their configured
  sizes.
- Pass criteria: all geometry and colour values match the shipped configuration.

### HYPR-04 Session autostart set
Subsystem: Hyprland session | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: fresh login.
- Test procedure: run `pgrep -a` for waybar, swaync, lxpolkit, hypridle, kanshi, wl-paste,
  and check `hyprctl clients`; inspect `~/.local/state/fluorine/` and `~/Desktop`,
  `~/Pictures`, and other XDG directories.
- Expected result: every autostart entry ran once; XDG directories exist; wallpaper and
  shader restored; onboarding shown on first login only.
- Pass criteria: all daemons present exactly once and state files correct.

### HYPR-05 Toolkit and scaling environment
Subsystem: Hyprland session | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a Qt application, an Electron application, and an X11 client available.
- Test procedure: run `env | grep -E 'QT_QPA|ELECTRON|XCURSOR|HYPRCURSOR'`; open one app of
  each kind.
- Expected result: `QT_QPA_PLATFORMTHEME=qt6ct`, `ELECTRON_OZONE_PLATFORM_HINT=auto`,
  cursor size 24, XWayland with zero scaling.
- Pass criteria: variables set and each app renders with the expected theme and scale.

## 6. Waybar

### WB-01 Bar layout and modules
Subsystem: Waybar | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: logged-in session.
- Test procedure: inspect the bar and `waybar` journal for module load errors.
- Expected result: 32 px top bar with workspaces and window title on the left, clock in the
  centre, and mode, SYS, power, Bluetooth, network, audio, and battery on the right.
- Pass criteria: every configured module renders; no error in the journal.

### WB-02 Module click actions
Subsystem: Waybar | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: NetworkManager, Bluetooth, and PipeWire running.
- Test procedure: left-click network, Bluetooth, audio, SYS, mode, and power; right-click SYS.
- Expected result: nmtui opens in a floating Kitty window, the Bluetooth manager opens,
  pavucontrol opens, flr-ctl opens, the mode picker opens, the power profile cycles, and
  flr-update opens in a terminal.
- Pass criteria: all actions launch the documented command and return focus sensibly.

### WB-03 Scroll and secondary-click behaviour
Subsystem: Waybar | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: audio sink present; Wi-Fi hardware present.
- Test procedure: scroll on the volume module; middle-click it; right-click the network module.
- Expected result: volume changes in 5 percent steps, middle-click toggles mute, and
  right-click toggles the Wi-Fi radio with an OSD confirmation.
- Pass criteria: state changes are reflected in `wpctl` and the bar within 2 seconds.

### WB-04 Bar theme, icons, and transparency
Subsystem: Waybar | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session with the Fluorine icon theme installed.
- Test procedure: inspect the bar at 100 percent scale; check the active workspace indicator and
  icon rendering.
- Expected result: `#0a0d10` background, 1.5 px `#1c2229` bottom border, lime underline on
  the active workspace, all icons resolve from the Fluorine theme, no shadow or alpha.
- Pass criteria: no missing-icon placeholders; colours match the design tokens.

## 7. Application launcher

### LAUNCH-01 Fuzzel opens with the shipped theme
Subsystem: Application launcher | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running.
- Test procedure: press `SUPER + D`.
- Expected result: Fuzzel opens with JetBrains Mono 11, `> ` prompt, 12 lines, width 40,
  1.5 px border, no shadow.
- Pass criteria: all visual parameters match `fuzzel.ini` and input is responsive.

### LAUNCH-02 Search, icons, and launch
Subsystem: Application launcher | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: at least three desktop entries installed.
- Test procedure: type partial names for a terminal, a file manager, and a settings app; launch
  each with Enter.
- Expected result: results filter as typed, each row shows its Fluorine icon, and the
  selected application starts.
- Pass criteria: correct application launches in every case; no blank icons.

### LAUNCH-03 Cancellation and empty input
Subsystem: Application launcher | Failure severity: Low | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running.
- Test procedure: open Fuzzel, press Escape; reopen and press Enter with no query.
- Expected result: Escape closes without launching; empty Enter launches nothing or the
  documented default, with no error dialog.
- Pass criteria: no spurious process launched and exit status is zero.

## 8. Terminal and shell

### TERM-01 Kitty theme and font
Subsystem: Terminal and shell | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running.
- Test procedure: press `SUPER + Return`; inspect the window and run `fc-match "JetBrains Mono"`.
- Expected result: Kitty opens with `#000000` background, `#e2e8f0` text, lime cursor, moss
  selection, JetBrains Mono, fully opaque.
- Pass criteria: palette and font match `kitty.conf`; window is not translucent.

### TERM-02 Shell environment and aliases
Subsystem: Terminal and shell | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a login shell for the installed user.
- Test procedure: open a login shell and run `echo "$PATH"`, `type -a flr-doctor`, and
  `bash -n ~/.bashrc`; inspect `.bash_aliases`.
- Expected result: `~/.local/bin` precedes system paths, `flr-*` resolve from
  `/usr/bin`, and the shell files parse without errors.
- Pass criteria: no startup errors; documented aliases available.

### TERM-03 Copy, paste, and selection colours
Subsystem: Terminal and shell | Failure severity: Low | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: Kitty open with text.
- Test procedure: select text, copy with `Ctrl+Shift+C`, paste into a second Kitty window with
  `Ctrl+Shift+V`.
- Expected result: selection uses `#2a3812` background, paste inserts the exact text, and
  bracketed paste works for multi-line input.
- Pass criteria: content identical; no trailing newline surprises.

## 9. Notifications

### NOTIF-01 Notification rendering and severity
Subsystem: Notifications | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: swaync running.
- Test procedure: run `notify-send "Test" "Body"`, then
  `notify-send -u critical "Critical" "Body"` and `-u low`.
- Expected result: cards appear on the carbon surface with a 1.5 px hairline and a 3 px
  severity edge in success/warning/error colours.
- Pass criteria: all three severities render and dismiss correctly.

### NOTIF-02 Do Not Disturb toggling
Subsystem: Notifications | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running.
- Test procedure: run `swaync-client -d`, send a notification, then toggle back; also switch to
  focus mode with `flr-mode focus`.
- Expected result: DND suppresses new notifications and the mode switch enables DND.
- Pass criteria: suppression and restoration both work; no notifications lost when
  restored intentionally.

### NOTIF-03 Actions, history, and single daemon
Subsystem: Notifications | Failure severity: Low | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: swaync running.
- Test procedure: send a notification with an action button; open the control centre; check
  `pgrep -c swaync`.
- Expected result: the action runs, history is listed, and exactly one daemon runs.
- Pass criteria: action executed once; no duplicate notifications.

## 10. Audio and microphone

### AUD-01 PipeWire and WirePlumber are active
Subsystem: Audio and microphone | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system with an audio device (or QEMU `intel-hda`).
- Test procedure: run `systemctl --user status pipewire wireplumber` and `wpctl status`.
- Expected result: both units active; at least one sink and one source.
- Pass criteria: no failed units; default sink and source present.

### AUD-02 Volume keys and OSD
Subsystem: Audio and microphone | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: audio sink present.
- Test procedure: press volume up three times, down once, then mute; read `wpctl get-volume`.
- Expected result: 5 percent steps, mute toggles, and a transient card reports the state.
- Pass criteria: `wpctl` values and the OSD agree after every press.

### AUD-03 Microphone mute
Subsystem: Audio and microphone | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a capture source present.
- Test procedure: press `XF86AudioMicMute` twice; inspect `wpctl status` and record a short
  sample with `pw-record` while muted.
- Expected result: the default source toggles mute and the OSD shows the muted state.
- Pass criteria: no audio captured while muted; unmute restores capture.

## 11. Networking and Wi-Fi

### NET-01 Wired networking and DNS
Subsystem: Networking and Wi-Fi | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: QEMU user networking or a bridged interface.
- Test procedure: run `nmcli device status`, `ip -brief address`, and `getent hosts deb.debian.org`.
- Expected result: the interface is managed and connected, an address is assigned, DNS
  resolves.
- Pass criteria: connectivity works without manual configuration.

### NET-02 Wi-Fi scan and connect through nmtui
Subsystem: Networking and Wi-Fi | Failure severity: High | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: Wi-Fi hardware and a test access point.
- Test procedure: click the Waybar network module (or run `flr-tui nmtui`), scan, join the AP,
  and reopen the connection editor.
- Expected result: a floating Kitty window hosts nmtui; the join succeeds and the profile
  persists.
- Pass criteria: connection survives a reboot and the window closes cleanly.

### NET-03 Waybar network states and radio toggle
Subsystem: Networking and Wi-Fi | Failure severity: Medium | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: Wi-Fi and Ethernet available.
- Test procedure: disconnect, connect, and toggle the radio with a right-click on the module.
- Expected result: `OFFLINE`, `WIFI <essid>`, and `ETH <ifname>` states render correctly;
  the radio toggles with an OSD.
- Pass criteria: every state label and the radio toggle match reality.

### NET-04 Reach the project HTTPS endpoints
Subsystem: Networking and Wi-Fi | Failure severity: High | Test environment: E5 Networked VM | Result status: NOT TESTED

- Preconditions: network access.
- Test procedure: run `curl -fsS https://fluorineos.github.io/apt-repo/dists/trixie/Release`
  and open `https://fluorineos.pages.dev`.
- Expected result: Release downloads with a valid signature path; the site responds.
- Pass criteria: HTTP 200 and no certificate error.

## 12. Bluetooth

### BT-01 Service and adapter availability
Subsystem: Bluetooth | Failure severity: High | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: a machine with a Bluetooth adapter and no soft block.
- Test procedure: run `systemctl status bluetooth`, `rfkill list bluetooth`, and
  `bluetoothctl show`; confirm the unit is enabled at boot.
- Expected result: the service is active and enabled, the adapter is powered and not
  soft-blocked, and a controller address is reported.
- Pass criteria: no blocked radio and a powered controller with the expected alias.

### BT-02 flr-bt opens a usable manager
Subsystem: Bluetooth | Failure severity: Medium | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: blueman installed on the first run; a second run prepared without it.
- Test procedure: run `flr-bt` with blueman present, then hide `blueman-manager` from `PATH`
  and run it again.
- Expected result: blueman-manager opens when available; otherwise bluetoothctl opens in a
  floating Kitty window.
- Pass criteria: both paths provide a usable interface and print no error.

### BT-03 Pair, connect, and reflect state
Subsystem: Bluetooth | Failure severity: High | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: a known pairable device (headset or input device).
- Test procedure: pair and connect it, run `bluetoothctl info <address>`, read the Waybar
  Bluetooth module, then disconnect.
- Expected result: pairing and connection succeed, the module reports `BT <n>` with the
  device listed, and a headset appears as an audio sink.
- Pass criteria: state matches `bluetoothctl` throughout and disconnects cleanly.

## 13. Brightness and volume controls

### BRT-01 Brightness keys and OSD
Subsystem: Brightness and volume controls | Failure severity: High | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: a backlight device under `/sys/class/backlight`.
- Test procedure: press brightness up and down three times; read
  `brightnessctl get` and `/sys/class/backlight/*/brightness`.
- Expected result: 5 percent steps, OSD card reports the new percentage, no error dialog.
- Pass criteria: the sysfs value changes by the expected amount each press.

### BRT-02 Graceful behaviour without a backlight
Subsystem: Brightness and volume controls | Failure severity: Medium | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: VM without a backlight device.
- Test procedure: press both brightness keys; run `flr-osd brightness up; echo $?`.
- Expected result: the command fails quietly, prints no stack trace, and creates no OSD.
- Pass criteria: exit status is non-zero or zero by design, with no visible error and no
  crash.

### BRT-03 Rapid volume and mic input
Subsystem: Brightness and volume controls | Failure severity: Low | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: audio device present.
- Test procedure: press volume up/down 20 times quickly, then mute and unmute five times.
- Expected result: OSD updates without queueing stale cards; final state matches `wpctl`.
- Pass criteria: no dropped keys, no stuck OSD, final state consistent.

## 14. Multi-monitor configuration

### MON-01 Hotplug applies the kanshi profile
Subsystem: Multi-monitor configuration | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: one output active; add a second virtual output or a physical monitor.
- Test procedure: connect a second display; run `hyprctl monitors` and `kanshi` journal.
- Expected result: the new output is enabled at preferred mode, auto position, scale 1.
- Pass criteria: no manual command needed; both outputs usable.

### MON-02 Manual layout with wdisplays
Subsystem: Multi-monitor configuration | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: two outputs.
- Test procedure: run `wdisplays` from the system menu; change position and resolution; apply.
- Expected result: the window opens floating and the layout changes immediately.
- Pass criteria: changes apply and persist for the session.

### MON-03 Fractional scaling and XWayland
Subsystem: Multi-monitor configuration | Failure severity: Medium | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: a display that supports 1.25 or 1.5 scaling.
- Test procedure: apply the documented scale example; open a Wayland and an X11 application.
- Expected result: Hyprland scales correctly and XWayland clients stay crisp with zero
  forced scaling.
- Pass criteria: no blurry X11 text; cursor size remains 24.

## 15. Screenshots

### SHOT-01 Interactive region capture
Subsystem: Screenshots | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: desktop visible.
- Test procedure: press `SUPER + Shift + S`, drag a region, then run `ls -l ~/Pictures/Screenshots`
  and paste into an image viewer.
- Expected result: `fluorine-<timestamp>.png` written, correct region captured, image on the
  clipboard.
- Pass criteria: file exists, dimensions match the selection, paste works.

### SHOT-02 Full-screen capture
Subsystem: Screenshots | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: desktop visible.
- Test procedure: run `flr-shot --full`; inspect the output file.
- Expected result: one PNG at full output resolution, copied to the clipboard.
- Pass criteria: dimensions equal the output resolution.

### SHOT-03 Cancelled selection
Subsystem: Screenshots | Failure severity: Low | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: desktop visible.
- Test procedure: run `flr-shot` and press Escape during selection; list the directory before
  and after.
- Expected result: no file is created and no partial image is left behind.
- Pass criteria: directory contents unchanged; no error dialog.

## 16. Clipboard

### CLIP-01 Text history capture
Subsystem: Clipboard | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: `wl-paste --watch cliphist store` running.
- Test procedure: copy three distinct strings from different applications, then run
  `cliphist list`.
- Expected result: all three entries appear, newest first.
- Pass criteria: every copied string is listed exactly once.

### CLIP-02 Pick from history with SUPER + C
Subsystem: Clipboard | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: at least two history entries.
- Test procedure: press `SUPER + C`, choose an older entry, paste into Kitty.
- Expected result: the Fuzzel list shows 12 lines with the `Clip > ` prompt and the chosen
  entry becomes the clipboard content.
- Pass criteria: pasted text equals the selected entry.

### CLIP-03 Image history
Subsystem: Clipboard | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: an image file and an image viewer that copies.
- Test procedure: copy an image, then pick it from `SUPER + C` and paste into an image-capable
  application.
- Expected result: the image is stored and restored intact.
- Pass criteria: pasted image matches the source dimensions and content.

## 17. Idle and screen locking

### IDLE-01 Display dims after five minutes
Subsystem: Idle and screen locking | Failure severity: High | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: backlight device; hypridle running.
- Test procedure: leave the machine idle for 300 seconds without touching input; then press a key
  and read `brightnessctl get`.
- Expected result: the backlight drops to 10 percent at 300 seconds and restores the previous
  level on activity.
- Pass criteria: dim happens within 300-320 seconds and restores exactly.

### IDLE-02 Session locks after ten minutes
Subsystem: Idle and screen locking | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: hypridle running; hyprlock installed.
- Test procedure: idle for 600 seconds without input.
- Expected result: hyprlock covers the session at 600 seconds; the desktop is not reachable
  without authentication.
- Pass criteria: lock occurs within 600-630 seconds and cannot be dismissed without the
  password.

### IDLE-03 Battery-only suspend after twenty minutes
Subsystem: Idle and screen locking | Failure severity: High | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: a machine with a battery, on AC and then on battery.
- Test procedure: idle for 1200 seconds on AC; then repeat on battery; inspect
  `journalctl -b` for suspend entries.
- Expected result: no suspend on AC; suspend after 1200 seconds on battery, with the session
  locked before sleep and DPMS restored on resume.
- Pass criteria: exactly the documented behaviour in both power states.

### IDLE-04 Lock screen authentication and failure state
Subsystem: Idle and screen locking | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session locked with hyprlock.
- Test procedure: enter a wrong password twice, then the correct one; inspect the ring and text.
- Expected result: lime ring while authenticating, red ring plus `Authentication failed` on
  failure, and unlock on success.
- Pass criteria: no unlock on failure, correct unlock on success, no crash or frozen input.

### IDLE-05 Present mode disables idle locking
Subsystem: Idle and screen locking | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: hypridle running.
- Test procedure: run `flr-mode present`, wait past 600 seconds; then `flr-mode work` and verify
  hypridle is running again.
- Expected result: present mode stops hypridle so the screen cannot lock; work mode restarts
  it.
- Pass criteria: no lock in present mode; locking restored in work mode.

## 18. Shipped flr-* utilities

Every utility test starts with `flr-<name> --help`, which must exit 0 and print ASCII-only
text. Record the exit status and the first line of output for each.

### UTIL-01 flr-box
Subsystem: Shipped flr-* utilities | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: rootless Podman and Distrobox installed; non-root user.
- Test procedure: run `flr-box init debian`, `flr-box enter` (then exit), `flr-box list`, and
  `flr-box export <binary>`; repeat `flr-box init` as root.
- Expected result: a box is created and recorded as current, `enter` opens a shell,
  `export` publishes into `~/.local/bin`, and root is refused with exit 1.
- Pass criteria: every command matches its help text; the host APT database is unchanged.

### UTIL-02 flr-bt
Subsystem: Shipped flr-* utilities | Failure severity: Medium | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: Bluetooth adapter present; blueman installed on the first run.
- Test procedure: run `flr-bt` with blueman installed, then hide `blueman-manager` from `PATH`
  (or test on an image without it) and run it again.
- Expected result: blueman-manager opens when available; otherwise bluetoothctl opens in a
  floating Kitty window.
- Pass criteria: both paths open a usable manager and no error is printed.

### UTIL-03 flr-config
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running; hypridle active.
- Test procedure: run `flr-config status`; `set gaps_in 8`; `set border_size 3`;
  `set idle_lock 900`; then an invalid key and an out-of-range value; finally `apply`.
- Expected result: status prints key/value lines; valid values apply to Hyprland and
  hypridle and persist; invalid input exits non-zero without writing.
- Pass criteria: `hyprctl getoption` and the hypridle timeout reflect the saved values;
  invalid input leaves state untouched.

### UTIL-04 flr-ctl
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running; Fuzzel available.
- Test procedure: open `flr-ctl` with `SUPER + Escape`; activate every row once, starting with
  the settings, network, Bluetooth, display, audio, power, shader, wallpaper, snapshot,
  mode, diagnostics, and session rows; cancel with Escape.
- Expected result: every row launches its target application or action; cancel exits 0.
- Pass criteria: no dead row, no duplicated window, and no command left running.

### UTIL-05 flr-doctor
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system; archive configured.
- Test procedure: run `flr-doctor`, then `NO_COLOR=1 flr-doctor`; compare the report with
  `systemctl --failed`, `wpctl status`, and `nmcli device status`.
- Expected result: sections for OS and boot, graphics and session, audio and connectivity,
  and services; tagged `[OK]`, `[WARN]`, `[INFO]` lines; readable without colour.
- Pass criteria: no false OK for a known-broken service; no crash; exits 0.

### UTIL-06 flr-keys
Subsystem: Shipped flr-* utilities | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running.
- Test procedure: run `flr-keys`; search for `lock`, `workspace`, and `;`; close with Escape.
- Expected result: a searchable list of the live bindings, including `SUPER + L` and
  `SUPER + ;`.
- Pass criteria: entries match `hyprctl binds` and the search filters correctly.

### UTIL-07 flr-mode
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running; Waybar, swaync, hypridle active.
- Test procedure: switch `work`, `focus`, `present`, run `next`, then `status`; after each step
  read `hyprctl getoption general:gaps_in`, the border width, `pgrep waybar`,
  `swaync-client -d`, and `pgrep hypridle`.
- Expected result: work restores gaps 4/6, 2 px border, Waybar visible, notifications on,
  hypridle running; focus uses gaps 0, 1 px border, hidden bar, DND on; present uses wide
  gaps, hidden bar, DND on, and no hypridle; the state file matches `status`.
- Pass criteria: all three profiles and `next` behave exactly as documented and survive a
  re-login.

### UTIL-08 flr-onboard
Subsystem: Shipped flr-* utilities | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a user who has never logged in interactively.
- Test procedure: run `flr-onboard` twice; inspect `~/.local/state/fluorine/onboarded`; use the
  flr-settings first-login toggle to re-enable it, then log in again.
- Expected result: the sheet appears once, the marker is written, the second run is silent,
  and the toggle makes it appear again.
- Pass criteria: no repeated sheet without the toggle and no missing sheet after it.

### UTIL-09 flr-osd
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running; swaync active; audio sink present.
- Test procedure: run `flr-osd volume up`, `volume down`, `mute`, `mic`, `brightness up`,
  `brightness down`, and `wifi`; then an unknown action.
- Expected result: each action changes the device and shows a transient card; the unknown
  action prints usage and exits non-zero.
- Pass criteria: state changes match the card text; no card is left on screen.

### UTIL-10 flr-power
Subsystem: Shipped flr-* utilities | Failure severity: Medium | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: power-profiles-daemon installed; a platform profile on the test machine
  and, separately, a machine without one.
- Test procedure: run `flr-power status`, `cycle` three times, and `flr-power waybar` piped
  through `jq`.
- Expected result: status reports the active profile; cycling moves power-saver, balanced,
  performance; the Waybar payload is valid JSON; no driver reports `PWR N/A`.
- Pass criteria: profile changes match `powerprofilesctl`; no crash without a driver.

### UTIL-11 flr-settings
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running; GTK4 and libadwaita present.
- Test procedure: open `flr-settings`; visit every sidebar section (Appearance, Workstation,
  Displays, Network, Audio, Power, System, and any further section present); change the
  wallpaper, shader, gaps, border, idle lock, mode, and scale; restart the panel and the
  session.
- Expected result: every control delegates to the matching `flr-*` command, changes apply
  immediately and persist, monitor and service state are read live, and no traceback is
  printed.
- Pass criteria: all sections usable, state survives restart, no unhandled exception in the
  terminal output.

### UTIL-12 flr-shader
Subsystem: Shipped flr-* utilities | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running; both shaders installed.
- Test procedure: run `flr-shader off`, `night`, `mono`, `cycle`, `restore`, and `status`;
  inspect `hyprctl getoption decoration:screen_shader`; pass an invalid name.
- Expected result: the screen shader path changes for night and mono, off clears it, cycle
  advances in order, restore reapplies the saved value, and the invalid name is rejected.
- Pass criteria: option values match the state file after every command.

### UTIL-13 flr-shot
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running.
- Test procedure: run `flr-shot --help`, `flr-shot --full`, and an interactive capture; cancel one
  selection.
- Expected result: help is ASCII and exits 0; both captures write a PNG under
  `~/Pictures/Screenshots` and copy it; cancelling writes nothing.
- Pass criteria: files and clipboard content match; no partial file after cancel.

### UTIL-14 flr-snapshot
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: Btrfs root with a Snapper root configuration.
- Test procedure: run `flr-snapshot create pre-update`, `list`, `rollback 0`, `rollback abc`, and
  `rollback <valid-id> --yes`; also run `create` on a non-Btrfs root in a separate VM.
- Expected result: creation prints an id and refreshes GRUB when a generator exists; list
  shows id, timestamp, and description; invalid ids and non-Btrfs roots are refused; the
  valid rollback completes after confirmation; labels are truncated to 60 characters.
- Pass criteria: every guard behaves as described and the rollback leaves `/home` intact.

### UTIL-15 flr-store
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running; network available; Flatpak installed.
- Test procedure: open `flr-store`; visit Development, Web, Multimedia, and System Utilities;
  install one small APT package and one Flatpak; remove the Flathub remote first to test
  re-adding it; force one launch failure.
- Expected result: categories and entries render with icons and installed state; APT
  installs request privileges through pkexec; Flathub is added when absent; failures are
  reported in the status pill or a toast; no GTK thread warnings.
- Pass criteria: installs succeed and installed-state buttons refresh without restarting.

### UTIL-16 flr-sync
Subsystem: Shipped flr-* utilities | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: user configuration present; Git installed; a bare test repository.
- Test procedure: run `flr-sync backup`, `status`, `backup --push`, `restore --dry-run`,
  `restore`, `remote set <url>`, `remote show`, `--version`, and the GUI; reject a symlink
  restore target.
- Expected result: archives are versioned and gzip-compressed, the Git mirror commits and
  pushes, dry-run lists conflicts without writing, restore asks for confirmation and takes a
  Btrfs pre-restore snapshot, remotes persist, and symlink targets are refused.
- Pass criteria: no data loss, correct exit codes, and the Git history stays intact.

### UTIL-17 flr-tui
Subsystem: Shipped flr-* utilities | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: session running; nmtui installed.
- Test procedure: run `flr-tui nmtui`; run it again outside a Hyprland session (tty); run
  `flr-tui` with no command.
- Expected result: nmtui opens in a floating sized Kitty window; without Hyprland it opens as
  a normal window or reports the reason; no command prints usage and exits non-zero.
- Pass criteria: no orphaned terminal and no silent failure.

### UTIL-18 flr-update
Subsystem: Shipped flr-* utilities | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system on Btrfs; archive reachable; at least one pending upgrade.
- Test procedure: run `flr-update --check`; confirm nothing changes; then run `flr-update` and
  inspect `flr-snapshot list` and `/var/run/reboot-required`.
- Expected result: `--check` refreshes metadata and lists incoming FluorineOS and security
  upgrades without installing; the full run creates `pre-update` first, upgrades, and
  reports reboot state and requesting packages.
- Pass criteria: snapshot exists before the upgrade; package versions change as expected; no
  partial upgrade state.

### UTIL-19 flr-wall
Subsystem: Shipped flr-* utilities | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: artwork installed; wallpaper set present.
- Test procedure: run `flr-wall` (picker), `set <name>`, `next`, `restore`, `status`; set a missing
  file; inspect the hyprlock background path.
- Expected result: the picker lists the shipped set and `~/Pictures/Wallpapers`; each command
  applies the wallpaper and remembers it; hyprlock follows the change; a missing file exits
  non-zero without clearing the lock screen configuration.
- Pass criteria: wallpaper and lock screen stay in step across a logout.

## 19. APT repository and package installation

### APT-01 Keyring and source definition
Subsystem: APT repository and package installation | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: `fluorine-keyring` installed.
- Test procedure: inspect `/usr/share/keyrings/fluorineos-archive-keyring.gpg` and
  `/etc/apt/sources.list.d/fluorineos.sources`; run
  `gpg --show-keys /usr/share/keyrings/fluorineos-archive-keyring.gpg`.
- Expected result: source uses `https://fluorineos.github.io/apt-repo`, suite `trixie`,
  component `main`, `Signed-By` pointing at the keyring, and the expected fingerprint.
- Pass criteria: fingerprint `DCF8 D117 1411 43E6 5F93 0B55 206E 4955 40B3 6253` and no
  other suites.

### APT-02 Metadata refresh over HTTPS
Subsystem: APT repository and package installation | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: network access.
- Test procedure: run `apt-get update` and inspect the output for the FluorineOS source; then
  `apt-cache policy fluorine-desktop`.
- Expected result: `InRelease` fetched and verified; no `NO_PUBKEY`, expired key, or hash
  mismatch; the candidate equals the published version.
- Pass criteria: update exits 0 and the candidate matches the archive index.

### APT-03 Install the desktop set from the archive
Subsystem: APT repository and package installation | Failure severity: Critical | Test environment: E5 Networked VM | Result status: NOT TESTED

- Preconditions: clean trixie system; `trixie-backports` enabled with the shipped pin;
  keyring installed.
- Test procedure: run
  `apt-get install --no-install-recommends fluorine-desktop fluorine-artwork fluorine-keyring`.
- Expected result: dependency resolution succeeds, Hyprland `0.55.x` is selected from
  backports, and no unmet dependency is reported.
- Pass criteria: install completes with exit 0 and `hyprland` reports a 0.55 version.

### APT-04 Repository metadata and payload integrity
Subsystem: APT repository and package installation | Failure severity: Critical | Test environment: E5 Networked VM | Result status: NOT TESTED

- Preconditions: archive checked out locally.
- Test procedure: run `gpg --verify dists/trixie/InRelease` with the packaged key; compare each
  `SHA256` in `Packages` with `sha256sum` of the pool file; in a throwaway copy, alter one
  `.deb` and confirm `apt-get update`/`install` refuses it.
- Expected result: both `Release.gpg` and `InRelease` verify; all digests match; the altered
  copy is rejected.
- Pass criteria: no unverified file accepted and no digest mismatch.

## 20. Desktop package upgrade

### UPG-01 Dry-run upgrade summary
Subsystem: Desktop package upgrade | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: an installed system with an older `fluorine-*` package set.
- Test procedure: run `flr-update --check`; diff `dpkg-query -W` before and after.
- Expected result: the list shows the pending FluorineOS and security upgrades; no package
  changes.
- Pass criteria: no version changed and the listing is accurate.

### UPG-02 In-place upgrade with a pre-update snapshot
Subsystem: Desktop package upgrade | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: Btrfs root; Snapper configured; pending upgrades.
- Test procedure: run `flr-update`; confirm the snapshot, the upgrade, and the new versions;
  log out and back in.
- Expected result: snapshot `pre-update` exists, packages upgrade cleanly, and the session
  starts with the new configuration.
- Pass criteria: no broken package state (`dpkg --audit` clean) and no session regression.

### UPG-03 Reboot reporting
Subsystem: Desktop package upgrade | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a kernel or core package upgrade pending.
- Test procedure: run `flr-update`; inspect `/var/run/reboot-required` and the reported package
  list; reboot.
- Expected result: the pending reboot and requesting packages are reported; the system boots
  normally afterwards.
- Pass criteria: report accurate and boot clean.

## 21. Calamares installer

### CAL-01 Launch, branding, and links
Subsystem: Calamares installer | Failure severity: High | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: live desktop.
- Test procedure: launch `Install FluorineOS`; inspect the welcome page and the release-notes
  link target.
- Expected result: branding matches the artwork package, version strings are consistent with
  the build label, and the release-notes link resolves (no 404).
- Pass criteria: no placeholder text and no dead link.

### CAL-02 Six-step sequence and validation
Subsystem: Calamares installer | Failure severity: Critical | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: live desktop.
- Test procedure: walk welcome, locale, keyboard, partition, users, and summary; attempt to
  continue with an empty password, with mismatched passwords, and with a 7-character
  password; then with an 8-character password.
- Expected result: exactly the six documented steps. Empty, mismatched, and 7-character
  passwords are blocked with a clear message; the 8-character password is accepted.
  `users.conf` sets `minLength: 8` with no libpwquality section, so no character-class rule
  is applied.
- Pass criteria: cannot proceed with a password shorter than 8 characters, and can proceed
  with exactly 8 characters drawn from a single character class.

### CAL-03 Fully offline installation
Subsystem: Calamares installer | Failure severity: Critical | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: live medium booted with networking disabled.
- Test procedure: complete an installation with no network; inspect the installer log for mirror
  access.
- Expected result: the install completes from the medium, with no repository refresh or
  network error.
- Pass criteria: exit to the finished page; no mirror contact in the log.

### CAL-04 Post-install cleanup of live-only files
Subsystem: Calamares installer | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: completed installation.
- Test procedure: check
  `/etc/sudoers.d/99-fluorine-live-installer`,
  `/etc/skel/Desktop/install-fluorineos.desktop`,
  `/home/<user>/Desktop/install-fluorineos.desktop`,
  `/etc/xdg/autostart/calamares-desktop-icon.desktop`,
  `/etc/calamares`, `/usr/share/calamares/branding/debian`,
  `/usr/share/applications/calamares-install-debian.desktop`, and
  `/usr/share/pixmaps/install-debian.png` on the installed system. Then read
  `/var/log/fluorineos-install/cleanup.log`.
- Expected result: the sudoers rule, both shortcuts, the XDG autostart entry, the Debian
  installer desktop entry, the Debian pixmap, the Debian branding directory, and the
  Calamares configuration tree are all absent. `cleanup.log` lists each path as removed or
  absent, with no FAILED lines.
- Pass criteria: every listed path is absent, unrelated files under the same directories are
  untouched, and a second manual run of the cleanup helper exits 0 without changing
  anything.

### CAL-05 Failure handling on an unsuitable disk
Subsystem: Calamares installer | Failure severity: High | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: a target disk smaller than the documented minimum.
- Test procedure: attempt an automatic install on a disk below 15 GiB of available storage.
- Expected result: the welcome page reports the storage requirement and refuses to continue
  (`requiredStorage: 15.0` is in the blocking `required` list, together with `ram`). A
  machine with less than 2.5 GiB of RAM is refused the same way. Nothing is written to any
  disk.
- Pass criteria: the installer cannot reach the partition page, no partition table is
  created, and the installer remains usable.

### CAL-06 Module sequence and configuration ownership
Subsystem: Calamares installer | Failure severity: Critical | Test environment: E1 Static | Result status: NOT TESTED

- Preconditions: source checkout of the build that produced the ISO.
- Test procedure: run `bash tests/validation/phase4-test.sh`; then read
  `/root/.cache/Calamares/session.log` (or the preserved copy) for the module list.
- Expected result: the exec phase is partition, mount, unpackfs, machineid, fstab, locale,
  keyboard, localecfg, luksbootkeyfile, users, hwclock, packages, initramfscfg, initramfs,
  bootloader, shellprocess, umount. `packages` precedes `initramfscfg`/`initramfs`, and
  `initramfs` precedes `bootloader`. `displaymanager`, `networkcfg`, `services-systemd`,
  `grubcfg` and `luksopenswaphookcfg` are absent. Every executed module has a configuration
  file in the repository, except `mount`.
- Pass criteria: static test exits 0 and the session log shows no "module not found" and no
  "configuration file not found" for any executed module.

### CAL-07 Installer log preservation
Subsystem: Calamares installer | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: completed installation (successful, and separately a failed one).
- Test procedure: list `/var/log/fluorineos-install/`, read `session.log`,
  `install-context.txt`, `snapper.log`, and `cleanup.log`; check modes and ownership.
- Expected result: the directory is 0750 root:root, `session.log` is 0640 and contains the
  Calamares session up to the final steps, `install-context.txt` records the source path,
  size and timestamp, and no passphrase or user password appears in any file. On a failed
  install the log is present and truncated at the failure point.
- Pass criteria: all four files present with correct modes, and a `grep -Ei 'pass(word|phrase)'`
  shows no credential value. Note: the copy is taken during `shellprocess`, so it does not
  include the finished-page rendering after it.

## 22. Partitioning and filesystem configuration

### PART-01 Automatic layout
Subsystem: Partitioning and filesystem configuration | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: blank virtual disk; automatic partitioning selected.
- Test procedure: complete the install; run `lsblk -f`, `blkid`, and `swapon --show` from the
  installed system.
- Expected result: an EFI system partition, a Btrfs root, and an active swap device; no
  second ESP and no unformatted leftovers.
- Pass criteria: layout matches the documented defaults and the system boots.

### PART-02 Manual partitioning
Subsystem: Partitioning and filesystem configuration | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: blank disk.
- Test procedure: create a custom layout in manual mode with separate `/` and `/home`; install.
- Expected result: the installer honours the layout and the system boots with both mounts.
- Pass criteria: `findmnt` shows the requested mount points and no installer error.

### PART-03 Installed fstab correctness
Subsystem: Partitioning and filesystem configuration | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: completed installation.
- Test procedure: read `/etc/fstab`; reboot twice; run `systemctl --failed`.
- Expected result: UUID-based entries for ESP, root (`subvol=@`), home (`subvol=@home`),
  snapshots (`subvol=@snapshots`), logs (`subvol=@log`), and swap; the crypttab options are
  `luks,keyscript=/bin/cat` on an encrypted install; no live medium references; no failed
  units after reboot.
- Pass criteria: clean boot with no emergency shell and no fstab errors.

### PART-04 Swap and ZRAM on the installed system
Subsystem: Partitioning and filesystem configuration | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: completed installation.
- Test procedure: run `swapon --show`, `zramctl`, and `cat /etc/default/zramswap`.
- Expected result: the disk swap and the zram device are active with zstd at the configured
  percentage.
- Pass criteria: both active and correctly prioritised.

## 23. Btrfs subvolumes

### BTRFS-01 Subvolume layout
Subsystem: Btrfs subvolumes | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: Btrfs root install.
- Test procedure: run `btrfs subvolume list /` and `findmnt -t btrfs`.
- Expected result: `@` mounted at `/`, `@home` at `/home`, `@snapshots` at `/.snapshots`,
  `@log` at `/var/log`.
- Pass criteria: all four present and mounted at the documented paths, and `/var/log` is a
  separate mount rather than a directory inside `@`.
- Rationale for `@log`: log writes must not churn every snapshot, and a rollback of `@` must
  not discard `/var/log/fluorineos-install`, which is where installer diagnostics live.

### BTRFS-02 Snapshot isolation from home
Subsystem: Btrfs subvolumes | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: at least one snapshot of `@`.
- Test procedure: create a file in `/home`, roll the root subvolume back, then inspect the file.
- Expected result: `/home` content is untouched by a root rollback.
- Pass criteria: the home file survives and root reflects the snapshot.

### BTRFS-03 Boot subvolume and mount options
Subsystem: Btrfs subvolumes | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system.
- Test procedure: inspect `findmnt /`, the kernel command line, and the fstab `subvol=` values.
- Expected result: root mounts `subvol=@`, the ESP is vfat, and `/` is not mounted at the
  top-level subvolume.
- Pass criteria: consistent values across fstab, mount table, and boot.

## 24. Encryption (LUKS1)

The supported architecture is LUKS1 with GRUB as the unlocker; see docs/INSTALLER.md.
LUKS2 is not offered by the configuration and must not appear in any install.

### LUKS-01 Automated encryption creates a bootable LUKS1 container
Subsystem: Encryption | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: blank disk; encryption enabled in the automatic layout.
- Test procedure: complete the install; from a rescue shell run `cryptsetup luksDump <device>`
  for the root container and for the swap container.
- Expected result: `Version: 1` on the root container, and `PBKDF2` key derivation rather than
  Argon2i/Argon2id. The keyslot KDF is the deciding property: GRUB can read a LUKS1 header
  and its PBKDF2 keyslot, and cannot unlock a LUKS2/Argon2id one.
- Pass criteria: `Version: 1` for the root container, `luksDump` lists no Argon2 KDF, and the
  root filesystem is inside the container. A LUKS2 container is a FAIL even if the install
  completed, because it is not bootable by the shipped GRUB.

### LUKS-02 Boot unlock flow
Subsystem: LUKS2 encryption | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: encrypted install.
- Test procedure: boot and enter the passphrase at the GRUB prompt; count the prompts; after
  login inspect `/etc/crypttab`, `findmnt /`, and `lsblk`.
- Expected result: GRUB unlocks the container and loads the kernel. Exactly one passphrase
  prompt is shown: `luksbootkeyfile` plus `crypttabOptions: luks,keyscript=/bin/cat` remove
  the second initramfs prompt. `/` is mounted from the mapper device and the ESP is the only
  unencrypted filesystem.
- Pass criteria: system boots to the greeter with no plaintext root, and the boot shows one
  prompt rather than two. Two prompts is a FAIL for the single-prompt contract, not a boot
  failure.

### LUKS-03 Wrong passphrase handling
Subsystem: LUKS2 encryption | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: encrypted install.
- Test procedure: boot and enter a wrong passphrase three times, then the correct one.
- Expected result: each failure returns to the prompt with a clear message; the correct
  passphrase still unlocks.
- Pass criteria: no data corruption and no boot loop.

### LUKS-04 Initramfs and key hygiene
Subsystem: LUKS2 encryption | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: encrypted install.
- Test procedure: inspect `lsinitramfs /boot/initrd.img-* | grep -E 'cryptsetup|crypto_keyfile'`,
  `/etc/crypttab`, the permissions on `/crypto_keyfile.bin` and the initramfs, and
  `grep -E 'resume|GRUB_ENABLE_CRYPTODISK' /etc/default/grub /boot/grub/grub.cfg`.
- Expected result: cryptsetup and the keyfile are present in the initramfs, crypttab
  references the correct UUID with the `keyscript=/bin/cat` option, and the keyfile is not
  world-readable (initramfs 0600, keyfile 0400 or root-readable only). No `resume=` kernel
  parameter is present: hibernation is not supported.
- Pass criteria: no missing module, no key material in world-readable files, and no `resume=`
  claim in the generated configuration.

## 25. Bootloader installation

### BOOT-01 EFI system partition and NVRAM entry
Subsystem: Bootloader installation | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: completed installation.
- Test procedure: run `efibootmgr -v`, `ls -R /boot/efi/EFI`, and `findmnt /boot/efi`.
- Expected result: a boot entry labelled `FluorineOS` pointing at
  `/boot/efi/EFI/FluorineOS/grubx64.efi`, plus the fallback copy
  `/boot/efi/EFI/BOOT/BOOTX64.EFI` (`installEFIFallback: true`). The ESP directory name comes
  from `efiBootloaderId: "FluorineOS"`, not from branding. No shim is present.
- Pass criteria: entry present, ESP mounted, both GRUB binaries exist, and no
  `shimx64.efi`/`mmx64.efi` pair is present (their absence matches the documented Secure
  Boot contract).

### BOOT-02 Menu entries on the installed system
Subsystem: Bootloader installation | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system.
- Test procedure: boot the primary entry and the recovery entry; confirm the kernel command
  lines.
- Expected result: primary uses `quiet splash`; recovery is verbose and reaches a usable
  environment.
- Pass criteria: both boot and the documented verbosity difference holds.

### BOOT-03 NVRAM persistence and Secure Boot state
Subsystem: Bootloader installation | Failure severity: High | Test environment: E4 Physical | Result status: NOT TESTED

- Preconditions: physical UEFI machine with Secure Boot togglable, and a second machine or
  OVMF configuration that will only boot signed media.
- Test procedure: reboot twice with Secure Boot off; then enable Secure Boot and boot the
  installed disk; then attempt to boot the live ISO with Secure Boot on.
- Expected result: with Secure Boot off the NVRAM entry persists and the system boots. With
  Secure Boot on the firmware refuses the unsigned `grubx64.efi`, and it also refuses the
  ISO, because `auto/config` does not enable Secure Boot for the live medium. Both refusals
  must be explicit firmware messages, not a black screen or a `grub>` prompt.
- Pass criteria: the documented limitation reproduces identically from the medium and the
  installed disk. A successful Secure Boot boot is not expected and would mean the contract
  in docs/INSTALLER.md is stale.

## 26. Post-install first boot

### FIRST-01 Greeter and first login
Subsystem: Post-install first boot | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installation just completed; medium removed.
- Test procedure: boot the disk; log in as the created user.
- Expected result: tuigreet appears on vt7 and the session starts via `start-hyprland`.
- Pass criteria: no emergency shell, no missing firmware prompt, desktop reachable.

### FIRST-02 Desktop defaults from skel
Subsystem: Post-install first boot | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: first login.
- Test procedure: inspect `~/.config/hypr`, `~/.config/waybar`, `~/.config/kitty`, the XDG
  directories, the wallpaper, the shader, and the cursor theme.
- Expected result: the full skel tree is copied, XDG directories exist, and wallpaper and
  shader are restored.
- Pass criteria: every documented default present with no manual setup.

### FIRST-03 Onboarding appears exactly once
Subsystem: Post-install first boot | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: first login.
- Test procedure: observe the first login, log out, log in again; check
  `~/.local/state/fluorine/onboarded`.
- Expected result: the cheat sheet appears only on the first login and the marker exists.
- Pass criteria: second login shows no sheet.

### FIRST-04 Live-only state is gone
Subsystem: Post-install first boot | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system.
- Test procedure: check the live installer sudoers file and shortcut, `sudo -l`, `/etc/hostname`,
  and `/etc/timezone`.
- Expected result: no live installer privileges or shortcuts; normal sudo for the user;
  hostname and timezone from the installer.
- Pass criteria: all four correct.

### FIRST-05 Account, groups, and sudo
Subsystem: Post-install first boot | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system; user created as `tester`.
- Test procedure: inspect `/etc/passwd`, run `id tester`, `ls -l /etc/sudoers.d`, `visudo -c`,
  and `sudo -v` as the user.
- Expected result: the user exists with `/bin/bash` and home mode 0700, is a member of `sudo`
  plus the documented default groups, `/etc/sudoers.d/10-installer` exists and validates, and
  `sudo -v` succeeds with no password prompt failure.
- Pass criteria: group membership matches `users.conf` exactly and `visudo -c` reports no
  syntax error.

### FIRST-06 Root account remains locked
Subsystem: Post-install first boot | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system.
- Test procedure: run `passwd -S root` and `su -` with an empty password.
- Expected result: root is locked (`L`), consistent with `setRootPassword: false`, and `su -`
  cannot authenticate.
- Pass criteria: root locked and no root login path.

### FIRST-07 Installer autologin and greetd state
Subsystem: Post-install first boot | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system.
- Test procedure: read `/etc/greetd/config.toml`, check for any autologin file created by the
  users module, and boot twice.
- Expected result: `config.toml` is the shipped file (no greeter rewrite), `doAutologin: false`
  produced no autologin configuration, and the greeter appears on both boots.
- Pass criteria: no rewritten config, no autologin, greeter reachable every boot.

### FIRST-08 Hostname resolution
Subsystem: Post-install first boot | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system.
- Test procedure: run `hostname`, `cat /etc/hostname`, `cat /etc/hosts`, `getent hosts "$(hostname)"`,
  and `sudo -v`.
- Expected result: `/etc/hostname` and the `127.0.1.1` line in `/etc/hosts` name the same host,
  `getent hosts` resolves it, and `sudo -v` prints no "unable to resolve host" warning.
- Pass criteria: no resolver warning and no duplicate or conflicting `127.0.1.1` lines.

### FIRST-09 Locale and keyboard survive the install
Subsystem: Post-install first boot | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installation performed with a non-default locale and layout (for example
  `de_DE.UTF-8` and `de`).
- Test procedure: run `localectl status`, `locale`, `locale -a | grep -i de_DE`, and
  `cat /etc/default/keyboard`.
- Expected result: the chosen locale is generated and active, `/etc/default/keyboard` carries
  the chosen layout, and the session uses it.
- Pass criteria: all three reflect the installer selection, proving `localecfg` and the
  keyboard module wrote the target and not only the live session.

## 27. Snapper snapshot creation and restoration

### SNAP-00 The installer created the root configuration
Subsystem: Snapper snapshot creation and restoration | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a Btrfs install produced by the current configuration.
- Test procedure: on the installed system run `test -f /etc/snapper/configs/root`,
  `snapper list-configs`, `snapper --no-dbus -c root list`, and read
  `/var/log/fluorineos-install/snapper.log`.
- Expected result: the configuration exists, `SUBVOLUME="/"`, `TIMELINE_CREATE="no"`, and the
  log records that the target filesystem was detected as `btrfs` and the configuration was
  created or verified. It must not record a skip.
- Pass criteria: all commands exit 0 and the log contains no `not btrfs` skip line. This case
  is the one that fails on the pre-remediation configuration, where the chroot reported the
  live overlay and the installer reported success with no configuration at all.

### SNAP-01 Root configuration
Subsystem: Snapper snapshot creation and restoration | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: Btrfs install.
- Test procedure: run `snapper --no-dbus -c root list` and inspect `/etc/snapper/configs/root`.
- Expected result: a `root` configuration with `SUBVOLUME="/"` and a working list command.
- Pass criteria: list works without error; configuration matches `/.snapshots`.

### SNAP-02 Create and list snapshots
Subsystem: Snapper snapshot creation and restoration | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: configuration present.
- Test procedure: run `flr-snapshot create test-snap`; then `flr-snapshot list` and
  `snapper list`.
- Expected result: one read-only snapshot with the label, visible in both listings.
- Pass criteria: ids and descriptions agree.

### SNAP-03 Rollback and recovery
Subsystem: Snapper snapshot creation and restoration | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a known-good snapshot and a deliberate change to `/`.
- Test procedure: run `flr-snapshot rollback <id>`, confirm; reboot; verify the change is undone
  and `/home` is intact.
- Expected result: root returns to the snapshot state, home untouched, system boots.
- Pass criteria: both conditions hold after reboot.

### SNAP-04 GRUB refresh behaviour
Subsystem: Snapper snapshot creation and restoration | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: `grub-btrfs` not installed (the default).
- Test procedure: create a snapshot and read the command output.
- Expected result: the tool reports that no snapshot menu generator is installed and does
  not fail.
- Pass criteria: exit status 0 and a clear message; boot menu still correct.

## 28. Recovery and troubleshooting

### REC-01 Console fallback
Subsystem: Recovery and troubleshooting | Failure severity: Critical | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: installed system with a broken graphical session.
- Test procedure: switch to a TTY with `Ctrl+Alt+F2`, log in, and start a shell.
- Expected result: a working text login on a spare VT while the session is broken.
- Pass criteria: login succeeds and the system remains responsive.

### REC-02 Diagnostic report
Subsystem: Recovery and troubleshooting | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: broken and healthy states.
- Test procedure: run `flr-doctor` in both states; compare with the actual service state.
- Expected result: the report identifies the failing subsystem with `[WARN]` or `[ERROR]`
  and remains readable without colour.
- Pass criteria: no false OK for the known failure and no false alarm in the healthy state.

### REC-03 Recover from a broken Hyprland configuration
Subsystem: Recovery and troubleshooting | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a deliberately invalid `~/.config/hypr/hyprland.lua`.
- Test procedure: log in, observe the failure, move the file aside from a TTY, log in again.
- Expected result: the failure is diagnosable and a clean login is possible with the
  defaults restored.
- Pass criteria: no reinstall required; `hyprctl configerrors` explains the original fault.

### REC-04 Offline root rollback from the live medium
Subsystem: Recovery and troubleshooting | Failure severity: Critical | Test environment: E2 QEMU live | Result status: NOT TESTED

- Preconditions: unbootable installed system with snapshots; live ISO available.
- Test procedure: boot the live medium, mount the Btrfs root, list subvolumes, and roll `@` back
  to a snapshot using the documented procedure; reboot the disk.
- Expected result: the installed system boots again with `/home` preserved.
- Pass criteria: recovery completes without reinstalling.

### REC-05 Package recovery from the archive
Subsystem: Recovery and troubleshooting | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a removed or broken `fluorine-desktop` package, network access.
- Test procedure: run `apt-get install --reinstall fluorine-desktop` and `apt-get -f install`.
- Expected result: the package reinstalls cleanly from the signed archive and the session
  starts.
- Pass criteria: `dpkg --audit` clean and desktop functional.

### REC-06 Interrupted installation
Subsystem: Recovery and troubleshooting | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a target disk, live media, and a way to kill the VM.
- Test procedure: kill QEMU during `unpackfs`, reboot the live medium, and run the installer
  again onto the same disk with the same automatic layout.
- Expected result: the second run completes; no stale mount, LUKS mapping, or swap remains
  from the first; the disk boots afterwards.
- Pass criteria: second install succeeds and the installed system boots.

### REC-07 Reinstall over an existing FluorineOS install
Subsystem: Recovery and troubleshooting | Failure severity: High | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: a disk already carrying FluorineOS with Btrfs subvolumes and
  `/etc/snapper/configs/root`.
- Test procedure: install again onto that disk using manual partitioning over the existing
  subvolumes.
- Expected result: either the install completes and `snapper-init` repairs and re-validates the
  existing configuration, or it refuses with a clear message. It must not report success while
  leaving an unusable Snapper configuration.
- Pass criteria: `snapper --no-dbus -c root list` works afterwards, or the refusal is explicit
  and nothing was half-written.

### REC-08 Encrypted swap does not delay boot
Subsystem: Recovery and troubleshooting | Failure severity: Medium | Test environment: E3 QEMU installed | Result status: NOT TESTED

- Preconditions: encrypted install.
- Test procedure: after login run `cat /etc/crypttab`, `swapon --show`, `systemd-analyze blame`,
  and `journalctl -b | grep -iE 'timed out|device.*not found'`.
- Expected result: the swap container is unlocked and active, no unit waits on a missing
  device, and no `resume=` parameter was generated. Hibernation is documented as unsupported,
  so no resume path is expected to work.
- Pass criteria: swap active, no device timeout in the journal, and `systemctl hibernate`
  either refuses or is documented as a known failure rather than silently losing the session.

## 29. Artifact version consistency

### VER-01 Version source agreement
Subsystem: Artifact version consistency | Failure severity: Critical | Test environment: E1 Static inspection | Result status: NOT TESTED

- Preconditions: a built ISO or an installed FluorineOS root, plus the source checkout that
  produced it. Inspection is read-only: no boot, mount, disk image, or repository write.
- Test procedure: run
  `scripts/validation/inspect-artifact.sh --iso <iso> --json --manifest <evidence>/manifest.json`
  for an ISO. Use `--root <dir>` for an extracted filesystem root or `--system` for a
  running FluorineOS system. For a tagged artifact from another checkout, pass
  `--expected-version <version>` so the reference is that tag, not the current worktree.
  Add `--expected-packages <file>` only when a recorded component package set must be
  enforced; the file contains `package version` or `package = version` lines. Save the
  JSON report as evidence and record the result with
  `scripts/validation/record-result.sh --test-id VER-01 --result <status> --environment E1 ...`.
- Required tools: `xorriso`, `unsquashfs`, `dpkg-query`, and `jq`. A missing tool produces
  BLOCKED, names the tool, and never silently substitutes a partial check. Extracted
  squashfs files are cached outside Git, by default under
  `$XDG_CACHE_HOME/fluorineos/validation`.
- Version relationships:

  | Source | Relationship | Requirement |
  | --- | --- | --- |
  | Repository `VERSION` | Reference | Defines the expected OS version unless `--expected-version` overrides it for a tagged artifact. |
  | ISO application id `FluorineOS <version>` | Exact | Must equal the reference when an ISO is inspected. |
  | ISO volume label `FLUORINEOS_<major>_<minor>_<patch>` | Exact | Must decode to the reference when an ISO is inspected. |
  | `/etc/os-release` `VERSION` and `VERSION_ID` | Exact | Both must equal the reference. |
  | `/etc/issue` | Exact | First line must name FluorineOS and the reference. |
  | Calamares branding `version` and `shortVersion` | Exact | Both must equal the reference when branding ships. |
  | `fluorine-desktop`, `fluorine-artwork`, `fluorine-keyring` | Independent | Must be present and report a valid version; versions are recorded, not required to equal the OS version. |
  | Other shipped `fluorine-*` packages | Independent | Recorded only. Enforced only when named in `--expected-packages`. |

- Expected result: every exact source is present, parseable, and equal to the reference;
  the three required component packages are present; any extra `fluorine-*` packages are
  recorded; and any `--expected-packages` entries match exactly.
- Pass criteria: inspector exits 0 and reports PASS; the JSON report lists no
  discrepancies, and the manifest `version_report` and `stages.version` show PASS when a
  manifest was supplied.
- Fail criteria: any exact version source is missing, invalid, or mismatched; a required
  component package is missing; or an `--expected-packages` version is wrong. Record the
  discrepancy source, expected value, and actual value. An old ISO that disagrees with the
  current build tree is a real discrepancy, not a reason to skip this test.
- Blocked criteria: a required tool is absent, a source cannot be read, or the reference
  version is unavailable and no confirmed discrepancy exists. Record the exact missing
  tool or source.
- Evidence: inspector JSON report, the exact command, and the manifest if one was merged.
  Independent component versions may legitimately differ from the OS version; do not
  report that as a failure without an expected-packages entry.

## 30. Release gate summary

The following tests block a release when they FAIL or are BLOCKED. Everything else may ship
with a recorded, approved exception.

| Gate | Tests |
| --- | --- |
| Image integrity | ISO-01, ISO-02, VER-01 |
| Boot | ISO-03, ISO-04, ISO-05 |
| Session entry | DM-01, DM-03, HYPR-01 |
| Core desktop | AUD-01, NET-01 |
| Security | IDLE-02, IDLE-04 |
| Package delivery | APT-01, APT-02, APT-03, APT-04 |
| Installer | CAL-02, CAL-03, CAL-04, CAL-06, CAL-07 |
| Storage | PART-01, PART-03, BTRFS-01, BTRFS-02, SNAP-00 |
| Encryption | LUKS-01, LUKS-02, LUKS-04 |
| Bootloader | BOOT-01 |
| First boot | FIRST-01, FIRST-04 |
| Recovery | SNAP-03, REC-04 |

## 31. Known limitations of this plan

- The idle policy under test is the shipped one: dim 300 s, lock 600 s, suspend 1200 s on
  battery, no DPMS-off listener. If a DPMS listener is added, IDLE-01 through IDLE-03 must
  be revised.
- Wi-Fi, Bluetooth, backlight, battery, and fractional scaling require E4. They cannot be
  validated in QEMU and must not be reported as passing from a VM run.
- Secure Boot is unsupported by design: `auto/config` does not build the medium with shim
  and the installed bootloader is unsigned. BOOT-03 records the refusal, and a successful
  Secure Boot boot means the documented contract is stale, not that the test passed.
- Hibernation is unsupported. LUKS-04 and REC-08 assert that no `resume=` claim is generated;
  `systemctl hibernate` is not expected to resume.
- Snapshots are not bootable from GRUB: `grub-btrfs` is not packaged for trixie. REC-04 is
  the only supported rollback path.
- The installer's own static and fixture checks live in `tests/validation/phase4-test.sh`
  and cover CAL-06, the cleanup helper, log preservation, and Snapper initialisation logic.
  They prove configuration semantics, not a successful installation.
- Theming tests verify tokens, geometry, and icon resolution; they do not judge visual taste.
- No test here validates the third-party Flint writer, because no repository ships it.
- CI status is not evidence. The ISO workflow invokes the shared boot gate for only
  ISO-03 and ISO-04; the desktop and artwork packaging workflows are currently failing
  and must not be cited as a pass.
- VER-01 checks declared version sources, not binary provenance. Matching labels do not
  prove that the squashfs was built from the recorded commit.
- A manifest stage left PENDING still needs an explicit evidence-backed result in the
  ledger. QEMU exiting 0 proves only that the process ended cleanly; use boot-gate
  `gate.txt` and serial evidence for ISO-03 and ISO-04.
- The direct-kernel live gate cannot validate firmware or bootloader behaviour. A PASS
  there does not replace ISO-03, GRUB-01, GRUB-02, or BOOT-03.
- Documentation consistency is audited separately; this plan tests behaviour.

## 32. Run record

Copy this block into the release record for every test run.

```text
Artifact:            FluorineOS-<version>-amd64.iso
Size (bytes):        
SHA-256:             
Manifest:            
Version report:      
Ledger:              
Boot gate ISO-03:    <evidence dir>/gate.txt
Boot gate ISO-04:    <evidence dir>/gate.txt
fluorine commit:     
fluorine-desktop:    
fluorine-artwork:    
fluorine-keyring:    
VER-01 result:       
Date:                
Tester:              
Environment:         E1 / E2 / E3 / E4 / E5
Firmware:            OVMF version or physical UEFI model
GPU:                 
RAM / vCPU:          
Result summary:      PASS <n> | FAIL <n> | BLOCKED <n> | NOT TESTED <n>
Release decision:    APPROVED / REJECTED / APPROVED WITH EXCEPTIONS
Exceptions:          
```


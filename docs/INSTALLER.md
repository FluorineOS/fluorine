# FluorineOS installer contracts

This document is the authoritative statement of what the Calamares installer in
this repository does and does not support. It describes the configured
behaviour, not the result of an installation run: every runtime claim below is
marked with its evidence level.

Evidence levels used here:

| Level | Meaning |
| --- | --- |
| Static | Proven by reading the shipped configuration, package lists, or upstream source. |
| Fixture | Proven by the non-destructive tests in `tests/validation/phase4-test.sh`, which run the installer's own helpers against temporary directory trees. |
| Deferred | Requires a real installation, boot, or firmware. Recorded in `TEST_PLAN.md` as NOT TESTED. |

Nothing in this repository records a completed installation of the current
configuration. The only executed install in `SOURCE_OF_TRUTH/BUILD_STATUS.md`
used ext4 with a swap partition and an earlier module sequence.

## 1. Module sequence and configuration ownership

```
show: welcome, locale, keyboard, partition, users, summary
exec: partition, mount, unpackfs, machineid, fstab, locale, keyboard,
      localecfg, luksbootkeyfile, users, hwclock, packages, initramfscfg,
      initramfs, bootloader, shellprocess, umount
show: finished
```

Every executed module reads a configuration file from this repository:

| Module | Configuration | Owns |
| --- | --- | --- |
| partition | `modules/partition.conf` | filesystem, subvolumes, LUKS generation |
| unpackfs | `modules/unpackfs.conf` | squashfs source |
| machineid | `modules/machineid.conf` | per-install machine identity |
| fstab | `modules/fstab.conf` | fstab and crypttab options |
| locale | `modules/locale.conf` | timezone default, GeoIP off |
| keyboard | `modules/keyboard.conf` | `/etc/default/keyboard` |
| users | `modules/users.conf` | groups, password policy, hostname, `/etc/hosts` |
| packages | `modules/packages.conf` | offline package removal |
| initramfs | `modules/initramfs.conf` | initramfs rebuild scope |
| bootloader | `modules/bootloader.conf` | GRUB EFI target and id |
| shellprocess | `modules/shellprocess.conf` | target-side finalisation |
| mount | inherited from `calamares-settings-debian` | bind mounts used during execution only |

`initramfscfg`, `localecfg`, `hwclock`, `umount` and `finished` have no
configuration keys that FluorineOS needs to change and run on their packaged
defaults. `modules/displaymanager.conf` is documentation only and is not in the
sequence.

Ordering constraints that must not be changed without re-validating:

- `packages` runs before `initramfscfg` and `initramfs`. `live-config` diverts
  `update-initramfs`; the divert has to be gone before the image can be rebuilt.
- `fstab` and `luksbootkeyfile` run before `initramfscfg`, which installs the
  hook that copies `/etc/crypttab` and `/crypto_keyfile.bin` into the image.
- `initramfs` runs before `bootloader`, so `grub-mkconfig` sees the final
  initramfs.
- `shellprocess` runs before `umount`, while the target is still mounted.

## 2. Encryption

**Supported: LUKS1 with GRUB as the unlocker, automated and manual.**

`partition.conf` sets `luksGeneration: luks1`. This is a bootability
requirement:

- GRUB reads a LUKS1 header directly. It cannot unlock a LUKS2 keyslot, because
  cryptsetup creates LUKS2 keyslots with Argon2id and GRUB has no Argon2
  implementation.
- `luksGeneration` selects the container format, never the key derivation
  function. Setting `luks2` therefore produces an installation that completes,
  prompts for the passphrase at the GRUB menu, rejects the correct passphrase and
  drops to `grub>`. This is reported against Calamares by multiple distributions.
- `grub-probe` does not recognise LUKS2 headers, so `grub-mkconfig` cannot emit
  the `cryptomount` line that `/boot` needs when it lives inside the encrypted
  root. Converting the keyslot to PBKDF2 after installing does not repair that.

The rest of the encrypted path:

| Piece | Configuration | Effect |
| --- | --- | --- |
| `/boot` location | inside the encrypted root | GRUB unlocks once; no separate `/boot` partition |
| GRUB cryptodisk | `GRUB_ENABLE_CRYPTODISK=y` in `/etc/default/grub` | `grub-install` embeds cryptodisk and luks modules |
| Single passphrase prompt | `luksbootkeyfile` in the sequence | `/crypto_keyfile.bin` is registered with every container and copied into the initramfs |
| initramfs keyfile | `crypttabOptions: luks,keyscript=/bin/cat` in `fstab.conf` | initramfs-tools honours the keyfile instead of prompting again |
| initramfs generation | `initramfscfg` + `initramfs` modules | the target's crypttab and keyfile are in the image before the first boot |
| keyslot KDF | LUKS1 (PBKDF2) | readable by GRUB |

LUKS2 is not offered. The installer does not expose a setting that would produce
it, so there is no silent path to an unbootable encrypted system.

## 3. Secure Boot

**Unsupported for installed systems, and the live medium no longer claims
otherwise.**

- The installed bootloader is unsigned `grubx64.efi`. Firmware with Secure Boot
  enabled refuses it.
- `auto/config` does not pass `--uefi-secure-boot`, so the ISO is not built with
  Debian's shim either. The live medium and the installed system make the same
  claim: firmware must allow an unsigned bootloader.
- The practical consequence is a refusal at the first step instead of a
  successful install followed by an unbootable disk, which is what a
  shim-booted live medium with an unsigned target produced.

Enabling Secure Boot later requires the full signed chain: `shim-signed` and
`grub-efi-amd64-signed` in the image, `efiBootLoader: "sb-shim"` with the
ID that the signed GRUB binary's embedded prefix expects, and a verification run
on Secure Boot firmware. None of that can be validated without hardware, so it is
not claimed.

## 4. Dual boot

**Supported.** `os-prober` is in `config/package-lists/installer.list.chroot` and
`/etc/default/grub` sets `GRUB_DISABLE_OS_PROBER="false"`; Debian 13 disables
os-prober by default, so both are required.

- `grub-mkconfig` runs in the target during the bootloader step, with the live
  session's device nodes bound into the chroot, and adds entries for other
  operating systems it can identify.
- Existing EFI boot entries are not deleted. GRUB adds its own NVRAM entry and,
  because `installEFIFallback: true`, also writes `EFI/BOOT/BOOTX64.EFI`.
- Encrypted non-Linux volumes (BitLocker, FileVault) are not probed. They appear
  as absent, not as damaged.

## 5. Swap and hibernation

**Hibernation is unsupported on every FluorineOS installation.**

- Encryption: Calamares gives swap its own LUKS container, registered with the same keyfile, so swap is persistent rather than random-key. It is unlocked from `/etc/crypttab` during the normal boot, which is after the point where the kernel would look for a hibernation image.
- No `resume=` kernel parameter is written. `/etc/default/grub` ships with an
  empty `GRUB_CMDLINE_LINUX`, the `grubcfg` module is not in the sequence, and
  the bootloader module only emits `resume=` for the bootloaders FluorineOS does
  not use. The configuration therefore does not claim a working resume path.
- `luksopenswaphookcfg` is deliberately absent. It writes an `openswap` hook for
  `mkinitcpio`, which Debian does not use; running it would configure nothing
  while implying hibernation support.
- The system still has working suspend-to-RAM and zram, which is what the desktop
  idle policy uses.

Making hibernation work would require a random-key-free encrypted swap, an
initramfs that opens it before resume, and a `resume=` parameter validated by an
actual hibernate and resume cycle. None of that is implemented.

## 6. Filesystem layout and Snapper

Btrfs with four subvolumes:

| Subvolume | Mount point | Reason |
| --- | --- | --- |
| `@` | `/` | system; the rollback unit |
| `@home` | `/home` | user data; never part of a root rollback |
| `@snapshots` | `/.snapshots` | Snapper store; keeps snapshots out of `@` |
| `@log` | `/var/log` | keeps log writes out of snapshots and survives a rollback |

`/usr/lib/fluorineos/snapper-init` runs in the target through `shellprocess`:

- The filesystem type of the mounted target is measured outside the chroot and
  passed in. `findmnt -no FSTYPE /` inside a chroot resolves against the live
  mount namespace and reports the live overlay, which made the previous version
  skip Snapper on every real installation.
- It creates `/etc/snapper/configs/root` with `snapper create-config`, or seeds
  `/usr/share/snapper/config-templates/default` when `/.snapshots` already
  exists, which is the normal case for this layout.
- It pins `SUBVOLUME="/"` and `TIMELINE_CREATE="no"`. Timeline snapshots are off
  so the store does not grow unbounded; `flr-update` creates a `pre-update`
  snapshot before every upgrade.
- It validates the result with `snapper --no-dbus -c root list` and exits
  non-zero when a Btrfs root cannot be configured. A skip is only reported for a
  non-Btrfs root, which is the one case where Snapper does not apply.
- A reinstall over an existing install repairs and re-validates the existing
  configuration instead of reporting success unverified.

Snapshots are **not bootable from GRUB**: `grub-btrfs` is not packaged for
Debian 13. Rollback is performed from live media with `flr-snapshot rollback`.

## 7. Installer logging

`/var/log/fluorineos-install/` in the installed system contains:

| File | Content |
| --- | --- |
| `session.log` | the Calamares session log, with credential-shaped values redacted |
| `install-context.txt` | source path, size, timestamp of the copy |
| `snapper.log` | what Snapper initialisation did, including skips and errors |
| `cleanup.log` | every path the cleanup step removed, found absent, or failed on |

The copy is made by `installer-log-preserve`, which searches the live session's
root and user cache directories and `/var/log/calamares` for the newest
`session.log` rather than assuming one path. `/var/log` is its own subvolume, so
the log survives a rollback of `/`. A missing log is recorded as a note; it is
not an install failure.

## 8. Live-session privileges and cleanup

The live session may run exactly one command as root without a password:

```
Defaults:%sudo env_keep += "WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE"
%sudo ALL=(ALL) NOPASSWD: /usr/bin/calamares
```

There is no `/usr/bin/env` grant: `sudo env <command>` is unrestricted root. The
desktop entry runs `sudo calamares`; the three Wayland variables Calamares needs
are preserved with `env_keep`, which cannot inject `LD_PRELOAD` into a root
process the way an unrestricted environment grant can.

`installer-cleanup` runs inside the target and removes, idempotently:

- `/etc/sudoers.d/99-fluorine-live-installer` (the rule above)
- `/etc/skel/Desktop/install-fluorineos.desktop` and the same file in every user
  home directory
- `/etc/xdg/autostart/calamares-desktop-icon.desktop`, whose `Exec` binary is
  removed with the Debian Calamares packaging and which otherwise fails on every
  login
- Debian installer desktop entries, pixmaps and branding
- `/etc/calamares` and the Debian Calamares helper module descriptors

It requires an explicit `--installed-target` argument so it cannot be run on the
live session by accident, and it only ever removes literal installer paths.

## 9. User and password policy

| Item | Value | Rationale |
| --- | --- | --- |
| minimum password length | 8 | length dominates composition for offline guessing resistance |
| maximum password length | unlimited | no reason to reject a long passphrase |
| character-class rules | none | they produce predictable substitutions |
| empty password | rejected | `nonempty` is implicit and length 8 covers it |
| root account | locked | FluorineOS is sudo-only |
| created user | in `sudo`, receives `/etc/sudoers.d/10-installer` | matches the live privilege model |
| autologin | disabled | greetd authenticates every session |
| home permissions | `0700` | user data is not world-readable |

## 10. Locale, keyboard, and resources

- Locale: the user's selection is written to `/etc/locale.gen` and generated by
  `localecfg`. `locales` is an explicit package entry so a dependency trim cannot
  break the fatal `localecfg` step. The timezone default is the live session's,
  not a hardcoded city, and GeoIP is off.
- Keyboard: `writeEtcDefaultKeyboard: true` with `useLocale1: false`, because
  systemd-localed is not reachable from the target chroot and the localed path
  would leave `/etc/default/keyboard` unwritten.
- Hostname: the `users` module writes `/etc/hostname` and the matching
  `127.0.1.1` entry in `/etc/hosts`, so `sudo` does not print "unable to resolve
  host". The live image ships the same pair.
- Resources: 15 GiB storage and 2.5 GiB RAM, both blocking. The thresholds are
  derived from the unpacked image size plus snapshots and swap, not from a
  packaged default.

## 11. Known limitations

| Limitation | Consequence | Mitigation |
| --- | --- | --- |
| Secure Boot unsupported | firmware must allow an unsigned bootloader | documented here; the ISO is not shim-booted either |
| Hibernation unsupported | suspend-to-disk does not resume | suspend-to-RAM and zram only |
| No bootable snapshots | snapshots cannot be selected from the GRUB menu | rollback from live media with `flr-snapshot rollback` |
| LUKS2 not offered | newer container format unavailable | LUKS1 is what the shipped GRUB can unlock |
| No installer UI for hostname limits | hostname is chosen on the users page | `users.conf` rejects `localhost` and sanitises the value |
| Offline-only package set | no extra packages during install | the ISO carries everything the target needs |

## 12. Validation status

| Area | Static | Fixture | QEMU |
| --- | --- | --- | --- |
| module sequence and configuration ownership | yes | yes | deferred |
| encryption configuration | yes | partial | deferred |
| encrypted boot | no | no | deferred, release gate |
| Secure Boot | yes (declared unsupported) | n/a | deferred |
| dual boot | yes | no | deferred |
| Snapper initialisation | yes | yes | deferred, release gate |
| installer cleanup | yes | yes | deferred |
| log preservation | yes | yes | deferred |
| password policy | yes | no | deferred |
| hostname and `/etc/hosts` | yes | no | deferred |

Static and fixture checks live in `tests/validation/phase4-test.sh`. Runtime
cases are in `TEST_PLAN.md`; none of them has been executed against this
configuration.

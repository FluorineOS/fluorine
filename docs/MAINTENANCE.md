# Maintenance, Updates and Recovery

This is the runbook for a FluorineOS system after installation: what owns which
file, how an upgrade is supposed to run, what to do when it does not, and where
the recovery path stops. `docs/INSTALLER.md` covers how the system is laid out
during installation; this document starts where that one ends.

Nothing here promises automatic recovery. Every recovery step below is a command
a person runs, after reading what it does.

## What owns what

| Area | Owner | Consequence |
| --- | --- | --- |
| Installer behaviour | `config/includes.chroot/etc/calamares/modules/*.conf` | A `calamares` upgrade cannot silently change the password policy or the partition layout |
| Image contents | `config/package-lists/*.list.chroot`, `config/hooks/normal/*` | Two places, not three: a package is in a list, a unit is enabled in a hook |
| Desktop session | `fluorine-desktop` (`/etc/skel/.config`, `bin/flr-*`) | The files are conffile-free: a package upgrade replaces them, and user edits live in `$HOME` |
| Branding and icons | `fluorine-artwork` | Replaced wholesale on upgrade |
| Snapper configuration | `/usr/lib/fluorineos/snapper-init`, run once by the installer | Re-running it repairs and re-verifies an existing configuration |
| Update workflow | `flr-update`, `flr-snapshot` | No timer, no daemon, no automatic apt run |

Because the desktop files under `/etc/skel` are shipped by a package, an upgrade
overwrites them. Anything a user changed in `$HOME` is untouched: the session
reads `$HOME` first.

## APT configuration

Three sources, and only three:

| Source | Suite | Trust |
| --- | --- | --- |
| Debian | `trixie` | Debian archive keyring |
| Debian backports | `trixie-backports`, pinned to a named package list at priority 900 | Debian archive keyring |
| FluorineOS | `trixie` on `https://fluorineos.github.io/apt-repo` | `Signed-By` a single key shipped by `fluorine-keyring` |

The backports pin is a name list (`hyprland*`, `hypridle*`, `hyprlock*`,
`libhypr*`, `xdg-desktop-portal-hyprland`, and the few libraries those need), not
a blanket preference, so nothing else is ever taken from backports. Verify it
with `apt-cache policy hyprland` and `apt-cache policy <any other package>`.

## How an upgrade runs

`flr-update` is the supported path:

1. `apt-get update`, then `apt-get -s upgrade` to list what would change.
2. A free-space check: below 1 GiB on `/` it prints the recovery command before
   touching anything.
3. On Btrfs with a working Snapper configuration, `flr-snapshot create
   pre-update`. A failed snapshot aborts the upgrade; nothing is installed.
4. `apt-get upgrade`.

Two deliberate properties:

- **`upgrade`, not `full-upgrade`.** A package that needs another package removed
  is held back and listed as not upgraded. The alternative would remove software
  the user did not ask to remove, which is the wrong default for a workstation.
- **No `autoremove`.** Nothing is deleted on the user's behalf.

There is no automatic upgrade. Debian's `apt` package enables `apt-daily.timer`
and `apt-daily-upgrade.timer`, and on a fresh FluorineOS image both do nothing:
`/usr/lib/apt/apt.systemd.daily` runs `unattended-upgrade` only when that binary
exists and `APT::Periodic::Unattended-Upgrade` is set, and the image installs
neither `unattended-upgrades` nor any `APT::Periodic` configuration. Check with
`apt-config dump | grep Periodic` (expected: no output) and
`systemctl list-timers 'apt*'` (the timers exist and last ran without doing work).

Release upgrades between Debian codenames are **not** supported by FluorineOS
today. `trixie` is pinned everywhere; a `forky` upgrade is a Debian operation
that this project has not tested, and the backports pin would have to be
rewritten for it.

## When an upgrade stops half way

Interrupted upgrades are the common failure, and they are recoverable without
reinstalling:

```sh
sudo dpkg --configure -a      # finish configuration of unpacked packages
sudo apt-get -f install       # repair broken dependencies
sudo apt-get -s upgrade       # re-check before trying again
```

`flr-doctor` reports the first of these for you: it runs `dpkg --audit` and warns
when unfinished work is present. The pre-update snapshot is the fallback if the
system no longer boots; see the boundaries below before relying on it.

If the failure is a conffile prompt, the package is left unconfigured until the
question is answered. `apt-get upgrade` asks; answer it, do not force a default
with `--force-confold` unless the local file is known to be disposable.

## Disk space

The floor is 1 GiB free on `/` before an upgrade. `flr-doctor` reports free space
on `/`, `/home`, and `/var` and warns below it. When space is short, in order of
safety:

| Step | Command | What it removes |
| --- | --- | --- |
| Old downloaded packages | `sudo apt-get clean` | Cached `.deb` files only |
| Old journal entries | `sudo journalctl --vacuum-size=200M` | Journal beyond the limit |
| Old snapshots | `sudo flr-snapshot list`, then delete by id with `snapper` | Snapshots, never files |
| Flatpak runtimes no longer referenced | `flatpak uninstall --unused` | Runtimes, never applications |

Nothing here deletes user documents, and no FluorineOS component runs these
automatically. `apt-get autoremove` is deliberately not part of any workflow.

## Logs

`/var/log` is its own Btrfs subvolume (`@log`), so it survives a rollback of `/`
and does not churn snapshots of the root subvolume. The journal is persistent:
systemd's Debian `postinst` creates `/var/log/journal`, which is the condition
`Storage=auto` looks for, so `journalctl -b -1` works after a crash. Journald's
own size cap (a percentage of the filesystem, capped by systemd) applies; there
is no custom log rotation to maintain.

Installer logs land in `/var/log/fluorineos-install/`: `session.log`,
`snapper.log`, `cleanup.log`, `install-context.txt`. They are written once at
install time and are not rotated.

## Snapshots and recovery: what they are not

This is the part that must not be oversold.

- **A snapshot is not a backup.** It lives on the same Btrfs filesystem, in the
  same LUKS container, on the same disk. A failed disk, a corrupted filesystem,
  or a lost passphrase takes the snapshots with the system. Only a copy on other
  media is a backup.
- **Snapshots are not bootable from the GRUB menu.** `grub-btrfs` is not packaged
  for Debian 13, so the menu has no snapshot entries. This is the same boundary
  recorded in `docs/INSTALLER.md`.
- **A rollback only covers the root subvolume.** `/home` (`@home`), `/var/log`
  (`@log`), and `/.snapshots` (`@snapshots`) are separate subvolumes and are not
  part of it. A rollback does not restore user files, and it does not undo
  anything in `/var/log`.
- **A rollback is not automatic.** `flr-snapshot rollback <id>` requires a typed
  confirmation, refuses without a terminal unless `--yes` is given, and refuses
  snapshot 0. It changes the default subvolume and tells you to reboot; it does
  not reboot, repair, or repartition anything.
- **Snapshots exist only where Snapper was configured.** `flr-update` snapshots
  before an upgrade, and `flr-snapshot create` takes one on request. Timeline
  snapshots are off, boot snapshots are disabled, and the cleanup timer prunes to
  `NUMBER_LIMIT=50`. A system that never ran an update may have no snapshot at
  all.

### Rolling back a system that still boots

```sh
flr-snapshot list                 # find the pre-update id
sudo flr-snapshot rollback <id>   # asks for confirmation, then sets it default
sudo systemctl reboot
findmnt -no SOURCE,FSTYPE /       # after reboot: confirm the subvolume
```

### Rolling back a system that does not boot

Use the FluorineOS live medium. From the live session, mount the installed root
subvolume, then run Snapper against it:

```sh
sudo mount -o subvol=@ /dev/mapper/<root> /mnt
sudo snapper --no-dbus -c root -r /mnt list
sudo snapper --no-dbus -c root -r /mnt rollback <id>
sudo umount /mnt
```

Then reboot the installed system. Do not run `mkfs`, `fsck` repair, or any
partition change as part of this; those are separate operations with their own
consequences, and nothing in FluorineOS runs them for you.

## Recovery runbook

| Symptom | First check | Then |
| --- | --- | --- |
| Black screen, no boot | Power on, watch for the GRUB menu | Boot the previous kernel from "Advanced options"; if GRUB never appears, boot the live medium and inspect `/boot` |
| Boot stops before the greeter | `systemctl --failed` from a TTY (Ctrl+Alt+F2) | `journalctl -b -p err`; a failed `greetd` is a login problem, not a filesystem problem |
| Greeter appears, login loops | `journalctl -b -u greetd` | `cat /etc/greetd/config.toml`; the command must be `/usr/local/bin/fluorineos-greeter`, and the user `_greetd` |
| Session starts, desktop broken | `hyprctl reload` from a TTY, or log out and back in | `hyprland.lua` is the compositor config; a Lua error is reported in the session log. Restore the shipped file from `/etc/skel/.config/hypr/` |
| No network | `nmcli device status` | `flr-tui nmtui` from a TTY, or `systemctl restart NetworkManager` |
| Packages broken | `sudo dpkg --audit` | The `dpkg --configure -a` sequence above |
| Disk full | `df -h /` | The disk-space table above |
| User config corrupted | `flr-doctor` | Move the offending file aside, copy the shipped default from `/etc/skel/`, log back in |
| Update interrupted | `dpkg --audit`, `flr-doctor` | Finish the upgrade; roll back only if the system will not boot |

## Releasing an image

The image installs the three FluorineOS packages from `config/packages.chroot`,
not from the APT repository, so the staged `.deb` files are part of the source
tree. A release therefore has an order:

1. Build each package from its repository (`dpkg-buildpackage -b -uc -us`).
2. Copy the resulting `.deb` into `config/packages.chroot/`.
3. Confirm the staged version matches the source changelog; the helper test
   prints a warning while the two disagree.
4. Publish the packages to the APT repository before publishing an image that
   expects them there.

At the time of writing the staged `fluorine-desktop` is `0.15.1` while the
source is `0.16.1`. That is a release step that has not been run, not a bug in
the image: the built image simply ships the older desktop until the `.deb` is
rebuilt and staged.

## Runtime validation

Everything below is static or reasoned from package contents. It still needs a
real machine:

| Area | Command | Expected |
| --- | --- | --- |
| Upgrade end to end | `flr-update --check`, then `flr-update` | Pre-update snapshot created, upgrade applied, no package removed |
| Snapshot rollback | `sudo flr-snapshot rollback <id>` on a test install | Reboot lands on the snapshot's root; `/home` unchanged |
| Interrupted upgrade | kill `apt-get` mid-run, then `sudo dpkg --configure -a` | System returns to a consistent state |
| Low disk | fill a test VM to under 1 GiB, run `flr-update` | Warning printed before any change |
| Persistent journal | reboot, then `journalctl -b -1` | Previous boot is readable |
| APT timer behaviour | `systemctl list-timers 'apt*'`, `apt-config dump \| grep Periodic` | Timers present, no periodic configuration, no upgrade |
| Rollback from live media | the `snapper -r /mnt` sequence above | Rollback completes without touching other subvolumes |

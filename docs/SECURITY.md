# Security Baseline

FluorineOS ships the Debian 13 `trixie` security stack with a small number of
choices made explicitly. This document states what those choices are, why they
exist, what they do not cover, and which claims still need a machine to verify.
Nothing here is a guarantee of safety: the image is a desktop operating system
with a single privileged user, and physical access to an unlocked machine
defeats every control below.

Package versions and package contents in this document were read from the
`trixie` indexes and from the packages themselves on 2026-11-27.

## Threat model

The baseline targets a single-user workstation or laptop that is used
interactively. It assumes:

- The disk may be stolen, so the root volume is encrypted on request.
- The user is trusted with administrator rights, and authenticates with a
  password for `sudo`.
- The network is untrusted, so nothing listens on it by default.
- Firmware and kernel are trusted; Secure Boot is out of scope.

It does not attempt to defend a session against a hostile process running as the
same user, or a machine against an attacker with physical access to an unlocked
session.

## Defaults

| Area | Default | Where |
| --- | --- | --- |
| Root login | Root account stays locked (`setRootPassword: false`) | `config/includes.chroot/etc/calamares/modules/users.conf` |
| Administrator | Created user joins `sudo`; `sudo` asks for the user password | `users.conf`, Debian `sudo` defaults |
| Home directory | Created with mode `0700`, no other user can read it | `users.conf` |
| Password policy | Minimum 8 characters, no composition rules, no maximum | `users.conf` |
| Firewall | `deny incoming`, `allow outgoing`, enabled in the image | `config/hooks/normal/0200-services.hook.chroot` |
| Inbound ports | `5353/udp` only, for multicast DNS printer discovery | same hook |
| Remote access | No SSH, telnet, SMB, NFS, or FTP server is installed | `config/package-lists/` |
| Disk encryption | LUKS1 available in the installer, keyslot unlocked once by GRUB | `partition.conf`, `fstab.conf` |
| Machine identity | `machineid` module writes a fresh `/etc/machine-id` per install | `settings.conf` |
| Live credentials | Live session may run Calamares without a password; the rule is deleted on install | `0400-live-calamares-polkit.hook.chroot`, `installer-cleanup` |
| Install log | Copied into the target with password and passphrase values redacted | `installer-log-preserve` |
| Telemetry | None. No popularity contest, crash reporter, or usage reporting is installed | `config/package-lists/` |
| Repository trust | Debian archive plus the signed FluorineOS repository; no other archive | `config/archives/` |
| Third-party software | Flatpak is installed but has no remote until the user adds one | `fluorine-desktop` |

### Firewall and listening services

The firewall is enabled inside the image and starts at boot. The single inbound
allowance is multicast DNS, because `avahi-daemon` needs it: a printer answers
an mDNS query on 5353/udp, and the default deny rule drops that answer, which
makes driverless printing fail with no error. The `avahi-daemon` package ships
no ufw application profile, so the port is opened by number.

Everything else that listens does so on a local socket or on loopback: CUPS
binds `localhost:631` and is socket activated, NetworkManager, BlueZ, UPower
and power-profiles-daemon are D-Bus services, and PipeWire listens on a user
runtime directory. There is no sshd, no Samba, no NFS server, and no RPC
service in the image.

### Privilege boundaries

- `sudo` uses the Debian default policy: the created user is in `sudo` and
  authenticates with their own password.
- The live medium adds one passwordless rule: `%sudo ALL=(ALL) NOPASSWD:
  /usr/bin/calamares`. It names one executable, the grant cannot carry a
  command prefix, and `installer-cleanup` deletes the file from the installed
  system. If cleanup fails, the installation fails.
- Desktop helpers that need root run through `pkexec` (`flr-settings`,
  `flr-sync`, `flr-store`) or through `sudo` with a password (`flr-update`,
  `flr-snapshot`). `flr-store` builds its root command from a fixed catalog of
  package names in its own source, never from user input, which is what makes
  `pkexec env DEBIAN_FRONTEND=noninteractive apt-get install -y <name>` safe.
  A future change that lets a user-supplied package name reach that argv would
  hand root to the caller, so it must not happen without a validated allowlist.
- `flr-ctl` launches Calamares with `sudo` only when `/run/live` exists, so the
  entry is absent on installed systems.

### Boot and encryption

The installer writes an unsigned `grubx64.efi`. Secure Boot is therefore not
supported: firmware with Secure Boot enabled refuses the installed system, and
the live medium does not claim otherwise. Enabling it is a release-level change
that requires shim, a signed kernel, and Machine Owner Key enrolment.

`partition.conf` pins `luksGeneration: luks1` because GRUB 2.12 cannot derive a
LUKS2 Argon2id keyslot. LUKS1 uses PBKDF2 with a high iteration count, which is
weaker against offline guessing than Argon2id at equal passphrase strength. The
passphrase is the only barrier between an attacker with the disk and the data,
so it has to be long; the installer enforces eight characters, which is a floor
for convenience, not a recommendation.

### Privacy

- No telemetry package is installed, and no default service reports usage to a
  third party.
- The Calamares `networkcfg` module is deliberately out of the sequence: it
  would copy the live session's NetworkManager profiles, including any Wi-Fi
  pre-shared key the operator used on the live medium, onto the installed disk.
  The installer is offline by design, so there is nothing to carry over.
- `machineid` replaces the image's identity, so two machines installed from the
  same ISO do not share a DHCP client identifier or a journald machine ID.
- Live-build already empties `/etc/machine-id` and removes
  `/var/lib/dbus/machine-id` from the image (`8060-remove-systemd-machine-id`
  and `8020-remove-dbus-machine-id` internal hooks), so the live medium itself
  generates a fresh identity on every boot.
- The installer log is copied into `/var/log/fluorineos-install` with mode
  `0640` and any `password:` or `passphrase=` value replaced before the write,
  so a future module that echoes a credential cannot put it on the disk.
- `avahi-daemon` keeps the Debian defaults `publish-workstation=no` and
  `publish-hinfo=no`, so the machine does not advertise a workstation service.
- NetworkManager randomises the MAC address while scanning for networks
  (upstream default since 1.4), but keeps the hardware address for connections,
  because cloning it breaks captive portals, DHCP reservations, and 802.1X.

### Session locking

`hypridle` runs `lock_cmd = pidof hyprlock || hyprlock` and
`before_sleep_cmd = loginctl lock-session`. `before_sleep_cmd` fires on logind's
`PrepareForSleep` signal, which logind emits for every suspend it initiates,
including closing the lid, so a suspended machine comes back locked. The idle
policy locks at ten minutes and suspends at twenty, the latter only while
discharging.

Presentation mode (`flr-mode present`) stops `hypridle` for the duration, which
also disables lock-on-sleep. That is a deliberate trade-off for presenting, and
it means the session is unlocked after a resume in that mode.

## Known limitations

| Limitation | Consequence | Mitigation |
| --- | --- | --- |
| No Secure Boot | Firmware with Secure Boot refuses the medium and the install | Turn Secure Boot off, or enrol a key and sign the chain |
| LUKS1 only | Weaker key derivation than LUKS2/Argon2id | Use a long passphrase |
| No automatic security updates | Debian security fixes arrive only when the user runs `flr-update` | Run it regularly; it snapshots first |
| No Mandatory Access Control | AppArmor is not enabled and no profile is shipped | Run untrusted applications in a Flatpak or `flr-box` container |
| No integrity monitoring | No AIDE or IMA; a modified binary is not detected | Reinstall or verify packages with `dpkg --verify` |
| `pkexec` in the desktop helpers | The polkit agent authorises a program, not a command line | Commands are fixed in `fluorine-desktop`; keep it that way |
| Presentation mode | Lock-on-sleep is off while presenting | Do not leave the machine unattended in that mode |
| Greeter remembers the last user | The username is visible at the login screen | Delete `/var/lib/tuigreet/lastuser` or drop `--remember` |
| Unattended installer log | The log records the chosen hostname and username | It holds no credentials after redaction |

`unattended-upgrades` is deliberately not installed. Automatic upgrades would
bypass the pre-update Btrfs snapshot that `flr-update` takes, and a distro that
snapshots before every upgrade should not have a second, snapshot-less path.
Users who prefer automatic security updates can install it and configure
`Unattended-Upgrade::Origins-Pattern` for `Debian-Security` themselves; doing so
means accepting an upgrade that no snapshot covers.

## Verification requirements

Nothing below has been verified on hardware. Run these on an installed system
and record the output in `TEST_PLAN.md` before claiming a security property in
public documentation.

| Check | Command | Expected |
| --- | --- | --- |
| Firewall state | `sudo ufw status verbose` | `Status: active`, `Default: deny (incoming)`, one 5353/udp allow |
| Listening sockets | `ss -tulpn` | Loopback and D-Bus only, plus 5353/udp |
| No remote shell | `ss -tulpn \| grep ':22 '` | No output |
| Sudo policy | `sudo -l` | No `NOPASSWD` entry on an installed system |
| Live rule removed | `ls /etc/sudoers.d/` | No `99-fluorine-live-installer` |
| Root locked | `sudo passwd -S root` | `root L` |
| Home permissions | `stat -c '%a %U' ~` | `700 <user>` |
| Encryption | `lsblk -o NAME,FSTYPE`, `cryptsetup luksDump /dev/<part>` | LUKS1, no plaintext root |
| Machine identity | `cat /etc/machine-id` on two installs | Different values |
| Install log redaction | `sudo grep -Ei 'pass(word\|phrase)\s*[:=]' /var/log/fluorineos-install/session.log` | No clear values |
| Printer discovery | `avahi-browse -rt _ipp._tcp` | The network printer is listed |
| Lock on sleep | Close the lid, resume | `hyprlock` is on screen |
| Service sandboxing | `systemd-analyze security --no-pager` | Review per unit, not a target score |
| Package integrity | `dpkg --verify` | No modified files outside `/etc` |

`systemd-analyze security` reports a score per unit; a low score is not a
vulnerability and a high score is not proof. It is useful for spotting a unit
that runs with full privileges when it does not need to, and nothing in the
image has been hardened at that level.

## Changing these defaults

Every default above lives in a file in this repository, and every one of them is
covered by `tests/validation/security-test.sh`. Run that suite before changing
any of them, and update this document in the same commit: a security baseline
that drifts from the image is worse than no baseline, because it is believed.

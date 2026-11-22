# FluorineOS

`Debian 13 Trixie | Hyprland 0.55+ | x86_64`

FluorineOS is a minimalist Debian 13 workstation distribution built around the Hyprland
Wayland compositor. The interface uses a pure AMOLED black canvas (`#000000`) with a single
reactive lime accent (`#B4F03A`) and hairline borders (`#1C2229`). Compositor configuration
is native Hyprland 0.55 Lua, and installation is handled offline by Calamares.

[Website][website] | [Latest Release][releases] | [APT Repository][apt] | [Issues][issues]

## Download and Verify

Official release ISO images and cryptographic checksums are published through GitHub
releases.

| Item | Value |
| --- | --- |
| Release version | `0.0.1` |
| Image file | `FluorineOS-0.0.1-amd64.iso` |
| Checksum file | `FluorineOS-0.0.1-amd64.iso.sha256` |
| Release page | [FluorineOS Releases][releases] |

Download both the image and the checksum file, then verify cryptographic integrity:

```sh
sha256sum -c FluorineOS-0.0.1-amd64.iso.sha256
```

## Architecture

FluorineOS builds directly on Debian 13 (`trixie`) with Hyprland pinned from the official
`trixie-backports` suite.

| Component | Upstream Package | Role |
| --- | --- | --- |
| Base OS | Debian 13 (`trixie`) | Package ecosystem and core system libraries |
| Compositor | Hyprland `0.55+` | Wayland tiling window manager configured in Lua |
| Display manager | `greetd` + `tuigreet` | Minimal console login launcher |
| Status bar | Waybar | Top bar with workspace indicator and system monitors |
| Application menu | Fuzzel | Wayland desktop application launcher |
| Notification daemon | SwayNC | Notification center and control panel |
| Terminal | Kitty | Fast terminal emulator using JetBrains Mono |
| Audio | PipeWire + WirePlumber | System audio server and media routing |
| Memory management | ZRAM (`zstd`) | Compressed in-memory swap device |
| Firewall | `ufw` | Default active state host firewall |

## Design Tokens

The desktop environment strictly enforces the AMOLED Void design system across all toolkits
and applications:

| Token | Hex | Role |
| --- | --- | --- |
| Void canvas | `#000000` | Desktop, terminal, and application background |
| Raised carbon | `#0A0D10` | Panels, cards, popovers, and bars |
| Inactive border | `#1C2229` | 1.5px hairline borders on unfocused windows |
| Reactive lime | `#B4F03A` | Focus indicator, active borders, and primary actions |
| Deep moss | `#2A3812` | Text selection and active row background |
| Primary text | `#E2E8F0` | High-contrast body text and icons |
| Muted text | `#6E7681` | Secondary descriptions and disabled labels |

## Keybindings

Default shortcuts are bound in `~/.config/hypr/hyprland.lua`:

| Shortcut Chord | Action |
| --- | --- |
| `SUPER + Return` | Launch Kitty terminal emulator |
| `SUPER + D` | Launch Fuzzel application launcher |
| `SUPER + E` | Launch Thunar file manager |
| `SUPER + Q` | Close active window |
| `SUPER + V` | Toggle floating mode on active window |
| `SUPER + F` | Toggle fullscreen mode on active window |
| `SUPER + Shift + S` | Interactive area screenshot (`flr-shot`) |
| `SUPER + /` | Display keybinding reference dialog (`flr-keys`) |
| `SUPER + L` | Lock workstation screen (`hyprlock`) |
| `SUPER + 1..9` | Switch to workspace 1 through 9 |
| `SUPER + Shift + 1..9` | Move active window to workspace 1 through 9 |

## Installation

### Hardware Requirements

| Component | Minimum | Recommended |
| --- | --- | --- |
| Processor | x86_64 dual-core | x86_64 quad-core or better |
| Memory | 4 GB RAM | 8 GB RAM or more |
| Storage | 20 GB free disk | 50 GB NVMe or SSD |
| Firmware | UEFI 64-bit | UEFI 64-bit |
| Graphics | DRM/KMS compatible GPU | Intel, AMD, or Nouveau |

### Flashing to USB

Write the verified ISO image to a USB flash drive using `dd`:

```sh
sudo dd if=FluorineOS-0.0.1-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Replace `/dev/sdX` with the target block device node.

## QEMU Testing

Test the live ISO image using QEMU with UEFI firmware:

```sh
qemu-system-x86_64 \
  -enable-kvm \
  -m 4G \
  -smp 4 \
  -bios /usr/share/ovmf/OVMF.fd \
  -vga virtio \
  -display gtk,gl=on \
  -cdrom FluorineOS-0.0.1-amd64.iso
```

For software rendering fallback without KVM acceleration:

```sh
qemu-system-x86_64 \
  -m 4G \
  -smp 4 \
  -bios /usr/share/ovmf/OVMF.fd \
  -vga std \
  -cdrom FluorineOS-0.0.1-amd64.iso
```

## Repositories

| Repository | Purpose | Format |
| --- | --- | --- |
| [`fluorine`][main] | Primary ISO and live-build monorepo | ISO image |
| [`fluorine-desktop`][desktop] | Hyprland configuration, themes, and `flr-*` tools | Debian package |
| [`fluorine-artwork`][artwork] | AMOLED wallpapers, Plymouth splash, branding assets | Debian package |
| [`fluorine-keyring`][keyring] | Signing keyring and APT sources configuration | Debian package |
| [`apt-repo`][apt] | Signed static reprepro package archive | APT source |
| [`fluorine-website`][website] | Official web portal and documentation interface | Web application |

## Building from Source

Build dependencies require Debian 13 (`trixie`) and `live-build`:

```sh
sudo apt-get update
sudo apt-get install -y live-build debootstrap xorriso squashfs-tools
```

Clone the repository and run live-build:

```sh
git clone https://github.com/FluorineOS/fluorine.git
cd fluorine
sudo lb clean --purge
sudo lb config
sudo lb build
```

## License

FluorineOS is open-source software distributed under the GNU General Public License v3.

[website]: https://github.com/FluorineOS/fluorine-website
[main]: https://github.com/FluorineOS/fluorine
[releases]: https://github.com/FluorineOS/fluorine/releases/latest
[apt]: https://fluorineos.github.io/apt-repo
[issues]: https://github.com/FluorineOS/fluorine/issues
[desktop]: https://github.com/FluorineOS/fluorine-desktop
[artwork]: https://github.com/FluorineOS/fluorine-artwork
[keyring]: https://github.com/FluorineOS/fluorine-keyring

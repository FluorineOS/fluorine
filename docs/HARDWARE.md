# Hardware Support

FluorineOS ships the Debian 13 `trixie` kernel, the Debian firmware
packages, and the free in-kernel drivers. It does not carry a custom kernel,
does not build drivers from source, and does not install a proprietary driver
by default. Every package named here resolves to `trixie` or to `trixie
non-free-firmware`; the archive areas are `main contrib non-free` and
`non-free-firmware`, so anything described as a manual install below is one
`apt install` away.

Package versions in this document were read from the `trixie` package indexes
on 2026-11-27.

## What ships in the image

The firmware and integration packages live in
`config/package-lists/hardware.list.chroot`, and the boot services live in
`config/hooks/normal/0200-services.hook.chroot`.

| Subsystem | Packages | Notes |
| --- | --- | --- |
| Kernel | `linux-image-amd64` | Debian `6.12` kernel, no local patches |
| CPU microcode | `intel-microcode`, `amd64-microcode` | Early load from the initramfs |
| Intel graphics | `firmware-intel-graphics` | GuC, HuC, and DMC blobs for `i915` and `xe` |
| AMD graphics | `firmware-amd-graphics` | Pulled by `firmware-linux-nonfree` |
| NVIDIA graphics | `firmware-nvidia-graphics` | nouveau and GSP blobs |
| Intel audio | `firmware-intel-sound`, `firmware-sof-signed` | SST and Sound Open Firmware |
| Wi-Fi | `firmware-iwlwifi`, `firmware-atheros`, `firmware-realtek`, `firmware-brcm80211`, `firmware-mediatek` | Intel, Qualcomm Atheros, Realtek, Broadcom, MediaTek |
| Regulatory data | `wireless-regdb` | Country-correct channels and transmit power |
| Wi-Fi supplicant | `wpasupplicant`, `iw`, `rfkill` | NetworkManager backend plus inspection tools |
| Video decode | `mesa-va-drivers`, `intel-media-va-driver`, `vainfo` | VA-API for AMD and Intel Gen8+ |
| Removable storage | `udisks2`, `exfatprogs` | Thunar volume manager, exFAT formatting |
| Power | `power-profiles-daemon`, `upower`, `brightness-udev` | Platform profiles, battery reporting, unprivileged backlight |
| Hybrid graphics | `switcheroo-control` | D-Bus query of available GPUs |
| Qt on Wayland | `qt6-wayland` | Native Wayland, no XWayland frame copy |
| Printing | `cups`, `cups-pk-helper`, `avahi-daemon`, `libnss-mdns` | Driverless IPP printing and `.local` name resolution |
| Screen reader | `orca` | AT-SPI over GTK and Qt |

`firmware-linux` is a metapackage over `firmware-linux-free` and
`firmware-linux-nonfree`. In trixie `firmware-linux-nonfree` pulls only
`firmware-misc-nonfree` and `firmware-amd-graphics`, which is why every other
GPU and radio family is named explicitly in the package list.

## Open drivers and proprietary components

| Component | Driver | Source status | Installed |
| --- | --- | --- | --- |
| Intel graphics | `i915`, `xe` | Free, in-kernel | Yes |
| AMD graphics | `amdgpu`, `radeon` | Free, in-kernel | Yes |
| NVIDIA graphics | `nouveau` | Free, in-kernel | Yes |
| NVIDIA graphics | `nvidia` | Proprietary, DKMS | No, manual |
| Intel and AMD firmware | kernel blobs | Proprietary, redistributable | Yes |
| Intel VA-API | `intel-media-va-driver` | Free | Yes |
| Mesa VA-API | `mesa-va-drivers` | Free | Yes |
| Vulkan | `mesa-vulkan-drivers` | Free | No, manual |

Firmware blobs are redistributable but not open source. They are included only
where a free driver needs a blob to bring the device up at all. The proprietary
NVIDIA driver is not installed: it is out of tree, it needs
`linux-headers-amd64` and DKMS, it cannot be signed for Secure Boot on this
image, and it changes the kernel module set. Users who want it install it
themselves.

## Device classes

### Graphics and display

Intel and AMD graphics run on the free in-kernel drivers with KMS enabled by
default, which is what Hyprland needs. NVIDIA cards run on `nouveau` with the
GSP firmware included in the image; that covers display output and 2D, and it
does not cover the proprietary driver's power management or CUDA. Hybrid
laptops expose both GPUs, and an application can request the discrete one with
`DRI_PRIME=1` or by asking `switcheroo-control` which GPUs exist.

Output layout is managed by `kanshi`, which applies a profile per output set,
and `hyprctl monitors` for one-off changes. Fractional scaling is per output
through `hl.monitor`, and XWayland clients keep a 1:1 pixel scale so they stay
crisp on a scaled output. HiDPI is not forced on: the default is scale `1`,
and `~/.config/hypr/hyprland.lua` documents the `1.25` and `1.5` variants.

### Laptops

| Feature | Mechanism | Notes |
| --- | --- | --- |
| Battery reporting | `upower`, Waybar `battery` module | `/sys/class/power_supply` |
| Power profiles | `power-profiles-daemon`, `flr-power` | `power-saver`, `balanced`, `performance` |
| Idle policy | `hypridle` | Dim at 5 min, lock at 10 min, suspend at 20 min on battery |
| Suspend and resume | `systemd-logind` | Lock before sleep, DPMS on after resume |
| Lid | `systemd-logind` default policy | Close suspends, open resumes |
| Panel brightness | `brightnessctl`, `brightness-udev`, `flr-osd` | Keys bound in `hyprland.lua` |
| Keyboard backlight | `brightnessctl` over `/sys/class/leds/*::kbd_backlight` | Keys bound in `hyprland.lua` |
| Touchpad | `libinput` through the Hyprland `input` block | Tap to click, natural scroll, palm rejection |
| Touchscreen | `libinput` | Works as a pointer device, no gesture mapping |
| Thermal | Kernel `thermal` and `acpi_thermal_rel` | No userspace daemon |

`thermald` is not installed. It only applies to Intel CPUs, it duplicates work
the kernel thermal governor already does, and on several platforms it fights
`power-profiles-daemon` over the same platform profile.

### Connectivity

NetworkManager owns Wi-Fi and Ethernet, and `nmcli`, `nmtui`, and `flr-ctl` are
the three front ends. Bluetooth runs on `bluez` with `blueman` as the panel and
PipeWire as the audio backend, so A2DP and HSP/HFP both work. Wi-Fi hotspots
are NetworkManager's access point mode; whether a given card can run one
depends on the driver, and `nmcli device wifi hotspot` reports the failure when
it cannot.

USB Ethernet adapters and USB Wi-Fi dongles work when their firmware and
driver are in the kernel; the firmware packages above cover the common
Realtek, MediaTek, and Atheros parts, and a dongle with no in-kernel driver is
not supported.

### Peripherals

Audio and microphones are PipeWire with WirePlumber, and `pavucontrol` and
`pulsemixer` are installed. Webcams use the kernel `uvcvideo` driver with
`v4l-utils` for control and inspection; laptops with an IPU6 sensor need the
`intel-ipu6` stack, which this image does not include. Printers use driverless
IPP over CUPS, so any printer that advertises IPP Everywhere or AirPrint works;
printers that need a vendor driver need that driver installed by hand. Game
controllers appear as `evdev`/`joydev` devices and work in applications that
read them; no remapping daemon ships. Storage devices, including exFAT and
NTFS volumes, mount through `udisks2` in Thunar, with in-kernel `exfat` and
`ntfs3` doing the filesystem work.

### Input

The keyboard layout is chosen in the installer and written to
`/etc/default/keyboard`; `hyprland.lua` reads the same layout for the session.
Pointer and touchpad behaviour is configured through the Hyprland `input`
block rather than a separate `libinput` daemon. Three-finger horizontal swipe
switches workspaces. Input methods are not installed: a user who needs one
installs `fcitx5` or `ibus` and starts it from `hyprland.lua`. Accessibility
devices work through `orca` and AT-SPI; a braille display needs `brltty`,
which is not installed.

## Not installed on purpose

| Package | Reason | How to add it |
| --- | --- | --- |
| `nvidia-driver` | Proprietary, out of tree, unsigned for Secure Boot | `sudo apt install linux-headers-amd64 nvidia-driver` |
| `nvidia-detect` | Only useful before choosing a driver | `sudo apt install nvidia-detect` from `non-free` |
| `mesa-vulkan-drivers` | Only needed by Vulkan applications | `sudo apt install mesa-vulkan-drivers` |
| `i965-va-driver` | Intel graphics older than Gen8 only | `sudo apt install i965-va-driver` |
| `tlp` | Conflicts with `power-profiles-daemon` | Remove the daemon first |
| `thermald` | Intel-only, duplicates the kernel governor | `sudo apt install thermald` |
| `fwupd` | Adds a daemon and a refresh timer | `sudo apt install fwupd` |
| `fcitx5`, `ibus` | Input methods are a user choice | Install and add the `exec-once` line |
| `brltty` | Braille support is device-specific | `sudo apt install brltty` |
| `firmware-qcom-soc` | arm64 SoCs only, image is `amd64` | Not applicable |

## NVIDIA

`nouveau` needs no configuration and drives the display on Turing and newer
cards because the GSP firmware ships in the image. The proprietary driver is a
manual step:

```sh
sudo apt update
sudo apt install linux-headers-amd64 nvidia-driver
```

The live medium already boots with `nvidia_drm.modeset=1`. An installed system
on the proprietary driver needs that parameter as well:

```sh
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia_drm.modeset=1"/' /etc/default/grub
sudo update-grub
```

Secure Boot is not supported by this image: the installer writes an unsigned
`grubx64.efi`, and firmware with Secure Boot enabled refuses it. A machine with
Secure Boot on cannot boot the medium or the installed system, and the
proprietary NVIDIA driver cannot be loaded without enrolling a Machine Owner
Key.

## Validation requirements

Nothing in this document is a hardware verification. The image has not been
booted on physical hardware as part of this change, and the following checks
must be run on real machines before any compatibility claim is published.

| Area | What to check | Hardware |
| --- | --- | --- |
| Intel graphics | `flr-doctor` reports a hardware renderer; `vainfo` lists H.264 and HEVC decode | Intel Gen9 through Gen14 laptop |
| AMD graphics | Same, plus `amdgpu` loaded instead of `radeon` fallback | AMD APU and a discrete card |
| NVIDIA nouveau | Display output, 2D, suspend and resume | Turing or newer card |
| NVIDIA proprietary | Install the driver, add `nvidia_drm.modeset=1`, confirm a Wayland session | Same card |
| Hybrid graphics | `DRI_PRIME=1` renders on the discrete GPU; both GPUs enumerated | Laptop with iGPU and dGPU |
| Intel audio | Internal speakers and microphone work without a `sof` firmware error in `dmesg` | Ice Lake or newer Intel laptop |
| Suspend and resume | `systemctl suspend` returns with display, input, audio, and network | Two laptops, Intel and AMD |
| Lid | Close suspends, open resumes, external display stays awake when docked | Laptop |
| Brightness | `XF86MonBrightnessUp` and `XF86MonBrightnessDown` change the panel and show the OSD | Laptop |
| Keyboard backlight | `XF86KbdBrightnessUp` and `XF86KbdBrightnessDown` change the LED and show the OSD | Laptop with a backlit keyboard |
| Touchpad | Tap, two-finger scroll, three-finger swipe, palm rejection | Two laptops |
| Wi-Fi | Association on 2.4 and 5 GHz, correct country channels, suspend and resume | Intel, MediaTek, and Broadcom cards |
| Bluetooth | Pairing, A2DP playback, HFP microphone | Laptop with an Intel or Broadcom radio |
| Hotspot | `nmcli device wifi hotspot` brings up an AP that another device joins | Wi-Fi card that supports AP mode |
| Printing | Driverless IPP discovery over mDNS, print, and cancel | Network printer on the same link |
| Webcam | `v4l2-ctl --list-devices` lists the sensor and a capture works | UVC webcam and an IPU6 laptop |
| External display | Hotplug applies the `kanshi` profile, fractional scaling keeps text crisp | Laptop plus external monitor |
| Removable storage | Mount and unmount an exFAT and an NTFS stick in Thunar | Two USB sticks |

Record results in `TEST_PLAN.md` before publishing hardware claims. Until those
checks exist, the accurate statement is that FluorineOS ships the Debian
hardware stack and the integration described above, not that it supports any
particular machine.

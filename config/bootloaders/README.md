# Bootloader overrides

`grub-pc/` holds the Debian `live-build` GRUB templates from
`/usr/share/live/build/bootloaders/grub-pc`, copied verbatim except for one extra
`menuentry` in `grub.cfg`.

Live-build 20250505 reads `config/bootloaders/grub-pc` for both BIOS and UEFI builds
(`binary_grub_cfg` sets `_SOURCE_USER="config/bootloaders/grub-pc"`), and upstream ships
no `grub-efi` template directory. Do not create a separate `grub-efi` override here: it
would be ignored, and editing it would silently have no effect on the image.

The additional entry boots with `systemd.setenv=WLR_RENDERER_ALLOW_SOFTWARE=1` so
Hyprland can start on VirtualBox and other virtual machines without VirGL 3D
acceleration.

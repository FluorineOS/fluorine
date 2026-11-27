# Default Applications

This document records what FluorineOS installs for each everyday role, how it is
wired into the session, and where a gap is known rather than hidden. It is the
reference for `docs/PERFORMANCE.md` (what runs) and `docs/HARDWARE.md` (what the
devices need).

The rule for this set is one application per role. Where two tools cover the same
role, the one that is not the default must justify its size: `pulsemixer` is a
terminal mixer beside `pavucontrol`, and `btop` is a terminal monitor beside the
system summary in `flr-settings`, so neither duplicates a GUI the other replaces.

## Roles and handlers

| Role | Application | Package | Wayland | Notes |
| --- | --- | --- | --- | --- |
| File manager | Thunar | `thunar` | native (GTK3) | Volumes through `gvfs` and `thunar-volman`, archives through `thunar-archive-plugin`, thumbnails through `tumbler` |
| Terminal | kitty | `kitty` | native | Registers itself as `x-terminal-emulator` (priority 20), so Thunar's terminal action and `exo-open` reach it |
| Text editor | Mousepad | `mousepad` | native (GTK3) | Also handles empty files |
| Archive manager | File Roller | `file-roller` | native (GTK4) | 7z support comes from `7zip`, which File Roller depends on; gzip, xz, zstd, lz4, and rar read through `libarchive` |
| Image viewer | Swayimg | `swayimg` | native (wlroots) | Marked `NoDisplay`, so it opens images without adding a launcher entry for a single-purpose viewer |
| PDF viewer | Zathura | `zathura` + `zathura-pdf-poppler` | native (GTK3) | Recoloured through `/etc/skel/.config/zathura/zathurarc` |
| Media player | mpv | `mpv` | native | Audio and video, hardware decode through the VA-API stack in `hardware.list.chroot` |
| Screenshot | `flr-shot` | `grim`, `slurp`, `wl-clipboard` | native | Region and full-screen capture, file plus clipboard, bound to Print and SUPER+SHIFT+S |
| Calculator | Galculator | `galculator` | native (GTK3) | |
| System monitor | `btop` | `btop` | terminal | The graphical summary lives in `flr-settings` |
| Settings | `flr-settings` | `fluorine-desktop` | native (GTK4) | Every control delegates to the matching `flr-*` command |
| Bluetooth | Blueman | `blueman` | native (GTK3) | Waybar's Bluetooth module opens `flr-bt` |
| Network | `nmtui` via `flr-tui` | `network-manager` | terminal | Waybar's network module opens it; no separate GUI editor is installed |
| Audio | Pavucontrol | `pavucontrol` | native (GTK3) | Waybar's volume module opens it; `flr-osd` reports changes from the media keys |
| Clipboard | `cliphist` + `wl-clipboard` | both | native | SUPER+C opens the history; the store watcher starts once from `hyprland.lua` |
| Launcher | Fuzzel | `fuzzel` | native (layer shell) | `icon-theme=Fluorine`, so entries resolve their icons through the shipped theme |
| Notifications | SwayNC | `sway-notification-center` | native (layer shell) | SUPER+N opens the panel |
| File dialogs, screen share | XDG portals | `xdg-desktop-portal-hyprland`, `xdg-desktop-portal-gtk` | native | Declared as dependencies, not inherited from a Recommends |

## Web browser

No browser is installed, and that is a decision rather than an omission: the
image ships `flr-store`, whose Web category installs `firefox-esr` or
`epiphany-browser` from Debian in one step. Shipping a browser for every user
would add the largest single package on the medium for a choice most users want
to make themselves.

The consequence is honest: nothing registers `x-scheme-handler/http` or
`x-scheme-handler/https`, so a link clicked in a PDF or another application does
nothing until a browser is installed. The default handler list deliberately does
not map those types to the store, because opening a storefront when a link is
clicked would be worse than doing nothing.

## Password management

There is no Secret Service provider in the image, so applications that expect one
keep their own credential store (Firefox and Chromium both do) and Flatpak
applications that ask the Secret portal receive no answer.

`gnome-keyring` provides that service on Debian and is D-Bus activated
(`org.freedesktop.secrets`), so it costs nothing until something asks. It is not
added here because it pulls `dbus-user-session` into the session, and that
changes how the session bus is started: without
`dbus-update-activation-environment` at session start, a portal started on the
user manager's bus does not see `WAYLAND_DISPLAY`. That is a session
architecture decision with a runtime failure mode (portals silently unavailable),
so it belongs in a change that can be verified on hardware, not in a static
package pass.

## MIME defaults

`/etc/xdg/mimeapps.list` and `/etc/skel/.config/mimeapps.list` are identical
copies; the first covers every account, the second is the copy a new account
starts with. Both list only types that the named application declares in its own
desktop entry, so no association can point at a handler that cannot open the file.

Types that inherit from a mapped type are left out. `text/markdown` is the worked
example: it inherits `text/plain`, so Mousepad opens a markdown file without an
entry of its own.

The types were taken from the installed desktop entries rather than guessed:
`grep '^MimeType='` in the extracted packages for Thunar, Zathura, Swayimg, File
Roller, Mousepad, mpv, kitty, and Galculator. Each one was then confirmed to be a
type in trixie's `shared-mime-info` rather than an alias some application lists:
`audio/opus`, `image/jpg`, and `video/mkv` are aliases and are not mapped for
that reason.

## Verification

| Check | Command | Expected |
| --- | --- | --- |
| A default is registered | `gio mime image/tiff` | `swayimg.desktop` |
| An archive default | `gio mime application/gzip` | `org.gnome.FileRoller.desktop` |
| Inheritance still works | `gio mime text/markdown` | `org.xfce.mousepad.desktop` |
| Desktop entries are valid | `desktop-file-validate /usr/share/applications/*.desktop` | no output |
| Icons resolve | open Fuzzel and search for "Settings" | the Fluorine gear icon, not a generic square |
| Portals are present | `busctl --user list \| grep -i portal` | `xdg-desktop-portal` and `xdg-desktop-portal-hyprland` |
| Flatpak file dialog | install a Flatpak application, open a file | the GTK file chooser appears |
| No secret service | `busctl --user introspect org.freedesktop.secrets /` | fails, as documented above |
| Terminal action | Thunar: right-click a folder, Open Terminal Here | kitty opens in that directory |
| Double-click matrix | open one file of each mapped type in Thunar | the documented handler opens |

## Deliberate omissions

- **No second file manager, terminal, editor, or PDF reader.** The role is
  filled; a second application would double the maintenance and the menu.
- **No office suite, no image editor, no video editor.** These are large,
  opinionated choices that `flr-store` leaves to the user.
- **No GUI network editor.** `nmtui` covers connections, and NetworkManager's
  `nm-connection-editor` would add a GTK dependency for a task the terminal does
  correctly.
- **No password manager application.** A Secret Service provider is the
  integration point, and the application on top is a user choice.

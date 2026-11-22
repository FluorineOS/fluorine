# Start the Hyprland session on the live medium.
#
# The live medium autologins the live user on tty1 and skips greetd, so this
# login shell is the only place the desktop can start. Installed systems have no
# /run/live, keep greetd on tty1, and never reach this block.

if [ -d /run/live ] && [ -z "${WAYLAND_DISPLAY:-}" ] &&
    [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
    exec start-hyprland
fi

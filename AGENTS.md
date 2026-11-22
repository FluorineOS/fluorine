# AGENTS.md - FluorineOS Engineering Standards

This repository is the primary build monorepo for **FluorineOS**. The rules below are
non-negotiable for every OpenCode session, agent, and contributor. If a request conflicts
with them, stop and ask the maintainer before making changes.

## Local canonical reference (read first)

`SOURCE_OF_TRUTH/` is a local-only, gitignored directory at the repository root. It is the
canonical internal reference for all OpenCode sessions across the FluorineOS project. Never
add, stage, or commit anything inside it.

Before making any architectural, packaging, styling, or release change, read:

- `SOURCE_OF_TRUTH/PROJECT_CONTEXT.md`
- `SOURCE_OF_TRUTH/RELEASE_INSTRUCTIONS.md`
- `SOURCE_OF_TRUTH/DESIGN_SYSTEM.md`
- `SOURCE_OF_TRUTH/ARCHITECTURE_GOTCHAS.md`
- `SOURCE_OF_TRUTH/README_INSTRUCTIONS.md`

Every OpenCode session must read and obey `SOURCE_OF_TRUTH/README_INSTRUCTIONS.md` before
creating or modifying any `README.md` in any FluorineOS repository. The public README is a
contract with end users: internal state, roadmap prompts, build notes, and
`SOURCE_OF_TRUTH/` references must never appear in it.

Also check `SOURCE_OF_TRUTH/BUILD_STATUS.md` for current milestone progress.

## Required repository and commit workflow

- The Windows checkouts are siblings:
  `C:\Users\gowth\OneDrive\Desktop\FluorineOS` is the primary
  `FluorineOS/fluorine` repository, while `C:\Users\gowth\fluorine-workspace` is a
  container for separate companion repositories, not a Git repository itself.
- Resolve the owning Git root before editing or committing. Each project repository
  has its own GitHub remote under `https://github.com/FluorineOS`; the organization
  profile repository is rooted at `.github`, with its page content in `.github/profile`.
- Commit every intentional, commit-eligible project change, including file additions,
  modifications, and deletions, in its owning repository before reporting the task
  complete. For changes to multiple repositories, create a separate commit in each
  repository. Never combine sibling repositories in one commit or include unrelated
  pre-existing changes.
- Immediately push every new commit to that repository's configured `origin` branch.
  Do not leave a completed task's commit only in a local worktree; if a push fails,
  report the error and the unpushed commit.
- Never build or publish a FluorineOS ISO, create or push a release tag, or otherwise
  initiate a release unless the user explicitly authorizes that release action. This
  approval is separate from permission to make and push ordinary commits.
- Keep local-only `SOURCE_OF_TRUTH/` files, secrets, credentials, and ignored/generated
  build output out of commits. Do not force-add them to satisfy the commit requirement.
- Follow `SOURCE_OF_TRUTH/RELEASE_INSTRUCTIONS.md` for commit format, push every commit
  to `origin`, and follow its release-approval gate.

The zero-emoji mandate and semantic versioning rules in
`SOURCE_OF_TRUTH/RELEASE_INSTRUCTIONS.md` are mandatory for every session and every
repository in the FluorineOS organization. Use plain ASCII text and standard Markdown. Do
not add emojis to commit messages, tags, changelogs, README files, release notes, CLI
output, comments, or documentation.

## 1. OS identity and release

| Property | Required value |
| --- | --- |
| Distribution name | `FluorineOS` |
| Initial release version | `0.0.1` |
| Base distribution | Debian 13 (`trixie`) |
| Architecture | `amd64` only |
| Archive areas | `main contrib non-free-firmware` |
| Build system | Debian `live-build` |
| Default desktop | Hyprland `0.55.x` from `trixie-backports` |

- Refer to the base by its codename, `trixie`. Do not use `stable`, `testing`, `sid`, or
  `unstable` in build configuration.
- Do not add `arm64`, `i386`, `riscv64`, or any other architecture. All package lists,
  hooks, binaries, and image configuration are `amd64`-only.
- Keep the version at `0.0.1` unless the maintainer explicitly requests a version bump.
- Every package source must resolve to `trixie` or `trixie-backports`. Third-party
  repositories require explicit maintainer approval and must be documented.
- Do not commit generated build output. It is covered by `.gitignore`.

## 2. Hyprland 0.55.x standards

### Source and version

- Install Hyprland `0.55.x` from `trixie-backports`.
- Enable the backports suite explicitly for Hyprland packages and pin it with an APT
  preferences file so the rest of the system stays on `trixie`.
- Verify the exact candidate before changing package lists:

  ```sh
  apt-cache policy hyprland
  apt-cache madison hyprland
  ```

- Do not pull Hyprland or its companion tools from `sid`, `unstable`, a PPA, or a random
  third-party repository.

### Compositor configuration: native Lua only

The main compositor configuration **must** be native Lua at
`~/.config/hypr/hyprland.lua`. Do not ship a `hyprland.conf` for the compositor and do not
use Hyprland's deprecated hyprlang syntax for it.

Use the native Lua API:

- `hl.config({ ... })` for configuration sections.
- `hl.bind(...)` for keybindings.
- `hl.dsp.*` for dispatch actions.
- `hl.monitor(...)`, `hl.env(...)`, `hl.window_rule(...)`, `hl.workspace_rule(...)`, and
  `hl.animation(...)` where appropriate.

Minimal reference:

```lua
-- ~/.config/hypr/hyprland.lua
hl.config({
  general = {
    -- Closest integer to the 1.5px inactive-border token.
    border_size = 2,
    col = {
      active_border = { colors = { "rgba(b4f03aff)" } },
      inactive_border = "rgba(1c2229ff)",
    },
  },
  decoration = {
    rounding = 0,
    active_opacity = 1.0,
    inactive_opacity = 1.0,
    shadow = { enabled = false },
  },
})

hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("kitty"))
hl.bind("SUPER + Q", hl.dsp.window.close())
```

### Forbidden 0.54 options

Do not reintroduce these removed or deprecated options in any form:

| Deprecated 0.54 option | Required approach |
| --- | --- |
| `dwindle.pseudotile` | Bind `hl.dsp.window.pseudo()` instead |
| `decoration.shadow.ignore_window` | Remove it; shadows are disabled entirely |
| `misc.vfr` | Remove it; use `misc.vrr` only when explicitly required and verified against 0.55 documentation |

If a configuration snippet, package, or generated file still contains one of these options,
rewrite it before committing.

### Companion tools

- `hypridle` and `hyprlock` use their standard `.conf` syntax:
  `~/.config/hypr/hypridle.conf` and `~/.config/hypr/hyprlock.conf`.
- Do not convert `hypridle` or `hyprlock` configuration to Lua.
- `hypridle` must invoke `hyprlock` for locking; do not ship a second locker unless the
  maintainer approves it.

### Display manager and session entry

Display managers based on `greetd`/`tuigreet` **must** execute `start-hyprland`, not
`Hyprland` directly. For example:

```toml
# /etc/greetd/config.toml
[default_session]
command = "tuigreet --time --cmd start-hyprland"
user = "greeter"
```

Any Wayland session desktop file must also launch the wrapper:

```ini
Exec=start-hyprland
DesktopNames=Hyprland
```

## 3. Design language tokens

FluorineOS uses a pure AMOLED black base with a reactive lime accent. These values are
fixed and must be reused everywhere: Hyprland, GTK, terminal themes, bars, launchers,
lockscreen, greeter, and installer branding.

| Token | Hex | Usage |
| --- | --- | --- |
| Background | `#000000` | Pure AMOLED black application and desktop background |
| Elevated surface | `#0A0D10` | Elevated surfaces: panels, popovers, cards, bars, and containers |
| Inactive border | `#1C2229` | 1.5px borders on unfocused windows and controls |
| Primary accent | `#B4F03A` | Reactive lime for focus, active state, and primary actions |
| Selection highlight | `#2A3812` | Deep moss selection and active-row background |
| Foreground text | `#E2E8F0` | Primary text and icons |
| Muted text | `#6E7681` | Muted slate text: secondary text, placeholders, and disabled labels |

Mandatory visual rules:

- Backgrounds are exactly `#000000`; do not substitute near-black values such as `#010101`.
- `active_opacity = 1.0` and `inactive_opacity = 1.0`. Do not introduce transparency.
- Drop shadows are disabled everywhere: set `decoration.shadow.enabled = false` and disable
  shadows in GTK, bars, launchers, and lockscreen themes where the toolkit allows it.
- Inactive borders are `#1C2229` at 1.5px. Where a toolkit only accepts integer pixels, use
  the closest integer without changing the color.
- The lime accent `#B4F03A` is reserved for focus, active, and reactive states. Do not use
  it as a large background fill.
- Use `#2A3812` for text selection and selected rows; do not use the lime accent as a
  selection background.
- Use lowercase hex values in configuration files and document any toolkit-specific color
  format (for example, `rgba(b4f03aff)` or `0xffb4f03a`).
- Do not introduce gradients, glows, or additional accent colors without maintainer
  approval.

## 4. Script and hook quality

All shell scripts and `live-build` hooks must meet these requirements:

- Hooks live at `config/hooks/normal/<number>-<name>.hook.chroot` using a two-digit ordering
  prefix and a lowercase kebab-case name.
- Start with `#!/usr/bin/env bash` (preferred) or `#!/bin/sh`.
- Enable strict mode with `set -euo pipefail`. Because `pipefail` is not POSIX, prefer Bash
  for every hook and script; use `#!/bin/sh` only for strictly POSIX code.
- Pass `shellcheck` with zero warnings. Run `shellcheck -x <path>` before committing.
- Be executable: `chmod +x <path>`. On Windows worktrees, also record the mode with
  `git update-index --add --chmod=+x <path>`.
- Use LF line endings, quote all variable expansions, and avoid parsing `ls` output.
- Hooks must be idempotent, non-interactive, and safe to re-run. Use
  `DEBIAN_FRONTEND=noninteractive` for APT operations.
- Clean up temporary files with a `trap`, and never pipe a remote script directly into a
  shell.

Required hook skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Hook: <number>-<name>
# Runs inside the live-build chroot as root during the normal hook phase.

main() {
    :
}

main "$@"
```

## 5. Package verification

Before adding, removing, or renaming any package in `config/package-lists/`:

1. Verify the exact package name and availability in Debian 13:

   ```sh
   apt-cache policy <package>
   apt-cache madison <package>
   ```

2. Confirm the candidate comes from `trixie` or `trixie-backports`.
3. Inspect the package metadata for transitional packages:

   ```sh
   apt-cache show <package>
   ```

   Treat a package as transitional when its description says "transitional package" or its
   section is `oldlibs`. Replace it with the package it points to.
4. If the package is missing, only available from another suite, or transitional, stop and
   ask the maintainer. Do not guess a replacement or silently edit the package list.
5. For backports packages, document the required APT pin and confirm the version satisfies
   the 0.55.x requirement.
6. Run `/verify-pkgs` after any package-list change.

## 6. Safety rule

**Never run any of the following autonomously:**

```text
sudo lb build
sudo ./auto/build
sudo lb clean --purge
rm -rf <anything>
```

This also applies to equivalent destructive operations, including `sudo lb clean` variants
that delete build state, `dd`, `mkfs`, partitioning, and recursive deletion through other
commands. Always stop and ask the user for explicit confirmation first, and state the exact
command and its consequences.

Read-only inspection commands such as `git status`, `apt-cache policy`, `lb config --help`,
and `shellcheck` are allowed without confirmation.

## 7. Mandatory tool availability

Never skip a command, linter, validator, package check, or GitHub CLI operation because a
tool is not installed. Install the required Debian package immediately, then execute the
step in the same session.

| Step | Required tool | Debian package |
| --- | --- | --- |
| Shell linting | `shellcheck` | `shellcheck` |
| JSON validation | `jq` | `jq` |
| SVG rendering | `rsvg-convert` | `librsvg2-bin` |
| Package checks | `apt-cache` | `apt` |
| GitHub operations | `gh` | `gh` |
| Debian packaging | `dpkg-buildpackage`, `dh` | `dpkg-dev`, `debhelper` |
| APT archive | `reprepro` | `reprepro` |
| ISO assembly | `lb`, `xorriso`, `mksquashfs` | `live-build`, `xorriso`, `squashfs-tools` |
| VM verification | `qemu-system-x86_64` | `qemu-system-x86` |

- Install missing tools with `sudo apt-get update && sudo apt-get install -y <package>`
  before running the step, then run the step.
- State the tool and version that produced each verification result, for example
  `shellcheck 0.10.0`.
- A substitute tool, a manual inspection, or an unchecked assumption is not an acceptable
  replacement for the required tool. If the host genuinely cannot run it, stop and ask the
  maintainer instead of silently downgrading the check.
- Run `gh auth status` before any GitHub operation. If the CLI is not authenticated, pause
  and ask the maintainer to run `gh auth login`.

## 8. OpenCode workflow

- Repository commands:
  - `/new-hook` scaffolds a new chroot hook, makes it executable, and runs `shellcheck`.
  - `/verify-pkgs` checks every package in `config/package-lists/*.list.chroot` against
    Debian `trixie` and `trixie-backports`.
- `opencode.json` grants routine build and packaging commands while keeping privileged
  `live-build` operations behind an explicit prompt. Do not weaken those permissions.
- This `AGENTS.md` is authoritative. Update it only when the maintainer changes a standard.

## 9. Definition of done

Before considering a change complete:

- [ ] The OS identity, version, architecture, and archive areas match this document.
- [ ] Hyprland configuration uses `hyprland.lua` with `hl.config`, `hl.bind`, and `hl.dsp.*`.
- [ ] None of the forbidden 0.54 options are present.
- [ ] Companion tools use `.conf` syntax and the display manager launches `start-hyprland`.
- [ ] All design tokens match the table, with full opacity and no drop shadows.
- [ ] Every script and hook has the required shebang and strict mode, is executable, and
      passes `shellcheck` with zero warnings.
- [ ] Every package has been verified against `trixie` or `trixie-backports`.
- [ ] Every public `README.md` follows `SOURCE_OF_TRUTH/README_INSTRUCTIONS.md`.
- [ ] Every verification step ran with the required tool installed and reported its version.
- [ ] No generated build artifacts or secrets are staged.
- [ ] The change has been reviewed for destructive commands and follows the safety rule.

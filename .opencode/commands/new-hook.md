---
description: Scaffold a new live-build chroot hook
agent: build
---

Create a new FluorineOS `live-build` chroot hook.

Arguments: `$ARGUMENTS`

## Input contract

Accept either `<number>-<name>` (for example `10-amdgpu`) or `<number> <name>` (for
example `10 amdgpu`). The number is a zero-padded two-digit ordering prefix (`00`-`99`).
The name is lowercase kebab-case and must match `[a-z0-9]+(-[a-z0-9]+)*`.

If the arguments are missing, ambiguous, or malformed, stop and ask the user. If the target
file already exists, stop and ask; never overwrite an existing hook.

## Steps

1. Parse the arguments into `<number>` and `<name>`, then derive the target path:
   `config/hooks/normal/<number>-<name>.hook.chroot`.
2. Create the file with exactly this skeleton, replacing the comment placeholders:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   # Hook: <number>-<name>
   # Runs inside the live-build chroot as root during the normal hook phase.
   # Keep this hook idempotent and non-interactive.

   main() {
       :
   }

   main "$@"
   ```

3. Make it executable:

   ```bash
   chmod +x config/hooks/normal/<number>-<name>.hook.chroot
   ```

   On a Windows worktree, also record the executable bit in Git:

   ```bash
   git update-index --add --chmod=+x config/hooks/normal/<number>-<name>.hook.chroot
   ```

4. Run ShellCheck and require zero warnings:

   ```bash
   shellcheck -x config/hooks/normal/<number>-<name>.hook.chroot
   ```

   If ShellCheck is unavailable or reports any warning, fix the file or stop and report the
   problem. Do not suppress warnings with inline disables unless the user approves.

5. Verify the file starts with the required shebang and strict mode, then report the path,
   the executable status, and the ShellCheck result.

Do not execute the new hook, run `lb build`, use `sudo`, or stage/commit anything beyond the
executable-bit update above. Do not overwrite existing hooks.

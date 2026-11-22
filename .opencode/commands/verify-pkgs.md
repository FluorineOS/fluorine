---
description: Verify package-list entries against Debian trixie and trixie-backports
agent: build
---

Audit every package declared in this repository's `live-build` package lists against
Debian 13 (`trixie`) and `trixie-backports`. This is a read-only verification: do not
install, remove, or edit anything.

## Inputs

- Read every `config/package-lists/*.list.chroot`.
- Ignore blank lines and comments (`#`), including trailing comments.
- Trim surrounding whitespace.
- Skip and report `live-build` directives such as `!include`; they are not package names.
- Treat each remaining whitespace-separated token as an exact package name. Preserve
  architecture qualifiers such as `foo:amd64`.
- De-duplicate names for checking, but record every file and line where each name appears.
- If there are no package-list files or no package names, report that and stop.

## Procedure

1. Enumerate the files and extract candidate package names:

   ```bash
   find config/package-lists -maxdepth 1 -type f -name '*.list.chroot' -print0 |
   while IFS= read -r -d '' file; do
       sed -e 's/#.*//' "$file" |
           awk 'NF { for (i = 1; i <= NF; i++) print $i }'
   done | sort -u
   ```

2. For each package name, run both commands and capture the output:

   ```bash
   apt-cache policy "<package>"
   apt-cache show "<package>"
   ```

3. Classify each package:

   | Status | Meaning |
   | --- | --- |
   | `ok` | Candidate is available from the `trixie` family |
   | `backports` | Candidate is available only from `trixie-backports` (acceptable; report the version) |
   | `missing` | `apt-cache policy` reports no candidate or "Unable to locate package" |
   | `transitional` | `apt-cache show` reports `Section: oldlibs` or a description containing "transitional package" |
   | `wrong-suite` | Candidate exists, but only from `sid`, `unstable`, `testing`, or an unapproved repository |

   Treat `trixie`, `trixie-updates`, `trixie-security`, and `trixie-backports` as acceptable
   suites. Anything else is a failure.

4. Report a Markdown table with these columns: package, package-list file(s), status,
   candidate version, source suite, and notes. For missing or transitional packages, include
   the exact `apt-cache` output excerpt that proves the finding and suggest the likely
   replacement if one is obvious.

5. Finish with a summary count of `ok`, `backports`, `missing`, `transitional`, and
   `wrong-suite` packages. State clearly whether the package lists are safe to build.

Do not edit package lists, install packages, run `apt-get update`, modify APT sources, or
run any `live-build` command. If APT metadata is unavailable or stale, stop and ask the user
before doing anything that changes the system.

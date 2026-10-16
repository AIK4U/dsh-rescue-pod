# `_local-extensions\` -- the locally patched files, as a snapshot

This directory is the package's copy of every file that was patched locally and does
not exist in the published upstream release. The builder ships it as-is.

Two things make it more than an archive in the parent project:

1. **It is the comparison baseline.** A watchdog running beside a live installation
   compares the installed copy against this snapshot every round and restores it. It
   is not read-only history; if it drifts, the drift is what gets restored.

2. **A package manager update will wipe the installed copy**, not this snapshot. That
   is exactly why the snapshot has to be complete: it is the only thing that can put
   the patches back.

Hence the rule: any file that is not in the published release must be added here, or
it will be lost the next time dependencies are reinstalled.

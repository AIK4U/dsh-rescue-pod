# `_pod-src\` -- the pod's sources

Everything here is assembled into the rescue package by `_guard\build-pod.ps1`. The
directory is the **source of truth**: the package itself is a derived artifact and is
rebuilt from here, never edited in place.

| Path | What it is |
|---|---|
| `rescue.ps1` / `rescue.cmd` | the entry point: check / fix / boot |
| `watch.ps1` / `watch.cmd` | the watchdog that runs beside a live installation |
| `guide.txt` | the human-facing guide. **The builder writes it with a UTF-8 BOM**, because Notepad on a CJK locale needs one. It is the only `.txt` here on purpose: the builder takes the first one it finds and treats it as the guide. |
| `declared-version` | one line, the payload version this package is built to carry. Used only when the caller does not pass `-DeclaredVersion`. |
| `_extra\` | satellite files: copied verbatim with their relative path preserved, **before** the manifest is generated, so they end up hashed and listed like everything else. A collision with anything the builder produces is a hard error, never an overwrite. |

Two rules that are easy to get wrong:

**Every `.ps1` / `.cmd` here must be pure ASCII, or carry a UTF-8 BOM.** PowerShell 5.1
reads a BOM-less script as ANSI on a CJK locale; a mangled byte can swallow the next
line of code. The builder refuses to ship a script that fails this check.

**A `.cmd` may contain a non-ASCII *filename*, but never a non-ASCII *path* in its
body.** cmd.exe decodes the body with the console code page, so the path turns to
mojibake and the command quietly does nothing. Use `%~dp0`.

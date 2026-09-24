# mq project state

Updated September 24, 2026.

Local CLI for Apple Mail on macOS, written in Swift using Foundation and SQLite3.
Source: `mq.swift`. Compiled executable: `mq`.

## Available commands

- `mq search|s <text> [--limit N | -l N]`: search by subject and sender.
- `mq list|l [--limit N | -l N]`: list the most recent messages.
- `mq read|r <ROWID>`: read a local EMLX message.
- Default limit for search and list: 10.

The program automatically discovers the versioned Apple Mail folder containing
an Envelope Index. It opens SQLite read-only, excludes deleted messages, and
sorts results by date in descending order. Reading locates the EMLX or partial
EMLX file and decodes MIME headers and the text body, including multipart,
base64, and quoted-printable content. Character set support is limited to UTF-8.
Access to local Apple Mail data is required.

## Latest change and validation

Added `r` as an alias for `read`, consistent with `l` and `s`, and updated
the usage text and examples. Successfully rebuilt the `mq` executable.
Validation: `./mq r` reaches the `read` argument validation and returns
`Errore: Argomenti non validi.` (invalid arguments) with exit code 1 because
the ROWID is missing. Reading a complete message was not tested in this session.

## Build

```sh
swiftc -parse-as-library -module-cache-path /tmp/mq-swift-module-cache mq.swift -o mq
```

Use the `/tmp` cache path consistently: attempting to use its `/private/tmp`
alias caused a duplicate-module compiler error.

This directory is not a Git repository; project state is saved in local files.
No requested work remains outstanding.

# mq

Read-only Apple Mail CLI and terminal browser for macOS. Single source: `mq.swift`.

```sh
swiftc -parse-as-library -O mq.swift -lsqlite3 -o mq
```

Commands:

- `mq` or `mq browse`: interactive latest messages (default 100).
- `mq browse --limit 100`
- `mq browse search apple --limit 100`
- `mq l [--limit N]`: noninteractive list (default 10).
- `mq search apple [--limit N]`: noninteractive subject/sender search (default 10).
- `mq read ROWID`: print local message headers and body.
- Existing aliases `list`, `s`, `r`, and `-l` remain supported.

List: arrows or j/k move, Enter opens, q exits. Press s to edit a search query
(prefilled with the current filter). UTF-8, spaces and Backspace/Delete are
supported; Enter searches, Esc cancels without changing the list. An empty query
clears the filter. Esc in filtered results returns to the retained latest-message
list; Esc in the unfiltered list exits. Search uses the shared read-only SQL query
and the browse limit, only on Enter. Empty results remain interactive. Returning
from a message retains the result selection and list scroll position.

Message: arrows or j/k
scroll, PageUp/PageDown page, q/Esc returns. Resize is detected during input
polling. Browse requires a TTY on stdin and stdout. Missing local bodies show
an error in the list without closing the browser.

The terminal uses termios raw mode and the alternate screen. Cleanup restores
termios, cursor and screen via defer, including thrown errors. SIGINT, SIGTERM,
SIGHUP, SIGQUIT and SIGTSTP request a clean exit (Ctrl-Z exits rather than
suspending). SIGKILL and process/system crashes cannot run cleanup.

MIME parsing uses the EMLX byte count, recursive multipart parsing, text/plain
preference, HTML fallback, base64, quoted-printable, encoded headers, UTF-8,
ISO-8859-1 and Windows-1252. HTML conversion is intentionally minimal; attachments
are skipped. Quoted lines are dimmed. Control characters are filtered in the TUI.
Partial EMLX files can lack locally available body content.

The existing SQLite query and version-directory discovery are preserved. SQLite
opens with SQLITE_OPEN_READONLY; temporary query working storage stays in memory.
No application cache, index or temporary files are created. No mailbox/message
mutations, network requests or attachment downloads are performed.

Validation: optimized macOS build with warnings treated as errors; synthetic
MIME/charset/HTML/EMLX-length assertions; PTY navigation, scrolling, missing-file
handling and terminal restoration on normal exit and signals; local CLI smoke tests.
Original source committed as ef68ab3 before implementation.

Interactive-search regression test (synthetic data, no access to Apple Mail):

```sh
python3 tests/test_interactive_search.py
```

Only the test harness creates temporary fixtures, which it removes on completion.

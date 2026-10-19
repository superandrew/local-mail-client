"""macOS integration test: synthetic SQLite/EMLX only, never accesses Apple Mail."""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import sqlite3
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="mq-search-") as directory:
    root = Path(directory)
    database = root / "Envelope Index"
    with sqlite3.connect(database) as db:
        db.executescript("""
            CREATE TABLE subjects (subject TEXT);
            CREATE TABLE addresses (address TEXT, comment TEXT);
            CREATE TABLE messages (date_received INTEGER, subject_prefix TEXT,
                                   subject INTEGER, sender INTEGER, deleted INTEGER);
            INSERT INTO addresses VALUES ('test@example.com', 'Fixture');
        """)
        for index in range(1, 51):
            subject = f"apple {index}" if index <= 40 else "café 漢字 qjks"
            db.execute("INSERT INTO subjects VALUES (?)", (subject,))
            db.execute("INSERT INTO messages VALUES (?, '', ?, 1, 0)", (1800000000 - index, index))
            body = f"From: Fixture\nSubject: {subject}\n\n" + "body line\n" * 80
            encoded = body.encode()
            (root / f"{index}.emlx").write_bytes(str(len(encoded)).encode() + b"\n" + encoded)
    original_database = database.read_bytes()
    source = (ROOT / "mq.swift").read_text().replace("@main\nstruct MailCLI", "struct MailCLI")
    source += r'''
@main struct SearchIntegrationTest {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let paths = MailPaths(root: root, database: root.appendingPathComponent("Envelope Index"))
        let initial: String? = CommandLine.arguments.count > 2 ? "apple" : nil
        let results = try searchMail(databaseURL: paths.database, query: initial, limit: 50)
        try InteractiveMailBrowser(paths: paths, results: results, initialQuery: initial, limit: 50).run()
    }
}
'''
    swift = root / "test.swift"
    swift.write_text(source)
    binary = root / "test"
    subprocess.run(["swiftc", "-parse-as-library", "-warnings-as-errors", "-O", str(swift),
                    "-lsqlite3", "-o", str(binary)], check=True)

    def session(initial=False, interrupt=False):
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 140, 0, 0))
        command = [str(binary), str(root)] + (["search"] if initial else [])
        process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave)
        output = bytearray()

        def drain(duration=0.25):
            until = time.monotonic() + duration
            while time.monotonic() < until:
                if select.select([master], [], [], 0.02)[0]:
                    output.extend(os.read(master, 65536))
            return bytes(output).split(b"\x1b[H")[-1].decode(errors="replace")

        def send(value):
            os.write(master, value)
            return drain()

        try:
            frame = drain(1.0)
            assert "1/40" in frame if initial else "1/50" in frame
            if interrupt:
                send(b"squery")
                process.send_signal(signal.SIGTERM)
                drain()
            else:
                if initial:
                    assert "Search: apple" in frame
                    assert "1/50" in send(b"\x1b")
                assert "Search: _" in send(b"s")
                assert "Search: qjks _" in send(b"qjks ")
                # Cancellation must preserve the original list.
                assert "1/50" in send(b"\x1b")
                assert "Search: apple" in send(b"sapple\r")
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 80, 0, 0))
                narrow = drain()
                assert "Esc clear" in narrow and "q quit" in narrow
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 140, 0, 0))
                drain()
                assert "21/40" in send(b"j" * 20)
                before = drain()
                assert "Subject: apple 21" in send(b"\r")
                send(b"\x1b[6~")
                assert send(b"q") == before
                # Prefilled query; cancellation retains selection and scrolling.
                assert "Search: apple_" in send(b"s")
                send(b"new")
                assert send(b"\x1b") == before
                # Backspace, ASCII delete and forward-delete sequence act on the last character.
                send(b"s" + b"\x7f" * 5)
                send(b"caf")
                # UTF-8 may arrive across input poll timeouts.
                send(b"\xc3")
                send(b"\xa9")
                send(" 漢字 qjksX".encode())
                send(b"\x1b[3~")
                assert "1/10" in send(b"\r")
                send(b"s" + b"\x08" * len("café 漢字 qjks") + b"missing\r")
                assert 'Nessun risultato per "missing"' in drain()
                assert "0/0" in drain()
                assert "Search: missing_" in send(b"s")
                send(b"\x1b")
                assert "1/50" in send(b"\x1b")
                # Empty input returns to latest messages.
                send(b"sapple\r")
                assert "1/50" in send(b"s" + b"\x7f" * 5 + b"\r")
                send(b"\x1b")
            process.wait(timeout=3)
            restored = termios.tcgetattr(slave)
            # macOS may set this kernel retype-pending flag during tcsetattr.
            restored[3] &= ~termios.PENDIN
            original[3] &= ~termios.PENDIN
            assert restored == original, "Terminal attributes not restored"
            assert b"\x1b[?25h\x1b[?1049l" in output
            assert process.returncode == 0
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=3)
            os.close(master)
            os.close(slave)

    session()
    session(initial=True)
    session(interrupt=True)
    assert database.read_bytes() == original_database
    assert not list(root.glob("Envelope Index-*"))
    print("PASS: interactive search, UTF-8 editing, cancellation, empty results, message return, initial filter, terminal restoration, read-only SQLite")

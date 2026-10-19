import Foundation
import SQLite3
import Darwin

enum MailCLIError: Error, CustomStringConvertible {
    case mailRootNotFound
    case envelopeIndexNotFound
    case sqliteOpenFailed(String)
    case sqlitePrepareFailed(String)
    case sqliteBindFailed(String)
    case invalidArguments
    case messageNotFound(Int64)
    case unsupportedMessageFormat(String)

    var description: String {
        switch self {
        case .mailRootNotFound:
            return "Apple Mail root non trovata."

        case .envelopeIndexNotFound:
            return "Envelope Index non trovato."

        case .sqliteOpenFailed(let msg):
            return "Impossibile aprire SQLite: \(msg)"

        case .sqlitePrepareFailed(let msg):
            return "Errore preparando query SQLite: \(msg)"

        case .sqliteBindFailed(let msg):
            return "Errore nel bind SQLite: \(msg)"

        case .invalidArguments:
            return "Argomenti non validi."

        case .messageNotFound(let id):
            return "Messaggio \(id) non trovato."

        case .unsupportedMessageFormat(let msg):
            return "Formato messaggio non supportato: \(msg)"
        }
    }
}

struct MailPaths {
    let root: URL
    let database: URL
}

struct SearchResult {
    let id: Int64
    let date: String
    let sender: String
    let subject: String
}

struct ParsedMail {
    let from: String
    let to: String
    let cc: String
    let date: String
    let subject: String
    let body: String
}

@main
struct MailCLI {

    static func main() {
        do {
            let paths = try discoverMailPaths()
            let args = Array(CommandLine.arguments.dropFirst())

            let command = args.first ?? "browse"

            switch command {
            case "browse":
                try handleBrowse(args: Array(args.dropFirst()), paths: paths)

            case "search", "s":
                try handleSearch(
                    args: Array(args.dropFirst()),
                    paths: paths
                )

            case "list", "l":
                try handleList(
                    args: Array(args.dropFirst()),
                    paths: paths
                )

            case "read", "r":
                try handleRead(
                    args: Array(args.dropFirst()),
                    paths: paths
                )

            default:
                printUsage()
            }

        } catch {
            fputs("Errore: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Usage:
          mq [browse [search <text>] [--limit N]]
          mq search|s <text> [--limit N | -l N]
          mq list|l [--limit N | -l N]
          mq read|r <ROWID>

        Default limit: 10 for search and list.

        Examples:
          mq search invoice
          mq search "project update"
          mq search invoice --limit 200
          mq s invoice -l 10
          mq l
          mq l -l 50
          mq read 6296367
          mq r 6296367
        """)
    }
}


// MARK: - Apple Mail discovery

func discoverMailPaths() throws -> MailPaths {

    let home = FileManager.default.homeDirectoryForCurrentUser

    let mailBase = home
        .appendingPathComponent("Library")
        .appendingPathComponent("Mail")

    guard
        let entries = try? FileManager.default.contentsOfDirectory(
            at: mailBase,
            includingPropertiesForKeys: nil
        )
    else {
        throw MailCLIError.mailRootNotFound
    }

    let versionDirs = entries
        .filter { url in
            let name = url.lastPathComponent

            guard name.hasPrefix("V") else {
                return false
            }

            return Int(name.dropFirst()) != nil
        }
        .sorted {
            let a = Int($0.lastPathComponent.dropFirst()) ?? 0
            let b = Int($1.lastPathComponent.dropFirst()) ?? 0

            return a > b
        }

    for root in versionDirs {

        let db = root
            .appendingPathComponent("MailData")
            .appendingPathComponent("Envelope Index")

        if FileManager.default.fileExists(atPath: db.path) {
            return MailPaths(
                root: root,
                database: db
            )
        }
    }

    throw MailCLIError.envelopeIndexNotFound
}


// MARK: - Search command

func parseLimitArguments(
    args: [String],
    defaultLimit: Int
) throws -> (queryParts: [String], limit: Int) {

    var queryParts: [String] = []
    var limit = defaultLimit

    var i = 0

    while i < args.count {

        if args[i] == "--limit" || args[i] == "-l" {

            guard
                i + 1 < args.count,
                let parsed = Int(args[i + 1]),
                parsed > 0
            else {
                throw MailCLIError.invalidArguments
            }

            limit = parsed
            i += 2

        } else {
            queryParts.append(args[i])
            i += 1
        }
    }

    return (queryParts, limit)
}

func handleSearch(
    args: [String],
    paths: MailPaths
) throws {
    let options = try parseLimitArguments(args: args, defaultLimit: 10)
    let query = options.queryParts.joined(separator: " ")

    guard !query.isEmpty else {
        throw MailCLIError.invalidArguments
    }

    let results = try searchMail(
        databaseURL: paths.database,
        query: query,
        limit: options.limit
    )

    printSearchResults(results)
}

// MARK: - List command

func handleList(
    args: [String],
    paths: MailPaths
) throws {
    let options = try parseLimitArguments(args: args, defaultLimit: 10)

    guard options.queryParts.isEmpty else {
        throw MailCLIError.invalidArguments
    }

    let results = try searchMail(
        databaseURL: paths.database,
        query: nil,
        limit: options.limit
    )

    printSearchResults(results)
}


// MARK: - SQLite search

struct MailDatabase {
static func search(
    databaseURL: URL,
    query: String?,
    limit: Int
) throws -> [SearchResult] {

    var dbPointer: OpaquePointer?

    let openResult = sqlite3_open_v2(
        databaseURL.path,
        &dbPointer,
        SQLITE_OPEN_READONLY,
        nil
    )

    guard openResult == SQLITE_OK else {

        let message: String

        if let dbPointer {
            message = String(
                cString: sqlite3_errmsg(dbPointer)
            )
            sqlite3_close(dbPointer)
        } else {
            message = "errore sconosciuto"
        }

        throw MailCLIError.sqliteOpenFailed(message)
    }

    guard let db = dbPointer else {
        throw MailCLIError.sqliteOpenFailed(
            "Handle SQLite non disponibile."
        )
    }

    defer {
        sqlite3_close(db)
    }

    // Keep SQLite sorting/working storage in memory, even for large limits.
    guard sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil) == SQLITE_OK else {
        throw MailCLIError.sqlitePrepareFailed(String(cString: sqlite3_errmsg(db)))
    }

    let sql = """
    SELECT
        m.ROWID,

        datetime(
            m.date_received,
            'unixepoch',
            'localtime'
        ),

        CASE
            WHEN COALESCE(a.comment, '') != ''
            THEN
                a.comment ||
                ' <' ||
                a.address ||
                '>'
            ELSE
                COALESCE(a.address, '')
        END,

        COALESCE(
            m.subject_prefix,
            ''
        ) ||
        COALESCE(
            s.subject,
            ''
        )

    FROM messages m

    LEFT JOIN subjects s
        ON s.ROWID = m.subject

    LEFT JOIN addresses a
        ON a.ROWID = m.sender

    WHERE
        m.deleted = 0

        AND (
            ?1 IS NULL
            OR
            s.subject LIKE '%' || ?1 || '%'
            OR
            a.address LIKE '%' || ?1 || '%'
            OR
            a.comment LIKE '%' || ?1 || '%'
        )

    ORDER BY
        m.date_received DESC

    LIMIT ?2;
    """

    var stmt: OpaquePointer?

    guard
        sqlite3_prepare_v2(
            db,
            sql,
            -1,
            &stmt,
            nil
        ) == SQLITE_OK
    else {

        let msg = String(
            cString: sqlite3_errmsg(db)
        )

        throw MailCLIError.sqlitePrepareFailed(msg)
    }

    defer {
        sqlite3_finalize(stmt)
    }

    let bindTextResult = query.map { query in
        query.withCString { ptr in
            sqlite3_bind_text(
                stmt,
                1,
                ptr,
                -1,
                unsafeBitCast(
                    -1,
                    to: sqlite3_destructor_type.self
                )
            )
        }
    } ?? sqlite3_bind_null(stmt, 1)

    guard bindTextResult == SQLITE_OK else {
        throw MailCLIError.sqliteBindFailed(
            String(cString: sqlite3_errmsg(db))
        )
    }

    let bindLimitResult = sqlite3_bind_int64(
        stmt,
        2,
        Int64(limit)
    )

    guard bindLimitResult == SQLITE_OK else {
        throw MailCLIError.sqliteBindFailed(
            String(cString: sqlite3_errmsg(db))
        )
    }

    var results: [SearchResult] = []

    while true {

        let stepResult = sqlite3_step(stmt)

        if stepResult == SQLITE_DONE {
            break
        }

        guard stepResult == SQLITE_ROW else {
            throw MailCLIError.sqlitePrepareFailed(
                String(cString: sqlite3_errmsg(db))
            )
        }

        let id = sqlite3_column_int64(
            stmt,
            0
        )

        let date = columnText(
            stmt,
            index: 1
        )

        let sender = columnText(
            stmt,
            index: 2
        )

        let subject = columnText(
            stmt,
            index: 3
        )

        results.append(
            SearchResult(
                id: id,
                date: date,
                sender: sender,
                subject: subject
            )
        )
    }

    return results
}

}

func searchMail(databaseURL: URL, query: String?, limit: Int) throws -> [SearchResult] {
    try MailDatabase.search(databaseURL: databaseURL, query: query, limit: limit)
}

func columnText(
    _ stmt: OpaquePointer?,
    index: Int32
) -> String {

    guard
        let ptr = sqlite3_column_text(
            stmt,
            index
        )
    else {
        return ""
    }

    return String(
        cString: ptr
    )
}


// MARK: - Search output

func printSearchResults(
    _ results: [SearchResult]
) {

    if results.isEmpty {
        print("Nessun messaggio trovato.")
        return
    }

    let idWidth = max(
        8,
        results
            .map { String($0.id).count }
            .max() ?? 8
    )

    let dateWidth = 19
    let senderWidth = 40

    print(
        pad("ID", to: idWidth),
        pad("DATA", to: dateWidth),
        pad("MITTENTE", to: senderWidth),
        "OGGETTO"
    )

    print(
        String(
            repeating: "-",
            count:
                idWidth +
                dateWidth +
                senderWidth +
                50
        )
    )

    for result in results {

        print(
            pad(
                String(result.id),
                to: idWidth
            ),

            pad(
                result.date,
                to: dateWidth
            ),

            pad(
                truncate(
                    result.sender,
                    max: senderWidth
                ),
                to: senderWidth
            ),

            result.subject
        )
    }
}

func pad(
    _ text: String,
    to width: Int
) -> String {

    if text.count >= width {
        return text
    }

    return text +
        String(
            repeating: " ",
            count: width - text.count
        )
}

func truncate(
    _ text: String,
    max: Int
) -> String {

    guard text.count > max else {
        return text
    }

    return String(
        text.prefix(max - 1)
    ) + "…"
}


// MARK: - Read command

func handleRead(
    args: [String],
    paths: MailPaths
) throws {

    guard
        args.count == 1,
        let id = Int64(args[0])
    else {
        throw MailCLIError.invalidArguments
    }

    let messageURL = try locateMessage(
        id: id,
        paths: paths
    )

    let parsed = try parseEMLX(
        url: messageURL
    )

    print("From:    \(parsed.from)")
    print("To:      \(parsed.to)")

    if !parsed.cc.isEmpty {
        print("Cc:      \(parsed.cc)")
    }

    print("Date:    \(parsed.date)")
    print("Subject: \(parsed.subject)")

    print(
        String(
            repeating: "-",
            count: 80
        )
    )

    print(parsed.body)
}


// MARK: - Locate EMLX

struct MailMessageLocator {
static func locate(
    id: Int64,
    paths: MailPaths
) throws -> URL {

    let fm = FileManager.default

    guard
        let enumerator = fm.enumerator(
            at: paths.root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    else {
        throw MailCLIError.messageNotFound(id)
    }

    let expectedEMLX = "\(id).emlx"
    let expectedPartial = "\(id).partial.emlx"

    for case let url as URL in enumerator {

        if terminalSignal != 0 { throw TerminalError.failure("Interrotto.") }
        let name = url.lastPathComponent

        if name == expectedEMLX ||
           name == expectedPartial {

            return url
        }
    }

    throw MailCLIError.messageNotFound(id)
}


}

func locateMessage(id: Int64, paths: MailPaths) throws -> URL {
    try MailMessageLocator.locate(id: id, paths: paths)
}

// MARK: - EMLX parsing

func parseEMLX(url: URL) throws -> ParsedMail {
    try EMLXParser.parse(data: Data(contentsOf: url))
}

// MARK: - RFC822 headers

func parseHeaders(
    _ block: String
) -> [String: String] {

    var unfolded: [String] = []

    for line in block.split(
        separator: "\n",
        omittingEmptySubsequences: false
    ) {

        let s = String(line)

        if s.hasPrefix(" ") ||
           s.hasPrefix("\t") {

            if !unfolded.isEmpty {

                unfolded[
                    unfolded.count - 1
                ] +=
                    " " +
                    s.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
            }

        } else {

            unfolded.append(s)
        }
    }

    var result: [String: String] = [:]

    for line in unfolded {

        guard
            let colon = line.firstIndex(of: ":")
        else {
            continue
        }

        let key = String(
            line[..<colon]
        ).lowercased()

        let value = String(
            line[
                line.index(
                    after: colon
                )...
            ]
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        result[key] = value
    }

    return result
}


// MARK: - Byte-preserving MIME parser

struct EMLXParser {
    static func parse(data: Data) throws -> ParsedMail {
        guard let newline = data.firstIndex(of: 10),
              let countString = String(data: data[..<newline], encoding: .ascii),
              let count = Int(countString.trimmingCharacters(in: .whitespacesAndNewlines)),
              count >= 0, count <= data.count - newline - 1 else {
            throw MailCLIError.unsupportedMessageFormat("Lunghezza EMLX non valida.")
        }
        // Latin-1 is used only as a lossless byte transport before charset decoding.
        let bytes = data[(newline + 1)..<(newline + 1 + count)]
        let raw = String(bytes.map { Character(UnicodeScalar($0)) })
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard let (headers, body) = split(raw) else {
            throw MailCLIError.unsupportedMessageFormat("Separatore header/body non trovato.")
        }
        let parts = content(headers, body, depth: 0)
        func header(_ name: String) -> String {
            decodeMIMEHeader(decode(bytesOf(headers[name] ?? ""), charset: nil))
        }
        return ParsedMail(from: header("from"), to: header("to"), cc: header("cc"),
                          date: header("date"), subject: header("subject"),
                          body: parts.plain ?? parts.html ?? "[Nessun corpo leggibile disponibile localmente]")
    }

    static func bytesOf(_ text: String) -> Data {
        Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    static func split(_ raw: String) -> ([String: String], String)? {
        if raw.hasPrefix("\n") { return ([:], String(raw.dropFirst())) }
        guard let range = raw.range(of: "\n\n") else { return nil }
        return (parseHeaders(String(raw[..<range.lowerBound])), String(raw[range.upperBound...]))
    }

    static func parameter(_ name: String, in value: String) -> String? {
        let pattern = "(?i)(?:^|;)\\s*" + name + #"\s*=\s*(?:"([^"]*)"|([^;\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        for index in 1...2 {
            if let range = Range(match.range(at: index), in: value) { return String(value[range]) }
        }
        return nil
    }

    static func content(_ headers: [String: String], _ body: String, depth: Int) -> (plain: String?, html: String?) {
        guard depth < 40 else { return (nil, nil) }
        let type = headers["content-type"] ?? "text/plain"
        let media = type.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
        if (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return (nil, nil) }
        if media.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: type), !boundary.isEmpty else { return (nil, nil) }
            var parts: [String] = [], current: [String]? = nil
            for line in body.components(separatedBy: "\n") {
                let marker = line.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
                if marker == "--" + boundary || marker == "--" + boundary + "--" {
                    if let current { parts.append(current.joined(separator: "\n")) }
                    current = nil
                    if marker.hasSuffix(boundary + "--") { break }
                    current = []
                } else if current != nil { current!.append(line) }
            }
            if let current { parts.append(current.joined(separator: "\n")) }
            var plain: [String] = [], html: [String] = []
            for part in parts {
                guard let (h, b) = split(part) else { continue }
                let found = content(h, b, depth: depth + 1)
                if let text = found.plain { plain.append(text) }
                if let text = found.html { html.append(text) }
            }
            return (plain.isEmpty ? nil : plain.joined(separator: "\n\n"),
                    html.isEmpty ? nil : html.joined(separator: "\n\n"))
        }
        guard media == "text/plain" || media == "text/html" else { return (nil, nil) }
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        var data = bytesOf(body)
        if encoding == "base64" { data = Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? data }
        if encoding == "quoted-printable" { data = quotedPrintable(data) }
        let text = decode(data, charset: parameter("charset", in: type))
        return media == "text/plain" ? (text, nil) : (nil, htmlText(text))
    }

    static func decode(_ data: Data, charset: String?) -> String {
        let encoding: String.Encoding
        switch charset?.lowercased() {
        case "iso-8859-1", "latin1", "latin-1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "us-ascii", "ascii": encoding = .ascii
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    static func quotedPrintable(_ data: Data) -> Data {
        let bytes = Array(data)
        var output: [UInt8] = [], i = 0
        while i < bytes.count {
            if bytes[i] == 61 {
                if i + 1 < bytes.count && bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count && bytes[i + 1] == 13 && bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count,
                   let h = Int(String(UnicodeScalar(bytes[i + 1])), radix: 16),
                   let l = Int(String(UnicodeScalar(bytes[i + 2])), radix: 16) {
                    output.append(UInt8(h * 16 + l)); i += 3; continue
                }
            }
            output.append(bytes[i]); i += 1
        }
        return Data(output)
    }

    static func htmlText(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [
            (#"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, ""),
            (#"(?s)<!--.*?-->"#, ""),
            (#"(?i)<br\b[^>]*>"#, "\n"),
            (#"(?i)</?p\b[^>]*>"#, "\n\n"),
            (#"(?i)</?(div|tr|h[1-6])\b[^>]*>"#, "\n"),
            (#"(?i)<li\b[^>]*>"#, "\n• "),
            (#"(?i)</(li|td|th)\s*>"#, " "),
            (#"(?s)<[^>]*>"#, "")
        ] { text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
                        "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "euro": "€"]
        if let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), let keyRange = Range(match.range(at: 1), in: text) else { continue }
                let key = String(text[keyRange])
                var value = entities[key]
                if key.hasPrefix("#") {
                    let hex = key.hasPrefix("#x")
                    if let number = UInt32(key.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) {
                        value = String(scalar)
                    }
                }
                if let value { text.replaceSubrange(range, with: value) }
            }
        }
        return text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n[ \t]+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func decodeMIMEHeader(_ input: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return input }
    var result = "", cursor = input.startIndex, previousEncoded = false
    for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
        guard let whole = Range(match.range, in: input), let charset = Range(match.range(at: 1), in: input),
              let encoding = Range(match.range(at: 2), in: input), let payload = Range(match.range(at: 3), in: input) else { continue }
        let gap = String(input[cursor..<whole.lowerBound])
        let data: Data?
        if input[encoding].lowercased() == "b" { data = Data(base64Encoded: String(input[payload])) }
        else { data = EMLXParser.quotedPrintable(Data(input[payload].replacingOccurrences(of: "_", with: " ").utf8)) }
        if !(previousEncoded && data != nil && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { result += gap }
        result += data.map { EMLXParser.decode($0, charset: String(input[charset])) } ?? String(input[whole])
        previousEncoded = data != nil
        cursor = whole.upperBound
    }
    return result + input[cursor...]
}

// MARK: - Terminal lifecycle and input

private var terminalSignal: sig_atomic_t = 0
private func handleTerminalSignal(_ number: Int32) { terminalSignal = number }

enum TerminalError: Error, CustomStringConvertible {
    case failure(String)
    var description: String { switch self { case .failure(let message): return message } }
}

enum TerminalKey {
    case up, down, pageUp, pageDown, enter, quit, escape, search, delete, other, end
    case text(String)
}

final class TerminalController {
    private var original = termios()
    private var active = false
    private var savedSignals: [(Int32, sigaction)] = []
    private var pending: [UInt8] = []
    private var utf8Input: [UInt8] = []
    var lastFrame = ""

    func start() throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw TerminalError.failure("La modalità browse richiede un terminale interattivo; usa mq l o mq search.")
        }
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw TerminalError.failure("tcgetattr fallita.") }
        terminalSignal = 0
        for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGPIPE] {
            var action = sigaction(), old = sigaction()
            action.__sigaction_u.__sa_handler = handleTerminalSignal
            sigemptyset(&action.sa_mask)
            if sigaction(number, &action, &old) != 0 {
                restore()
                throw TerminalError.failure("Impossibile installare il gestore segnali.")
            }
            savedSignals.append((number, old))
        }
        var raw = original
        cfmakeraw(&raw)
        // Poll with a timeout: signals and resize are handled on the main thread.
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)] = 0
            bytes[Int(VTIME)] = 1
        }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            restore(); throw TerminalError.failure("Impossibile attivare raw mode.")
        }
        active = true
        send("\u{1B}[?1049h\u{1B}[?25l\u{1B}[0m")
    }

    func restore() {
        if active {
            send("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
            while tcsetattr(STDIN_FILENO, TCSANOW, &original) != 0 && errno == EINTR {}
            active = false
        }
        for (number, saved) in savedSignals {
            var action = saved
            sigaction(number, &action, nil)
        }
        savedSignals.removeAll()
    }
    deinit { restore() }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    var size: (rows: Int, columns: Int) {
        var dimensions = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &dimensions) == 0, dimensions.ws_row > 0, dimensions.ws_col > 0 {
            return (Int(dimensions.ws_row), Int(dimensions.ws_col))
        }
        return (24, 80)
    }

    private func byte() throws -> UInt8? {
        if !pending.isEmpty { return pending.removeFirst() }
        var value: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &value, 1)
        if count == 1 { return value }
        if count < 0 && errno != EINTR { throw TerminalError.failure("Lettura del terminale fallita.") }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 0) > 0 && descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            throw TerminalError.failure("Terminale disconnesso.")
        }
        return nil
    }

    func key(textInput: Bool = false) throws -> TerminalKey {
        if terminalSignal != 0 { return .end }
        guard let first = try byte() else { return .other }
        if textInput && first >= 32 && first != 127 {
            if first < 128 {
                utf8Input.removeAll()
                return .text(String(UnicodeScalar(first)))
            }
            if first >= 0xC2 && first <= 0xF4 { utf8Input = [first] }
            else if first >= 0x80 && first <= 0xBF && !utf8Input.isEmpty { utf8Input.append(first) }
            else { utf8Input.removeAll(); return .other }
            let expected = utf8Input[0] < 0xE0 ? 2 : (utf8Input[0] < 0xF0 ? 3 : 4)
            if utf8Input.count == expected {
                let text = String(bytes: utf8Input, encoding: .utf8)
                utf8Input.removeAll()
                if let text { return .text(TerminalRenderer.safe(text)) }
            }
            return .other
        }
        utf8Input.removeAll()
        switch first {
        case 3: terminalSignal = SIGINT; return .end
        case 4: return .end
        case 26: terminalSignal = SIGTSTP; return .end
        case 113: return .quit
        case 115: return .search
        case 8, 127: return .delete
        case 106: return .down
        case 107: return .up
        case 10, 13: return .enter
        case 27:
            guard let second = try byte() else { return .escape }
            guard second == 91 || second == 79 else { pending.append(second); return .escape }
            var sequence: [UInt8] = []
            for _ in 0..<16 {
                guard let next = try byte() else { return .other }
                sequence.append(next)
                if next >= 64 && next <= 126 { break }
            }
            switch String(decoding: sequence, as: UTF8.self) {
            case "A": return .up
            case "B": return .down
            case "5~": return .pageUp
            case "6~": return .pageDown
            case "3~": return .delete
            default: return .other
            }
        default: return .other
        }
    }
}

// MARK: - Safe terminal rendering

struct TerminalRenderer {
    static func safe(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 32 && !($0.value >= 127 && $0.value <= 159) && $0.value != 0x2028 && $0.value != 0x2029 })
    }
    static func width(_ character: Character) -> Int {
        let widths = character.unicodeScalars.map { max(0, Int(wcwidth(wchar_t($0.value)))) }
        if character.unicodeScalars.contains(where: { $0.value == 0x200D || $0.value == 0xFE0F }) { return max(2, widths.max() ?? 0) }
        return widths.reduce(0, +)
    }
    static func fit(_ text: String, _ columns: Int, pad: Bool = false) -> String {
        var result = "", used = 0
        for character in safe(text) {
            let count = width(character)
            if used + count > max(0, columns) { break }
            result.append(character); used += count
        }
        if pad { result += String(repeating: " ", count: max(0, columns - used)) }
        return result
    }
    static func wrap(_ text: String, columns: Int) -> [String] {
        let limit = max(1, columns)
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            let clean = safe(line.replacingOccurrences(of: "\t", with: "    "))
            let quoted = clean.trimmingCharacters(in: .whitespaces).hasPrefix(">")
            var buffer = "", used = 0
            for character in clean {
                let count = width(character)
                if used + count > limit && !buffer.isEmpty {
                    lines.append(quoted ? "\u{1B}[2m" + buffer + "\u{1B}[0m" : buffer)
                    buffer = ""; used = 0
                }
                if count <= limit { buffer.append(character); used += count }
            }
            lines.append(quoted ? "\u{1B}[2m" + buffer + "\u{1B}[0m" : buffer)
        }
        return lines
    }
    static func date(_ date: String) -> String {
        let parts = date.components(separatedBy: " ")
        let ymd = (parts.first ?? "").components(separatedBy: "-")
        guard ymd.count == 3, parts.count > 1 else { return date }
        return "\(ymd[2])/\(ymd[1])/\(ymd[0]) \(parts[1].prefix(5))"
    }
    static func row(date: String, sender: String, subject: String, columns: Int) -> String {
        if columns < 42 { return fit(sender + "  " + subject, columns) }
        let senderWidth = min(40, max(10, (columns - 19) / 3))
        return fit(fit(date, 16, pad: true) + "  " + fit(sender, senderWidth, pad: true) + "  " + subject, columns)
    }
    static func frame(_ lines: [String], status: String, terminal: TerminalController) {
        let size = terminal.size
        var output = "\u{1B}[H"
        for index in 0..<max(0, size.rows - 1) {
            output += "\u{1B}[0m\u{1B}[2K" + (index < lines.count ? lines[index] : "") + "\r\n"
        }
        output += "\u{1B}[0m\u{1B}[2K\u{1B}[7m" + fit(status, max(0, size.columns - 1), pad: true) + "\u{1B}[0m"
        if terminal.lastFrame != output {
            terminal.send(output)
            terminal.lastFrame = output
        }
    }
}

enum ViewState { case list, searchInput, message }

struct InteractiveMailBrowser {
    let paths: MailPaths
    let results: [SearchResult]
    var initialQuery: String? = nil
    var limit: Int = 100

    func run() throws {
        // Retain the unfiltered list separately, including when launched with browse search.
        let latest = try initialQuery == nil ? results : searchMail(databaseURL: paths.database, query: nil, limit: limit)
        var displayed = results
        var currentQuery = initialQuery
        var state = ViewState.list
        var input = ""
        setlocale(LC_CTYPE, "")
        let terminal = TerminalController()
        try terminal.start()
        defer { terminal.restore() }
        var selected = 0, top = 0, scroll = 0
        var message: ParsedMail?, notice = ""
        var wrapped: [String] = [], previousWidth = -1
        while terminalSignal == 0 {
            let size = terminal.size, columns = max(1, size.columns - 1)
            let page = max(1, size.rows - (state == .message ? 1 : 2))
            if state == .message, let message {
                if columns != previousWidth {
                    let text = "From: \(message.from)\nTo: \(message.to)\nCc: \(message.cc)\nDate: \(message.date)\nSubject: \(message.subject)\n\n\(message.body)"
                    wrapped = TerminalRenderer.wrap(text, columns: columns)
                    previousWidth = columns
                }
                scroll = min(scroll, max(0, wrapped.count - page))
                TerminalRenderer.frame(Array(wrapped.dropFirst(scroll).prefix(page)),
                    status: "↑↓ scroll   PgUp/PgDn   q back", terminal: terminal)
            } else {
                top = min(top, max(0, displayed.count - page))
                if selected < top { top = selected }
                if selected >= top + page { top = selected - page + 1 }
                var lines = [TerminalRenderer.row(date: "DATA", sender: "MITTENTE", subject: "OGGETTO", columns: columns)]
                for index in top..<min(displayed.count, top + page) {
                    let result = displayed[index]
                    let row = TerminalRenderer.row(date: TerminalRenderer.date(result.date), sender: result.sender, subject: result.subject, columns: columns)
                    lines.append(index == selected ? "\u{1B}[7m" + TerminalRenderer.fit(row, columns, pad: true) + "\u{1B}[0m" : row)
                }
                if displayed.isEmpty {
                    lines.append(TerminalRenderer.fit(currentQuery.map { "Nessun risultato per \"\($0)\"" } ?? "Nessun messaggio trovato.", columns))
                }
                let position = "\(displayed.isEmpty ? 0 : selected + 1)/\(displayed.count)"
                var status = position + "   ↑↓ move   Enter open   s search   q quit"
                if let currentQuery {
                    let hints = columns >= 110
                        ? "   ↑↓ move   Enter open   s new search   Esc clear   q quit"
                        : "  ↑↓ move  Enter open  s search  Esc clear  q quit"
                    let queryWidth = max(1, columns - 11 - position.count - hints.count)
                    status = "Search: " + TerminalRenderer.fit(currentQuery, queryWidth) + "   " + position + hints
                }
                if !notice.isEmpty { status = notice }
                if state == .searchInput {
                    // End-only editor: keep the insertion point visible for long queries.
                    var tail = "", used = 0
                    for character in input.reversed() {
                        let width = TerminalRenderer.width(character)
                        if used + width > max(0, columns - 9) { break }
                        tail.insert(character, at: tail.startIndex); used += width
                    }
                    status = "Search: " + tail + "_"
                }
                TerminalRenderer.frame(lines, status: status, terminal: terminal)
            }
            let key = try terminal.key(textInput: state == .searchInput)
            if state == .searchInput {
                switch key {
                case .end: return
                case .escape: state = .list
                case .text(let text): input += text
                case .delete: if !input.isEmpty { input.removeLast() }
                case .enter:
                    let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    do {
                        let found = try query.isEmpty ? latest : searchMail(databaseURL: paths.database, query: query, limit: limit)
                        displayed = found
                        currentQuery = query.isEmpty ? nil : query
                        selected = 0; top = 0; notice = ""
                    } catch { notice = "Errore: \(error) — s riprova, Esc annulla" }
                    state = .list
                default: break // Input never dispatches list or message commands.
                }
                continue
            }
            switch key {
            case .end: return
            case .quit, .escape:
                if state == .message {
                    message = nil; state = .list; notice = ""
                } else if case .escape = key, currentQuery != nil {
                    displayed = latest; currentQuery = nil
                    selected = 0; top = 0; notice = ""
                } else { return }
            case .search:
                if state == .list { input = currentQuery ?? ""; state = .searchInput }
            case .up:
                if state == .message { scroll = max(0, scroll - 1) } else { selected = max(0, selected - 1); notice = "" }
            case .down:
                if state == .message { scroll = min(max(0, wrapped.count - page), scroll + 1) }
                else { selected = min(max(0, displayed.count - 1), selected + 1); notice = "" }
            case .pageUp: if state == .message { scroll = max(0, scroll - page) }
            case .pageDown: if state == .message { scroll = min(max(0, wrapped.count - page), scroll + page) }
            case .enter:
                if state == .list && !displayed.isEmpty {
                    terminal.lastFrame = ""
                    terminal.send("\u{1B}[\(size.rows);1H\u{1B}[2KCaricamento…")
                    do {
                        message = try parseEMLX(url: locateMessage(id: displayed[selected].id, paths: paths))
                        state = .message; scroll = 0; previousWidth = -1
                    } catch { notice = "Errore: \(error)  — q esce" }
                }
            case .other, .delete, .text: break
            }
        }
    }
}

func handleBrowse(args: [String], paths: MailPaths) throws {
    let searching = args.first == "search" || args.first == "s"
    let options = try parseLimitArguments(args: searching ? Array(args.dropFirst()) : args, defaultLimit: 100)
    let query = options.queryParts.joined(separator: " ")
    guard searching ? !query.isEmpty : query.isEmpty else { throw MailCLIError.invalidArguments }
    let results = try searchMail(databaseURL: paths.database, query: searching ? query : nil, limit: options.limit)
    try InteractiveMailBrowser(paths: paths, results: results, initialQuery: searching ? query : nil, limit: options.limit).run()
    if terminalSignal != 0 { exit(128 + terminalSignal) }
}

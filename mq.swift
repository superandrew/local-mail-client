import Foundation
import SQLite3

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

            guard let command = args.first else {
                printUsage()
                return
            }

            switch command {
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

func searchMail(
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

func locateMessage(
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

        let name = url.lastPathComponent

        if name == expectedEMLX ||
           name == expectedPartial {

            return url
        }
    }

    throw MailCLIError.messageNotFound(id)
}


// MARK: - EMLX parsing

func parseEMLX(
    url: URL
) throws -> ParsedMail {

    let data = try Data(
        contentsOf: url
    )

    guard
        let firstNewline = data.firstIndex(of: 0x0A)
    else {
        throw MailCLIError.unsupportedMessageFormat(
            "Prima riga EMLX non trovata."
        )
    }

    let lengthData = data[
        ..<firstNewline
    ]

    guard
        let lengthString = String(
            data: lengthData,
            encoding: .ascii
        ),
        let messageLength = Int(
            lengthString.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
    else {
        throw MailCLIError.unsupportedMessageFormat(
            "Lunghezza EMLX non valida."
        )
    }

    let messageStart = data.index(
        after: firstNewline
    )

    guard
        messageLength >= 0,
        messageStart + messageLength <= data.endIndex
    else {
        throw MailCLIError.unsupportedMessageFormat(
            "Lunghezza EMLX fuori intervallo."
        )
    }

    let messageData = data[
        messageStart ..<
        messageStart + messageLength
    ]

    guard
        let raw = String(
            data: messageData,
            encoding: .utf8
        )
    else {
        throw MailCLIError.unsupportedMessageFormat(
            "Messaggio RFC822 non UTF-8."
        )
    }

    let normalized = raw.replacingOccurrences(
        of: "\r\n",
        with: "\n"
    )

    guard
        let separator = normalized.range(
            of: "\n\n"
        )
    else {
        throw MailCLIError.unsupportedMessageFormat(
            "Separatore header/body non trovato."
        )
    }

    let headerBlock = String(
        normalized[
            ..<separator.lowerBound
        ]
    )

    let rawBody = String(
        normalized[
            separator.upperBound...
        ]
    )

    let headers = parseHeaders(
        headerBlock
    )

    let contentType =
        headers["content-type"]
        ?? "text/plain"

    let encoding =
        headers[
            "content-transfer-encoding"
        ]?
        .lowercased()
        .trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        ?? ""

    let body: String

    if contentType
        .lowercased()
        .contains("multipart/") {

        body =
            extractPlainTextFromMultipart(
                body: rawBody,
                contentType: contentType
            )
            ??
            "[Nessun corpo text/plain disponibile localmente]"

    } else {

        body = decodeBody(
            rawBody,
            encoding: encoding
        )
    }

    return ParsedMail(
        from: decodeMIMEHeader(
            headers["from"] ?? ""
        ),

        to: decodeMIMEHeader(
            headers["to"] ?? ""
        ),

        cc: decodeMIMEHeader(
            headers["cc"] ?? ""
        ),

        date:
            headers["date"] ?? "",

        subject: decodeMIMEHeader(
            headers["subject"] ?? ""
        ),

        body: body
    )
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


// MARK: - Multipart MIME

func extractPlainTextFromMultipart(
    body: String,
    contentType: String
) -> String? {

    guard
        let boundary = extractBoundary(
            from: contentType
        )
    else {
        return nil
    }

    let marker = "--\(boundary)"

    let parts = body.components(
        separatedBy: marker
    )

    for part in parts {

        let cleaned = part.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if cleaned.isEmpty ||
           cleaned == "--" {
            continue
        }

        let normalized = cleaned.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )

        guard
            let separator = normalized.range(
                of: "\n\n"
            )
        else {
            continue
        }

        let headerBlock = String(
            normalized[
                ..<separator.lowerBound
            ]
        )

        let partBody = String(
            normalized[
                separator.upperBound...
            ]
        )

        let headers = parseHeaders(
            headerBlock
        )

        let ct =
            headers["content-type"]?
                .lowercased()
            ?? "text/plain"

        if ct.contains("multipart/") {

            if let nested =
                extractPlainTextFromMultipart(
                    body: partBody,
                    contentType: ct
                ) {

                return nested
            }
        }

        if ct.contains("text/plain") {

            let encoding =
                headers[
                    "content-transfer-encoding"
                ]?
                .lowercased()
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                ?? ""

            return decodeBody(
                partBody,
                encoding: encoding
            )
        }
    }

    return nil
}


// MARK: - MIME boundary

func extractBoundary(
    from contentType: String
) -> String? {

    let lower = contentType.lowercased()

    guard
        let range = lower.range(
            of: "boundary="
        )
    else {
        return nil
    }

    var value = String(
        contentType[
            range.upperBound...
        ]
    )

    value = value.trimmingCharacters(
        in: .whitespacesAndNewlines
    )

    if value.hasPrefix("\"") {

        value.removeFirst()

        if let quote = value.firstIndex(
            of: "\""
        ) {
            value = String(
                value[..<quote]
            )
        }

    } else {

        if let semicolon = value.firstIndex(
            of: ";"
        ) {
            value = String(
                value[..<semicolon]
            )
        }
    }

    return value
}


// MARK: - Content Transfer Encoding

func decodeBody(
    _ body: String,
    encoding: String
) -> String {

    switch encoding {

    case "base64":

        let compact = body.components(
            separatedBy: .whitespacesAndNewlines
        ).joined()

        guard
            let data = Data(
                base64Encoded: compact,
                options: [.ignoreUnknownCharacters]
            )
        else {
            return body
        }

        return
            String(
                data: data,
                encoding: .utf8
            )
            ?? body


    case "quoted-printable":

        return decodeQuotedPrintable(
            body
        )


    default:

        return body
    }
}


// MARK: - Quoted Printable

func decodeQuotedPrintable(
    _ input: String
) -> String {

    let bytes = Array(
        input.utf8
    )

    var output: [UInt8] = []

    var i = 0

    while i < bytes.count {

        if bytes[i] == 61 {

            if
                i + 1 < bytes.count,
                bytes[i + 1] == 10 {

                i += 2
                continue
            }

            if
                i + 2 < bytes.count,
                bytes[i + 1] == 13,
                bytes[i + 2] == 10 {

                i += 3
                continue
            }

            if
                i + 2 < bytes.count,
                let high = hexValue(
                    bytes[i + 1]
                ),
                let low = hexValue(
                    bytes[i + 2]
                ) {

                output.append(
                    high * 16 + low
                )

                i += 3
                continue
            }
        }

        output.append(
            bytes[i]
        )

        i += 1
    }

    return
        String(
            data: Data(output),
            encoding: .utf8
        )
        ?? input
}

func hexValue(
    _ byte: UInt8
) -> UInt8? {

    switch byte {

    case 48...57:
        return byte - 48

    case 65...70:
        return byte - 55

    case 97...102:
        return byte - 87

    default:
        return nil
    }
}


// MARK: - MIME encoded headers

func decodeMIMEHeader(
    _ input: String
) -> String {

    var result = input

    let pattern =
        #"=\?([^?]+)\?([bBqQ])\?([^?]+)\?="#

    guard
        let regex = try? NSRegularExpression(
            pattern: pattern
        )
    else {
        return input
    }

    while true {

        let nsRange = NSRange(
            result.startIndex..<result.endIndex,
            in: result
        )

        guard
            let match = regex.firstMatch(
                in: result,
                range: nsRange
            ),

            match.numberOfRanges == 4,

            let wholeRange = Range(
                match.range(at: 0),
                in: result
            ),

            let encodingRange = Range(
                match.range(at: 2),
                in: result
            ),

            let payloadRange = Range(
                match.range(at: 3),
                in: result
            )

        else {
            break
        }

        let encoding = String(
            result[
                encodingRange
            ]
        ).uppercased()

        let payload = String(
            result[
                payloadRange
            ]
        )

        var decoded = payload

        if encoding == "B" {

            if let data = Data(
                base64Encoded: payload
            ) {

                decoded =
                    String(
                        data: data,
                        encoding: .utf8
                    )
                    ?? payload
            }

        } else if encoding == "Q" {

            let qp = payload.replacingOccurrences(
                of: "_",
                with: " "
            )

            decoded = decodeQuotedPrintable(
                qp
            )
        }

        result.replaceSubrange(
            wholeRange,
            with: decoded
        )
    }

    return result
}

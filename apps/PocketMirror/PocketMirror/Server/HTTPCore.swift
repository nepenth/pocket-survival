import Foundation

// Pure HTTP helpers (no networking), shared by the app and the macOS range test.

struct HTTPRequest {
    let method: String
    /// Request target as sent, e.g. "/library/a%20b.zim?x=1".
    let target: String
    /// Header names lowercased.
    let headers: [String: String]

    /// Decoded path without the query string, or nil if it isn't a valid absolute path.
    var path: String? {
        let raw = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard raw.hasPrefix("/"), let decoded = raw.removingPercentEncoding else { return nil }
        return decoded
    }

    var wantsClose: Bool {
        headers["connection"]?.lowercased().contains("close") == true
    }

    /// Parses the request line and headers (everything before the blank line).
    static func parse(_ head: Data) -> HTTPRequest? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers)
    }
}

enum ByteRange: Equatable {
    case full
    /// Inclusive byte offsets.
    case partial(start: Int64, end: Int64)
    case unsatisfiable

    /// Parses a single-range `Range` header (RFC 9110): "bytes=a-b", "bytes=a-" or "bytes=-n".
    /// Multiple ranges are answered with the first one. Malformed headers are ignored (full body).
    static func parse(_ header: String?, size: Int64) -> ByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return .full }
        guard header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let pieces = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 2 else { return .full }

        if pieces[0].isEmpty {
            // Suffix range: the last n bytes.
            guard let n = Int64(pieces[1]) else { return .full }
            guard n > 0, size > 0 else { return .unsatisfiable }
            return .partial(start: max(0, size - n), end: size - 1)
        }
        guard let start = Int64(pieces[0]) else { return .full }
        guard start < size else { return .unsatisfiable }
        if pieces[1].isEmpty { return .partial(start: start, end: size - 1) }
        guard let end = Int64(pieces[1]) else { return .full }
        guard end >= start else { return .full }
        return .partial(start: start, end: min(end, size - 1))
    }
}

enum HTTPStatus: Int {
    case ok = 200, created = 201, partialContent = 206, movedPermanently = 301, notModified = 304, badRequest = 400, forbidden = 403,
         notFound = 404, methodNotAllowed = 405, lengthRequired = 411, rangeNotSatisfiable = 416,
         serverError = 500, insufficientStorage = 507

    var reason: String {
        switch self {
        case .ok: return "OK"
        case .created: return "Created"
        case .partialContent: return "Partial Content"
        case .movedPermanently: return "Moved Permanently"
        case .notModified: return "Not Modified"
        case .badRequest: return "Bad Request"
        case .forbidden: return "Forbidden"
        case .notFound: return "Not Found"
        case .methodNotAllowed: return "Method Not Allowed"
        case .lengthRequired: return "Length Required"
        case .rangeNotSatisfiable: return "Range Not Satisfiable"
        case .serverError: return "Internal Server Error"
        case .insufficientStorage: return "Insufficient Storage"
        }
    }
}

enum HTTPCore {
    static func responseHead(_ status: HTTPStatus, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status.rawValue) \(status.reason)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// Maps a decoded URL path onto a file inside `root`, refusing anything that escapes it.
    static func resolve(path: String, root: URL) -> URL? {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { $0 == ".." || $0 == "." || $0.contains("\0") }) { return nil }
        // With "." and ".." refused, appending components can't leave the root. (No standardizing:
        // `standardizedFileURL` drops "/private" only for paths that exist, which made new files
        // under /private/var or /private/tmp look like they were outside the root.)
        var url = root
        for component in components { url.appendPathComponent(component) }
        return url
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json", "webmanifest": return "application/json"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "xml": return "application/xml"
        case "wasm": return "application/wasm"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "pdf": return "application/pdf"
        case "epub": return "application/epub+zip"
        case "zim": return "application/octet-stream"
        case "sqlite", "db", "mbtiles": return "application/vnd.sqlite3"
        case "pbf", "mvt": return "application/x-protobuf"
        case "pmtiles": return "application/octet-stream"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "mp4", "m4v": return "video/mp4"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    static func httpDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

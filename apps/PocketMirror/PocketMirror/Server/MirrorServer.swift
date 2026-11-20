import Foundation
import Network

/// Small static-file HTTP/1.1 server on Network.framework (no dependencies).
/// GET/HEAD with single byte ranges (206/416), keep-alive, directory index.html or listing, and
/// PUT uploads into a separate upload root, only while uploads are switched on.
/// Serves files from an ordered list of roots (first match wins) and nothing outside them. Compiles on iOS 14+ and macOS (for the CI range test).
final class MirrorServer {
    enum State: Equatable {
        case stopped
        case running(port: UInt16, lan: Bool)
        case failed(String)
    }

    let port: UInt16
    var onStateChange: ((State) -> Void)?
    /// Answers GET /api/<name>?<query> (e.g. directions). Called off the network queue; returns
    /// an HTTP status and a JSON body. Set before start().
    var api: APIHandler?
    typealias APIHandler = (_ name: String, _ query: [String: String]) -> (status: Int, json: Data)

    private let queue = DispatchQueue(label: "mirror.server.listener")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    private var roots: [URL] = []
    private var uploadRoot: URL?
    private let uploads = UploadGate()

    /// While on, PUT /some/path writes a file into the upload root (the content folder).
    var uploadsEnabled: Bool {
        get { uploads.isOn }
        set { uploads.isOn = newValue }
    }

    init(port: UInt16 = 8090) {
        self.port = port
    }

    func start(root: URL, lan: Bool) {
        start(roots: [root], lan: lan)
    }

    /// Starts (or restarts) serving `roots`; a path is looked up in each root in order. With `lan`
    /// false the server only accepts connections from this device (bound to 127.0.0.1).
    /// `uploadRoot` (normally one of `roots`) receives PUT uploads; nil refuses them.
    func start(roots: [URL], uploadRoot: URL? = nil, lan: Bool) {
        queue.async { [self] in
            self.stopLocked()
            self.roots = roots
            self.uploadRoot = uploadRoot
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let nwPort = NWEndpoint.Port(rawValue: self.port)!
                let listener: NWListener
                if lan {
                    listener = try NWListener(using: params, on: nwPort)
                } else {
                    params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
                    listener = try NWListener(using: params)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    // Ignore late updates from a listener replaced by a restart.
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.report(.running(port: self.port, lan: lan))
                    case .failed(let error): self.report(.failed(error.localizedDescription))
                    case .cancelled: self.report(.stopped)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                self.report(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func report(_ state: State) {
        onStateChange?(state)
    }

    private func accept(_ connection: NWConnection) {
        let client = ClientConnection(connection: connection, roots: roots, uploadRoot: uploadRoot, uploads: uploads, api: api)
        let id = ObjectIdentifier(client)
        connections[id] = client
        client.onClose = { [weak self] in
            self?.queue.async { self?.connections[id] = nil }
        }
        client.start()
    }
}

/// Thread-safe on/off switch shared with every connection.
final class UploadGate {
    private let lock = NSLock()
    private var value = false
    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// One TCP connection; handles requests one after another (keep-alive).
private final class ClientConnection {
    private let connection: NWConnection
    private let roots: [URL]
    private let uploadRoot: URL?
    private let uploads: UploadGate
    private let api: MirrorServer.APIHandler?
    private static let apiQueue = DispatchQueue(label: "mirror.server.api")   // one search at a time
    private let queue = DispatchQueue(label: "mirror.server.connection")
    private var buffer = Data()
    private var closed = false
    var onClose: (() -> Void)?

    private static let chunkSize = 256 * 1024
    private static let maxHeadSize = 32 * 1024
    private static let headTerminator = Data("\r\n\r\n".utf8)

    init(connection: NWConnection, roots: [URL], uploadRoot: URL?, uploads: UploadGate, api: MirrorServer.APIHandler?) {
        self.connection = connection
        self.roots = roots
        self.uploadRoot = uploadRoot
        self.uploads = uploads
        self.api = api
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finishClose()
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHead()
    }

    func cancel() {
        connection.cancel()
    }

    private func finishClose() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    // MARK: Reading requests

    private func receiveHead() {
        if let range = buffer.range(of: Self.headTerminator) {
            let head = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            handle(head: head)
            return
        }
        if buffer.count > Self.maxHeadSize {
            sendSimple(.badRequest, keepAlive: false)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if error != nil || (isComplete && (data?.isEmpty ?? true)) {
                self.connection.cancel()
                return
            }
            self.receiveHead()
        }
    }

    private func handle(head: Data) {
        guard let request = HTTPRequest.parse(head) else {
            sendSimple(.badRequest, keepAlive: false)
            return
        }
        let keepAlive = !request.wantsClose
        if request.method == "PUT" {
            handleUpload(request, keepAlive: keepAlive)
            return
        }
        // GET/HEAD requests carry no body; drop any declared body so it isn't parsed as a request.
        if let length = request.headers["content-length"].flatMap(Int.init), length > 0 {
            buffer.removeAll()
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            sendSimple(.methodNotAllowed, keepAlive: false, extra: [("Allow", "GET, HEAD, PUT")])
            return
        }
        let isHead = request.method == "HEAD"
        guard let path = request.path else {
            sendSimple(.badRequest, keepAlive: keepAlive)
            return
        }
        if path.hasPrefix("/api/"), let api {
            let name = String(path.dropFirst(5)), query = request.query
            Self.apiQueue.async { [weak self] in
                let (status, body) = api(name, query)
                self?.queue.async { self?.sendJSON(status, body, keepAlive: keepAlive, head: isHead) }
            }
            return
        }
        let candidates = roots.compactMap { HTTPCore.resolve(path: path, root: $0) }
        guard !candidates.isEmpty else {
            sendSimple(.forbidden, keepAlive: keepAlive)
            return
        }
        let fm = FileManager.default
        func isDir(_ u: URL) -> Bool? {
            var d: ObjCBool = false
            return fm.fileExists(atPath: u.path, isDirectory: &d) ? d.boolValue : nil
        }
        // First root that has the path; for folders, prefer one with an index.html.
        let existing = candidates.filter { isDir($0) != nil }
        guard let first = existing.first else {
            sendSimple(.notFound, keepAlive: keepAlive)
            return
        }
        let url = existing.first { isDir($0) == true && fm.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
            ?? first
        let isDirectory = ObjCBool(isDir(url) == true)
        if isDirectory.boolValue {
            if !path.hasSuffix("/") {
                let location = request.target.contains("?")
                    ? request.target.replacingOccurrences(of: "?", with: "/?", options: [], range: request.target.range(of: "?"))
                    : request.target + "/"
                sendSimple(.movedPermanently, keepAlive: keepAlive, extra: [("Location", location)])
                return
            }
            let index = url.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                serveFile(index, request: request, isHead: isHead, keepAlive: keepAlive)
            } else {
                serveListing(of: url, path: path, isHead: isHead, keepAlive: keepAlive)
            }
            return
        }
        serveFile(url, request: request, isHead: isHead, keepAlive: keepAlive)
    }

    // MARK: Uploads

    /// PUT: streams the body into a hidden temporary file next to the target, then renames it, so a
    /// broken transfer never leaves a truncated file under the real name.
    private func handleUpload(_ request: HTTPRequest, keepAlive: Bool) {
        // Errors close the connection: the unread body would otherwise be parsed as a request.
        guard uploads.isOn, let root = uploadRoot else {
            sendSimple(.forbidden, keepAlive: false, message: "Uploads are off. Turn on Accept Uploads in Pocket Mirror.")
            return
        }
        guard let length = request.headers["content-length"].flatMap(Int64.init), length >= 0 else {
            sendSimple(.lengthRequired, keepAlive: false)
            return
        }
        guard let path = request.path, !path.hasSuffix("/"),
              let target = HTTPCore.resolve(path: path, root: root),
              !target.lastPathComponent.hasPrefix(".") else {
            sendSimple(.forbidden, keepAlive: false)
            return
        }
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            sendSimple(.forbidden, keepAlive: false, message: "Can't create \(folder.lastPathComponent): \(error.localizedDescription)")
            return
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            sendSimple(.forbidden, keepAlive: false, message: "A folder already has that name.")
            return
        }
        if let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, free > 0, length + 50_000_000 > free {
            sendSimple(.insufficientStorage, keepAlive: false,
                       message: "Not enough space on the phone: \(length / 1_000_000) MB needed, \(free / 1_000_000) MB free.")
            return
        }
        let temp = folder.appendingPathComponent(".upload-\(UUID().uuidString)-\(target.lastPathComponent)")
        guard fm.createFile(atPath: temp.path, contents: nil), let handle = try? FileHandle(forWritingTo: temp) else {
            sendSimple(.serverError, keepAlive: false, message: "Can't write the file.")
            return
        }
        let upload = Upload(handle: handle, temp: temp, target: target, remaining: length, total: length, keepAlive: keepAlive)

        // Body bytes that arrived together with the request head.
        let early = Int(min(Int64(buffer.count), length))
        if early > 0 {
            handle.write(buffer.prefix(early))
            buffer.removeFirst(early)
            upload.remaining -= Int64(early)
        }
        let continueBody: () -> Void = { [weak self] in self?.receiveBody(upload) }
        if request.headers["expect"]?.lowercased() == "100-continue", upload.remaining > 0 {
            send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), then: continueBody)
        } else {
            continueBody()
        }
    }

    private final class Upload {
        let handle: FileHandle, temp: URL, target: URL, total: Int64, keepAlive: Bool
        var remaining: Int64
        init(handle: FileHandle, temp: URL, target: URL, remaining: Int64, total: Int64, keepAlive: Bool) {
            (self.handle, self.temp, self.target, self.remaining, self.total, self.keepAlive) =
                (handle, temp, target, remaining, total, keepAlive)
        }
        func abandon() {
            handle.closeFile()
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func receiveBody(_ upload: Upload) {
        if upload.remaining == 0 {
            finishUpload(upload)
            return
        }
        let wanted = Int(min(Int64(1 << 20), upload.remaining))
        connection.receive(minimumIncompleteLength: 1, maximumLength: wanted) { [weak self] data, _, isComplete, error in
            guard let self else { upload.abandon(); return }
            if let data, !data.isEmpty {
                upload.handle.write(data)
                upload.remaining -= Int64(data.count)
            }
            if upload.remaining == 0 {
                self.finishUpload(upload)
            } else if error != nil || isComplete {
                upload.abandon() // connection ended early: keep nothing
                self.connection.cancel()
            } else {
                self.receiveBody(upload)
            }
        }
    }

    private func finishUpload(_ upload: Upload) {
        upload.handle.closeFile()
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: upload.target.path) { try fm.removeItem(at: upload.target) }
            try fm.moveItem(at: upload.temp, to: upload.target)
        } catch {
            try? fm.removeItem(at: upload.temp)
            sendSimple(.serverError, keepAlive: false, message: "Saving failed: \(error.localizedDescription)")
            return
        }
        sendSimple(.created, keepAlive: upload.keepAlive, message: "Saved \(upload.total) bytes")
    }

    // MARK: Responses

    private func baseHeaders(keepAlive: Bool) -> [(String, String)] {
        [
            ("Server", "PocketMirror"),
            ("Connection", keepAlive ? "keep-alive" : "close"),
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges"),
            ("Cache-Control", "no-cache"),
        ]
    }

    private func serveFile(_ url: URL, request: HTTPRequest, isHead: Bool, keepAlive: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url) else {
            sendSimple(.forbidden, keepAlive: keepAlive)
            return
        }
        var headers = baseHeaders(keepAlive: keepAlive)
        headers.append(("Content-Type", HTTPCore.mimeType(for: url)))
        headers.append(("Accept-Ranges", "bytes"))
        if let modified = attributes[.modificationDate] as? Date {
            headers.append(("Last-Modified", HTTPCore.httpDate(modified)))
        }

        let start: Int64, length: Int64, status: HTTPStatus
        switch ByteRange.parse(request.headers["range"], size: size) {
        case .full:
            (start, length, status) = (0, size, .ok)
        case .partial(let s, let e):
            (start, length, status) = (s, e - s + 1, .partialContent)
            headers.append(("Content-Range", "bytes \(s)-\(e)/\(size)"))
        case .unsatisfiable:
            handle.closeFile()
            sendSimple(.rangeNotSatisfiable, keepAlive: keepAlive, extra: [("Content-Range", "bytes */\(size)")])
            return
        }
        headers.append(("Content-Length", String(length)))

        send(HTTPCore.responseHead(status, headers: headers)) { [weak self] in
            guard let self else { handle.closeFile(); return }
            if isHead || length == 0 {
                handle.closeFile()
                self.finishResponse(keepAlive: keepAlive)
            } else {
                handle.seek(toFileOffset: UInt64(start))
                self.stream(handle, remaining: length, keepAlive: keepAlive)
            }
        }
    }

    /// Sends the file in chunks, waiting for each send to complete (no whole-file buffering).
    private func stream(_ handle: FileHandle, remaining: Int64, keepAlive: Bool) {
        let count = Int(min(Int64(Self.chunkSize), remaining))
        let chunk = handle.readData(ofLength: count)
        guard !chunk.isEmpty else {
            // File shrank underneath us; the declared length can't be honoured.
            handle.closeFile()
            connection.cancel()
            return
        }
        send(chunk) { [weak self] in
            guard let self else { handle.closeFile(); return }
            let left = remaining - Int64(chunk.count)
            if left > 0 {
                self.stream(handle, remaining: left, keepAlive: keepAlive)
            } else {
                handle.closeFile()
                self.finishResponse(keepAlive: keepAlive)
            }
        }
    }

    private func serveListing(of directory: URL, path: String, isHead: Bool, keepAlive: Bool) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var html = "<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width\">"
        html += "<title>\(HTTPCore.htmlEscape(path))</title><style>body{font:17px -apple-system,sans-serif;margin:16px}"
        html += "a{display:block;padding:8px 0}</style><h3>\(HTTPCore.htmlEscape(path))</h3>"
        if path != "/" { html += "<a href=\"../\">..</a>" }
        for name in names {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDir)
            let display = name + (isDir.boolValue ? "/" : "")
            let href = (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name) + (isDir.boolValue ? "/" : "")
            html += "<a href=\"\(HTTPCore.htmlEscape(href))\">\(HTTPCore.htmlEscape(display))</a>"
        }
        let body = Data(html.utf8)
        var headers = baseHeaders(keepAlive: keepAlive)
        headers.append(("Content-Type", "text/html; charset=utf-8"))
        headers.append(("Content-Length", String(body.count)))
        var data = HTTPCore.responseHead(.ok, headers: headers)
        if !isHead { data.append(body) }
        send(data) { [weak self] in self?.finishResponse(keepAlive: keepAlive) }
    }

    private func sendSimple(_ status: HTTPStatus, keepAlive: Bool, extra: [(String, String)] = [], message: String? = nil) {
        let body = Data("\(status.rawValue) \(status.reason)\(message.map { ": " + $0 } ?? "")\n".utf8)
        var headers = baseHeaders(keepAlive: keepAlive) + extra
        headers.append(("Content-Type", "text/plain; charset=utf-8"))
        headers.append(("Content-Length", String(body.count)))
        var data = HTTPCore.responseHead(status, headers: headers)
        data.append(body)
        send(data) { [weak self] in self?.finishResponse(keepAlive: keepAlive) }
    }

    private func sendJSON(_ status: Int, _ body: Data, keepAlive: Bool, head: Bool) {
        let code = HTTPStatus(rawValue: status) ?? .serverError
        var headers = baseHeaders(keepAlive: keepAlive)
        headers.append(("Content-Type", "application/json; charset=utf-8"))
        headers.append(("Content-Length", String(body.count)))
        var data = HTTPCore.responseHead(code, headers: headers)
        if !head { data.append(body) }
        send(data) { [weak self] in self?.finishResponse(keepAlive: keepAlive) }
    }

    private func send(_ data: Data, then: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.connection.cancel()
                return
            }
            then()
        })
    }

    private func finishResponse(keepAlive: Bool) {
        if keepAlive {
            receiveHead()
        } else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        }
    }
}

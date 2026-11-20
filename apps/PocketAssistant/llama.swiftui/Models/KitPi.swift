import Foundation
import UIKit

/// The kit's Raspberry Pi, reached over its own Wi-Fi hotspot (or a home network). It runs:
///   :8080  llama.cpp server (OpenAI-style /v1/chat/completions; some models take photos)
///   :80    kit dashboard (/api/models, /api/model, POST /api/swap to change the model)
///   :80    also /api/books/retrieve, /api/books/page/<id>/<n>: the dashboard's read-only pass-through
///          to the Lastbook book library (:8890), which otherwise admits other devices only with
///          its access key. No setup on the phone.
///   :8090  kiwix-serve (/search?format=xml across all the ZIM archives)
/// On the hotspot every name resolves to the Pi, so the default address is just "survivalpi";
/// the Wi-Fi network's .1 address is tried as well.
struct KitPiStatus: Equatable {
    var host: String
    /// IPv4 address the host name resolved to (Lastbook only accepts IP addresses).
    var ip: String
    /// The book library answered (through the dashboard).
    var booksOK: Bool
    var modelFile: String
    var vision: Bool
    var contextTokens: Int
    var models: [String]

    /// "gemma-3-4b-it-Q4_K_M.gguf" -> "Gemma 3 4B"
    var modelName: String { KitPi.displayName(modelFile) }
}

/// A passage the answer can cite. Stored with the reply so the sources stay tappable.
struct SourceRef: Codable, Equatable, Identifiable {
    var id: Int            // [n] in the answer
    var title: String
    var detail: String     // book + page, or archive name
    var url: String        // opened in the in-app browser ("" = show readText in the app)
    var text: String       // what the model was shown (trimmed)
    var readText: String? = nil   // the whole page, for reading in the app
}

enum KitPi {
    static let defaultHost = "survivalpi"

    static func displayName(_ file: String) -> String {
        var s = (file as NSString).lastPathComponent
        s = s.replacingOccurrences(of: ".gguf", with: "")
        s = s.replacingOccurrences(of: #"[-_.](Q\d.*|IQ\d.*|F16|BF16)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"[-_.]it$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let words = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { w -> String in
            let lw = w.lowercased()
            if lw == "gemma" { return "Gemma" }
            if lw == "medgemma" { return "MedGemma" }
            if lw.hasSuffix("b"), Double(lw.dropLast()) != nil { return lw.uppercased() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }
        return words.joined(separator: " ")
    }

    /// Addresses to try: the one in Settings first, then the current Wi-Fi network's .1 address
    /// (the hotspot's own address, whatever subnet it uses).
    static func candidates(_ configured: String) -> [String] {
        var out: [String] = []
        let c = configured.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { out.append(c) }
        if let gw = wifiGatewayGuess(), !out.contains(gw) { out.append(gw) }
        return out
    }

    private static func wifiGatewayGuess() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(cString: ifa.ifa_name) == "en0", let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let parts = String(cString: host).split(separator: ".")
            guard parts.count == 4 else { continue }
            return parts[0...2].joined(separator: ".") + ".1"
        }
        return nil
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private static func get(_ url: URL, timeout: TimeInterval) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        return await withCheckedContinuation { cont in
            session.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                cont.resume(returning: ok ? data : nil)
            }.resume()
        }
    }

    // MARK: Finding the Pi

    static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func booksRequest(_ host: String, _ pathAndQuery: String) -> URLRequest? {
        URL(string: "http://\(host)/api/books\(pathAndQuery)").map { URLRequest(url: $0) }
    }

    private static func getJSON(_ req: URLRequest?, timeout: TimeInterval) async -> [String: Any]? {
        guard var req else { return nil }
        req.timeoutInterval = timeout
        let data: Data? = await withCheckedContinuation { cont in
            session.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                cont.resume(returning: ok ? data : nil)
            }.resume()
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func probe(_ configured: String) async -> KitPiStatus? {
        for host in candidates(configured) {
            guard let url = URL(string: "http://\(host):8080/props"),
                  let data = await get(url, timeout: 2.5),
                  let props = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let modalities = props["modalities"] as? [String: Any]
            let settings = props["default_generation_settings"] as? [String: Any]
            var models: [String] = []
            if let url = URL(string: "http://\(host)/api/models"), let data = await get(url, timeout: 2.5),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["models"] as? [[String: Any]] {
                models = list.compactMap { $0["name"] as? String }
            }
            let ip = await Task.detached { resolveIPv4(host) }.value ?? host
            let booksOK = await getJSON(booksRequest(ip, "/retrieve?q=water&k=1"), timeout: 3) != nil
            return KitPiStatus(host: host, ip: ip, booksOK: booksOK, modelFile: props["model_path"] as? String ?? "model",
                               vision: modalities?["vision"] as? Bool ?? false,
                               contextTokens: settings?["n_ctx"] as? Int ?? 4096, models: models)
        }
        return nil
    }

    /// Asks the dashboard to switch the Pi's model (the server restarts; takes a minute).
    static func swapModel(host: String, to file: String) async -> String? {
        guard let url = URL(string: "http://\(host)/api/swap") else { return "Bad address." }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": file])
        req.timeoutInterval = 130
        return await withCheckedContinuation { cont in
            session.dataTask(with: req) { data, resp, error in
                if let error { cont.resume(returning: error.localizedDescription); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) { cont.resume(returning: nil); return }
                let msg = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
                cont.resume(returning: msg ?? "The Pi refused (HTTP \(code)).")
            }.resume()
        }
    }

    static func ready(host: String) async -> Bool {
        guard let url = URL(string: "http://\(host):8080/health") else { return false }
        return await get(url, timeout: 3) != nil
    }

    // MARK: Library lookup

    private static let stopWords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are",
        "was", "be", "do", "does", "did", "how", "what", "why", "when", "where", "which", "who", "can", "could", "should",
        "would", "i", "me", "my", "we", "you", "it", "this", "that", "if", "there", "about", "best", "way", "need", "get",
        "much", "many", "some", "any", "tell", "please", "know", "make", "use", "using", "from", "at", "by", "as", "so",
        "bad", "good", "someone", "somebody", "something", "thing", "things", "really", "very", "just", "like", "long",
        "his", "her", "their", "our", "your", "him", "them", "they", "he", "she", "will", "has", "have", "had", "not"]

    static func keywords(_ question: String) -> String {
        let words = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
        return words.prefix(8).joined(separator: " ")
    }

    /// Book passages (Lastbook, with page text) and encyclopedia snippets (Kiwix), trimmed so the
    /// whole set stays near `maxChars`. Empty if the Pi's library can't be reached.
    static func lookUp(_ question: String, pi: KitPiStatus, maxChars: Int) async -> [SourceRef] {
        let q = keywords(question)
        guard !q.isEmpty else { return [] }
        // Books get most of the room: their passages are the most reliable.
        let window = max(500, maxChars * 2 / 9)
        async let books = pi.booksOK ? lastbook(question, host: pi.ip, window: window) : []
        async let wiki = kiwix(q, host: pi.ip)
        let wikiHits = await wiki.filter { titleMatches($0.title, keywords: q) }
        var all = Array(await books.prefix(3)) + Array(wikiHits.prefix(2))
        let per = max(300, maxChars / max(all.count, 1))
        for i in all.indices where all[i].text.count > per {
            all[i].text = String(all[i].text.prefix(per)) + "…"
        }
        for i in all.indices { all[i].id = i + 1 }
        return Array(all)
    }

    /// An encyclopedia hit is kept only if its title shares a word stem with the question
    /// ("Water purification" for "boil water"; not "Disfigurement" for "burn").
    private static func titleMatches(_ title: String, keywords: String) -> Bool {
        if title.contains("questions/tagged/") { return false }
        let t = title.lowercased()
        return keywords.split(separator: " ").contains { w in w.count >= 4 && t.contains(w.prefix(min(5, w.count - 1))) }
    }

    /// `window` characters of `text` centred on where `excerpt` (the search hit) appears.
    private static func centred(_ text: String, on excerpt: String, window: Int) -> String {
        guard text.count > window else { return text }
        let core = excerpt.replacingOccurrences(of: "…", with: " ").components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.prefix(8).joined(separator: " ")
        var center = window / 2
        if core.count >= 12 {
            var probe = String(core.prefix(40))
            while probe.count >= 12 {
                if let r = text.range(of: probe, options: [.caseInsensitive]) {
                    center = text.distance(from: text.startIndex, to: r.lowerBound) + window / 4
                    break
                }
                probe = String(probe.dropLast(8))
            }
        }
        let start = max(0, min(text.count - window, center - window / 2))
        let a = text.index(text.startIndex, offsetBy: start), b = text.index(a, offsetBy: window)
        return (start > 0 ? "…" : "") + text[a..<b] + (start + window < text.count ? "…" : "")
    }

    private static func lastbook(_ question: String, host: String, window: Int) async -> [SourceRef] {
        let q = question.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let obj = await getJSON(booksRequest(host, "/retrieve?q=\(q.prefix(400))&k=6"), timeout: 6),
              let results = obj["results"] as? [[String: Any]] else { return [] }
        var out: [SourceRef] = []
        for r in results where (r["kind"] as? String) == "pdf" {
            guard let id = r["doc_id"] as? String, let page = r["page"] as? Int else { continue }
            let title = r["title"] as? String ?? "Book"
            let publisher = r["publisher"] as? String ?? ""
            let excerpt = (r["excerpt"] as? String ?? "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            var text = excerpt
            // The whole page reads better than the match snippet.
            if let po = await getJSON(booksRequest(host, "/page/\(id)/\(page)"), timeout: 5),
               let pageText = po["text"] as? String, !pageText.isEmpty {
                text = pageText
            }
            let flat = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            let flatExcerpt = excerpt.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            out.append(SourceRef(id: 0, title: title, detail: [publisher, "page \(page)"].filter { !$0.isEmpty }.joined(separator: ", "),
                                 url: "", text: centred(flat, on: flatExcerpt, window: window), readText: String(text.prefix(6000))))
            if out.count == 3 { break }
        }
        return out
    }

    private static func kiwix(_ q: String, host: String) async -> [SourceRef] {
        var comps = URLComponents(string: "http://\(host):8090/search")!
        comps.queryItems = [URLQueryItem(name: "pattern", value: q), URLQueryItem(name: "format", value: "xml"),
                            URLQueryItem(name: "pageLength", value: "4")]
        guard let url = comps.url, let data = await get(url, timeout: 8) else { return [] }
        var out: [SourceRef] = []
        for item in KiwixResults(data: data).items.prefix(4) {
            var source = SourceRef(id: 0, title: item.title, detail: item.book, url: "http://\(host):8090\(item.link)", text: item.snippet)
            // Some archives (LibreTexts) are web apps that iOS 14's browser can't run: their article
            // links are stubs that redirect into the app. Show those passages in the app instead.
            if let page = URL(string: source.url), let body = await get(page, timeout: 4), body.count < 4000,
               let html = String(data: body, encoding: .utf8), html.contains("http-equiv=\"refresh\""), html.contains("index.html#") {
                source.url = ""
                source.readText = item.snippet + "\n\n(This archive can't be opened on this phone; the passage above is what the assistant read.)"
            }
            out.append(source)
        }
        return out
    }

    // MARK: Chat

    /// Streams a chat completion. `onText` gets each piece of the answer on the main actor.
    /// Cancel the returned handle to stop.
    static func chat(host: String, messages: [[String: Any]], maxTokens: Int?,
                     onText: @escaping @MainActor (String) -> Void,
                     onDone: @escaping @MainActor (Error?, [String: Any]?) -> Void) -> ChatStream? {
        guard let url = URL(string: "http://\(host):8080/v1/chat/completions") else { return nil }
        var body: [String: Any] = ["messages": messages, "stream": true, "cache_prompt": true,
                                   "timings_per_token": false]
        if let maxTokens { body["max_tokens"] = maxTokens }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600   // reading a long prompt on the Pi takes a while before the first word
        let stream = ChatStream(onText: onText, onDone: onDone)
        stream.start(req)
        return stream
    }

    /// JPEG data URL for the Pi's vision models (longest side 1024 px).
    static func imageDataURL(_ image: UIImage) -> String? {
        let maxSide: CGFloat = 1024
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}

/// Server-sent events from /v1/chat/completions (iOS 14 has no URLSession.bytes, so a delegate).
final class ChatStream: NSObject, URLSessionDataDelegate {
    private let onText: @MainActor (String) -> Void
    private let onDone: @MainActor (Error?, [String: Any]?) -> Void
    private var buffer = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timings: [String: Any]?
    private var finished = false
    private var httpError: String?

    init(onText: @escaping @MainActor (String) -> Void, onDone: @escaping @MainActor (Error?, [String: Any]?) -> Void) {
        self.onText = onText
        self.onDone = onDone
    }

    func start(_ req: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session?.dataTask(with: req)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            httpError = "The Pi answered HTTP \(http.statusCode)."
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if httpError != nil {
            if let obj = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
               let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                httpError = "The Pi: \(msg)"
            }
            return
        }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let t = obj["timings"] as? [String: Any] { timings = t }
            if let choices = obj["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any],
               let text = delta["content"] as? String, !text.isEmpty {
                let cb = onText
                Task { @MainActor in cb(text) }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        let cb = onDone, t = timings
        var err = error
        if err == nil, let httpError { err = NSError(domain: "KitPi", code: 1, userInfo: [NSLocalizedDescriptionKey: httpError]) }
        Task { @MainActor in cb(err, t) }
        session.finishTasksAndInvalidate()
    }
}

/// Parses kiwix-serve's /search?format=xml (RSS with <item><title><link><description><book><title>).
private final class KiwixResults: NSObject, XMLParserDelegate {
    struct Item { var title = "", link = "", snippet = "", book = "" }
    private(set) var items: [Item] = []
    private var current: Item?
    private var text = ""
    private var inBook = false

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "item" { current = Item() }
        if name == "book" { inBook = true }
        if name != "b" { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard current != nil else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": if inBook { current!.book = t } else { current!.title = t }
        case "link": current!.link = t
        case "description": current!.snippet = t
        case "book": inBook = false
        case "item": items.append(current!); current = nil
        default: break
        }
    }
}

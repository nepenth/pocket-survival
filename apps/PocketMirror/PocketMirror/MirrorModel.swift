import Foundation
import UIKit

/// App state: which content folder is served (alongside the built-in pages), the server's status
/// and the LAN toggle.
@MainActor
final class MirrorModel: ObservableObject {
    enum Source: String {
        /// The app's own Documents folder; fill it from a Mac with Finder (File Sharing).
        case documents
        /// A folder picked in the Files app, remembered with a security-scoped bookmark.
        case picked
    }

    static let port: UInt16 = 8090
    /// libkiwix's own server for the ZIM library (browse + full-text search).
    static let libraryPort: Int32 = 8091
    let localURL = URL(string: "http://127.0.0.1:\(MirrorModel.port)/")!

    @Published private(set) var source: Source
    @Published private(set) var pickedFolderName: String?
    @Published private(set) var serverState: MirrorServer.State = .stopped
    @Published private(set) var lanAddress: String?
    @Published var lanEnabled: Bool = false {
        didSet { if lanEnabled != oldValue { restartServer() } }
    }
    @Published var problem: String?
    /// e.g. "19 archives" or why the library isn't available.
    @Published private(set) var libraryStatus = "Not loaded"
    /// Bumped when the served folder changes, so the browser reloads.
    @Published private(set) var contentVersion = 0
    /// Lets a computer send files into the content folder (see tools/push-content.sh). Off at every
    /// launch; while on, the screen stays awake so iOS doesn't suspend the app mid-transfer.
    @Published var uploadsEnabled = false {
        didSet {
            server.uploadsEnabled = uploadsEnabled
            UIApplication.shared.isIdleTimerDisabled = uploadsEnabled
        }
    }

    private let server = MirrorServer(port: MirrorModel.port)
    /// Offline directions for the map (maps/routing.bin in the content folder).
    private let routes = RouteService()
    private let kiwix = KiwixServer()
    /// KiwixServer isn't thread-safe; opening archives can take a moment, so keep it off the main thread.
    private let kiwixQueue = DispatchQueue(label: "mirror.kiwix")
    private var accessedFolder: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let sourceKey = "contentSource"
    private static let bookmarkKey = "pickedFolderBookmark"

    init() {
        // Older builds also had a "demo" source; anything unknown falls back to Documents.
        source = Source(rawValue: UserDefaults.standard.string(forKey: Self.sourceKey) ?? "") ?? .documents
        server.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.serverState = state }
        }
        let routes = self.routes
        server.api = { name, query in routes.handle(name, query) }
    }

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Built-in pages (launcher, map viewer, phone checks), looked up before the content folder.
    static var webURL: URL {
        Bundle.main.url(forResource: "Web", withExtension: nil)!
    }

    static var documentsHasContent: Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        return items.contains { !$0.hasPrefix(".") }
    }

    var sourceDescription: String {
        switch source {
        case .documents: return "On My iPhone › Pocket Mirror"
        case .picked: return pickedFolderName ?? "Chosen folder"
        }
    }

    var isRunning: Bool {
        if case .running = serverState { return true }
        return false
    }

    // MARK: Content source

    func use(_ newSource: Source) {
        source = newSource
        UserDefaults.standard.set(newSource.rawValue, forKey: Self.sourceKey)
        restartServer()
        contentVersion += 1
    }

    /// Saves a folder chosen in the document picker so it can be reopened on later launches.
    func usePickedFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            problem = nil
            use(.picked)
        } catch {
            problem = "Couldn't remember that folder: \(error.localizedDescription)"
        }
    }

    /// Resolves the folder to serve, starting security-scoped access for a picked folder.
    private func resolveRoot() -> URL? {
        releaseFolderAccess()
        switch source {
        case .documents:
            return Self.documentsURL
        case .picked:
            guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
                problem = "No folder chosen yet."
                return nil
            }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                problem = "The chosen folder can't be found. Choose it again."
                return nil
            }
            guard url.startAccessingSecurityScopedResource() else {
                problem = "No permission to read the chosen folder. Choose it again."
                return nil
            }
            accessedFolder = url
            pickedFolderName = url.lastPathComponent
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
            }
            return url
        }
    }

    private func releaseFolderAccess() {
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
    }

    // MARK: Server

    func startServer() {
        guard let root = resolveRoot() else {
            server.stop()
            return
        }
        if source != .picked { problem = nil }
        lanAddress = lanEnabled ? Self.wifiAddress().map { "http://\($0):\(Self.port)/" } : nil
        // Built-in pages first, so content (or an upload) can never replace them; uploads land
        // only in the content folder.
        routes.setContentRoot(root)
        server.start(roots: [Self.webURL, root], uploadRoot: root, lan: lanEnabled)
        startLibrary(contentRoot: root)
    }

    func restartServer() {
        startServer()
    }

    /// Serves every .zim in <content>/library with libkiwix on port 8091.
    private func startLibrary(contentRoot: URL) {
        let folder = contentRoot.appendingPathComponent("library")
        let zims = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".zim") }
            .sorted()
            .map { folder.appendingPathComponent($0).path }
        let lan = lanEnabled
        let port = Self.libraryPort
        libraryStatus = zims.isEmpty ? "No archives in the library folder" : "Opening \(zims.count) archives…"
        kiwixQueue.async { [kiwix] in
            let opened = zims.isEmpty ? 0 : kiwix.start(withZimPaths: zims, port: port, lan: lan)
            if zims.isEmpty { kiwix.stop() }
            let status = zims.isEmpty ? "No archives in the library folder"
                : opened > 0 ? "\(opened) archive\(opened == 1 ? "" : "s") ready" + (opened < zims.count ? " (\(zims.count - opened) unreadable)" : "")
                : (kiwix.lastError ?? "The library couldn't start")
            DispatchQueue.main.async { self.libraryStatus = status }
        }
    }

    func stopServer() {
        server.stop()
        kiwixQueue.async { [kiwix] in kiwix.stop() }
        releaseFolderAccess()
    }

    /// iOS suspends the app (and its server) shortly after it leaves the screen. Ask for the
    /// usual ~30 s grace period so switching to Safari or another app briefly still works.
    func didEnterBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PocketMirrorServer") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func didBecomeActive() {
        endBackgroundTask()
        // The listener may have been torn down while suspended; restarting is cheap.
        startServer()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// IPv4 address of the Wi-Fi interface (en0), for the LAN URL.
    static func wifiAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

/// All calls go through `MirrorModel.kiwixQueue`, one at a time.
extension KiwixServer: @unchecked Sendable {}

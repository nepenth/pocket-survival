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
    let localURL = URL(string: "http://127.0.0.1:\(MirrorModel.port)/")!

    @Published private(set) var source: Source
    @Published private(set) var pickedFolderName: String?
    @Published private(set) var serverState: MirrorServer.State = .stopped
    @Published private(set) var lanAddress: String?
    @Published var lanEnabled: Bool = false {
        didSet { if lanEnabled != oldValue { restartServer() } }
    }
    @Published var problem: String?

    private let server = MirrorServer(port: MirrorModel.port)
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
    }

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Built-in pages (launcher, map viewer, phone checks), served after the content folder.
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
        server.start(roots: [root, Self.webURL], lan: lanEnabled)
    }

    func restartServer() {
        startServer()
    }

    func stopServer() {
        server.stop()
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

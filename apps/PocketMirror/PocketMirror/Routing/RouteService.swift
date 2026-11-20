import Foundation

/// Answers the map page's /api/route requests from <content>/maps/routing.bin.
/// GET /api/route?check=1                                  -> {"ready": true|false}
/// GET /api/route?mode=foot|car&from=lat,lon&to=lat,lon    -> route JSON (see RouteGraph.Route.json)
/// Errors come back as {"error": "..."} with a 4xx/5xx status. The server runs one request at a
/// time on its API queue; the content folder can change from the main thread, hence the lock.
final class RouteService {
    private let lock = NSLock()
    private var contentRoot: URL?
    private var graph: RouteGraph?
    private var graphStamp: String?

    func setContentRoot(_ url: URL?) {
        lock.lock(); contentRoot = url; lock.unlock()
    }

    func handle(_ name: String, _ query: [String: String]) -> (status: Int, json: Data) {
        guard name == "route" else { return failure(404, "Unknown API.") }
        lock.lock()
        let root = contentRoot
        lock.unlock()
        guard let file = root?.appendingPathComponent("maps/routing.bin"),
              FileManager.default.fileExists(atPath: file.path) else {
            return query["check"] != nil ? (200, Data(#"{"ready":false}"#.utf8))
                : failure(404, "No routing data on this phone yet (maps/routing.bin).")
        }
        if query["check"] != nil { return (200, Data(#"{"ready":true}"#.utf8)) }
        guard let mode = RouteGraph.Mode(rawValue: query["mode"] ?? "foot"),
              let from = point(query["from"]), let to = point(query["to"]) else {
            return failure(400, "Need mode, from and to.")
        }
        do {
            let g = try loadGraph(file)
            let route = try g.route(from: from, to: to, mode: mode)
            return (200, route.json(mode: mode))
        } catch let problem as RouteGraph.Failure {
            return failure(422, problem.description)
        } catch {
            return failure(500, "Routing failed: \(error.localizedDescription)")
        }
    }

    /// Reuses the mapped graph until the file is replaced (e.g. by a new upload).
    private func loadGraph(_ file: URL) throws -> RouteGraph {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = "\(attrs?[.size] ?? 0)-\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let graph, stamp == graphStamp { return graph }
        graph = nil
        let g = try RouteGraph(url: file)
        graph = g
        graphStamp = stamp
        return g
    }

    private func point(_ s: String?) -> RouteGraph.Point? {
        guard let parts = s?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2,
              abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { return nil }
        return RouteGraph.Point(lat: parts[0], lon: parts[1])
    }

    private func failure(_ status: Int, _ message: String) -> (status: Int, json: Data) {
        (status, (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data())
    }
}

import Foundation

/// Offline routing over content/maps/routing.bin (built by tools/build-routing.sh): walking and
/// driving directions on the OpenStreetMap road and trail network. The file is memory-mapped, so
/// only the parts a search touches are read from flash. Foundation only (also builds on macOS for
/// the route test). Not thread-safe: callers run one search at a time.
final class RouteGraph {
    enum Mode: String { case foot, car }

    struct Point { var lat: Double; var lon: Double }

    struct Step {
        var text: String
        var meters: Double
        var at: Point
    }

    struct Route {
        var meters: Double
        var seconds: Double
        var coords: [Point]
        var steps: [Step]
        /// Straight-line distance from the requested points to the network.
        var startGap: Double
        var endGap: Double
    }

    enum Failure: Error, CustomStringConvertible {
        case badFile(String), noRoadNear(String), noRoute
        var description: String {
            switch self {
            case .badFile(let s): return "The routing file is damaged (\(s)). Copy maps/routing.bin again."
            case .noRoadNear(let s): return "No road or trail within 5 km of the \(s)."
            case .noRoute: return "No connected route between these points."
            }
        }
    }

    // MARK: File

    private let base: UnsafeRawPointer
    private let size: Int
    let nodeCount: Int, edgeCount: Int
    private let rows: Int, cols: Int
    private let minLat: Double, minLon: Double, cellDeg: Double
    private let nodeLat, nodeLon: UnsafePointer<Int32>
    private let first, adj: UnsafePointer<UInt32>
    private let edgeU, edgeV: UnsafePointer<UInt32>
    private let edgeLen: UnsafePointer<Float>
    private let edgeName: UnsafePointer<UInt32>
    private let geomStart: UnsafePointer<UInt32>
    private let geomCount: UnsafePointer<UInt16>
    private let edgeClass, edgeFlags, edgeKmh: UnsafePointer<UInt8>
    private let geomLat, geomLon: UnsafePointer<Int32>
    private let nameOffset: UnsafePointer<UInt32>
    private let nameBytes: UnsafePointer<UInt8>
    private let cellStart: UnsafePointer<UInt32>

    private static let carForward: UInt8 = 1, carBackward: UInt8 = 2, foot: UInt8 = 4, major: UInt8 = 8

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Failure.badFile("can't open") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 60 else { throw Failure.badFile("too small") }
        size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            throw Failure.badFile("can't map")
        }
        let start = UnsafeRawPointer(p)
        base = start
        guard String(bytes: UnsafeRawBufferPointer(start: start, count: 4), encoding: .ascii) == "PMRT",
              start.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == 1 else {
            munmap(p, size); throw Failure.badFile("not a routing file")
        }
        func u32(_ i: Int) -> Int { Int(start.loadUnaligned(fromByteOffset: 4 + 4 * i, as: UInt32.self)) }
        nodeCount = u32(1); edgeCount = u32(2)
        let geomPoints = u32(3), names = u32(4), nameByteCount = u32(5)
        rows = u32(6); cols = u32(7)
        minLat = start.loadUnaligned(fromByteOffset: 36, as: Double.self)
        minLon = start.loadUnaligned(fromByteOffset: 44, as: Double.self)
        cellDeg = start.loadUnaligned(fromByteOffset: 52, as: Double.self)

        var offset = 60
        func take<T>(_ count: Int, _ type: T.Type) -> UnsafePointer<T> {
            let p = (start + offset).assumingMemoryBound(to: T.self)
            let bytes = count * MemoryLayout<T>.stride
            offset += bytes + (4 - bytes % 4) % 4
            return p
        }
        let N = u32(1), E = u32(2)
        nodeLat = take(N, Int32.self); nodeLon = take(N, Int32.self)
        first = take(N + 1, UInt32.self); adj = take(2 * E, UInt32.self)
        edgeU = take(E, UInt32.self); edgeV = take(E, UInt32.self)
        edgeLen = take(E, Float.self); edgeName = take(E, UInt32.self)
        geomStart = take(E, UInt32.self); geomCount = take(E, UInt16.self)
        edgeClass = take(E, UInt8.self); edgeFlags = take(E, UInt8.self); edgeKmh = take(E, UInt8.self)
        geomLat = take(geomPoints, Int32.self); geomLon = take(geomPoints, Int32.self)
        nameOffset = take(names + 1, UInt32.self)
        nameBytes = take(nameByteCount, UInt8.self)
        cellStart = take(rows * cols + 1, UInt32.self)
        guard offset <= size else { munmap(p, size); throw Failure.badFile("truncated") }
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    // MARK: Geometry helpers

    private func point(_ node: Int) -> Point {
        Point(lat: Double(nodeLat[node]) / 1e7, lon: Double(nodeLon[node]) / 1e7)
    }

    /// Edge shape from u to v (both ends included).
    private func shape(_ e: Int) -> [Point] {
        var pts = [point(Int(edgeU[e]))]
        let s = Int(geomStart[e])
        for i in 0..<Int(geomCount[e]) {
            pts.append(Point(lat: Double(geomLat[s + i]) / 1e7, lon: Double(geomLon[s + i]) / 1e7))
        }
        pts.append(point(Int(edgeV[e])))
        return pts
    }

    static func distance(_ a: Point, _ b: Point) -> Double {
        let r = 6_371_008.8, toRad = Double.pi / 180
        let dLat = (b.lat - a.lat) * toRad, dLon = (b.lon - a.lon) * toRad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * toRad) * cos(b.lat * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func bearing(_ a: Point, _ b: Point) -> Double {
        let toRad = Double.pi / 180
        let y = sin((b.lon - a.lon) * toRad) * cos(b.lat * toRad)
        let x = cos(a.lat * toRad) * sin(b.lat * toRad) - sin(a.lat * toRad) * cos(b.lat * toRad) * cos((b.lon - a.lon) * toRad)
        return (atan2(y, x) / toRad + 360).truncatingRemainder(dividingBy: 360)
    }

    private func name(_ e: Int) -> String? {
        let id = edgeName[e]
        guard id != 0xFFFF_FFFF else { return nil }
        let a = Int(nameOffset[Int(id)]), b = Int(nameOffset[Int(id) + 1])
        return String(decoding: UnsafeBufferPointer(start: nameBytes + a, count: b - a), as: UTF8.self)
    }

    // MARK: Costs

    /// Seconds to travel the edge, or nil if the mode can't use it in that direction.
    private func cost(_ e: Int, reverse: Bool, _ mode: Mode) -> Double? {
        let f = edgeFlags[e], len = Double(edgeLen[e])
        switch mode {
        case .car:
            guard f & (reverse ? Self.carBackward : Self.carForward) != 0 else { return nil }
            return len / (Double(max(edgeKmh[e], 10)) / 3.6)
        case .foot:
            guard f & Self.foot != 0 else { return nil }
            return len / 1.34 * Self.footFactor[Int(edgeClass[e])]
        }
    }
    /// Walking: busy roads count as longer so quieter streets and trails win when close.
    private static let footFactor: [Double] = [9, 2.0, 1.4, 1.2, 1.1, 1.0, 1.0, 1.0, 1.05, 1.1, 1.0, 1.6, 2.0, 1, 1, 1]
    /// Fastest possible speed (m/s) for the A* estimate: it must never overestimate.
    private static func maxSpeed(_ mode: Mode) -> Double { mode == .car ? 120 / 3.6 : 1.34 }

    // MARK: Snapping

    private struct Snap {
        var edge: Int
        var along: Double      // metres from u
        var point: Point
        var gap: Double        // metres from the requested point
    }

    /// Nearest usable edge within about 5 km.
    private func snap(_ p: Point, _ mode: Mode, label: String, majorOnly: Bool = false) throws -> Snap {
        let row = min(max(Int((p.lat - minLat) / cellDeg), 0), rows - 1)
        let col = min(max(Int((p.lon - minLon) / cellDeg), 0), cols - 1)
        var best: Snap? = nil
        var seen = Set<Int>()
        for radius in [2, 5, 12, 40] {   // cells; long rural edges have junctions far apart
            for r in max(0, row - radius)...min(rows - 1, row + radius) {
                for c in max(0, col - radius)...min(cols - 1, col + radius) {
                    let cell = r * cols + c
                    for n in Int(cellStart[cell])..<Int(cellStart[cell + 1]) {
                        for k in Int(first[n])..<Int(first[n + 1]) {
                            let e = Int(adj[k] & 0x7FFF_FFFF)
                            guard seen.insert(e).inserted, usable(e, mode), !majorOnly || edgeFlags[e] & Self.major != 0 else { continue }
                            if let s = project(p, onto: e), s.gap < (best?.gap ?? .infinity) { best = s }
                        }
                    }
                }
            }
            if let best, best.gap < Double(radius) * cellDeg * 111_000 * 0.7 { return best }
        }
        if let best, best.gap < 5000 { return best }
        throw Failure.noRoadNear(label)
    }

    private func usable(_ e: Int, _ mode: Mode) -> Bool {
        let f = edgeFlags[e]
        return mode == .foot ? f & Self.foot != 0 : f & (Self.carForward | Self.carBackward) != 0
    }

    private func project(_ p: Point, onto e: Int) -> Snap? {
        let pts = shape(e)
        let kx = cos(p.lat * .pi / 180) * 111_320.0, ky = 110_574.0
        var best: Snap? = nil
        var along = 0.0
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let ax = (a.lon - p.lon) * kx, ay = (a.lat - p.lat) * ky
            let bx = (b.lon - p.lon) * kx, by = (b.lat - p.lat) * ky
            let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
            let qx = ax + t * dx, qy = ay + t * dy
            let gap = (qx * qx + qy * qy).squareRoot()
            let segLen = len2.squareRoot()
            if gap < (best?.gap ?? .infinity) {
                best = Snap(edge: e, along: along + t * segLen,
                            point: Point(lat: a.lat + t * (b.lat - a.lat), lon: a.lon + t * (b.lon - a.lon)), gap: gap)
            }
            along += segLen
        }
        // Planar lengths differ slightly from the stored length; scale to it.
        if var s = best, along > 0 { s.along *= Double(edgeLen[e]) / along; best = s }
        return best
    }

    // MARK: Search

    /// Shortest route by time. If the nearest road at either end is cut off from the rest (a
    /// park's paths, a parking lot), tries again from the nearest road on the main network.
    func route(from: Point, to: Point, mode: Mode) throws -> Route {
        do {
            return try search(from: from, to: to, mode: mode,
                              a: try snap(from, mode, label: "start"), b: try snap(to, mode, label: "destination"))
        } catch Failure.noRoute {
            return try search(from: from, to: to, mode: mode,
                              a: try snap(from, mode, label: "start", majorOnly: true),
                              b: try snap(to, mode, label: "destination", majorOnly: true))
        }
    }

    private func search(from: Point, to: Point, mode: Mode, a: Snap, b: Snap) throws -> Route {
        let lenA = Double(edgeLen[a.edge]), lenB = Double(edgeLen[b.edge])
        let speed = Self.maxSpeed(mode)

        // Same edge, and allowed to go straight along it.
        var direct: Double? = nil
        if a.edge == b.edge {
            let forward = b.along >= a.along
            if let c = cost(a.edge, reverse: !forward, mode) {
                direct = c * abs(b.along - a.along) / max(lenA, 0.01)
            }
        }

        let N = nodeCount
        var g = [Float](repeating: .infinity, count: N)
        var prev = [UInt32](repeating: .max, count: N)     // adj value used to arrive (edge | reverse bit)
        var heap = MinHeap()
        let goal = b.point
        func h(_ n: Int) -> Float { Float(Self.distance(point(n), goal) / speed * 0.98) }

        // Seeds: from the start point to either end of its edge.
        if let c = cost(a.edge, reverse: true, mode) {   // towards u
            let n = Int(edgeU[a.edge]), v = Float(c * a.along / max(lenA, 0.01))
            if v < g[n] { g[n] = v; heap.push(v + h(n), n) }
        }
        if let c = cost(a.edge, reverse: false, mode) {  // towards v
            let n = Int(edgeV[a.edge]), v = Float(c * (lenA - a.along) / max(lenA, 0.01))
            if v < g[n] { g[n] = v; heap.push(v + h(n), n) }
        }
        // Finishing costs: from either end of the destination edge to the destination point.
        let bu = Int(edgeU[b.edge]), bv = Int(edgeV[b.edge])
        let finishFromU = cost(b.edge, reverse: false, mode).map { $0 * b.along / max(lenB, 0.01) }
        let finishFromV = cost(b.edge, reverse: true, mode).map { $0 * (lenB - b.along) / max(lenB, 0.01) }

        var bestTotal = direct ?? .infinity
        var bestEnd = -1
        var closed = [Bool](repeating: false, count: N)
        while let (f, n) = heap.pop() {
            if Double(f) >= bestTotal { break }
            if closed[n] { continue }
            closed[n] = true
            let gn = Double(g[n])
            if n == bu, let fin = finishFromU, gn + fin < bestTotal { bestTotal = gn + fin; bestEnd = n }
            if n == bv, let fin = finishFromV, gn + fin < bestTotal { bestTotal = gn + fin; bestEnd = n }
            for k in Int(first[n])..<Int(first[n + 1]) {
                let entry = adj[k]
                let e = Int(entry & 0x7FFF_FFFF), reverse = entry & 0x8000_0000 != 0
                guard let c = cost(e, reverse: reverse, mode) else { continue }
                let m = Int(reverse ? edgeU[e] : edgeV[e])
                let v = Float(gn + c)
                if v < g[m] { g[m] = v; prev[m] = entry; heap.push(v + h(m), m) }
            }
        }
        guard bestTotal.isFinite else { throw Failure.noRoute }

        // Rebuild the path.
        var coords: [Point] = [from, a.point]
        var legs: [(edge: Int, reverse: Bool, meters: Double)] = []
        if bestEnd < 0 {   // straight along the shared edge
            coords += cut(a.edge, from: a.along, to: b.along)
            legs.append((a.edge, b.along < a.along, abs(b.along - a.along)))
        } else {
            var chain: [UInt32] = []
            var n = bestEnd
            while prev[n] != .max {
                let entry = prev[n]
                chain.append(entry)
                let e = Int(entry & 0x7FFF_FFFF)
                n = Int(entry & 0x8000_0000 != 0 ? edgeV[e] : edgeU[e])
            }
            chain.reverse()
            // First partial edge: start point to the node the search began from (n).
            let startTowardsU = n == Int(edgeU[a.edge])
            coords += cut(a.edge, from: a.along, to: startTowardsU ? 0 : lenA)
            legs.append((a.edge, startTowardsU, startTowardsU ? a.along : lenA - a.along))
            for entry in chain {
                let e = Int(entry & 0x7FFF_FFFF), reverse = entry & 0x8000_0000 != 0
                let pts = shape(e)
                coords += reverse ? Array(pts.reversed().dropFirst()) : Array(pts.dropFirst())
                legs.append((e, reverse, Double(edgeLen[e])))
            }
            let endFromU = bestEnd == bu
            coords += cut(b.edge, from: endFromU ? 0 : lenB, to: b.along)
            legs.append((b.edge, !endFromU, endFromU ? b.along : lenB - b.along))
        }
        coords += [b.point, to]
        let meters = legs.reduce(0) { $0 + $1.meters }
        let seconds = mode == .foot ? footSeconds(legs) : bestTotal
        return Route(meters: meters, seconds: seconds, coords: coords, steps: steps(legs, mode: mode),
                     startGap: a.gap, endGap: b.gap)
    }

    /// Shape of an edge between two distances from u (in either direction), excluding the start.
    private func cut(_ e: Int, from: Double, to: Double) -> [Point] {
        let pts = shape(e)
        var cum = [0.0]
        for i in 1..<pts.count { cum.append(cum[i - 1] + Self.distance(pts[i - 1], pts[i])) }
        let scale = Double(edgeLen[e]) / max(cum.last!, 0.01)
        func at(_ d: Double) -> Point {
            let x = d / scale
            for i in 1..<pts.count where cum[i] >= x {
                let t = (x - cum[i - 1]) / max(cum[i] - cum[i - 1], 0.001)
                return Point(lat: pts[i - 1].lat + t * (pts[i].lat - pts[i - 1].lat), lon: pts[i - 1].lon + t * (pts[i].lon - pts[i - 1].lon))
            }
            return pts.last!
        }
        var out: [Point] = []
        if from <= to {
            for i in 0..<pts.count where cum[i] * scale > from && cum[i] * scale < to { out.append(pts[i]) }
        } else {
            for i in (0..<pts.count).reversed() where cum[i] * scale < from && cum[i] * scale > to { out.append(pts[i]) }
        }
        out.append(at(to))
        return out
    }

    /// Walking time without the busy-road preference: trails and steps are slower than pavement.
    private func footSeconds(_ legs: [(edge: Int, reverse: Bool, meters: Double)]) -> Double {
        legs.reduce(0) { t, leg in
            let cls = Int(edgeClass[leg.edge])
            let speed = cls == 11 ? 0.6 : (cls == 8 || cls == 9) ? 1.1 : 1.34
            return t + leg.meters / speed
        }
    }

    // MARK: Directions

    private static let classNames = ["highway", "highway", "road", "road", "road", "road", "street", "service road",
                                     "track", "trail", "path", "steps", "ramp", "road", "road", "road"]

    private func label(_ e: Int) -> String {
        if var n = name(e), !n.isEmpty {
            // Route numbers from ref tags: "I 89" -> "I-89", "US 2;VT 100" -> "US 2 / VT 100".
            n = n.replacingOccurrences(of: ";", with: " / ")
            if n.hasPrefix("I ") { n = "I-" + n.dropFirst(2) }
            return n
        }
        return "the " + Self.classNames[Int(edgeClass[e])]
    }

    /// Groups legs into named stretches and says how to turn between them.
    private func steps(_ legs: [(edge: Int, reverse: Bool, meters: Double)], mode: Mode) -> [Step] {
        struct Stretch { var label: String; var meters: Double; var startEdge: Int; var startReverse: Bool; var lastEdge: Int; var lastReverse: Bool }
        var stretches: [Stretch] = []
        for leg in legs where leg.meters > 0.5 {
            let l = label(leg.edge)
            if var last = stretches.last, last.label == l {
                last.meters += leg.meters; last.lastEdge = leg.edge; last.lastReverse = leg.reverse
                stretches[stretches.count - 1] = last
            } else {
                stretches.append(Stretch(label: l, meters: leg.meters, startEdge: leg.edge, startReverse: leg.reverse,
                                         lastEdge: leg.edge, lastReverse: leg.reverse))
            }
        }
        // Tidy: pieces under 25 m join their neighbour; an unnamed piece you go straight through
        // (a bridge, a short connector) between two stretches of the same road disappears.
        var tidy: [Stretch] = []
        for (i, s) in stretches.enumerated() {
            let between = i > 0 && i + 1 < stretches.count && stretches[i - 1].label == stretches[i + 1].label
            if var last = tidy.last, s.meters < 25 || (between && s.label.hasPrefix("the ")) || last.label == s.label {
                last.meters += s.meters; last.lastEdge = s.lastEdge; last.lastReverse = s.lastReverse
                tidy[tidy.count - 1] = last
            } else {
                tidy.append(s)
            }
        }
        stretches = tidy
        guard !stretches.isEmpty else { return [] }

        func headingOut(_ e: Int, _ reverse: Bool) -> (Point, Double) {
            let pts = reverse ? Array(shape(e).reversed()) : shape(e)
            let target = pts.dropFirst().first { Self.distance(pts[0], $0) > 15 } ?? pts.last!
            return (pts[0], Self.bearing(pts[0], target))
        }
        func headingIn(_ e: Int, _ reverse: Bool) -> Double {
            let pts = reverse ? Array(shape(e).reversed()) : shape(e)
            let end = pts.last!
            let from = pts.dropLast().last { Self.distance($0, end) > 15 } ?? pts[0]
            return Self.bearing(from, end)
        }

        var out: [Step] = []
        let verb = mode == .foot ? "Walk" : "Drive"
        let (start, startHeading) = headingOut(stretches[0].startEdge, stretches[0].startReverse)
        out.append(Step(text: "\(verb) \(Self.compass(startHeading)) on \(stretches[0].label)",
                        meters: stretches[0].meters, at: start))
        for i in 1..<stretches.count {
            let before = headingIn(stretches[i - 1].lastEdge, stretches[i - 1].lastReverse)
            let (at, after) = headingOut(stretches[i].startEdge, stretches[i].startReverse)
            var turn = (after - before + 540).truncatingRemainder(dividingBy: 360) - 180   // -180...180, + = right
            if turn == -180 { turn = 180 }
            let side = turn > 0 ? "right" : "left", a = abs(turn)
            let how = a < 20 ? "Continue" : a < 50 ? "Bear \(side)" : a < 135 ? "Turn \(side)" : "Make a sharp \(side)"
            let text = stretches[i].label == "the ramp"
                ? (a < 20 ? "Take the ramp" : "Take the ramp on the \(side)")
                : "\(how) onto \(stretches[i].label)"
            out.append(Step(text: text, meters: stretches[i].meters, at: at))
        }
        return out
    }

    static func compass(_ deg: Double) -> String {
        ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"][Int((deg / 45).rounded()) % 8]
    }
}

/// Binary min-heap of (priority, node).
private struct MinHeap {
    private var keys: [Float] = []
    private var vals: [Int] = []

    mutating func push(_ k: Float, _ v: Int) {
        keys.append(k); vals.append(v)
        var i = keys.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if keys[p] <= keys[i] { break }
            keys.swapAt(p, i); vals.swapAt(p, i); i = p
        }
    }

    mutating func pop() -> (Float, Int)? {
        guard let k = keys.first else { return nil }
        let v = vals[0]
        let lastK = keys.removeLast(), lastV = vals.removeLast()
        if !keys.isEmpty {
            keys[0] = lastK; vals[0] = lastV
            var i = 0
            let n = keys.count
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < n && keys[l] < keys[m] { m = l }
                if r < n && keys[r] < keys[m] { m = r }
                if m == i { break }
                keys.swapAt(m, i); vals.swapAt(m, i); i = m
            }
        }
        return (k, v)
    }
}

extension RouteGraph.Route {
    /// JSON for the map page: coords as [lat, lon] pairs, steps with text/metres/position.
    func json(mode: RouteGraph.Mode) -> Data {
        func r(_ x: Double) -> Double { (x * 1e5).rounded() / 1e5 }
        let obj: [String: Any] = [
            "mode": mode.rawValue,
            "meters": meters.rounded(),
            "seconds": seconds.rounded(),
            "startGap": startGap.rounded(),
            "endGap": endGap.rounded(),
            "coords": coords.map { [r($0.lat), r($0.lon)] },
            "steps": steps.map { ["text": $0.text, "meters": $0.meters.rounded(), "lat": r($0.at.lat), "lon": r($0.at.lon)] },
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }
}

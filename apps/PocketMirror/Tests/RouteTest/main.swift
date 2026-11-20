import Foundation

// Route test: runs the app's router (Routing/RouteGraph.swift) on macOS against a routing.bin.
// Usage: routetest <routing.bin> <foot|car> <lat,lon> <lat,lon> [<lat,lon> <lat,lon> ...]
let args = CommandLine.arguments
guard args.count >= 5, let mode = RouteGraph.Mode(rawValue: args[2]) else {
    print("usage: routetest routing.bin foot|car lat,lon lat,lon ..."); exit(2)
}
func parse(_ s: String) -> RouteGraph.Point {
    let p = s.split(separator: ",").compactMap { Double($0) }
    return RouteGraph.Point(lat: p[0], lon: p[1])
}
let t0 = Date()
let graph = try RouteGraph(url: URL(fileURLWithPath: args[1]))
print("loaded \(graph.nodeCount) junctions, \(graph.edgeCount) edges in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
var failures = 0
var i = 3
while i + 1 < args.count {
    let a = parse(args[i]), b = parse(args[i + 1]); i += 2
    let t = Date()
    do {
        let r = try graph.route(from: a, to: b, mode: mode)
        print(String(format: "%@ -> %@: %.1f km, %.0f min, %d points, %d steps, gaps %.0f/%.0f m, %.2f s",
                     args[i - 2], args[i - 1], r.meters / 1000, r.seconds / 60, r.coords.count, r.steps.count,
                     r.startGap, r.endGap, Date().timeIntervalSince(t)))
        for s in r.steps.prefix(12) { print(String(format: "   %6.0f m  %@", s.meters, s.text)) }
        if r.steps.count > 12 { print("   … \(r.steps.count - 12) more") }
    } catch {
        failures += 1
        print("\(args[i - 2]) -> \(args[i - 1]): \(error)")
    }
}
exit(failures == 0 ? 0 : 1)

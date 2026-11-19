import Foundation

// macOS harness: serve a folder with the same server code the app uses.
// Usage: rangetest <root> <port> [lan]
let args = CommandLine.arguments
guard args.count >= 3, let port = UInt16(args[2]) else {
    FileHandle.standardError.write(Data("usage: rangetest <root> <port>\n".utf8)); exit(2)
}
let server = MirrorServer(port: port)
server.onStateChange = { state in print("server state: \(state)"); fflush(stdout) }
server.start(root: URL(fileURLWithPath: args[1], isDirectory: true), lan: args.count > 3 && args[3] == "lan")
dispatchMain()

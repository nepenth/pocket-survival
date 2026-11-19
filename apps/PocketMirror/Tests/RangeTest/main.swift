import Foundation

// macOS harness: serve a folder with the same server code the app uses.
// Usage: rangetest <root>[:<root2>...] <port> [lan] [upload]
// Roots are searched in order; with "upload", PUT uploads go into the last root.
let args = CommandLine.arguments
guard args.count >= 3, let port = UInt16(args[2]) else {
    FileHandle.standardError.write(Data("usage: rangetest <root> <port>\n".utf8)); exit(2)
}
let server = MirrorServer(port: port)
server.uploadsEnabled = args.dropFirst(3).contains("upload")
server.onStateChange = { state in print("server state: \(state)"); fflush(stdout) }
let roots = args[1].split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
server.start(roots: roots, uploadRoot: roots.last, lan: args.dropFirst(3).contains("lan"))
dispatchMain()

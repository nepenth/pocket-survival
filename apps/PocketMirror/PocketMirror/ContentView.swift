import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: MirrorModel
    @State private var showingBrowser = false
    @State private var showingPicker = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button(action: { showingBrowser = true }) {
                        HStack {
                            Image(systemName: "safari")
                            Text("Open Mirror")
                                .fontWeight(.semibold)
                        }
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(!model.isRunning)
                }

                Section(header: Text("Content"),
                        footer: Text("To load your own content, connect the phone to a Mac, open it in Finder, choose Files › Pocket Mirror and copy the folder contents in. Or pick a folder in the Files app.")) {
                    HStack {
                        Text("Serving")
                        Spacer()
                        Text(model.sourceDescription)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    sourceButton("Use On My iPhone › Pocket Mirror", .documents)
                    Button("Choose a Folder…") { showingPicker = true }
                    sourceButton("Use the Built-in Sample", .demo)
                    if let problem = model.problem {
                        Text(problem)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(header: Text("Server"),
                        footer: Text("The mirror works fully offline. iOS pauses the server about 30 seconds after you leave the app, so use Open Mirror rather than Safari.")) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(model.isRunning ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(statusText)
                        Spacer()
                        Button(model.isRunning ? "Restart" : "Start") { model.restartServer() }
                    }
                    HStack {
                        Text("Address")
                        Spacer()
                        Text(model.localURL.absoluteString)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    Button("Open in Safari") { UIApplication.shared.open(model.localURL) }
                        .disabled(!model.isRunning)
                }

                Section(header: Text("Share on Wi-Fi"),
                        footer: Text("Off by default. When on, other devices on the same Wi-Fi network can browse this content at the address below, while this app is open.")) {
                    Toggle("Share on Local Network", isOn: $model.lanEnabled)
                    if model.lanEnabled {
                        Text(model.lanAddress ?? "Not connected to Wi-Fi")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion).foregroundColor(.secondary)
                    }
                }
            }
            .navigationBarTitle("Pocket Mirror")
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .fullScreenCover(isPresented: $showingBrowser) {
            MirrorBrowser(url: model.localURL) { showingBrowser = false }
        }
        .sheet(isPresented: $showingPicker) {
            FolderPicker { url in
                showingPicker = false
                if let url { model.usePickedFolder(url) }
            }
        }
    }

    private func sourceButton(_ title: String, _ source: MirrorModel.Source) -> some View {
        Button(action: { model.use(source) }) {
            HStack {
                Text(title)
                Spacer()
                if model.source == source { Image(systemName: "checkmark") }
            }
        }
    }

    private var statusText: String {
        switch model.serverState {
        case .stopped: return "Stopped"
        case .running(_, let lan): return lan ? "Running (Wi-Fi sharing on)" : "Running"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (build \(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// Files-app folder picker (iOS 14 API).
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}

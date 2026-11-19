import SwiftUI

struct DownloadButton: View {
    @ObservedObject private var llamaState: LlamaState
    private var modelName: String
    private var modelUrl: String
    private var filename: String
    private var sizeLabel: String?
    private var isLarge: Bool
    private var blurb: String?
    private var expectedBytes: Int64?

    @State private var status: String
    @State private var errorText: String?

    @State private var downloadTask: URLSessionDownloadTask?
    @State private var progress = 0.0
    @State private var observation: NSKeyValueObservation?

    private static func getFileURL(filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
    }

    init(llamaState: LlamaState, modelName: String, modelUrl: String, filename: String,
         sizeLabel: String? = nil, isLarge: Bool = false, blurb: String? = nil, expectedBytes: Int64? = nil) {
        self.llamaState = llamaState
        self.modelName = modelName
        self.modelUrl = modelUrl
        self.filename = filename
        self.sizeLabel = sizeLabel
        self.isLarge = isLarge
        self.blurb = blurb
        self.expectedBytes = expectedBytes

        let fileURL = DownloadButton.getFileURL(filename: filename)
        _status = State(initialValue: FileManager.default.fileExists(atPath: fileURL.path) ? "downloaded" : "download")
    }

    private func download() {
        guard let url = URL(string: modelUrl) else { return }
        if let expectedBytes, llamaState.freeDiskBytes() < expectedBytes + 300_000_000 {
            errorText = "Not enough free space. Free up \(String(format: "%.1f", Double(expectedBytes + 300_000_000 - llamaState.freeDiskBytes()) / 1e9)) GB or delete another model."
            return
        }
        status = "downloading"
        errorText = nil
        progress = 0
        // Large downloads take minutes; keep the screen on so iOS doesn't suspend the app mid-download.
        UIApplication.shared.isIdleTimerDisabled = true
        let fileURL = DownloadButton.getFileURL(filename: filename)
        let model = Model(name: modelName, url: modelUrl, filename: filename, status: "downloaded")

        downloadTask = URLSession.shared.downloadTask(with: url) { temporaryURL, response, error in
            // Runs on a background queue: move the file here (the temporary file is deleted when this
            // returns), then hand every UI/state change to the main thread.
            var failure: String?
            if let error = error as NSError? {
                failure = error.code == NSURLErrorCancelled ? nil : error.localizedDescription
                if failure == nil { failure = "" }
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failure = "Server returned HTTP \(http.statusCode)"
            } else if let temporaryURL {
                do {
                    try? FileManager.default.removeItem(at: fileURL)
                    try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
                } catch {
                    failure = "Could not save the file: \(error.localizedDescription)"
                }
            } else {
                failure = "Download failed"
            }

            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                observation = nil
                if let failure {
                    status = "download"
                    errorText = failure.isEmpty ? nil : failure
                } else {
                    status = "downloaded"
                    llamaState.cacheCleared = false
                    llamaState.didDownload(model)
                }
            }
        }

        observation = downloadTask?.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async { self.progress = progress.fractionCompleted }
        }

        downloadTask?.resume()
    }

    private var details: String {
        [sizeLabel, blurb, isLarge ? "Large: slower, uses the most memory" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if status == "download" {
                Button(action: download) {
                    Text("Download " + modelName)
                }
            } else if status == "downloading" {
                Button(action: {
                    downloadTask?.cancel()
                    status = "download"
                }) {
                    Text("\(modelName) – downloading \(Int(progress * 100))% – keep this screen open, tap to cancel")
                }
            } else if status == "downloaded" {
                Button(action: {
                    let fileURL = DownloadButton.getFileURL(filename: filename)
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        download()
                        return
                    }
                    try? llamaState.loadModel(modelUrl: fileURL)
                }) {
                    Text(llamaState.loadedModelName == modelName ? "\(modelName) (loaded)" : "Load \(modelName)")
                }
                .disabled(llamaState.isLoadingModel || llamaState.isGenerating)
            } else {
                Text("Unknown status")
            }
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundColor(isLarge ? .orange : .secondary)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
        .onDisappear() {
            downloadTask?.cancel()
        }
        .onChange(of: llamaState.cacheCleared) { newValue in
            if newValue {
                downloadTask?.cancel()
                let fileURL = DownloadButton.getFileURL(filename: filename)
                status = FileManager.default.fileExists(atPath: fileURL.path) ? "downloaded" : "download"
            }
        }
    }
}

import SwiftUI

struct InputButton: View {
    @ObservedObject var llamaState: LlamaState
    @State private var inputLink: String = ""
    @State private var status: String = "download"
    @State private var filename: String = ""

    @State private var downloadTask: URLSessionDownloadTask?
    @State private var progress = 0.0
    @State private var observation: NSKeyValueObservation?

    /// Uses the link's full file name (the old code cut it at the first ".", so
    /// "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf" was saved as "Qwen2").
    private static func extractModelInfo(from link: String) -> (modelName: String, filename: String)? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let filename = url.lastPathComponent.removingPercentEncoding,
              filename.lowercased().hasSuffix(".gguf") else {
            return nil
        }
        return (String(filename.dropLast(5)), filename)
    }

    private static func getFileURL(filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
    }

    private func download() {
        guard let extractedInfo = InputButton.extractModelInfo(from: inputLink) else {
            // Handle invalid link or extraction failure
            return
        }

        let (modelName, filename) = extractedInfo
        self.filename = filename  // Set the state variable

        status = "downloading"
        print("Downloading model \(modelName) from \(inputLink)")
        guard let url = URL(string: inputLink.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let fileURL = InputButton.getFileURL(filename: filename)

        let model = Model(name: modelName, url: inputLink, filename: filename, status: "downloaded")
        UIApplication.shared.isIdleTimerDisabled = true
        downloadTask = URLSession.shared.downloadTask(with: url) { temporaryURL, response, error in
            // Background queue: save the file here, then update state on the main thread.
            var saved = false
            if error == nil,
               (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false,
               let temporaryURL {
                try? FileManager.default.removeItem(at: fileURL)
                saved = (try? FileManager.default.moveItem(at: temporaryURL, to: fileURL)) != nil
            }
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                if saved {
                    llamaState.cacheCleared = false
                    llamaState.didDownload(model)
                    status = "downloaded"
                } else {
                    status = "download"
                }
            }
        }

        observation = downloadTask?.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async { self.progress = progress.fractionCompleted }
        }

        downloadTask?.resume()
    }

    var body: some View {
        VStack {
            HStack {
                TextField("https://…/model.gguf", text: $inputLink)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button(action: {
                    downloadTask?.cancel()
                    status = "download"
                }) {
                    Text("Cancel")
                }
            }

            if status == "download" {
                Button(action: download) {
                    Text("Download Custom Model")
                }
            } else if status == "downloading" {
                Button(action: {
                    downloadTask?.cancel()
                    status = "download"
                }) {
                    Text("Downloading \(Int(progress * 100))%")
                }
            } else if status == "downloaded" {
                Button(action: {
                    let fileURL = InputButton.getFileURL(filename: self.filename)
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        download()
                        return
                    }
                    try? llamaState.loadModel(modelUrl: fileURL)
                }) {
                    Text("Load Custom Model")
                }
            } else {
                Text("Unknown status")
            }
        }
        .onDisappear() {
            downloadTask?.cancel()
        }
        .onChange(of: llamaState.cacheCleared) { newValue in
            if newValue {
                downloadTask?.cancel()
                let fileURL = InputButton.getFileURL(filename: self.filename)
                status = FileManager.default.fileExists(atPath: fileURL.path) ? "downloaded" : "download"
            }
        }
    }
}

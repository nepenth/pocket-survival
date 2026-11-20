import Foundation
import UIKit
import os

struct Model: Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var filename: String
    var status: String?
    /// Download size shown next to catalog entries, e.g. "0.99 GB".
    var sizeLabel: String? = nil
    /// Marks the heavyweight option in the list.
    var isLarge = false
    /// Names older builds saved this file under (the old downloader cut names at the first ".").
    var legacyFilenames: [String] = []
    /// Exact file size from Hugging Face; a smaller file on disk is an incomplete download.
    var expectedBytes: Int64? = nil
    /// One line on why this model is on the list.
    var blurb: String? = nil
}

/// Breadcrumb log that survives a crash: each step is written to disk before it starts, so after
/// an unexpected exit the next launch can say what the app was doing and how much memory was free.
enum Diagnostics {
    private static let maxLines = 300
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.log")
    }()

    static func mark(_ event: String) {
        let freeMB = os_proc_available_memory() / 1_048_576
        let line = "\(timestamp()) [\(freeMB) MB free] \(event)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.synchronizeFile()
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }

    /// Recent log lines, newest last.
    static func recent(_ count: Int = 40) -> String {
        guard let text = try? String(contentsOf: url) else { return "" }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    /// Called once at launch: reports a step that began but never finished in the previous run,
    /// then trims the log.
    static func startSession() -> String? {
        let previous = (try? String(contentsOf: url)) ?? ""
        let lines = previous.split(separator: "\n").map(String.init)
        var unfinished: String?
        for line in lines.reversed() {
            if line.contains("END ") || line.contains("APP START") { break }
            if line.contains("BEGIN ") { unfinished = line; break }
        }
        let kept = lines.suffix(maxLines).joined(separator: "\n")
        try? (kept.isEmpty ? "" : kept + "\n").write(to: url, atomically: true, encoding: .utf8)
        mark("APP START")
        return unfinished
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    let role: Role
    var text: String
    /// App-generated notice shown in the chat but never sent to the model.
    var isNotice = false
    /// A photo sent with this message (file name in the chats folder's images/).
    var imageFile: String? = nil
    /// Library passages the reply was given (shown under it, tappable).
    var sources: [SourceRef]? = nil
    /// Where the reply was written, e.g. "Gemma 3 4B on the Pi".
    var answeredBy: String? = nil
}

/// One saved conversation, stored as Application Support/chats/<id>.json.
struct SavedChat: Codable {
    var id: UUID
    var created: Date
    var updated: Date
    var messages: [ChatMessage]
}

/// What the chat list shows, without loading every conversation's messages.
struct ChatSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let preview: String
    let updated: Date
    let count: Int
}

@MainActor
class LlamaState: ObservableObject {
    /// Activity log (model loading, downloads, speed test); shown in Settings, not in the chat.
    @Published var messageLog = ""

    // MARK: Chat state
    @Published var messages: [ChatMessage] = []
    @Published var isGenerating = false
    @Published var loadedModelName: String?
    @Published var isLoadingModel = false
    @Published var modelLoadError: String?
    /// Set at launch when the previous run ended in the middle of a step (likely a crash).
    @Published var previousCrashNote: String?
    /// First message that was still inside the assistant's memory for the latest reply.
    @Published var memoryStartID: UUID?
    /// Bumped whenever streamed text is flushed, so the chat view can keep the newest text in view.
    @Published var scrollTick = 0
    @Published var lastStats: String?
    @Published var systemPrompt: String = "" {
        didSet { saveSystemPrompt() }
    }
    private var stopRequested = false

    /// Hard ceiling for the formatted prompt on the phone. The context holds 2048 tokens; this
    /// leaves ~500 for the reply. Library passages and the remembered history share it. The A13
    /// reads about 50-100 tokens a second, so a full prompt means ~15-30 s before the first word:
    /// accepted, because a grounded answer matters more than a fast one.
    private let promptTokenBudget = 1536
    /// Of that, the most the library passages may take (characters; ~4 per token).
    private let phoneSourceChars = 2600

    // MARK: Kit Pi (bigger models, photos, the full library) over its Wi-Fi
    private static let piHostKey = "piHost", usePiKey = "usePi", useLibraryKey = "useLibrary"
    /// Address of the kit's Pi; "survivalpi" works on its hotspot (every name resolves to it).
    @Published var piHost: String = UserDefaults.standard.string(forKey: LlamaState.piHostKey) ?? KitPi.defaultHost {
        didSet { UserDefaults.standard.set(piHost, forKey: Self.piHostKey) }
    }
    /// Answer with the Pi's model whenever the Pi is reachable (on by default).
    @Published var usePi: Bool = UserDefaults.standard.object(forKey: LlamaState.usePiKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(usePi, forKey: Self.usePiKey) }
    }
    /// Look the question up in the kit's library first and give the passages to the model.
    @Published var useLibrary: Bool = UserDefaults.standard.object(forKey: LlamaState.useLibraryKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(useLibrary, forKey: Self.useLibraryKey) }
    }
    @Published var piStatus: KitPiStatus?
    @Published var piChecking = false
    @Published var piSwapping: String?
    @Published var piNote: String?
    /// Photo waiting to go with the next message (Pi vision models only).
    @Published var attachedImage: UIImage?
    /// Shown in place of "Thinking…" while a reply is being prepared.
    @Published var replyPhase: String?
    private var piStream: ChatStream?

    /// True when replies will come from the Pi.
    var piActive: Bool { usePi && piStatus != nil }
    var canSendPhotos: Bool { piActive && (piStatus?.vision ?? false) }
    /// Streamed text is applied to the UI at most this often, so long replies don't re-render per token.
    private let streamFlushInterval: UInt64 = 80_000_000 // ns
    private static let systemPromptKey = "customSystemPrompt"
    private static let lastModelKey = "lastModelFilename"
    private static let briefAnswersKey = "briefAnswers"
    private static let threadsKey = "generationThreads"
    private static let batchThreadsKey = "promptThreads"

    /// CPU threads used while writing a reply. The A13 has 2 fast and 4 efficiency cores;
    /// the Speed Test in Settings measures which count is fastest on this phone.
    @Published var generationThreads: Int = UserDefaults.standard.object(forKey: LlamaState.threadsKey) as? Int ?? 4 {
        didSet { UserDefaults.standard.set(generationThreads, forKey: Self.threadsKey); applyThreads() }
    }
    /// CPU threads used while reading the prompt (batched work scales with more cores).
    @Published var promptThreads: Int = UserDefaults.standard.object(forKey: LlamaState.batchThreadsKey) as? Int ?? 4 {
        didSet { UserDefaults.standard.set(promptThreads, forKey: Self.batchThreadsKey); applyThreads() }
    }
    @Published var isTuning = false
    @Published var tuningReport: String?
    /// Reply length cap while "Brief answers" is on: shorter replies save battery and time.
    private let briefReplyTokenCap = 320

    /// Short answers by default; each reply costs battery on a phone that may not be recharged soon.
    @Published var briefAnswers: Bool = UserDefaults.standard.object(forKey: LlamaState.briefAnswersKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(briefAnswers, forKey: Self.briefAnswersKey) }
    }

    /// Starter questions shown on an empty chat, so help is one tap away under stress.
    let quickQuestions: [String] = [
        "Someone is bleeding heavily. What do I do?",
        "How do I treat a burn?",
        "How do I do CPR on an adult?",
        "Signs of hypothermia and what to do",
        "How can I make water safe to drink?",
        "How do I signal for rescue?",
    ]

    /// Before 1.3.0 there was only one chat, kept here; it becomes the first saved chat.
    private static let legacyChatURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("chat.json")
    }()
    private static let chatsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let currentChatKey = "currentChatID"

    /// The conversation on screen; saved under this id once it has a message.
    private var currentChatID = UUID()
    private var currentChatCreated = Date()
    /// Every saved conversation, newest first.
    @Published var chats: [ChatSummary] = []
    var currentChat: UUID { currentChatID }

    @Published var cacheCleared = false
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []
    let NS_PER_S = 1_000_000_000.0


    private var llamaContext: LlamaContext?
    private var defaultModelUrl: URL? {
        Bundle.main.url(forResource: "ggml-model", withExtension: "gguf", subdirectory: "models")
        // Bundle.main.url(forResource: "llama-2-7b-chat", withExtension: "Q2_K.gguf", subdirectory: "models")
    }

    init() {
        let unfinished = Diagnostics.startSession()
        if let unfinished {
            previousCrashNote = "The app closed unexpectedly last time during: \(unfinished)"
            messageLog += (previousCrashNote ?? "") + "\n"
        }
        systemPrompt = UserDefaults.standard.string(forKey: Self.systemPromptKey) ?? defaultSystemPrompt
        restoreChat()
        loadModelsFromDisk()
        loadDefaultModels()
        autoLoadLastModel(skip: unfinished?.contains("BEGIN load") == true)
    }

    /// Reloads the model used last time, so the app is ready to answer as soon as it opens.
    /// Skipped when the previous run died while loading, to avoid a crash loop.
    private func autoLoadLastModel(skip: Bool) {
        guard let filename = UserDefaults.standard.string(forKey: Self.lastModelKey) else { return }
        let url = getDocumentsDirectory().appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if skip {
            messageLog += "Not reloading \(filename) automatically because the last load did not finish.\n"
            return
        }
        try? loadModel(modelUrl: url)
    }

    // MARK: Chat persistence (the app may be closed by iOS at any time; keep the instructions)

    private func restoreChat() {
        migrateLegacyChat()
        loadChatList()
        if let raw = UserDefaults.standard.string(forKey: Self.currentChatKey), let id = UUID(uuidString: raw),
           let saved = readChat(id) {
            currentChatID = saved.id
            currentChatCreated = saved.created
            messages = saved.messages.filter { !$0.text.isEmpty }
        }
    }

    private func chatURL(_ id: UUID) -> URL { Self.chatsDir.appendingPathComponent(id.uuidString + ".json") }

    private func readChat(_ id: UUID) -> SavedChat? {
        guard let data = try? Data(contentsOf: chatURL(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SavedChat.self, from: data)
    }

    private func migrateLegacyChat() {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: Self.legacyChatURL) else { return }
        if let old = try? JSONDecoder().decode([ChatMessage].self, from: data), !old.isEmpty {
            let modified = (try? fm.attributesOfItem(atPath: Self.legacyChatURL.path)[.modificationDate] as? Date) ?? Date()
            let chat = SavedChat(id: UUID(), created: modified, updated: modified, messages: old)
            write(chat)
            UserDefaults.standard.set(chat.id.uuidString, forKey: Self.currentChatKey)
        }
        try? fm.removeItem(at: Self.legacyChatURL)
    }

    private func write(_ chat: SavedChat) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(chat) else { return }
        try? data.write(to: chatURL(chat.id), options: .atomic)
    }

    private func summary(_ chat: SavedChat) -> ChatSummary? {
        let real = chat.messages.filter { !$0.text.isEmpty && !$0.isNotice }
        guard let first = real.first(where: { $0.role == .user }) else { return nil }
        let title = first.text.replacingOccurrences(of: "\n", with: " ")
        let last = real.last(where: { $0.role == .assistant })?.text ?? ""
        let preview = last.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
        return ChatSummary(id: chat.id, title: String(title.prefix(80)), preview: String(preview.prefix(120)),
                           updated: chat.updated, count: real.count)
    }

    private func loadChatList() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.chatsDir, includingPropertiesForKeys: nil)) ?? []
        chats = files.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .compactMap(readChat).compactMap(summary)
            .sorted { $0.updated > $1.updated }
    }

    private func saveChat() {
        let kept = messages.filter { !$0.text.isEmpty }
        guard kept.contains(where: { $0.role == .user }) else { return }
        let chat = SavedChat(id: currentChatID, created: currentChatCreated, updated: Date(), messages: kept)
        write(chat)
        UserDefaults.standard.set(currentChatID.uuidString, forKey: Self.currentChatKey)
        if let s = summary(chat) {
            chats.removeAll { $0.id == chat.id }
            chats.insert(s, at: 0)
        }
    }

    /// Switches to a saved conversation. The model re-reads the kept history on the next
    /// message anyway, so nothing else has to change.
    func openChat(_ id: UUID) {
        guard !isGenerating, id != currentChatID, let saved = readChat(id) else { return }
        saveChat()
        currentChatID = saved.id
        currentChatCreated = saved.created
        messages = saved.messages.filter { !$0.text.isEmpty }
        memoryStartID = nil
        UserDefaults.standard.set(id.uuidString, forKey: Self.currentChatKey)
        scrollTick += 1
    }

    func deleteChat(_ id: UUID) {
        guard !(isGenerating && id == currentChatID) else { return }
        try? FileManager.default.removeItem(at: chatURL(id))
        chats.removeAll { $0.id == id }
        if id == currentChatID { startNewChat() }
    }

    /// Words in a saved chat, for the chat list's search box.
    func chatMatches(_ id: UUID, _ query: String) -> Bool {
        guard let chat = readChat(id) else { return false }
        return chat.messages.contains { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func startNewChat() {
        messages.removeAll()
        memoryStartID = nil
        currentChatID = UUID()
        currentChatCreated = Date()
        UserDefaults.standard.removeObject(forKey: Self.currentChatKey)
    }

    /// Free space for downloads, in bytes.
    func freeDiskBytes() -> Int64 {
        let values = try? getDocumentsDirectory().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Checks a model file before loading: a truncated or non-GGUF file would otherwise crash llama.cpp.
    private func validateModelFile(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "The file can't be opened." }
        let magic = handle.readData(ofLength: 4)
        handle.closeFile()
        guard magic == Data("GGUF".utf8) else { return "This isn't a GGUF model file (or the download is damaged)." }
        if let expected = catalogEntry(forFilename: url.lastPathComponent)?.expectedBytes,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64,
           size < expected {
            return "The download is incomplete (\(size / 1_000_000) of \(expected / 1_000_000) MB)."
        }
        return nil
    }

    private func loadModelsFromDisk() {
        do {
            let documentsURL = getDocumentsDirectory()
            let modelURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            for modelURL in modelURLs {
                let filename = modelURL.lastPathComponent
                let modelName = catalogEntry(forFilename: filename)?.name ?? modelURL.deletingPathExtension().lastPathComponent
                downloadedModels.append(Model(name: modelName, url: "", filename: filename, status: "downloaded"))
            }
        } catch {
            print("Error loading models from disk: \(error)")
        }
    }

    private func loadDefaultModels() {
        do {
            try loadModel(modelUrl: defaultModelUrl)
        } catch {
            messageLog += "Error!\n"
        }

        refreshCatalog()
    }

    /// Catalog entries whose file (under its current or a legacy name) is not on the phone.
    func refreshCatalog() {
        undownloadedModels = defaultModels.filter { model in
            !([model.filename] + model.legacyFilenames).contains { name in
                FileManager.default.fileExists(atPath: getDocumentsDirectory().appendingPathComponent(name).path)
            }
        }
    }

    func catalogEntry(forFilename filename: String) -> Model? {
        defaultModels.first { $0.filename == filename || $0.legacyFilenames.contains(filename) }
    }

    /// Called by the downloaders on the main thread once a file is saved.
    func didDownload(_ model: Model) {
        downloadedModels.removeAll { $0.filename == model.filename }
        downloadedModels.append(model)
        refreshCatalog()
        Diagnostics.mark("downloaded \(model.filename)")
    }

    func didDelete(filenames: [String]) {
        downloadedModels.removeAll { filenames.contains($0.filename) }
        refreshCatalog()
    }

    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    /// Default download list for the iPhone 11 (4 GB RAM), small to large. Every model is
    /// <= 2.1 GB (Q4_K_M) so weights + context stay under the phone's ~2.5 GB budget, and every
    /// architecture is supported by the pinned llama.cpp. Links and byte sizes checked 2026-11-19.
    let defaultModels: [Model] = [
        Model(
            name: "LFM2.5 1.2B Instruct",
            url: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
            filename: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf", status: "download",
            sizeLabel: "0.73 GB", legacyFilenames: ["LFM2"], expectedBytes: 730_895_168,
            blurb: "Fastest and lightest on battery"
        ),
        Model(
            name: "Atlas First Aid 1.5B",
            url: "https://huggingface.co/Kami574/Atlas-FirstAid/resolve/main/Atlas-FirstAid.Q4_K_M.gguf",
            filename: "Atlas-FirstAid.Q4_K_M.gguf", status: "download",
            sizeLabel: "0.99 GB", legacyFilenames: ["Atlas-FirstAid"], expectedBytes: 986_048_096,
            blurb: "First-aid specialist"
        ),
        Model(
            name: "Qwen3.5 2B",
            url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
            filename: "Qwen3.5-2B-Q4_K_M.gguf", status: "download",
            sizeLabel: "1.28 GB", expectedBytes: 1_280_835_840,
            blurb: "Newest general model; best all-round for its size"
        ),
        Model(
            name: "Gemma 2 2B IT",
            url: "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf",
            filename: "gemma-2-2b-it-Q4_K_M.gguf", status: "download",
            sizeLabel: "1.71 GB", legacyFilenames: ["gemma-2-2b-it-Q4_K_M"], expectedBytes: 1_708_582_752,
            blurb: "Broad general knowledge"
        ),
        Model(
            name: "PocketSurvivor 3B",
            url: "https://huggingface.co/mfielding92/PocketSurvivor-3B/resolve/main/PocketSurvivor-3B-Q4_K_M.gguf",
            filename: "PocketSurvivor-3B-Q4_K_M.gguf", status: "download",
            sizeLabel: "2.02 GB", isLarge: true, expectedBytes: 2_019_377_984,
            blurb: "Survival specialist (shelter, water, injuries, disasters)"
        ),
        Model(
            name: "Llama 3.2 3B Instruct",
            url: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf", status: "download",
            sizeLabel: "2.02 GB", isLarge: true, legacyFilenames: ["Llama-3"], expectedBytes: 2_019_377_696,
            blurb: "Best general quality that fits"
        ),
    ]

    /// Loads a model off the main thread. The previous model is released first so two models are
    /// never in memory at once (4 GB phone), and taps while a load is running are ignored.
    func loadModel(modelUrl: URL?) throws {
        guard let modelUrl else {
            messageLog += "Load a model from the list below\n"
            return
        }
        guard !isGenerating else {
            messageLog += "Stop the current reply before switching models\n"
            return
        }
        guard !isLoadingModel else { return }

        let filename = modelUrl.lastPathComponent
        if let problem = validateModelFile(modelUrl) {
            messageLog += "Could not load \(filename): \(problem) Delete it and download it again.\n"
            modelLoadError = "\(problem) Delete it and download it again."
            return
        }
        modelLoadError = nil
        let displayName = catalogEntry(forFilename: filename)?.name ?? modelUrl.deletingPathExtension().lastPathComponent
        isLoadingModel = true
        llamaContext = nil
        loadedModelName = nil
        messageLog += "Loading \(displayName)...\n"
        Diagnostics.mark("BEGIN load \(filename)")

        let path = modelUrl.path
        Task {
            do {
                let context = try await Task.detached(priority: .userInitiated) {
                    try LlamaContext.create_context(path: path)
                }.value
                await context.set_threads(generation: generationThreads, batch: promptThreads)
                llamaContext = context
                loadedModelName = displayName
                if UserDefaults.standard.string(forKey: Self.systemPromptKey) == nil {
                    systemPrompt = defaultSystemPrompt
                }
                messageLog += "Loaded \(filename)\n"
                UserDefaults.standard.set(filename, forKey: Self.lastModelKey)
                Diagnostics.mark("END load \(filename)")
                updateDownloadedModels(modelName: filename, status: "downloaded")
            } catch {
                messageLog += "Could not load \(filename). The file may be incomplete; delete it and download again.\n"
                modelLoadError = "Could not load this model. Delete it and download it again."
                Diagnostics.mark("END load failed \(filename)")
            }
            isLoadingModel = false
        }
    }

    private func updateDownloadedModels(modelName: String, status: String) {
        undownloadedModels.removeAll { $0.name == modelName }
    }


    // MARK: - Chat

    /// Something can answer: a model on the phone, or the Pi.
    var hasModel: Bool { llamaContext != nil || piActive }
    var hasLocalModel: Bool { llamaContext != nil }

    var defaultSystemPrompt: String {
        if loadedModelName?.lowercased().contains("atlas") == true {
            return """
                You are Atlas, an offline first-aid assistant. Give numbered, step-by-step \
                instructions with the most urgent life-saving steps first (airway and breathing). \
                Be direct and brief. Say when to contact emergency services (911 or 112) if they \
                are reachable. Only give standard first-aid guidance; never invent treatments.
                """
        }
        return """
            You are an offline survival and first-aid assistant on a phone with no internet. \
            Give practical, step-by-step answers with the most urgent safety steps first. \
            Be clear and brief. Say when to get professional help or contact emergency services \
            if they are reachable. If you are not sure, say so instead of guessing.
            """
    }

    private func saveSystemPrompt() {
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || systemPrompt == defaultSystemPrompt {
            UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
        } else {
            UserDefaults.standard.set(systemPrompt, forKey: Self.systemPromptKey)
        }
    }

    func resetSystemPrompt() {
        systemPrompt = defaultSystemPrompt
    }

    /// Keeps the current conversation in the chat list and starts an empty one.
    func newChat() {
        guard !isGenerating else { return }
        saveChat()
        startNewChat()
    }

    func stopGenerating() {
        stopRequested = true
        piStream?.cancel()
    }

    // MARK: Kit Pi

    func refreshPi() async {
        guard !piChecking, piSwapping == nil else { return }
        piChecking = true
        let status = await KitPi.probe(piHost)
        piChecking = false
        if status != piStatus { piStatus = status }
    }

    /// Switches the Pi's model through its dashboard, then waits for it to come back.
    func swapPiModel(_ file: String) async {
        guard let host = piStatus?.ip, piSwapping == nil, !isGenerating else { return }
        piSwapping = KitPi.displayName(file)
        piNote = nil
        if let problem = await KitPi.swapModel(host: host, to: file) {
            piNote = problem
        } else {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if await KitPi.ready(host: host) { break }
            }
        }
        piSwapping = nil
        await refreshPi()
    }

    private static let imagesDir: URL = {
        let dir = LlamaState.chatsDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func imageURL(_ name: String) -> URL { Self.imagesDir.appendingPathComponent(name) }

    private func saveImage(_ image: UIImage) -> String? {
        let name = UUID().uuidString + ".jpg"
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        try? data.write(to: imageURL(name), options: .atomic)
        return name
    }

    /// The library passages as the model sees them.
    private static func sourcesBlock(_ sources: [SourceRef]) -> String {
        guard !sources.isEmpty else { return "" }
        return "\n\nReference passages from the kit's offline library. Use them when they answer the question and cite them like [1]. "
            + "If they don't cover it, answer from your own knowledge and say the library didn't cover it.\n"
            + sources.map { "[\($0.id)] \($0.title) (\($0.detail)): \($0.text)" }.joined(separator: "\n")
    }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = canSendPhotos ? attachedImage : nil
        guard !question.isEmpty || image != nil, !isGenerating else { return }
        let pi = piActive ? piStatus : nil
        guard pi != nil || llamaContext != nil else { return }

        isGenerating = true
        stopRequested = false
        var userMessage = ChatMessage(role: .user, text: question.isEmpty ? "What is in this photo?" : question)
        if let image { userMessage.imageFile = saveImage(image) }
        attachedImage = nil
        messages.append(userMessage)
        let history = messages.filter { !$0.text.isEmpty && !$0.isNotice }
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        scrollTick += 1

        var system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if briefAnswers { system += (system.isEmpty ? "" : " ") + "Keep answers short." }
        saveChat()
        Task {
            // Library first (from the Pi's book library and Kiwix), when the Pi is in reach.
            var sources: [SourceRef] = []
            if useLibrary, !question.isEmpty {
                if piStatus == nil { await refreshPi() }
                if let status = piStatus {
                    replyPhase = "Looking in the library…"
                    sources = await KitPi.lookUp(question, pi: status, maxChars: pi != nil ? 5000 : phoneSourceChars)
                    if let i = messages.firstIndex(where: { $0.id == reply.id }), !sources.isEmpty { messages[i].sources = sources }
                }
            }
            if stopRequested {
                finishStopped(reply.id)
                return
            }
            if let pi {
                let ok = await generatePiReply(pi, system: system, sources: sources, history: history, replyID: reply.id)
                if ok || stopRequested || llamaContext == nil { return }
                // The Pi went away mid-question: answer on the phone instead.
                piStatus = nil
                isGenerating = true
                setReply(reply.id, "")
            }
            if let llamaContext {
                await generateReply(context: llamaContext, system: system, sources: sources, history: history, replyID: reply.id)
            }
        }
    }

    private func finishStopped(_ id: UUID) {
        setReply(id, "(Stopped)")
        replyPhase = nil
        isGenerating = false
        saveChat()
    }

    /// Streams the answer from the Pi. Returns false if the Pi couldn't be reached at all.
    private func generatePiReply(_ pi: KitPiStatus, system: String, sources: [SourceRef], history: [ChatMessage], replyID: UUID) async -> Bool {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let by = "\(pi.modelName) on the Pi"
        if let i = messages.firstIndex(where: { $0.id == replyID }) { messages[i].answeredBy = by }

        // Recent history that fits the Pi's context (about 3.5 characters a token), newest last.
        let systemText = system + Self.sourcesBlock(sources)
        var budget = max(2000, (pi.contextTokens - 1024) * 3) - systemText.count
        var turns: [ChatMessage] = []
        for m in history.reversed() {
            if !turns.isEmpty && budget - m.text.count < 0 { break }
            budget -= m.text.count
            turns.insert(m, at: 0)
        }
        while let first = turns.first, first.role != .user { turns.removeFirst() }
        memoryStartID = turns.first?.id
        let newestUser = turns.last(where: { $0.role == .user })?.id
        var payload: [[String: Any]] = []
        if !systemText.isEmpty { payload.append(["role": "system", "content": systemText]) }
        for m in turns {
            if m.id == newestUser, let file = m.imageFile, pi.vision,
               let img = UIImage(contentsOfFile: imageURL(file).path), let url = KitPi.imageDataURL(img) {
                payload.append(["role": "user", "content": [["type": "text", "text": m.text],
                                                            ["type": "image_url", "image_url": ["url": url]]]])
            } else {
                payload.append(["role": m.role.rawValue, "content": m.text])
            }
        }

        replyPhase = sources.isEmpty ? "The Pi is reading…" : "The Pi is reading \(sources.count) library passages…"
        Diagnostics.mark("BEGIN Pi reply (\(systemText.count + turns.reduce(0) { $0 + $1.text.count }) chars, \(sources.count) sources)")
        let t0 = DispatchTime.now().uptimeNanoseconds
        var text = ""
        var firstAt: UInt64?
        var lastFlush: UInt64 = 0
        let result: (Error?, [String: Any]?) = await withCheckedContinuation { cont in
            piStream = KitPi.chat(host: pi.ip, messages: payload, maxTokens: briefAnswers ? briefReplyTokenCap : nil,
                onText: { [weak self] piece in
                    guard let self else { return }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if firstAt == nil { firstAt = now; self.replyPhase = nil }
                    text += piece
                    if now - lastFlush >= self.streamFlushInterval {
                        lastFlush = now
                        self.setReply(replyID, Self.visibleText(text))
                    }
                },
                onDone: { error, timings in cont.resume(returning: (error, timings)) })
            if piStream == nil { cont.resume(returning: (NSError(domain: "KitPi", code: 2), nil)) }
        }
        piStream = nil
        replyPhase = nil
        let (error, timings) = result
        if let error, !stopRequested, text.isEmpty {
            let reached = (error as NSError).domain == "KitPi"
            Diagnostics.mark("Pi reply failed: \(error.localizedDescription)")
            if !reached && llamaContext != nil { return false }
            setReply(replyID, "The Pi didn't answer: \(error.localizedDescription)")
            if let i = messages.firstIndex(where: { $0.id == replyID }) { messages[i].isNotice = true }
            isGenerating = false
            saveChat()
            return true
        }
        var finalText = Self.visibleText(text)
        if stopRequested { finalText += finalText.isEmpty ? "(Stopped)" : " …(stopped)" }
        setReply(replyID, finalText)
        let secondsToFirst = Double((firstAt ?? DispatchTime.now().uptimeNanoseconds) - t0) / NS_PER_S
        if let tps = timings?["predicted_per_second"] as? Double {
            lastStats = String(format: "Pi: %.1f tok/s, first word after %.1f s", tps, secondsToFirst)
        } else {
            lastStats = String(format: "Pi: first word after %.1f s", secondsToFirst)
        }
        Diagnostics.mark("END Pi reply (\(lastStats ?? ""))")
        isGenerating = false
        scrollTick += 1
        saveChat()
        return true
    }

    /// Picks the longest run of recent messages that fits the token budget, always starting
    /// on a user turn and always including the newest question.
    private func buildPrompt(context: LlamaContext, system: String, history: [ChatMessage]) async -> (prompt: String, firstID: UUID)? {
        func format(from start: Int) async -> String {
            var turns: [(role: String, content: String)] = []
            if !system.isEmpty { turns.append((role: "system", content: system)) }
            turns += history[start...].map { (role: $0.role.rawValue, content: $0.text) }
            return await context.format_chat(turns)
        }

        var start = history.count - 1
        var best = await format(from: start)
        guard await context.token_count(text: best) <= promptTokenBudget else { return nil }

        var candidate = start - 2
        while candidate >= 0 {
            if history[candidate].role != .user { candidate -= 1; continue }
            let prompt = await format(from: candidate)
            guard await context.token_count(text: prompt) <= promptTokenBudget else { break }
            start = candidate
            best = prompt
            candidate -= 2
        }
        return (best, history[start].id)
    }

    private func generateReply(context: LlamaContext, system: String, sources: [SourceRef] = [], history: [ChatMessage], replyID: UUID) async {
        // If the screen locks mid-reply iOS suspends the app and GPU work is not allowed in the
        // background, so keep the screen on while a reply is being written.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            isGenerating = false
            scrollTick += 1
            saveChat()
        }

        if let i = messages.firstIndex(where: { $0.id == replyID }) { messages[i].answeredBy = loadedModelName.map { "\($0) on this phone" } }
        replyPhase = sources.isEmpty ? nil : "Reading \(sources.count) library passages…"
        defer { replyPhase = nil }
        // Library passages go in the system message; drop the last ones if the prompt won't fit.
        var used = sources
        var built = await buildPrompt(context: context, system: system + Self.sourcesBlock(used), history: history)
        while built == nil && !used.isEmpty {
            used.removeLast()
            built = await buildPrompt(context: context, system: system + Self.sourcesBlock(used), history: history)
        }
        if used.count < sources.count, let i = messages.firstIndex(where: { $0.id == replyID }) {
            messages[i].sources = used.isEmpty ? nil : used
        }
        guard let built else {
            setReply(replyID, "That message is too long for this phone's memory. Please shorten it and try again.")
            if let index = messages.firstIndex(where: { $0.id == replyID }) { messages[index].isNotice = true }
            return
        }
        memoryStartID = built.firstID

        let promptTokens = await context.token_count(text: built.prompt)
        Diagnostics.mark("BEGIN reply (\(promptTokens)-token prompt, \(history.count) messages)")
        let t_start = DispatchTime.now().uptimeNanoseconds
        await context.completion_init(text: built.prompt)
        let t_first = DispatchTime.now().uptimeNanoseconds
        Diagnostics.mark("prompt read in \(String(format: "%.1f", Double(t_first - t_start) / NS_PER_S)) s")

        var reply = ""
        var pending = ""
        var nTokens = 0
        var lastFlush = t_first

        let tokenCap = briefAnswers ? briefReplyTokenCap : Int.max
        var hitCap = false
        while await !context.is_done, !stopRequested {
            pending += await context.completion_loop()
            nTokens += 1
            if nTokens >= tokenCap { hitCap = true; break }

            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastFlush >= streamFlushInterval {
                reply += pending
                pending = ""
                lastFlush = now
                if Self.trimAtTurnMarker(&reply) { break }
                setReply(replyID, Self.visibleText(reply))
            }
        }
        reply += pending
        _ = Self.trimAtTurnMarker(&reply)
        let t_end = DispatchTime.now().uptimeNanoseconds
        await context.clear()

        var finalText = Self.visibleText(reply)
        if hitCap && !stopRequested { finalText += " …\n\n(Shortened to save battery. Ask \"continue\" or turn off Brief Answers in Settings.)" }
        if stopRequested { finalText += finalText.isEmpty ? "(Stopped)" : " …(stopped)" }
        setReply(replyID, finalText)

        let secondsToFirst = Double(t_first - t_start) / NS_PER_S
        let tokensPerSecond = Double(nTokens) / max(Double(t_end - t_first) / NS_PER_S, 0.001)
        lastStats = String(format: "%.1f tok/s, first word after %.1f s", tokensPerSecond, secondsToFirst)
        Diagnostics.mark("END reply (\(nTokens) tokens, \(lastStats ?? ""))")
    }

    /// Hides a model's private reasoning (<think>…</think>, used by Qwen 3.x) from the chat.
    private static func visibleText(_ text: String) -> String {
        var out = text
        while let open = out.range(of: "<think>") {
            if let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts the reply at a leaked chat-template marker (the model started a new turn).
    private static func trimAtTurnMarker(_ text: inout String) -> Bool {
        for marker in ["<|im_end|>", "<|im_start|>", "<|endoftext|>", "<end_of_turn>", "<start_of_turn>", "<|eot_id|>", "<|start_header_id|>"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
                return true
            }
        }
        return false
    }

    private func setReply(_ id: UUID, _ text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        scrollTick += 1
    }

    func conversationText() -> String {
        messages.filter { !$0.text.isEmpty }
            .map { "\($0.role == .user ? "You" : "Assistant"): \($0.text)" }
            .joined(separator: "\n\n")
    }

    private func applyThreads() {
        guard let llamaContext else { return }
        let generation = generationThreads, batch = promptThreads
        Task { await llamaContext.set_threads(generation: generation, batch: batch) }
    }

    /// Tries 2, 3, 4 and 6 threads on the loaded model and keeps the fastest settings.
    func tuneThreads() async {
        guard let llamaContext, !isGenerating, !isTuning else { return }
        isTuning = true
        isGenerating = true // blocks sending and model switching while measuring
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isTuning = false
            isGenerating = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        Diagnostics.mark("BEGIN speed test")
        await llamaContext.set_threads(generation: 4, batch: 4)
        _ = await llamaContext.measure_speed(pp: 16, tg: 4) // warm up caches and clocks

        var lines: [String] = []
        var bestWrite = (threads: generationThreads, speed: 0.0)
        var bestRead = (threads: promptThreads, speed: 0.0)
        for threads in [2, 3, 4, 6] {
            tuningReport = "Testing \(threads) threads…"
            await llamaContext.set_threads(generation: threads, batch: threads)
            let speed = await llamaContext.measure_speed(pp: 64, tg: 24)
            lines.append(String(format: "%d threads: write %.1f tok/s, read %.0f tok/s", threads, speed.write, speed.read))
            if speed.write > bestWrite.speed { bestWrite = (threads, speed.write) }
            if speed.read > bestRead.speed { bestRead = (threads, speed.read) }
        }
        generationThreads = bestWrite.threads
        promptThreads = bestRead.threads
        await llamaContext.set_threads(generation: generationThreads, batch: promptThreads)
        lines.append("Using \(generationThreads) threads for writing, \(promptThreads) for reading.")
        tuningReport = lines.joined(separator: "\n")
        messageLog += "Speed test (\(loadedModelName ?? "model")):\n" + tuningReport! + "\n"
        Diagnostics.mark("END speed test: write \(generationThreads), read \(promptThreads)")
    }

    func bench() async {
        guard let llamaContext else {
            return
        }

        messageLog += "\n"
        messageLog += "Running benchmark...\n"
        messageLog += "Model info: "
        messageLog += await llamaContext.model_info() + "\n"

        let t_start = DispatchTime.now().uptimeNanoseconds
        let _ = await llamaContext.bench(pp: 8, tg: 4, pl: 1) // heat up
        let t_end = DispatchTime.now().uptimeNanoseconds

        let t_heat = Double(t_end - t_start) / NS_PER_S
        messageLog += "Heat up time: \(t_heat) seconds, please wait...\n"

        // if more than 5 seconds, then we're probably running on a slow device
        if t_heat > 5.0 {
            messageLog += "Heat up time is too long, aborting benchmark\n"
            return
        }

        let result = await llamaContext.bench(pp: 512, tg: 128, pl: 1, nr: 3)

        messageLog += "\(result)"
        messageLog += "\n"
    }

    func clear() async {
        guard let llamaContext else {
            return
        }

        await llamaContext.clear()
        messageLog = ""
    }
}

import SwiftUI
import SafariServices
import PhotosUI

struct ContentView: View {
    @StateObject var llamaState = LlamaState()
    @State private var draft = ""
    @State private var showingSettings = false
    @State private var showingChats = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ChatTranscript(llamaState: llamaState, onChooseModel: { showingSettings = true })
                Divider()
                ChatInputBar(
                    text: $draft,
                    isGenerating: llamaState.isGenerating,
                    hasModel: llamaState.hasModel,
                    canAttach: llamaState.canSendPhotos,
                    image: $llamaState.attachedImage,
                    onSend: send,
                    onStop: llamaState.stopGenerating
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Pocket Assistant")
                            .font(.headline)
                        Text(llamaState.piActive ? "\(llamaState.piStatus?.modelName ?? "") on the Pi"
                             : llamaState.isLoadingModel ? "Loading model…" : (llamaState.loadedModelName ?? "No model loaded"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showingChats = true }) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .imageScale(.large)
                            .accessibility(label: Text("Chats"))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: llamaState.newChat) {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                        .disabled(llamaState.messages.isEmpty || llamaState.isGenerating)

                        Button(action: { UIPasteboard.general.string = llamaState.conversationText() }) {
                            Label("Copy Conversation", systemImage: "doc.on.doc")
                        }
                        .disabled(llamaState.messages.isEmpty)

                        Button(action: { showingSettings = true }) {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.large)
                            .accessibility(label: Text("Menu"))
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(llamaState: llamaState)
            }
            // A second .sheet on the same view is ignored on iOS 14, so this one hangs off the transcript.
            .background(EmptyView().sheet(isPresented: $showingChats) {
                ChatListView(llamaState: llamaState)
            })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        // Look for the kit's Pi now and then (it may come into Wi-Fi range at any time).
        .onAppear { Task { await llamaState.refreshPi() } }
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in
            if !llamaState.isGenerating { Task { await llamaState.refreshPi() } }
        }
    }

    private func send() {
        llamaState.send(draft)
        draft = ""
    }
    struct DrawerView: View {

        @ObservedObject var llamaState: LlamaState
        @State private var showingHelp = false
        func delete(at offsets: IndexSet) {
            let filenames = offsets.map { llamaState.downloadedModels[$0].filename }
            for filename in filenames {
                let fileURL = getDocumentsDirectory().appendingPathComponent(filename)
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    print("Error deleting file: \(error)")
                }
            }
            // Deleted catalog models reappear under "Download Models".
            llamaState.didDelete(filenames: filenames)
        }

        func getDocumentsDirectory() -> URL {
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            return paths[0]
        }
        var body: some View {
            List {
                if llamaState.isLoadingModel {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading model…")
                        }
                    }
                } else if let error = llamaState.modelLoadError {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section(header: Text("On This Phone"),
                        footer: Text("Tap a model to load it. Swipe left to delete it and free space.")) {
                    if llamaState.downloadedModels.isEmpty {
                        Text("No models downloaded yet")
                            .foregroundColor(.secondary)
                    }
                    ForEach(llamaState.downloadedModels) { model in
                        DownloadButton(llamaState: llamaState, modelName: model.name, modelUrl: model.url, filename: model.filename)
                    }
                    .onDelete(perform: delete)
                }
                if !llamaState.undownloadedModels.isEmpty {
                    Section(header: Text("Download Models"),
                            footer: Text("Smallest first. Download at least one model now, while you have internet: after that everything works offline. Keep this screen open until downloads finish. Free space: \(String(format: "%.1f", Double(llamaState.freeDiskBytes()) / 1e9)) GB.")) {
                        ForEach(llamaState.undownloadedModels) { model in
                            DownloadButton(llamaState: llamaState, modelName: model.name, modelUrl: model.url,
                                           filename: model.filename, sizeLabel: model.sizeLabel, isLarge: model.isLarge,
                                           blurb: model.blurb, expectedBytes: model.expectedBytes)
                        }
                    }
                }
                Section(header: Text("Custom Link"),
                        footer: Text("Paste a direct .gguf download link from Hugging Face.")) {
                    InputButton(llamaState: llamaState)
                }

            }
            .listStyle(GroupedListStyle())
            .navigationBarTitle("Model Settings", displayMode: .inline).toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Help") {
                        showingHelp = true
                    }
                }
            }.sheet(isPresented: $showingHelp) {    // Sheet for help modal
                NavigationView {
                    VStack(alignment: .leading) {
                        VStack(alignment: .leading) {
                            Text("1. Make sure the model is in GGUF Format")
                                    .padding()
                            Text("2. Copy the download link of the quantized model")
                                    .padding()
                        }
                        Spacer()
                    }
                    .navigationTitle("Help")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingHelp = false
                            }
                        }
                    }
                }
            }
        }
    }
}

private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Chat transcript

private struct ChatTranscript: View {
    @ObservedObject var llamaState: LlamaState
    let onChooseModel: () -> Void

    private let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain VStack (not Lazy): conversations are short (bounded by the phone's memory),
                // and LazyVStack's scrollTo is unreliable on iOS 14 while content grows.
                VStack(alignment: .leading, spacing: 0) {
                    if llamaState.messages.isEmpty {
                        EmptyChatView(hasModel: llamaState.hasModel,
                                      hasDownloadedModel: !llamaState.downloadedModels.isEmpty,
                                      isLoading: llamaState.isLoadingModel,
                                      questions: llamaState.quickQuestions,
                                      onAsk: { llamaState.send($0) },
                                      onChooseModel: onChooseModel)
                    }
                    ForEach(llamaState.messages) { message in
                        if message.id == llamaState.memoryStartID && message.id != llamaState.messages.first?.id {
                            MemoryDivider()
                        }
                        MessageRow(
                            message: message,
                            isPending: llamaState.isGenerating && message.id == llamaState.messages.last?.id && message.text.isEmpty,
                            phase: llamaState.replyPhase,
                            started: llamaState.replyStarted,
                            imageURL: message.imageFile.map(llamaState.imageURL)
                        )
                    }
                    Color.clear
                        .frame(height: 8)
                        .id(bottomID)
                }
            }
            .onTapGesture(perform: hideKeyboard)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onChanged { value in
                    if value.translation.height > 24 { hideKeyboard() }
                }
            )
            .onChange(of: llamaState.scrollTick) { _ in
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

// MARK: - Saved chats

private struct ChatListView: View {
    @ObservedObject var llamaState: LlamaState
    @Environment(\.presentationMode) private var presentationMode
    @State private var query = ""

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private var shown: [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return llamaState.chats }
        return llamaState.chats.filter { llamaState.chatMatches($0.id, q) }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button(action: {
                        llamaState.newChat()
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .disabled(llamaState.isGenerating)
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Search chats", text: $query)
                            .disableAutocorrection(true)
                        if !query.isEmpty {
                            Button(action: { query = "" }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                }
                Section(header: Text(llamaState.chats.isEmpty ? "" : "Saved chats"),
                        footer: Text(llamaState.chats.isEmpty
                                     ? "Conversations are kept on this phone. They'll appear here."
                                     : "Tap a chat to continue it. Swipe left to delete.")) {
                    ForEach(shown) { chat in
                        Button(action: {
                            llamaState.openChat(chat.id)
                            presentationMode.wrappedValue.dismiss()
                        }) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(chat.title).font(.headline).lineLimit(1)
                                    if chat.id == llamaState.currentChat {
                                        Spacer()
                                        Text("Open").font(.caption).foregroundColor(.accentColor)
                                    }
                                }
                                if !chat.preview.isEmpty {
                                    Text(chat.preview).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                                }
                                Text("\(Self.dateFormatter.string(from: chat.updated)) · \(chat.count) messages")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .foregroundColor(.primary)
                        .disabled(llamaState.isGenerating && chat.id != llamaState.currentChat)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { shown[$0].id }
                        ids.forEach(llamaState.deleteChat)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isPending: Bool
    var phase: String? = nil
    var started: Date? = nil
    var imageURL: URL? = nil
    @State private var now = Date()
    @State private var openSource: SourceRef?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : "Assistant")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            if let imageURL, let image = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220, alignment: .leading)
                    .cornerRadius(10)
            }
            if isPending {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(phase ?? "Thinking…")
                        .font(.body)
                        .foregroundColor(.secondary)
                    if let started {
                        let s = max(0, Int(now.timeIntervalSince(started)))
                        Text(String(format: "%d:%02d", s / 60, s % 60))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
            } else if message.role == .assistant && !message.isNotice {
                MarkdownText(text: message.text)
                    .font(.body)
                    .lineSpacing(4)
            } else {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(message.isNotice ? .secondary : .primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if message.role == .assistant, let sources = message.sources, !sources.isEmpty, !isPending {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From the library").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    ForEach(sources) { source in
                        Button(action: { openSource = source }) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("[\(source.id)]").font(.caption).foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(source.title).font(.subheadline).foregroundColor(.accentColor).lineLimit(2)
                                    Text(source.detail).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
                .padding(.top, 4)
            }
            if message.role == .assistant, let by = message.answeredBy, !isPending, !message.isNotice {
                Text(by).font(.caption2).foregroundColor(.secondary)
            }
        }
        .sheet(item: $openSource) { source in
            if !source.url.isEmpty, let url = URL(string: source.url) {
                SafariView(url: url)
            } else {
                SourceTextView(source: source)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(message.role == .user ? Color.accentColor.opacity(0.10) : Color.clear)
        .contextMenu {
            Button(action: { UIPasteboard.general.string = message.text }) {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

private struct EmptyChatView: View {
    let hasModel: Bool
    let hasDownloadedModel: Bool
    let isLoading: Bool
    let questions: [String]
    let onAsk: (String) -> Void
    let onChooseModel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if hasModel {
                Text("What do you need help with?")
                    .font(.title3)
                    .fontWeight(.semibold)
                VStack(spacing: 8) {
                    ForEach(questions, id: \.self) { question in
                        Button(action: { onAsk(question) }) {
                            Text(question)
                                .font(.body)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                        }
                    }
                }
                Text("Works without internet. Or type your own question below.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLoading {
                ProgressView()
                Text("Loading model…")
                    .font(.title3)
                    .fontWeight(.semibold)
            } else {
                Image(systemName: hasDownloadedModel ? "cpu" : "square.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text(hasDownloadedModel ? "No model loaded" : "Get ready before you need it")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(hasDownloadedModel
                     ? "Choose a model to start. Everything runs on this phone."
                     : "Download a model now, while you have internet. After that, the assistant works with no signal at all.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(hasDownloadedModel ? "Choose a Model" : "Download a Model", action: onChooseModel)
                    .font(.headline)
                    .padding(.top, 4)
            }
            Text("AI answers can be wrong. If you can reach emergency services, contact them first.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 32)
    }
}

private struct MemoryDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color(.separator)).frame(height: 1)
            Text("Older messages are no longer remembered")
                .font(.caption2)
                .foregroundColor(.secondary)
                .layoutPriority(1)
            Rectangle().fill(Color(.separator)).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Input bar

private struct InputHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ChatInputBar: View {
    @Binding var text: String
    let isGenerating: Bool
    let hasModel: Bool
    var canAttach: Bool = false
    @Binding var image: UIImage?
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var textHeight: CGFloat = 0
    @State private var choosingSource = false
    @State private var picker: PickerKind?
    private let minHeight: CGFloat = 38
    private let maxHeight: CGFloat = 132 // about five lines at the default text size

    private var canSend: Bool {
        hasModel && !isGenerating && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (canAttach && image != nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        if canAttach, let image {
            HStack(spacing: 8) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipped().cornerRadius(8)
                Text("Photo goes with your next message").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(action: { self.image = nil }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .accessibility(label: Text("Remove photo"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        HStack(alignment: .bottom, spacing: 8) {
            if canAttach {
                Button(action: { choosingSource = true }) {
                    Image(systemName: "camera.fill").font(.system(size: 22))
                }
                .disabled(isGenerating)
                .accessibility(label: Text("Add a photo"))
                .padding(.bottom, 7)
                .actionSheet(isPresented: $choosingSource) {
                    ActionSheet(title: Text("Add a photo for the Pi's model"), buttons: [
                        .default(Text("Take Photo")) { picker = .camera },
                        .default(Text("Choose from Library")) { picker = .library },
                        .cancel(),
                    ])
                }
                .sheet(item: $picker) { kind in
                    if kind == .camera {
                        CameraPicker(image: $image).edgesIgnoringSafeArea(.all)
                    } else {
                        LibraryPicker(image: $image)
                    }
                }
            }
            ZStack(alignment: .topLeading) {
                // Hidden copy of the text, measured to grow the editor (TextEditor can't self-size on iOS 14).
                Text(text.isEmpty ? " " : text + " ")
                    .font(.body)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.clear)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: InputHeightKey.self, value: geo.size.height)
                    })
                TextEditor(text: $text)
                    .font(.body)
                    .disabled(!hasModel)
                if text.isEmpty {
                    Text(hasModel ? (canAttach ? "Message, or add a photo" : "Message") : "Load a model to start")
                        .font(.body)
                        .foregroundColor(Color(.placeholderText))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: min(max(textHeight, minHeight), maxHeight))
            .clipped()
            .padding(.horizontal, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 1)
            )
            .onPreferenceChange(InputHeightKey.self) { textHeight = $0 }

            Button(action: isGenerating ? onStop : onSend) {
                Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(!isGenerating && !canSend)
            .accessibility(label: Text(isGenerating ? "Stop" : "Send"))
            .padding(.bottom, 3)
        }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var llamaState: LlamaState
    @Environment(\.presentationMode) private var presentationMode

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (build \(build))"
    }

    var body: some View {
        NavigationView {
            Form {
                KitPiSection(llamaState: llamaState)

                Section(header: Text("Model on This Phone")) {
                    HStack {
                        Text("Loaded")
                        Spacer()
                        Text(llamaState.isLoadingModel ? "Loading…" : (llamaState.loadedModelName ?? "None"))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    NavigationLink(destination: ContentView.DrawerView(llamaState: llamaState)) {
                        Text("Download or Switch Model")
                    }
                    .disabled(llamaState.isGenerating)
                }

                Section(footer: Text("Short replies use less battery and arrive sooner. Ask \"continue\" for more.")) {
                    Toggle("Brief Answers", isOn: $llamaState.briefAnswers)
                }

                Section(header: Text("Assistant Instructions"),
                        footer: Text("Sent with every message. Shorter instructions leave more room for the assistant to remember the conversation.")) {
                    TextEditor(text: $llamaState.systemPrompt)
                        .font(.callout)
                        .frame(minHeight: 120)
                    Button("Reset to Default", action: llamaState.resetSystemPrompt)
                        .disabled(llamaState.systemPrompt == llamaState.defaultSystemPrompt)
                }

                Section(header: Text("Performance"),
                        footer: Text("The Speed Test tries 2, 3, 4 and 6 threads on the loaded model (about a minute) and keeps the fastest. Fewer threads also use less battery.")) {
                    HStack {
                        Text("Last reply")
                        Spacer()
                        Text(llamaState.lastStats ?? "—")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Stepper("Threads for writing: \(llamaState.generationThreads)",
                            value: $llamaState.generationThreads, in: 1...6)
                        .disabled(llamaState.isGenerating)
                    Stepper("Threads for reading: \(llamaState.promptThreads)",
                            value: $llamaState.promptThreads, in: 1...6)
                        .disabled(llamaState.isGenerating)
                    Button(llamaState.isTuning ? "Testing…" : "Run Speed Test") {
                        Task { await llamaState.tuneThreads() }
                    }
                    .disabled(!llamaState.hasLocalModel || llamaState.isGenerating)
                    if let report = llamaState.tuningReport {
                        Text(report)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Diagnostics"),
                        footer: Text("A step-by-step record kept on the phone, with free memory at each step. If the app closes unexpectedly, copy this and send it along.")) {
                    if let note = llamaState.previousCrashNote {
                        Text(note)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Copy Diagnostics") { UIPasteboard.general.string = Diagnostics.recent(80) }
                }

                Section(header: Text("Activity Log")) {
                    Text(llamaState.messageLog.isEmpty ? "No activity yet." : llamaState.messageLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy Log") { UIPasteboard.general.string = llamaState.messageLog }
                        .disabled(llamaState.messageLog.isEmpty)
                }
            }
            .navigationBarTitle("Settings", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

// MARK: - Markdown

/// Renders the markdown small models like to write: headings, bullet and numbered lists,
/// **bold**, *italic*, `code`, code blocks, quotes, rules and simple tables. Built from Text
/// concatenation because iOS 14's SwiftUI has no markdown support (AttributedString is iOS 15+).
/// Unfinished markup while a reply streams in just shows as plain text until it closes.
private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                Markdown.view(for: block)
            }
        }
    }
}

private enum Markdown {
    enum Block {
        case paragraph(String)
        case heading(Int, String)
        case item(indent: Int, marker: String, text: String)
        case code(String)
        case quote(String)
        case rule
        case table([[String]])
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        var table: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushTable() {
            if !table.isEmpty { out.append(.table(table)); table = [] }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if line.hasPrefix("```") { out.append(.code(code!.joined(separator: "\n"))); code = nil }
                else { code!.append(raw) }
                continue
            }
            if line.hasPrefix("```") { flushParagraph(); flushTable(); code = []; continue }
            if line.hasPrefix("|") {
                flushParagraph()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // Skip the |---|:---:| separator row.
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if line.isEmpty { flushParagraph(); continue }
            if line.count >= 3, Set(line.replacingOccurrences(of: " ", with: "")).count == 1,
               let c = line.first, "-*_".contains(c) {
                flushParagraph(); out.append(.rule); continue
            }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
               line[hashes] == " " {
                flushParagraph()
                let level = line.distance(from: line.startIndex, to: hashes)
                out.append(.heading(level, String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            let indent = (raw.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if let first = line.first, "-*+•".contains(first), line.dropFirst().first == " " {
                flushParagraph()
                out.append(.item(indent: indent, marker: "•", text: String(line.dropFirst(2))))
                continue
            }
            if let dot = line.firstIndex(where: { !$0.isNumber }), dot != line.startIndex,
               ".)".contains(line[dot]), line[line.index(after: dot)...].first == " " {
                flushParagraph()
                out.append(.item(indent: indent, marker: String(line[...dot]),
                                 text: String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                out.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            paragraph.append(line)
        }
        if let code { out.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return out
    }

    static func view(for block: Block) -> AnyView {
        switch block {
        case .paragraph(let s):
            return AnyView(inline(s).fixedSize(horizontal: false, vertical: true))
        case .heading(let level, let s):
            return AnyView(inline(s).font(level <= 2 ? .title3 : .headline).fontWeight(.semibold)
                .padding(.top, 4).fixedSize(horizontal: false, vertical: true))
        case .item(let indent, let marker, let s):
            return AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundColor(.secondary)
                    .frame(minWidth: marker == "•" ? 12 : 22, alignment: .trailing)
                inline(s).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, CGFloat(min(indent, 4)) * 16))
        case .code(let s):
            return AnyView(Text(s).font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12)).cornerRadius(8))
        case .quote(let s):
            return AnyView(HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3)
                inline(s).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            })
        case .rule:
            return AnyView(Divider().padding(.vertical, 4))
        case .table(let rows):
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell).font(.callout).fontWeight(index == 0 ? .semibold : .regular)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 6)
                    if index < rows.count - 1 { Divider() }
                }
            }.padding(.horizontal, 10).background(Color.secondary.opacity(0.08)).cornerRadius(8))
        }
    }

    /// **bold** / __bold__, *italic* / _italic_ and `code` within a line.
    static func inline(_ s: String) -> Text {
        let chars = Array(s)
        var out = Text("")
        var buffer = ""
        var bold = false
        var italic: Character? = nil
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var t = Text(buffer)
            if bold { t = t.bold() }
            if italic != nil { t = t.italic() }
            out = out + t
            buffer = ""
        }
        func closes(_ marker: [Character], from start: Int) -> Bool {
            guard start < chars.count else { return false }
            var j = start
            while j + marker.count <= chars.count {
                if Array(chars[j..<(j + marker.count)]) == marker { return j > start }
                j += 1
            }
            return false
        }

        while i < chars.count {
            let c = chars[i]
            let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
            let prev: Character = i > 0 ? chars[i - 1] : " "
            if c == "`", let end = chars[(i + 1)...].firstIndex(of: "`") {
                flush()
                out = out + Text(String(chars[(i + 1)..<end])).font(.system(.body, design: .monospaced))
                i = end + 1
                continue
            }
            if (c == "*" || c == "_"), next == c, bold || closes([c, c], from: i + 2) {
                flush(); bold.toggle(); i += 2
                continue
            }
            if c == "*" || c == "_" {
                if let open = italic, open == c, !prev.isWhitespace {
                    flush(); italic = nil; i += 1
                    continue
                }
                if italic == nil, !next.isWhitespace, !(c == "_" && (prev.isLetter || prev.isNumber)),
                   closes([c], from: i + 1) {
                    flush(); italic = c; i += 1
                    continue
                }
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }
}


// MARK: - Photos and links

private enum PickerKind: Identifiable { case camera, library; var id: Int { self == .camera ? 0 : 1 } }

/// The camera (UIImagePickerController); falls back to the library when there's no camera.
private struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.presentationMode.wrappedValue.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

/// The photo library (PHPicker: no photo-library permission needed).
private struct LibraryPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: LibraryPicker
        init(_ parent: LibraryPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentationMode.wrappedValue.dismiss()
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async { self.parent.image = object as? UIImage }
            }
        }
    }
}

/// In-app browser for library sources (pages served by the Pi).
private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}


// MARK: - Kit Pi settings

private struct KitPiSection: View {
    @ObservedObject var llamaState: LlamaState
    @State private var hostDraft = ""

    private var statusText: String {
        if let swapping = llamaState.piSwapping { return "Switching to \(swapping)… (about a minute)" }
        if let s = llamaState.piStatus {
            return "Connected · \(s.modelName)" + (s.vision ? " · sees photos" : "")
                + (s.booksOK ? " · books" : "")
        }
        return llamaState.piChecking ? "Looking for the Pi…" : "Not found"
    }

    var body: some View {
        Section(header: Text("Kit Pi"),
                footer: Text("Join the Pi's Wi-Fi hotspot in Settings › Wi-Fi. When it's in reach, answers come from the Pi's larger model, which can look at photos, and every question is first looked up in the kit's library (books and encyclopedias); the passages used are listed under the answer. Without the Pi, the model on this phone answers.")) {
            HStack {
                Image(systemName: llamaState.piStatus != nil ? "checkmark.circle.fill" : "wifi.exclamationmark")
                    .foregroundColor(llamaState.piStatus != nil ? .green : .secondary)
                Text(statusText).lineLimit(2)
                Spacer()
                if llamaState.piChecking { ProgressView() }
            }
            if let note = llamaState.piNote {
                Text(note).font(.footnote).foregroundColor(.red)
            }
            Toggle("Answer with the Pi when connected", isOn: $llamaState.usePi)
            Toggle("Look things up in the library first", isOn: $llamaState.useLibrary)
            if let status = llamaState.piStatus, !status.models.isEmpty {
                Menu {
                    ForEach(status.models, id: \.self) { file in
                        Button(action: { Task { await llamaState.swapPiModel(file) } }) {
                            if (status.modelFile as NSString).lastPathComponent == file {
                                Label(KitPi.displayName(file), systemImage: "checkmark")
                            } else {
                                Text(KitPi.displayName(file))
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Pi model")
                        Spacer()
                        Text(status.modelName).foregroundColor(.secondary)
                    }
                }
                .disabled(llamaState.piSwapping != nil || llamaState.isGenerating)
            }
            if llamaState.piStatus != nil && !(llamaState.piStatus?.booksOK ?? false) {
                Text("The Pi's book library isn't answering; encyclopedia lookups still work.")
                    .font(.footnote).foregroundColor(.orange)
            }
            HStack {
                Text("Address")
                TextField(KitPi.defaultHost, text: $hostDraft, onCommit: {
                    llamaState.piHost = hostDraft.trimmingCharacters(in: .whitespaces)
                    Task { await llamaState.refreshPi() }
                })
                .multilineTextAlignment(.trailing)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
            }
            Button("Check Again") {
                llamaState.piHost = hostDraft.trimmingCharacters(in: .whitespaces)
                Task { await llamaState.refreshPi() }
            }
            .disabled(llamaState.piChecking)
        }
        .onAppear { hostDraft = llamaState.piHost }
    }
}


/// A book passage from the Pi's library, read in the app.
private struct SourceTextView: View {
    let source: SourceRef
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(source.title).font(.title3).fontWeight(.semibold)
                    Text(source.detail).font(.subheadline).foregroundColor(.secondary)
                    Divider()
                    Text(source.readText ?? source.text)
                        .font(.system(.body, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }
            .navigationTitle("[\(source.id)] Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

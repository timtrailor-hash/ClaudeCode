import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var ws: WebSocketService
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @State private var autoScroll = true
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingImages: [PendingImage] = []
    @State private var isUploading = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    struct PendingImage: Identifiable {
        let id = UUID()
        let thumbnail: UIImage
        let data: Data
        let filename: String
        let isFile: Bool  // true for non-image files (PDFs, text, etc.)
        var serverPath: String?

        init(thumbnail: UIImage, data: Data, filename: String = "image.jpg", isFile: Bool = false) {
            self.thumbnail = thumbnail
            self.data = data
            self.filename = filename
            self.isFile = isFile
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages — ignores keyboard so only the input bar moves up
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(ws.messages) { message in
                                VStack(spacing: 4) {
                                    ForEach(message.toolUse) { tool in
                                        ToolIndicator(content: tool.content)
                                    }

                                    MessageBubble(message: message)

                                    if let cost = message.cost, message.role == .assistant {
                                        Text(cost)
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(hex: "#666666"))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 16)
                                    }
                                }
                            }

                            // Invisible anchor — also detects when user scrolls away from bottom
                            GeometryReader { geo in
                                Color.clear
                                    .preference(key: BottomVisibleKey.self,
                                                value: geo.frame(in: .named("chatScroll")).maxY)
                            }
                            .frame(height: 1)
                            .id("bottom")
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    }
                    .coordinateSpace(name: "chatScroll")
                    .scrollDismissesKeyboard(.never)
                    .onPreferenceChange(BottomVisibleKey.self) { bottomY in
                        // If the bottom anchor is well below the visible area,
                        // user has scrolled up — disable auto-scroll.
                        // If it's near the bottom edge, re-enable.
                        if let bottomY {
                            let screenH = UIScreen.main.bounds.height
                            autoScroll = bottomY < screenH + 100
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !autoScroll {
                            Button {
                                autoScroll = true
                                withAnimation {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(Color(hex: "#C9A96E"))
                                    .background(Circle().fill(Color(hex: "#1A1A2E")))
                                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            }
                            .padding(.trailing, 12)
                            .padding(.bottom, 8)
                        }
                    }
                    .onChange(of: ws.messages.last?.content) { _, _ in
                        if autoScroll {
                            proxy.scrollTo("bottom")
                        }
                    }
                    .onChange(of: ws.messages.count) { _, _ in
                        if autoScroll {
                            proxy.scrollTo("bottom")
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("bottom")
                    }
                }

                // Bottom bar — outside ScrollView so taps are never intercepted
                bottomBar
            }
            .background(Color(hex: "#1A1A2E"))
            .navigationTitle("Claude Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "#16213E"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New") {
                        ws.newSession()
                    }
                    .foregroundColor(Color(hex: "#C9A96E"))
                    .font(.system(size: 14, weight: .medium))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button {
                        inputFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "#C9A96E"))
                    }
                    Spacer()
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 5, matching: .images)
            .onChange(of: selectedPhotos) { _, newItems in
                Task { await loadSelectedPhotos(newItems) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    addCapturedImage(image)
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showFilePicker) {
                FileImagePicker { data, filename in
                    addFileData(data, filename: filename)
                }
            }
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    private var hasInput: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusColor: Color {
        switch ws.connectionState {
        case .connected: return .green
        case .disconnected: return .red
        case .reconnecting: return .yellow
        }
    }

    // Bottom bar: working indicator + permission prompt + pending images + input
    // Lives outside ScrollView in the VStack so button taps are never intercepted
    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            // Working indicator with elapsed time and activity
            if ws.isGenerating {
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "#C9A96E")))
                            .scaleEffect(0.7)

                        if let start = ws.generationStartTime {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let elapsed = Int(context.date.timeIntervalSince(start))
                                let min = elapsed / 60
                                let sec = elapsed % 60
                                Text(min > 0 ? "Working \(min)m \(sec)s" : "Working \(sec)s")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Color(hex: "#C9A96E"))
                            }
                        } else {
                            Text("Working...")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#C9A96E"))
                        }
                    }

                    if !ws.lastActivity.isEmpty {
                        Text(ws.lastActivity)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(hex: "#88AA88"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(hex: "#1A2A1A"))
            }

            // Permission prompt — Claude needs user approval to use a tool
            if let perm = ws.pendingPermission {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#C9A96E"))
                        Text("Permission Required")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: "#C9A96E"))
                        if ws.permissionQueue.count > 1 {
                            Text("+\(ws.permissionQueue.count - 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(hex: "#1A1A2E"))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: "#C9A96E"))
                                .cornerRadius(8)
                        }
                    }

                    Text(perm.summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: "#E0E0E0"))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Button {
                            ws.denyPermission(perm.id)
                        } label: {
                            Text("Deny")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(hex: "#EE5555"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color(hex: "#3A1A1A"))
                                .cornerRadius(8)
                        }

                        Button {
                            ws.allowPermission(perm.id)
                        } label: {
                            Text("Allow")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(hex: "#1A1A2E"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color(hex: "#C9A96E"))
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(hex: "#1A2A3A"))
                .cornerRadius(12)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

            // Pending attachment thumbnails
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingImages) { img in
                            ZStack(alignment: .topTrailing) {
                                if img.isFile {
                                    // File attachment — show icon and filename
                                    VStack(spacing: 2) {
                                        Image(systemName: fileIcon(for: img.filename))
                                            .font(.system(size: 24))
                                            .foregroundColor(Color(hex: "#C9A96E"))
                                        Text(img.filename)
                                            .font(.system(size: 8))
                                            .foregroundColor(Color(hex: "#E0E0E0"))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(width: 60, height: 60)
                                    .background(Color(hex: "#2A2A4A"))
                                    .cornerRadius(8)
                                } else {
                                    Image(uiImage: img.thumbnail)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .cornerRadius(8)
                                        .clipped()
                                }

                                Button {
                                    pendingImages.removeAll { $0.id == img.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.6)))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(Color(hex: "#16213E"))
            }

            // Input area
            HStack(alignment: .bottom, spacing: 6) {
                // Attach button — camera, photo library, screenshot, or file
                Menu {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }

                    Button {
                        captureScreenshot()
                    } label: {
                        Label("Screenshot", systemImage: "camera.viewfinder")
                    }

                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choose File", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "#C9A96E"))
                        .frame(width: 36, height: 42)
                }

                TextField("Ask anything...", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(hex: "#2A2A4A"))
                    .cornerRadius(20)
                    .foregroundColor(Color(hex: "#E0E0E0"))
                    .focused($inputFocused)

                // Send or stop — uses onTapGesture instead of Button to
                // prevent iOS first-responder change from eating the tap
                if ws.isGenerating && !hasInput {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(Color(hex: "#EE5555"))
                        .foregroundColor(.white)
                        .clipShape(Circle())
                        .contentShape(Circle())
                        .onTapGesture { ws.cancelGeneration() }
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(canSend ? Color(hex: "#C9A96E") : Color(hex: "#555555"))
                        .foregroundColor(canSend ? Color(hex: "#1A1A2E") : Color(hex: "#888888"))
                        .clipShape(Circle())
                        .contentShape(Circle())
                        .onTapGesture { if canSend { send() } }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(hex: "#16213E"))
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }

        let message = text.isEmpty ? "Here are the attached images." : text
        let images = pendingImages

        inputText = ""
        pendingImages = []
        selectedPhotos = []

        if images.isEmpty {
            ws.sendMessage(message)
        } else {
            Task {
                let paths = await uploadImages(images)
                ws.sendMessage(message, imagePaths: paths)
            }
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                let thumb = uiImage.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? uiImage
                // Compress to JPEG for upload
                let jpegData = uiImage.jpegData(compressionQuality: 0.8) ?? data
                await MainActor.run {
                    pendingImages.append(PendingImage(thumbnail: thumb, data: jpegData))
                }
            }
        }
        // Clear selection so picker can be used again
        await MainActor.run {
            selectedPhotos = []
        }
    }

    private func addCapturedImage(_ image: UIImage) {
        let thumb = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        let jpegData = image.jpegData(compressionQuality: 0.8) ?? Data()
        pendingImages.append(PendingImage(thumbnail: thumb, data: jpegData))
    }

    private func addFileData(_ data: Data, filename: String) {
        // Try to treat as image first
        if let image = UIImage(data: data) {
            let thumb = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
            let jpegData = image.jpegData(compressionQuality: 0.8) ?? data
            pendingImages.append(PendingImage(thumbnail: thumb, data: jpegData, filename: filename))
        } else {
            // Non-image file — use placeholder thumbnail
            let placeholder = UIImage(systemName: "doc.fill") ?? UIImage()
            pendingImages.append(PendingImage(thumbnail: placeholder, data: data, filename: filename, isFile: true))
        }
    }

    private func captureScreenshot() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first else { return }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let thumb = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        let jpegData = image.jpegData(compressionQuality: 0.8) ?? Data()
        pendingImages.append(PendingImage(thumbnail: thumb, data: jpegData, filename: "screenshot.jpg"))
    }

    private func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "txt", "md", "log": return "doc.text"
        case "csv", "xlsx", "xls": return "tablecells"
        case "json", "xml", "yaml", "yml": return "curlybraces"
        case "py", "swift", "js", "ts", "html", "css": return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz": return "doc.zipper"
        default: return "doc.fill"
        }
    }

    private func uploadImages(_ images: [PendingImage]) async -> [String] {
        var paths: [String] = []
        let baseURL = "http://\(ws.serverHost)/upload"
        guard let url = URL(string: baseURL) else { return paths }

        for img in images {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(UserDefaults.standard.string(forKey: "authToken") ?? "")", forHTTPHeaderField: "Authorization")

            let boundary = UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            let mimeType = img.isFile ? mimeTypeFor(filename: img.filename) : "image/jpeg"

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(img.filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(img.data)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body

            if let (data, _) = try? await URLSession.shared.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let path = json["path"] as? String {
                paths.append(path)
            }
        }
        return paths
    }

    private func mimeTypeFor(filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt", "md", "log": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "zip": return "application/zip"
        case "py", "swift", "js", "ts", "html", "css": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Camera Picker

struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - File Picker (any file from Files app)

struct FileImagePicker: UIViewControllerRepresentable {
    let onPick: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .image, .pdf, .plainText, .json, .xml, .commaSeparatedText,
            .data, .sourceCode, .spreadsheet, .presentation
        ])
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FileImagePicker
        init(parent: FileImagePicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url) {
                    parent.onPick(data, url.lastPathComponent)
                }
            }
        }
    }
}

// Preference key to track whether the bottom anchor is visible
private struct BottomVisibleKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

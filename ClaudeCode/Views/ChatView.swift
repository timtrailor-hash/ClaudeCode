import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var ws: WebSocketService
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @State private var autoScroll = true
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingImages: [PendingImage] = []
    @State private var isUploading = false

    struct PendingImage: Identifiable {
        let id = UUID()
        let thumbnail: UIImage
        let data: Data
        var serverPath: String?
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages
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

                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .onChange(of: ws.messages.last?.content) { _, _ in
                        if autoScroll {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

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

                // Pending image thumbnails
                if !pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingImages) { img in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: img.thumbnail)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .cornerRadius(8)
                                        .clipped()

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
                    // Attach button
                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: 5,
                        matching: .images
                    ) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                            .foregroundColor(Color(hex: "#C9A96E"))
                            .frame(width: 36, height: 42)
                    }
                    .onChange(of: selectedPhotos) { _, newItems in
                        Task { await loadSelectedPhotos(newItems) }
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
                        .onSubmit {
                            send()
                        }
                        .submitLabel(.send)

                    Button(action: {
                        if ws.isGenerating {
                            ws.cancelGeneration()
                        } else {
                            send()
                        }
                    }) {
                        Image(systemName: ws.isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(ws.isGenerating ? Color(hex: "#EE5555") : Color(hex: "#C9A96E"))
                            .foregroundColor(ws.isGenerating ? .white : Color(hex: "#1A1A2E"))
                            .clipShape(Circle())
                    }
                    .disabled(!canSend && !ws.isGenerating)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(hex: "#16213E"))
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
                    Spacer()
                    Button("Done") {
                        inputFocused = false
                    }
                    .foregroundColor(Color(hex: "#C9A96E"))
                    .font(.system(size: 15, weight: .medium))
                }
            }
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    private var statusColor: Color {
        switch ws.connectionState {
        case .connected: return .green
        case .disconnected: return .red
        case .reconnecting: return .yellow
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

    private func uploadImages(_ images: [PendingImage]) async -> [String] {
        var paths: [String] = []
        let baseURL = "http://\(ws.serverHost)/upload"
        guard let url = URL(string: baseURL) else { return paths }

        for img in images {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"

            let boundary = UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
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
}

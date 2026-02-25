import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            if message.role == .system {
                Text(message.content)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#77AA77"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(hex: "#1A3A2A"))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {
                    // Inline images from Claude reading image files
                    if !message.imageURLs.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(message.imageURLs, id: \.self) { urlString in
                                if let url = URL(string: urlString) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(maxWidth: 280, maxHeight: 200)
                                                .cornerRadius(8)
                                        case .failure:
                                            HStack(spacing: 4) {
                                                Image(systemName: "photo.badge.exclamationmark")
                                                Text("Image failed to load")
                                                    .font(.system(size: 11))
                                            }
                                            .foregroundColor(Color(hex: "#888888"))
                                        case .empty:
                                            ProgressView()
                                                .frame(width: 100, height: 60)
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    }

                    if message.role == .assistant && !message.isStreaming && !message.content.isEmpty {
                        MarkdownText(content: message.content)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    } else {
                        Text(message.content + (message.isStreaming ? "\u{2588}" : ""))
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#E0E0E0"))
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
                .background(
                    message.role == .user
                        ? Color(hex: "#0A3D62")
                        : Color(hex: "#2A2A4A")
                )
                .cornerRadius(16, corners: message.role == .user
                    ? [.topLeft, .topRight, .bottomLeft]
                    : [.topLeft, .topRight, .bottomRight])

                // Timestamp
                if !message.isStreaming {
                    Text(Self.timeFormatter.string(from: message.timestamp))
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#555555"))
                        .padding(.top, 2)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

// Custom corner radius extension
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorners(radius: radius, corners: corners))
    }
}

struct RoundedCorners: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

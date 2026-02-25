import SwiftUI

struct ToolIndicator: View {
    let content: String
    @State private var expanded = false

    var body: some View {
        Button(action: { expanded.toggle() }) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color(hex: "#C9A96E"))
                    .frame(width: 2)

                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#C9A96E"))

                Text(expanded ? content : String(content.prefix(60)) + (content.count > 60 ? "..." : ""))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(hex: "#C9A96E"))
                    .lineLimit(expanded ? nil : 1)
                    .multilineTextAlignment(.leading)

                Spacer()

                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#666666"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(hex: "#1A1A3A"))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

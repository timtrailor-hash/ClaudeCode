import SwiftUI

// MARK: - Data Models

struct PrintObject: Identifiable {
    var id: String { name }
    let name: String
    let center: CGPoint
    let polygon: [CGPoint]
    var isExcluded: Bool
    var isCurrentlyPrinting: Bool
}

// MARK: - Object Skip View

struct ObjectSkipView: View {
    @EnvironmentObject var ws: WebSocketService
    @Environment(\.dismiss) var dismiss

    @State private var objects: [PrintObject] = []
    @State private var selectedForSkip: Set<String> = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showConfirm = false
    @State private var excluding = false

    // SV08 Max bed size
    private let bedWidth: CGFloat = 500
    private let bedHeight: CGFloat = 500

    private let accent = Color(hex: "#C9A96E")
    private let bg = Color(hex: "#1A1A2E")
    private let cardBg = Color(hex: "#16213E")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading {
                    ProgressView("Loading objects...")
                        .foregroundColor(accent)
                        .padding(.top, 80)
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundColor(.red.opacity(0.7))
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#888888"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .padding(.top, 60)
                } else if objects.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 40))
                            .foregroundColor(Color(hex: "#444444"))
                        Text("No objects found")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "#888888"))
                        Text("EXCLUDE_OBJECT must be enabled\nin your slicer settings")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#666666"))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 60)
                } else {
                    // Bed map
                    bedMapView
                        .padding(16)

                    // Object list
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(objects) { obj in
                                objectRow(obj)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Action bar
                    if !selectedForSkip.isEmpty {
                        actionBar
                    }
                }
            }
            .background(bg)
            .navigationTitle("Skip Objects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(cardBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundColor(accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await fetchObjects() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(accent)
                    }
                }
            }
            .alert("Confirm Skip", isPresented: $showConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Skip \(selectedForSkip.count) Object\(selectedForSkip.count == 1 ? "" : "s")", role: .destructive) {
                    Task { await excludeSelected() }
                }
            } message: {
                Text("This will permanently skip the selected objects for the rest of this print. This cannot be undone.")
            }
        }
        .task {
            await fetchObjects()
        }
    }

    // MARK: - Bed Map

    private var bedMapView: some View {
        let mapSize: CGFloat = UIScreen.main.bounds.width - 32

        return Canvas { context, size in
            let scaleX = size.width / bedWidth
            let scaleY = size.height / bedHeight

            // Draw bed background
            let bedRect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: bedRect, cornerRadius: 8),
                        with: .color(Color(hex: "#0D1520")))

            // Draw grid
            let gridColor = Color.white.opacity(0.06)
            for i in stride(from: 0, through: bedWidth, by: 50) {
                let x = CGFloat(i) * scaleX
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
            }
            for i in stride(from: 0, through: bedHeight, by: 50) {
                let y = size.height - CGFloat(i) * scaleY
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
            }

            // Draw objects
            for obj in objects {
                let color: Color
                if obj.isExcluded {
                    color = .red.opacity(0.3)
                } else if selectedForSkip.contains(obj.name) {
                    color = .orange
                } else if obj.isCurrentlyPrinting {
                    color = .green
                } else {
                    color = .blue.opacity(0.6)
                }

                // Draw polygon
                if obj.polygon.count >= 3 {
                    var polyPath = Path()
                    let first = CGPoint(
                        x: obj.polygon[0].x * scaleX,
                        y: size.height - obj.polygon[0].y * scaleY
                    )
                    polyPath.move(to: first)
                    for pt in obj.polygon.dropFirst() {
                        polyPath.addLine(to: CGPoint(
                            x: pt.x * scaleX,
                            y: size.height - pt.y * scaleY
                        ))
                    }
                    polyPath.closeSubpath()

                    context.fill(polyPath, with: .color(color.opacity(0.3)))
                    context.stroke(polyPath, with: .color(color), lineWidth: 1.5)
                }

                // Draw center label
                let cx = obj.center.x * scaleX
                let cy = size.height - obj.center.y * scaleY
                let label = shortName(obj.name)
                context.draw(
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white),
                    at: CGPoint(x: cx, y: cy)
                )
            }
        }
        .frame(width: mapSize, height: mapSize)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { location in
            handleTap(at: location, mapSize: mapSize)
        }
    }

    // MARK: - Object Row

    private func objectRow(_ obj: PrintObject) -> some View {
        let isSelected = selectedForSkip.contains(obj.name)

        return HStack(spacing: 12) {
            // Status icon
            Image(systemName: obj.isExcluded ? "xmark.circle.fill" :
                    obj.isCurrentlyPrinting ? "printer.fill" :
                    isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(obj.isExcluded ? .red :
                    obj.isCurrentlyPrinting ? .green :
                    isSelected ? .orange : Color(hex: "#666666"))
                .font(.system(size: 20))

            VStack(alignment: .leading, spacing: 2) {
                Text(shortName(obj.name))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(obj.isExcluded ? .red.opacity(0.5) : .white)
                    .strikethrough(obj.isExcluded)

                Text("(\(Int(obj.center.x)), \(Int(obj.center.y)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "#666666"))
            }

            Spacer()

            if obj.isExcluded {
                Text("SKIPPED")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(4)
            } else if obj.isCurrentlyPrinting {
                Text("PRINTING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(12)
        .background(isSelected ? Color.orange.opacity(0.1) : cardBg)
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !obj.isExcluded else { return }
            if isSelected {
                selectedForSkip.remove(obj.name)
            } else {
                selectedForSkip.insert(obj.name)
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Text("\(selectedForSkip.count) selected")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#888888"))

            Spacer()

            Button("Clear") {
                selectedForSkip.removeAll()
            }
            .foregroundColor(Color(hex: "#888888"))

            Button {
                showConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "forward.fill")
                    Text("Skip")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.orange)
                .cornerRadius(10)
            }
            .disabled(excluding)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(cardBg)
    }

    // MARK: - Networking

    private func authedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let token = ws.authToken
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func fetchObjects() async {
        loading = true
        let urlString = "http://\(ws.serverHost)/printer-objects"
        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL"
            loading = false
            return
        }

        do {
            let request = authedRequest(url: url)
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid response"
                loading = false
                return
            }

            if let error = json["error"] as? String {
                errorMessage = error
                loading = false
                return
            }

            let currentObj = json["current_object"] as? String
            let excludedNames = json["excluded_objects"] as? [String] ?? []
            let rawObjects = json["objects"] as? [[String: Any]] ?? []

            objects = rawObjects.compactMap { obj -> PrintObject? in
                guard let name = obj["name"] as? String,
                      let center = obj["center"] as? [Double], center.count == 2 else {
                    return nil
                }
                let polygon = (obj["polygon"] as? [[Double]] ?? []).map {
                    CGPoint(x: $0[0], y: $0[1])
                }
                return PrintObject(
                    name: name,
                    center: CGPoint(x: center[0], y: center[1]),
                    polygon: polygon,
                    isExcluded: excludedNames.contains(name),
                    isCurrentlyPrinting: name == currentObj
                )
            }

            errorMessage = nil
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
        }
        loading = false
    }

    private func excludeSelected() async {
        excluding = true
        for name in selectedForSkip {
            let urlString = "http://\(ws.serverHost)/exclude-object"
            guard let url = URL(string: urlString) else { continue }

            var request = authedRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])

            _ = try? await URLSession.shared.data(for: request)

            // Mark as excluded locally
            if let idx = objects.firstIndex(where: { $0.name == name }) {
                objects[idx].isExcluded = true
            }
        }
        selectedForSkip.removeAll()
        excluding = false

        // Refresh from server
        await fetchObjects()
    }

    // MARK: - Helpers

    private func handleTap(at location: CGPoint, mapSize: CGFloat) {
        let scaleX = mapSize / bedWidth
        let scaleY = mapSize / bedHeight

        // Find closest object to tap point
        var closest: String?
        var closestDist: CGFloat = .infinity

        for obj in objects where !obj.isExcluded {
            let cx = obj.center.x * scaleX
            let cy = mapSize - obj.center.y * scaleY
            let dist = hypot(location.x - cx, location.y - cy)
            if dist < closestDist && dist < 60 {
                closestDist = dist
                closest = obj.name
            }
        }

        if let name = closest {
            if selectedForSkip.contains(name) {
                selectedForSkip.remove(name)
            } else {
                selectedForSkip.insert(name)
            }
        }
    }

    private func shortName(_ name: String) -> String {
        // Simplify object names: "ZEPHYROS-FULLSIZE_BYHOLLOWMAKER_100_.STL_ID_0_COPY_0" -> "Object 1"
        if let range = name.range(of: "ID_(\\d+)", options: .regularExpression) {
            let idStr = name[range].replacingOccurrences(of: "ID_", with: "")
            return "Object \(Int(idStr).map { $0 + 1 } ?? 0)"
        }
        // Fallback: last component
        let parts = name.split(separator: "_")
        if parts.count > 2 {
            return String(parts.suffix(3).joined(separator: " "))
        }
        return name
    }
}

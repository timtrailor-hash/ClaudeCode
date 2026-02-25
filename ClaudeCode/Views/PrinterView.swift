import SwiftUI

// MARK: - Data Models

struct PrinterStatusResponse {
    let sv08: SV08Status?
    let a1: A1Status?
    let daemon_timestamp: String?

    /// Parse top-level manually so one printer failing doesn't break the other
    init(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sv08 = nil; a1 = nil; daemon_timestamp = nil; return
        }
        daemon_timestamp = json["daemon_timestamp"] as? String

        if let sv08Json = json["sv08"],
           let sv08Data = try? JSONSerialization.data(withJSONObject: sv08Json) {
            sv08 = try? JSONDecoder().decode(SV08Status.self, from: sv08Data)
        } else {
            sv08 = nil
        }

        if let a1Json = json["a1"],
           let a1Data = try? JSONSerialization.data(withJSONObject: a1Json) {
            a1 = try? JSONDecoder().decode(A1Status.self, from: a1Data)
        } else {
            a1 = nil
        }
    }
}

struct SV08Status: Decodable {
    let state: String?
    let filename: String?
    let progress: Double?
    let print_duration: Double?
    let duration_str: String?
    let remaining_str: String?
    let bed_temp: Double?
    let bed_target: Double?
    let nozzle_temp: Double?
    let nozzle_target: Double?
    let current_layer: Int?
    let total_layers: Int?
    let speed_factor: Double?
    let live_velocity: Double?
    let alpha: Double?
    let optimal_speed_pct: Int?
    let current_speed_pct: Int?
    let eta_str: String?
    let eta_confidence: String?
    let eta_method: String?
    let camera: String?
    let thumbnail: String?
    let connection: String?
    let speed_graph: [SpeedGraphEntry]?
    let eta_history: [EtaHistoryEntry]?
}

struct A1Status: Decodable {
    let state: String?
    let filename: String?
    let progress: Double?
    let remaining_min: Int?
    let layer: Int?
    let total_layers: Int?
    let bed_temp: Double?
    let nozzle_temp: Double?
    let bed_target: Double?
    let nozzle_target: Double?
    let speed: String?
    let online: Bool?
    let has_camera: Bool?
    let remaining_str: String?
    let eta_str: String?
    let duration_str: String?
    let eta_history: [EtaHistoryEntry]?
}

// MARK: - Printer View

struct PrinterView: View {
    @EnvironmentObject var ws: WebSocketService
    @State private var printerData: PrinterStatusResponse?
    @State private var selectedPrinter = 0
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var lastRefresh = Date()
    @State private var refreshTimer: Timer?
    @State private var showObjectSkip = false

    private let background = Color(hex: "#1A1A2E")
    private let cardBg = Color(hex: "#16213E")
    private let accent = Color(hex: "#C9A96E")
    private let dimText = Color(hex: "#888888")
    private let fadedText = Color(hex: "#666666")
    private let labelText = Color(hex: "#AAAAAA")
    private let bodyText = Color(hex: "#E0E0E0")

    private var serverBaseURL: String {
        return "http://\(ws.serverHost)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented picker
                Picker("Printer", selection: $selectedPrinter) {
                    Text("SV08 Max").tag(0)
                    Text("Bambu A1").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ScrollView {
                    if loading && printerData == nil {
                        ProgressView("Loading printer status...")
                            .foregroundColor(dimText)
                            .padding(.top, 80)
                    } else if let error = errorMessage, printerData == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36))
                                .foregroundColor(.red.opacity(0.7))
                            Text("Connection Error")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(bodyText)
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(dimText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .padding(.top, 60)
                    } else {
                        if selectedPrinter == 0 {
                            sv08Card
                        } else {
                            a1Card
                        }

                        // Daemon timestamp
                        if let ts = printerData?.daemon_timestamp {
                            Text("Daemon: \(ts)")
                                .font(.system(size: 10))
                                .foregroundColor(fadedText)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                        }

                        // Last refresh
                        Text("Refreshed \(lastRefresh.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 10))
                            .foregroundColor(fadedText)
                            .padding(.bottom, 20)
                    }
                }
                .refreshable {
                    await fetchPrinterStatus()
                }
            }
            .background(background)
            .navigationTitle("Printers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(cardBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await fetchPrinterStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundColor(accent)
                    }
                }
            }
        }
        .onAppear {
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .sheet(isPresented: $showObjectSkip) {
            ObjectSkipView()
                .environmentObject(ws)
        }
    }

    // MARK: - SV08 Card

    @ViewBuilder
    private var sv08Card: some View {
        if let sv08 = printerData?.sv08 {
            VStack(spacing: 0) {
                // Header: state + filename
                printerHeader(
                    name: "Sovol SV08 Max",
                    state: sv08.state ?? "Unknown",
                    filename: sv08.filename,
                    connection: sv08.connection
                )

                Divider().background(Color.white.opacity(0.1))

                // Control buttons
                if let state = sv08.state?.lowercased(),
                   state.contains("print") || state.contains("paus") {
                    HStack(spacing: 10) {
                        Button {
                            showObjectSkip = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "square.slash")
                                    .font(.system(size: 12))
                                Text("Skip Objects")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(8)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                // Camera image
                if sv08.camera != nil {
                    cameraImageView(imageName: "sovol_camera.jpg")
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

                // Thumbnail
                if sv08.thumbnail != nil {
                    thumbnailView(imageName: "sovol_thumbnail.png")
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                // Progress
                if let progress = sv08.progress {
                    progressSection(progress: progress)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                }

                // Layer progress
                if let current = sv08.current_layer, let total = sv08.total_layers {
                    layerRow(current: current, total: total)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                // ETA
                if let eta = sv08.eta_str {
                    etaSection(
                        eta: eta,
                        confidence: sv08.eta_confidence,
                        method: sv08.eta_method
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }

                // Time elapsed / remaining
                if sv08.duration_str != nil || sv08.remaining_str != nil {
                    timeSection(
                        elapsed: sv08.duration_str,
                        remaining: sv08.remaining_str
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }

                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.vertical, 12)

                // Temperature grid
                temperatureGrid(
                    bedTemp: sv08.bed_temp,
                    bedTarget: sv08.bed_target,
                    nozzleTemp: sv08.nozzle_temp,
                    nozzleTarget: sv08.nozzle_target
                )
                .padding(.horizontal, 16)

                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.vertical, 12)

                // Speed section
                speedSection(
                    speedFactor: sv08.speed_factor,
                    optimalPct: sv08.optimal_speed_pct,
                    liveVelocity: sv08.live_velocity,
                    alpha: sv08.alpha
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                // Charts
                if let graph = sv08.speed_graph, graph.count > 2 {
                    Divider().background(Color.white.opacity(0.1))
                        .padding(.vertical, 4)
                    SpeedProfileChart(
                        data: graph,
                        currentLayer: sv08.current_layer,
                        currentSpeedPct: sv08.current_speed_pct
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }

                if let graph = sv08.speed_graph, graph.count > 2 {
                    ComplexityChart(
                        data: graph,
                        currentLayer: sv08.current_layer
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                if let history = sv08.eta_history, history.count > 2 {
                    EtaHistoryChart(data: history)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                Spacer().frame(height: 16)
            }
            .background(cardBg)
            .cornerRadius(16)
            .padding(.horizontal, 16)
            .padding(.top, 4)
        } else {
            offlineCard(name: "Sovol SV08 Max")
        }
    }

    // MARK: - A1 Card

    @ViewBuilder
    private var a1Card: some View {
        if let a1 = printerData?.a1 {
            VStack(spacing: 0) {
                // Header
                printerHeader(
                    name: "Bambu Lab A1",
                    state: a1.state ?? "Unknown",
                    filename: a1.filename,
                    connection: a1.online == true ? "online" : "offline"
                )

                Divider().background(Color.white.opacity(0.1))

                // Camera image
                if a1.has_camera == true {
                    cameraImageView(imageName: "a1_camera.jpg")
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

                // Progress
                if let progress = a1.progress {
                    progressSection(progress: progress)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                }

                // Layer progress
                if let current = a1.layer, let total = a1.total_layers {
                    layerRow(current: current, total: total)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                // ETA / Time
                if let eta = a1.eta_str {
                    HStack {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 12))
                            .foregroundColor(accent)
                        Text("ETA")
                            .font(.system(size: 13))
                            .foregroundColor(labelText)
                        Spacer()
                        Text(eta)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(bodyText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }

                // Time elapsed / remaining
                if a1.duration_str != nil || a1.remaining_str != nil {
                    timeSection(
                        elapsed: a1.duration_str,
                        remaining: a1.remaining_str
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }

                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.vertical, 12)

                // Temperatures
                temperatureGrid(
                    bedTemp: a1.bed_temp,
                    bedTarget: a1.bed_target,
                    nozzleTemp: a1.nozzle_temp,
                    nozzleTarget: a1.nozzle_target
                )
                .padding(.horizontal, 16)

                // Speed profile
                if let speed = a1.speed {
                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.vertical, 12)

                    HStack {
                        Image(systemName: "speedometer")
                            .font(.system(size: 12))
                            .foregroundColor(accent)
                        Text("Speed Profile")
                            .font(.system(size: 13))
                            .foregroundColor(labelText)
                        Spacer()
                        Text(speed)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(bodyText)
                    }
                    .padding(.horizontal, 16)
                }

                // ETA history chart
                if let history = a1.eta_history, history.count > 2 {
                    Divider().background(Color.white.opacity(0.1))
                        .padding(.vertical, 4)
                    EtaHistoryChart(data: history)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }

                Spacer().frame(height: 16)
            }
            .background(cardBg)
            .cornerRadius(16)
            .padding(.horizontal, 16)
            .padding(.top, 4)
        } else {
            offlineCard(name: "Bambu Lab A1")
        }
    }

    // MARK: - Shared Components

    private func printerHeader(name: String, state: String, filename: String?, connection: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(bodyText)

                Spacer()

                stateBadge(state: state)
            }

            if let filename = filename, !filename.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(fadedText)
                    Text(filename)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(labelText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let conn = connection {
                HStack(spacing: 4) {
                    Image(systemName: conn == "ethernet" ? "cable.connector" : "wifi")
                        .font(.system(size: 10))
                        .foregroundColor(fadedText)
                    Text(conn.capitalized)
                        .font(.system(size: 11))
                        .foregroundColor(fadedText)
                }
            }
        }
        .padding(16)
    }

    private func stateBadge(state: String) -> some View {
        let (color, icon) = stateVisuals(state)
        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(state)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15))
        .cornerRadius(12)
    }

    private func stateVisuals(_ state: String) -> (Color, String) {
        let lower = state.lowercased()
        if lower.contains("print") {
            return (.green, "printer.fill")
        } else if lower.contains("paus") {
            return (.yellow, "pause.fill")
        } else if lower.contains("error") || lower.contains("fault") {
            return (.red, "exclamationmark.triangle.fill")
        } else if lower.contains("complete") || lower.contains("finish") {
            return (Color(hex: "#888888"), "checkmark.circle.fill")
        } else if lower.contains("cancel") {
            return (.orange, "xmark.circle.fill")
        } else {
            return (Color(hex: "#888888"), "moon.fill")
        }
    }

    private func cameraImageView(imageName: String) -> some View {
        let urlString = "\(serverBaseURL)/printer-image/\(imageName)?t=\(Int(lastRefresh.timeIntervalSince1970))"
        return AsyncImage(url: URL(string: urlString)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(10)
            case .failure:
                HStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .foregroundColor(fadedText)
                    Text("Camera unavailable")
                        .font(.system(size: 12))
                        .foregroundColor(fadedText)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .background(Color.black.opacity(0.3))
                .cornerRadius(10)
            case .empty:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(10)
            @unknown default:
                EmptyView()
            }
        }
    }

    private func thumbnailView(imageName: String) -> some View {
        let urlString = "\(serverBaseURL)/printer-image/\(imageName)?t=\(Int(lastRefresh.timeIntervalSince1970))"
        return HStack {
            AsyncImage(url: URL(string: urlString)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 80)
                        .cornerRadius(8)
                case .failure:
                    EmptyView()
                case .empty:
                    ProgressView()
                        .frame(width: 80, height: 80)
                @unknown default:
                    EmptyView()
                }
            }
            Spacer()
        }
    }

    private func progressSection(progress: Double) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("Progress")
                    .font(.system(size: 13))
                    .foregroundColor(labelText)
                Spacer()
                Text(String(format: "%.1f%%", progress))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 10)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.8), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * CGFloat(progress / 100.0)), height: 10)
                }
            }
            .frame(height: 10)
        }
    }

    private func layerRow(current: Int, total: Int) -> some View {
        HStack {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 12))
                .foregroundColor(accent)
            Text("Layers")
                .font(.system(size: 13))
                .foregroundColor(labelText)
            Spacer()
            Text("\(current) / \(total)")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(bodyText)
        }
    }

    private func etaSection(eta: String, confidence: String?, method: String?) -> some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 12))
                    .foregroundColor(accent)
                Text("ETA")
                    .font(.system(size: 13))
                    .foregroundColor(labelText)
                Spacer()
                Text(eta)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(bodyText)
            }

            HStack(spacing: 8) {
                Spacer()
                if let confidence = confidence {
                    confidenceBadge(confidence)
                }
                if let method = method {
                    Text(method)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(fadedText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(4)
                }
            }
        }
    }

    private func confidenceBadge(_ confidence: String) -> some View {
        let color: Color = {
            switch confidence.lowercased() {
            case "high": return .green
            case "medium": return .yellow
            case "low": return .orange
            default: return dimText
            }
        }()

        return Text(confidence.capitalized)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private func timeSection(elapsed: String?, remaining: String?) -> some View {
        HStack(spacing: 16) {
            if let elapsed = elapsed {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Elapsed")
                            .font(.system(size: 10))
                            .foregroundColor(fadedText)
                        Text(elapsed)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(bodyText)
                    }
                }
            }

            Spacer()

            if let remaining = remaining {
                HStack(spacing: 6) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Remaining")
                            .font(.system(size: 10))
                            .foregroundColor(fadedText)
                        Text(remaining)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(bodyText)
                    }
                    Image(systemName: "hourglass")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                }
            }
        }
    }

    private func temperatureGrid(bedTemp: Double?, bedTarget: Double?, nozzleTemp: Double?, nozzleTarget: Double?) -> some View {
        HStack(spacing: 12) {
            temperatureCard(
                icon: "bed.double",
                label: "Bed",
                temp: bedTemp,
                target: bedTarget
            )

            temperatureCard(
                icon: "flame",
                label: "Nozzle",
                temp: nozzleTemp,
                target: nozzleTarget
            )
        }
    }

    private func temperatureCard(icon: String, label: String, temp: Double?, target: Double?) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(accent)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(labelText)
            }

            if let temp = temp {
                Text(String(format: "%.1f\u{00B0}C", temp))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(tempColor(temp: temp, target: target))
            } else {
                Text("--\u{00B0}C")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(dimText)
            }

            if let target = target {
                Text("Target: \(String(format: "%.0f\u{00B0}C", target))")
                    .font(.system(size: 10))
                    .foregroundColor(fadedText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(10)
    }

    private func tempColor(temp: Double, target: Double?) -> Color {
        guard let target = target, target > 0 else { return bodyText }
        let diff = abs(temp - target)
        if diff <= 2 { return .green }
        if temp > target + 5 { return .red }
        return .orange
    }

    private func speedSection(speedFactor: Double?, optimalPct: Int?, liveVelocity: Double?, alpha: Double?) -> some View {
        VStack(spacing: 10) {
            // Speed factor with optimal
            if let factor = speedFactor {
                HStack {
                    Image(systemName: "speedometer")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                    Text("Speed Factor")
                        .font(.system(size: 13))
                        .foregroundColor(labelText)
                    Spacer()
                    Text(String(format: "%.0f%%", factor * 100))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(bodyText)
                }

                if let optimal = optimalPct {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "target")
                                .font(.system(size: 10))
                            Text("Optimal: \(optimal)%")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.12))
                        .cornerRadius(6)
                    }
                }
            }

            // Live velocity
            if let velocity = liveVelocity {
                HStack {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                    Text("Live Velocity")
                        .font(.system(size: 13))
                        .foregroundColor(labelText)
                    Spacer()
                    Text(String(format: "%.1f mm/s", velocity))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(bodyText)
                }
            }

            // Alpha
            if let alpha = alpha {
                HStack {
                    Image(systemName: "function")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                    Text("Alpha (EMA)")
                        .font(.system(size: 13))
                        .foregroundColor(labelText)
                    Spacer()
                    Text(String(format: "%.3f", alpha))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(bodyText)
                }
            }
        }
    }

    private func offlineCard(name: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "printer.dotmatrix.fill.and.paper.fill")
                .font(.system(size: 40))
                .foregroundColor(dimText.opacity(0.5))

            Text(name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(bodyText)

            Text("No data available")
                .font(.system(size: 13))
                .foregroundColor(dimText)

            Text("Printer may be offline or\nnot reporting to the daemon")
                .font(.system(size: 12))
                .foregroundColor(fadedText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(cardBg)
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Data Fetching

    private func fetchPrinterStatus() async {
        let urlString = "\(serverBaseURL)/printer-status"
        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL: \(urlString)"
            loading = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                errorMessage = "Server returned status \(code)"
                loading = false
                return
            }

            let status = PrinterStatusResponse(from: data)
            printerData = status
            errorMessage = nil
            lastRefresh = Date()
            loading = false
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
            loading = false
        }
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        Task { await fetchPrinterStatus() }

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                await fetchPrinterStatus()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

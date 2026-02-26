import SwiftUI

// MARK: - Data Models

struct WorkStatusResponse {
    let emails: [EmailItem]
    let events: [CalendarEvent]
    let accounts: [AccountInfo]
    let setupRequired: Bool

    init(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            emails = []; events = []; accounts = []; setupRequired = false
            return
        }

        setupRequired = json["setup_required"] as? Bool ?? false

        emails = (json["emails"] as? [[String: Any]] ?? []).compactMap { e in
            guard let from = e["from"] as? String,
                  let subject = e["subject"] as? String else { return nil }
            return EmailItem(
                from: from, subject: subject,
                snippet: e["snippet"] as? String ?? "",
                time: e["time"] as? String ?? "",
                account: e["account"] as? String ?? "",
                accountColor: e["account_color"] as? String ?? "#888888"
            )
        }

        events = (json["events"] as? [[String: Any]] ?? []).compactMap { e in
            let title = e["summary"] as? String ?? e["title"] as? String ?? ""
            guard !title.isEmpty else { return nil }
            return CalendarEvent(
                title: title, when: e["when"] as? String ?? "",
                location: e["location"] as? String,
                attendees: e["attendees"] as? String,
                account: e["account"] as? String,
                accountColor: e["account_color"] as? String,
                htmlLink: e["html_link"] as? String
            )
        }

        accounts = (json["accounts"] as? [[String: Any]] ?? []).compactMap { a in
            guard let label = a["label"] as? String else { return nil }
            return AccountInfo(label: label, color: a["color"] as? String ?? "#888888")
        }
    }
}

struct SlackResponse {
    let messages: [SlackMessage]

    init(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            messages = []; return
        }
        messages = (json["messages"] as? [[String: Any]] ?? []).compactMap { s in
            guard let channel = s["channel"] as? String,
                  let user = s["user"] as? String,
                  let text = s["text"] as? String else { return nil }
            return SlackMessage(
                channel: channel, user: user, text: text,
                replies: s["replies"] as? String,
                time: s["time"] as? String ?? ""
            )
        }
    }
}

struct SearchResponse {
    let results: [SearchResult]

    init(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            results = []; return
        }
        results = (json["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let title = r["title"] as? String ?? r["summary"] as? String else { return nil }
            return SearchResult(
                type: r["type"] as? String ?? "result",
                title: title,
                snippet: r["snippet"] as? String ?? r["text"] as? String ?? "",
                time: r["time"] as? String ?? r["when"] as? String ?? "",
                source: r["source"] as? String ?? r["account"] as? String ?? ""
            )
        }
    }
}

struct EmailItem: Identifiable {
    let id = UUID()
    let from: String
    let subject: String
    let snippet: String
    let time: String
    let account: String
    let accountColor: String
}

struct CalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let when: String
    let location: String?
    let attendees: String?
    let account: String?
    let accountColor: String?
    let htmlLink: String?
}

struct SlackMessage: Identifiable {
    let id = UUID()
    let channel: String
    let user: String
    let text: String
    let replies: String?
    let time: String
}

struct AccountInfo: Identifiable {
    let id = UUID()
    let label: String
    let color: String
}

struct SearchResult: Identifiable {
    let id = UUID()
    let type: String
    let title: String
    let snippet: String
    let time: String
    let source: String
}

// MARK: - Work View

struct WorkView: View {
    @EnvironmentObject var ws: WebSocketService
    @State private var selectedSection = 0
    @State private var status: WorkStatusResponse?
    @State private var slackMessages: [SlackMessage] = []
    @State private var searchResults: [SearchResult] = []
    @State private var isLoading = true
    @State private var slackLoading = false
    @State private var errorMessage: String?
    @State private var refreshTimer: Timer?
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    private let sections = ["Emails", "Diary", "Slack"]
    private let accent = Color(hex: "#C9A96E")
    private let cardBg = Color(hex: "#16213E")
    private let bg = Color(hex: "#1A1A2E")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#888888"))
                        TextField("Search emails, calendar, slack...", text: $searchText)
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#E0E0E0"))
                            .focused($searchFocused)
                            .onSubmit { performSearch() }
                            .submitLabel(.search)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#2A2A4A"))
                    .cornerRadius(10)

                    if !searchText.isEmpty || isSearching {
                        Button("Cancel") {
                            searchText = ""
                            isSearching = false
                            searchResults = []
                            searchFocused = false
                        }
                        .font(.system(size: 14))
                        .foregroundColor(accent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if isSearching {
                    // Show search results
                    ScrollView {
                        if searchResults.isEmpty {
                            emptyState(icon: "magnifyingglass", message: "No results found")
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(searchResults) { result in
                                    searchResultCard(result)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                        }
                    }
                } else {
                    // Segmented picker
                    Picker("Section", selection: $selectedSection) {
                        ForEach(0..<sections.count, id: \.self) { i in
                            Text(sections[i]).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    // Content
                    ScrollView {
                        if isLoading && status == nil {
                            ProgressView("Loading work status...")
                                .foregroundColor(accent)
                                .padding(.top, 60)
                        } else if let error = errorMessage {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 36))
                                    .foregroundColor(accent)
                                Text(error)
                                    .foregroundColor(Color(hex: "#888888"))
                                    .multilineTextAlignment(.center)
                                    .font(.system(size: 14))
                            }
                            .padding(.top, 60)
                        } else if status?.setupRequired == true {
                            setupRequiredCard
                        } else {
                            LazyVStack(spacing: 10) {
                                switch selectedSection {
                                case 0: emailList
                                case 1: calendarList
                                case 2: slackList
                                default: EmptyView()
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                        }
                    }
                    .refreshable {
                        await fetchAll()
                    }
                }
            }
            .background(bg.ignoresSafeArea())
            .navigationTitle("Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(cardBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        Task { await fetchAll() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(accent)
                    }
                }
            }
            .onChange(of: selectedSection) { _, newValue in
                if newValue == 2 && slackMessages.isEmpty && !slackLoading {
                    Task { await fetchSlack() }
                }
            }
        }
        .onAppear {
            Task { await fetchAll() }
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }

    // MARK: - Setup Required Card

    private var setupRequiredCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 40))
                .foregroundColor(accent)
            Text("Google Workspace Setup Required")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Text("The work status endpoint needs Google Workspace credentials configured on the server.")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#888888"))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(cardBg)
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 40)
    }

    // MARK: - Email List

    @ViewBuilder
    private var emailList: some View {
        if let s = status, !s.emails.isEmpty {
            ForEach(s.emails) { email in
                emailCard(email)
            }
        } else {
            emptyState(icon: "envelope", message: "No emails to show")
        }
    }

    private func emailCard(_ email: EmailItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(email.from)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Text(email.time)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#888888"))
            }
            Text(email.subject)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "#E0E0E0"))
                .lineLimit(1)
            Text(email.snippet)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#888888"))
                .lineLimit(2)
            HStack {
                Spacer()
                Text(email.account)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: email.accountColor).opacity(0.3))
                    .cornerRadius(6)
            }
        }
        .padding(14)
        .background(cardBg)
        .cornerRadius(12)
    }

    // MARK: - Calendar List

    @ViewBuilder
    private var calendarList: some View {
        if let s = status, !s.events.isEmpty {
            ForEach(s.events) { event in
                calendarCard(event)
            }
        } else {
            emptyState(icon: "calendar", message: "No events today")
        }
    }

    private func calendarCard(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#52b788"))
                Text(event.when)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#52b788"))
            }
            if let location = event.location, !location.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#888888"))
                    Text(location)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#888888"))
                }
            }
            if let attendees = event.attendees, !attendees.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#888888"))
                    Text(attendees)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#888888"))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBg)
        .cornerRadius(12)
    }

    // MARK: - Slack List

    @ViewBuilder
    private var slackList: some View {
        if slackLoading {
            ProgressView("Loading Slack...")
                .foregroundColor(accent)
                .padding(.top, 60)
        } else if !slackMessages.isEmpty {
            ForEach(slackMessages) { msg in
                slackCard(msg)
            }
        } else {
            emptyState(icon: "number", message: "No Slack messages")
        }
    }

    private func slackCard(_ msg: SlackMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(msg.channel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "#9B72CF"))
                Spacer()
                Text(msg.time)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#888888"))
            }
            Text(msg.user)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
            Text(msg.text)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#C0C0C0"))
                .lineLimit(3)
            if let replies = msg.replies, !replies.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 11))
                    Text(replies)
                        .font(.system(size: 12))
                }
                .foregroundColor(Color(hex: "#6B8ADB"))
            }
        }
        .padding(14)
        .background(cardBg)
        .cornerRadius(12)
    }

    // MARK: - Search Results

    private func searchResultCard(_ result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: result.type == "email" ? "envelope" :
                        result.type == "event" ? "calendar" : "number")
                    .font(.system(size: 12))
                    .foregroundColor(accent)
                Text(result.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Text(result.time)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#888888"))
            }
            if !result.snippet.isEmpty {
                Text(result.snippet)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#AAAAAA"))
                    .lineLimit(2)
            }
            if !result.source.isEmpty {
                Text(result.source)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#666666"))
            }
        }
        .padding(12)
        .background(cardBg)
        .cornerRadius(10)
    }

    // MARK: - Empty State

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(Color(hex: "#444444"))
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#666666"))
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
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

    private func fetchAll() async {
        await fetchStatus()
        if selectedSection == 2 {
            await fetchSlack()
        }
    }

    private func fetchStatus() async {
        guard let url = URL(string: "http://\(ws.serverHost)/work-status") else {
            errorMessage = "Invalid server URL"
            isLoading = false
            return
        }

        do {
            let request = authedRequest(url: url)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                errorMessage = "Server returned an error"
                isLoading = false
                return
            }
            status = WorkStatusResponse(from: data)
            errorMessage = nil
        } catch {
            if status == nil {
                errorMessage = "Could not connect to server.\nPull down to retry."
            }
        }
        isLoading = false
    }

    private func fetchSlack() async {
        guard let url = URL(string: "http://\(ws.serverHost)/slack-messages") else { return }
        slackLoading = true
        do {
            let request = authedRequest(url: url)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                slackMessages = SlackResponse(from: data).messages
            }
        } catch {}
        slackLoading = false
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        searchFocused = false

        Task {
            guard let url = URL(string: "http://\(ws.serverHost)/work-search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)") else { return }
            do {
                let request = authedRequest(url: url)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    searchResults = SearchResponse(from: data).results
                }
            } catch {}
        }
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { await fetchAll() }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

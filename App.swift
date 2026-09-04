import SwiftUI

// One repo as GitHub's search API returns it, plus the delta we compute locally.
struct Repo: Codable, Identifiable {
    let id: Int
    let full_name: String
    let html_url: String
    let description: String?
    let language: String?
    let stargazers_count: Int
    let owner: Owner?
    var delta: Int = 0          // stars gained since the last snapshot we have
    var history: [Int] = []     // sao theo ngày, lấy từ metrics — vẽ sparkline

    struct Owner: Codable { let avatar_url: String? }

    // delta/history tính ở phía mình; để chúng ngoài CodingKeys thì decode
    // payload GitHub không chết vì thiếu field.
    private enum CodingKeys: String, CodingKey {
        case id, full_name, html_url, description, language, stargazers_count, owner
    }
}

private struct SearchResult: Codable { let items: [Repo] }

func today(_ offset: Int = 0) -> String { Store.day(offset) }

/// Trending has no API, so approximate it: repos created in the window, most starred.
/// `topic` narrows to the AI/tool slice the app is for.
func fetch(days: Int, topic: String) async throws -> [Repo] {
    var q = "created:>\(today(-days)) stars:>10"
    if !topic.isEmpty { q += " topic:\(topic)" }
    var c = URLComponents(string: "https://api.github.com/search/repositories")!
    c.queryItems = [.init(name: "q", value: q), .init(name: "sort", value: "stars"),
                    .init(name: "order", value: "desc"), .init(name: "per_page", value: "50")]
    var r = URLRequest(url: c.url!)
    r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    // A token lifts the 10 req/min unauthenticated search limit; optional.
    if let t = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !t.isEmpty {
        r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
    }
    let (data, resp) = try await URLSession.shared.data(for: r)
    if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
        throw NSError(domain: "github", code: h.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "GitHub returned \(h.statusCode) — rate limited? Set GITHUB_TOKEN."])
    }
    var repos = try JSONDecoder().decode(SearchResult.self, from: data).items
    let synced = try await Store.sync(repos)
    for i in repos.indices {
        let key = String(repos[i].id)
        if let was = synced.previous[key] { repos[i].delta = repos[i].stargazers_count - was }
        repos[i].history = synced.history[key] ?? []
    }
    return repos
}

@main struct App_: App {
    var body: some Scene {
        WindowGroup("GitHub Trending") { ContentView() }
            .defaultSize(width: 620, height: 720)
    }
}

/// Star chart nhỏ vẽ từ lịch sử `metrics` của chính mình — không phụ thuộc dịch vụ ngoài.
struct Sparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { g in
            let lo = values.min() ?? 0, hi = values.max() ?? 0
            let span = max(hi - lo, 1)
            if values.count > 1 {
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = g.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = g.size.height * (1 - CGFloat(v - lo) / CGFloat(span))
                        i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                    }
                }.stroke(.green, lineWidth: 1.5)
            }
        }
    }
}

struct ContentView: View {
    @State private var repos: [Repo] = []
    @State private var days = 7
    @State private var topic = "ai"
    @State private var error: String?
    @State private var loading = false
    @State private var configured = Store.isConfigured
    @State private var sbURL = Store.url
    @State private var sbKey = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $days) {
                    Text("1 ngày").tag(1); Text("7 ngày").tag(7); Text("30 ngày").tag(30)
                }.pickerStyle(.segmented).frame(width: 220)
                TextField("topic (ai, llm, cli…)", text: $topic).frame(width: 140)
                Button("Refresh") { Task { await load() } }.disabled(loading)
                if loading { ProgressView().scaleEffect(0.5) }
            }.padding(8)
            Divider()
            if let e = error { Text(e).foregroundStyle(.red).padding(8) }
            if !configured {
                // Chỉ hiện khi chưa có credential — nhập xong là biến mất.
                VStack(spacing: 6) {
                    TextField("https://xxx.supabase.co", text: $sbURL)
                    SecureField("anon key", text: $sbKey)
                    Button("Lưu Supabase") {
                        Store.url = sbURL; Store.key = sbKey
                        configured = Store.isConfigured
                        Task { await load() }
                    }.disabled(sbURL.isEmpty || sbKey.isEmpty)
                }.padding(8)
            }
            List(repos) { r in
                HStack(alignment: .top, spacing: 10) {
                    AsyncImage(url: r.owner?.avatar_url.flatMap(URL.init)) { $0.resizable() }
                        placeholder: { Color.gray.opacity(0.15) }
                        .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.full_name).font(.headline)
                            Spacer()
                            Sparkline(values: r.history).frame(width: 70, height: 20)
                            Text("★ \(r.stargazers_count)")
                            if r.delta > 0 { Text("+\(r.delta)").foregroundStyle(.green) }
                        }
                        if let d = r.description { Text(d).font(.caption).lineLimit(2) }
                        if let l = r.language { Text(l).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(URL(string: r.html_url)!) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do { repos = try await fetch(days: days, topic: topic) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

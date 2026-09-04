import SwiftUI

// One repo as GitHub's search API returns it, plus the delta we compute locally.
struct Repo: Codable, Identifiable {
    let id: Int
    let full_name: String
    let html_url: String
    let description: String?
    let language: String?
    let stargazers_count: Int
    var delta: Int = 0          // stars gained since the last snapshot we have
}

private struct SearchResult: Codable { let items: [Repo] }

// Snapshots live in Application Support so stats survive rebuilds of the .app.
private let storeURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Trending")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("snapshots.json")
}()

// date -> (repo id -> stars). Keeping every day makes "gained since yesterday" a lookup.
typealias Snapshots = [String: [String: Int]]

func loadSnapshots() -> Snapshots {
    guard let d = try? Data(contentsOf: storeURL) else { return [:] }
    return (try? JSONDecoder().decode(Snapshots.self, from: d)) ?? [:]
}

func saveSnapshot(_ repos: [Repo]) {
    var s = loadSnapshots()
    s[today()] = Dictionary(uniqueKeysWithValues: repos.map { (String($0.id), $0.stargazers_count) })
    // Keep a month; older snapshots buy nothing but disk.
    for k in s.keys.sorted().dropLast(30) { s.removeValue(forKey: k) }
    try? JSONEncoder().encode(s).write(to: storeURL)
}

func today(_ offset: Int = 0) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
}

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
    let prev = loadSnapshots()[today(-1)] ?? loadSnapshots()[today()] ?? [:]
    for i in repos.indices {
        if let was = prev[String(repos[i].id)] { repos[i].delta = repos[i].stargazers_count - was }
    }
    saveSnapshot(repos)
    return repos
}

@main struct App_: App {
    var body: some Scene {
        WindowGroup("GitHub Trending") { ContentView() }
            .defaultSize(width: 620, height: 720)
    }
}

struct ContentView: View {
    @State private var repos: [Repo] = []
    @State private var days = 7
    @State private var topic = "ai"
    @State private var error: String?
    @State private var loading = false

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
            if let e = error { Text(e).foregroundStyle(.red).padding() }
            List(repos) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(r.full_name).font(.headline)
                        Spacer()
                        Text("★ \(r.stargazers_count)")
                        if r.delta > 0 { Text("+\(r.delta)").foregroundStyle(.green) }
                    }
                    if let d = r.description { Text(d).font(.caption).lineLimit(2) }
                    if let l = r.language { Text(l).font(.caption2).foregroundStyle(.secondary) }
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

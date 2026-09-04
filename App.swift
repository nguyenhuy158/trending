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
    var aiSummary: String?      // tóm tắt / lý do AI đã cache trong DB
    var aiScore: Int?           // điểm đáng thử AI chấm
    var aiTag: String?          // agent / cli / lib / app / model / data

    struct Owner: Codable { let avatar_url: String? }

    // delta/history tính ở phía mình; để chúng ngoài CodingKeys thì decode
    // payload GitHub không chết vì thiếu field.
    private enum CodingKeys: String, CodingKey {
        case id, full_name, html_url, description, language, stargazers_count, owner
    }
}

private struct SearchResult: Codable { let items: [Repo] }

/// Search API trần 1000 kết quả, nên phân trang cũng dừng ở đó.
let pageSize = 50, maxResults = 1000

/// Preset chỉ là giá trị sẵn cho ô topic — vẫn gõ tay được topic khác.
let presets: [(name: String, topic: String)] = [
    ("Tất cả", ""), ("AI", "ai"), ("LLM", "llm"), ("AI agents", "ai-agents"),
    ("MCP", "mcp"), ("CLI", "cli"), ("Dev tools", "developer-tools"),
]

enum SortBy: String, CaseIterable, Identifiable {
    case stars = "Nhiều sao", updated = "Mới cập nhật", delta = "Tăng sao nhanh"
    case ai = "AI chọn", best = "Liên quan"
    var id: Self { self }
    /// `delta`/`ai` xếp ở phía mình nên vẫn hỏi API theo sao; `best` là best-match, bỏ tham số sort.
    var apiSort: String? {
        switch self {
        case .stars, .delta, .ai: return "stars"
        case .updated:            return "updated"
        case .best:               return nil
        }
    }
}

func today(_ offset: Int = 0) -> String { Store.day(offset) }

/// Trending has no API, so approximate it: repos created in the window, most starred.
/// `topic` narrows to the AI/tool slice the app is for.
func fetch(days: Int, topic: String, sort: SortBy = .stars, page: Int = 1) async throws -> [Repo] {
    var q = "created:>\(today(-days)) stars:>10"
    if !topic.isEmpty { q += " topic:\(topic)" }
    var c = URLComponents(string: "https://api.github.com/search/repositories")!
    c.queryItems = [.init(name: "q", value: q), .init(name: "order", value: "desc"),
                    .init(name: "per_page", value: "\(pageSize)"), .init(name: "page", value: "\(page)")]
    if let s = sort.apiSort { c.queryItems?.append(.init(name: "sort", value: s)) }
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
        repos[i].aiSummary = synced.summary[key]
        if let v = synced.verdict[key] { repos[i].aiScore = v.score; repos[i].aiTag = v.tag }
    }
    return repos
}

@main struct App_: App {
    var body: some Scene {
        WindowGroup("GitHub Trending") { ContentView() }
            .defaultSize(width: 900, height: 760)
        // Cửa sổ ⌘, của macOS — khỏi tốn chỗ trên toolbar.
        Settings { SetupView() }
    }
}

/// Nhập credential: hiện trong ⌘, và inline ở lần chạy đầu.
struct SetupView: View {
    var onSave: () -> Void = {}
    @State private var sbURL = Store.url
    @State private var sbKey = ""
    @State private var aiKey = ""
    @State private var aiModel = AI.model
    @State private var models: [AI.Model] = []
    @State private var saved = false

    var body: some View {
        Form {
            TextField("Supabase URL", text: $sbURL, prompt: Text("https://xxx.supabase.co"))
            SecureField("Supabase anon key", text: $sbKey)
            SecureField("OpenRouter API key", text: $aiKey, prompt: Text("cho nút ✨"))
            Picker("Model", selection: $aiModel) {
                // Model đang chọn có thể không nằm trong list (free đổi liên tục) — vẫn phải hiện.
                if !models.contains(where: { $0.id == aiModel }) { Text(aiModel).tag(aiModel) }
                ForEach(models) { Text($0.name).tag($0.id) }
            }
            .task { models = await AI.freeModels() }
            HStack {
                Button("Lưu") {
                    Store.url = sbURL
                    if !sbKey.isEmpty { Store.key = sbKey }
                    if !aiKey.isEmpty { AI.key = aiKey }
                    AI.model = aiModel
                    onSave()
                    saved = true
                    // Tự tắt sau 2s — đỡ phải làm hệ thống toast cho đúng một chỗ.
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); saved = false }
                }
                .keyboardShortcut(.defaultAction)

                if saved {
                    Label("Đã lưu", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: saved)
        }
        .padding()
        .frame(width: 380)
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
    @State private var sort = SortBy.stars
    @State private var error: String?
    @State private var loading = false
    @State private var page = 1
    @State private var canLoadMore = false
    @State private var configured = Store.isConfigured

    var body: some View {
        NavigationStack {
            List {
                if let e = error {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                if !configured { setupBox }
                ForEach(repos) { RepoRow(repo: $0) }
                // Cuộn tới cuối là tự kéo trang kế — không cần nút bấm.
                if canLoadMore {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .listRowSeparator(.hidden)
                        .onAppear { Task { await load(reset: false) } }
                }
            }
            .listStyle(.inset)
            // Thanh search của hệ thống: đúng chỗ, đúng phím tắt, không phải tự vẽ.
            .searchable(text: $topic, prompt: "topic: ai, llm, mcp…")
            .onSubmit(of: .search) { Task { await load() } }
            .toolbar {
                ToolbarItemGroup {
                    Picker("", selection: $days) {
                        Text("1d").tag(1); Text("7d").tag(7); Text("30d").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: days) { Task { await load() } }

                    Picker("Chủ đề", selection: Binding(get: { topic },
                                                        set: { topic = $0; Task { await load() } })) {
                        ForEach(presets, id: \.topic) { Text($0.name).tag($0.topic) }
                    }
                    .frame(width: 108)
                    Picker("Sắp xếp", selection: $sort) {
                        ForEach(SortBy.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 128)
                    .onChange(of: sort) { Task { await load() } }

                    Button { Task { await load() } } label: {
                        Image(systemName: loading ? "arrow.clockwise.circle" : "arrow.clockwise")
                    }
                    .help("Tải lại")
                    .disabled(loading)
                }
            }
            .overlay {
                if repos.isEmpty && !loading && configured && error == nil {
                    Text("Không có repo nào khớp bộ lọc").foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .task { await load() }
    }

    /// Lần chạy đầu chưa có gì thì hỏi ngay tại chỗ; sau đó dùng ⌘,.
    private var setupBox: some View {
        GroupBox("Kết nối Supabase — hoặc mở Cài đặt (⌘,)") {
            SetupView { configured = Store.isConfigured; Task { await load() } }
        }
        .listRowSeparator(.hidden)
    }

    private func load(reset: Bool = true) async {
        if loading { return }
        loading = true; error = nil
        let next = reset ? 1 : page + 1
        do {
            let batch = try await fetch(days: days, topic: topic, sort: sort, page: next)
            if reset {
                repos = batch
            } else {
                // Xếp hạng đổi giữa các lần gọi nên trang sau có thể lặp repo cũ.
                let seen = Set(repos.map(\.id))
                repos += batch.filter { !seen.contains($0.id) }
            }
            page = next
            // Delta chỉ mình biết (từ metrics), API không sort hộ được — xếp tại chỗ.
            if sort == .delta { repos.sort { $0.delta > $1.delta } }
            if sort == .ai { await rank() }
            canLoadMore = batch.count == pageSize && repos.count < maxResults
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    /// Chấm điểm những repo chưa có điểm rồi xếp lại. Chỉ tốn 1 call cho cả trang,
    /// và điểm nằm trong DB nên lần sau mở ra là có sẵn.
    private func rank() async {
        let todo = repos.filter { $0.aiScore == nil }
        guard !todo.isEmpty else { repos.sort { ($0.aiScore ?? -1) > ($1.aiScore ?? -1) }; return }
        do {
            let verdicts = try await AI.rank(todo)
            for i in repos.indices {
                guard let v = verdicts[String(repos[i].id)] else { continue }
                repos[i].aiScore = v.score; repos[i].aiTag = v.tag; repos[i].aiSummary = v.why
            }
            try? await Store.saveRanking(repos, verdicts)
        } catch { self.error = error.localizedDescription }
        repos.sort { ($0.aiScore ?? -1) > ($1.aiScore ?? -1) }
    }
}

struct RepoRow: View {
    let repo: Repo
    @State private var hovering = false
    @State private var summary: String?
    @State private var asking = false

    /// Lỗi cũng đổ vào chỗ hiện tóm tắt — một dòng chữ, khỏi alert.
    private func ask() async {
        asking = true
        do { summary = try await AI.summarize(repo) }
        catch { summary = error.localizedDescription }
        asking = false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: repo.owner?.avatar_url.flatMap(URL.init)) { $0.resizable().scaledToFill() }
                placeholder: { Rectangle().fill(.quaternary) }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(repo.full_name).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    if let s = repo.aiScore {
                        Label("\(s)", systemImage: "sparkles")
                            .font(.caption.weight(.semibold)).foregroundStyle(.purple)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.purple.opacity(0.12), in: Capsule())
                            .help("Điểm đáng thử do AI chấm")
                    }
                    if repo.delta > 0 {
                        Text("+\(repo.delta)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                    Label("\(repo.stargazers_count)", systemImage: "star.fill")
                        .font(.callout.monospacedDigit()).foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                if let d = repo.description, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if let s = summary ?? repo.aiSummary {
                    Label(s, systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.purple)
                        .padding(8)
                        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack(spacing: 8) {
                    if let l = repo.language {
                        Text(l).font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if let t = repo.aiTag {
                        Text(t).font(.caption2).foregroundStyle(.purple)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.purple.opacity(0.1), in: Capsule())
                    }
                    Button { Task { await ask() } } label: {
                        if asking { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "sparkles") }
                    }
                    .buttonStyle(.borderless)
                    .disabled(asking)
                    .help("Nhờ Claude tóm tắt")
                    Spacer()
                    Sparkline(values: repo.history).frame(width: 72, height: 18)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(URL(string: repo.html_url)!) }
    }
}

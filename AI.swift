import Foundation

/// Tóm tắt repo qua OpenRouter (API kiểu OpenAI). Mặc định dùng model `:free`
/// nên không tốn tiền. Kết quả cache vào cột `items.ai_summary` — mỗi repo gọi
/// đúng một lần, ai mở app sau cũng thấy sẵn.
enum AI {
    /// glm-5.2:free nghe hay nhất nhưng pool chung của nó 429 gần như liên tục.
    static let defaultModel = "minimax/minimax-m3:free"

    static var key: String {
        get { stored("OPENROUTER_API_KEY") }
        set { UserDefaults.standard.set(newValue, forKey: "OPENROUTER_API_KEY") }
    }
    static var model: String {
        get { let m = stored("OPENROUTER_MODEL"); return m.isEmpty ? defaultModel : m }
        set { UserDefaults.standard.set(newValue, forKey: "OPENROUTER_MODEL") }
    }
    static var isConfigured: Bool { !key.isEmpty }

    private static func stored(_ k: String) -> String {
        let e = ProcessInfo.processInfo.environment[k] ?? ""
        return e.isEmpty ? (UserDefaults.standard.string(forKey: k) ?? "") : e
    }

    struct Model: Codable, Identifiable, Hashable { let id: String; let name: String }
    private struct ModelList: Codable { let data: [Model] }

    /// Danh sách model free lấy live — OpenRouter thay model free khá thường xuyên.
    /// Endpoint này public, không cần key.
    static func freeModels() async -> [Model] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONDecoder().decode(ModelList.self, from: data)
        else { return [] }
        return list.data.filter { $0.id.hasSuffix(":free") }.sorted { $0.name < $1.name }
    }

    private struct Reply: Codable {
        let choices: [Choice]
        struct Choice: Codable { let message: Message }
        struct Message: Codable { let content: String? }
    }

    /// Pool free dùng chung nên 429 là chuyện thường ngày; đổi tạm sang model free khác.
    private static let fallbacks = [
        "minimax/minimax-m3:free", "google/gemma-4-31b-it:free", "nvidia/nemotron-3.5-lightning:free",
    ]

    /// 429 = nghẽn tạm thời, khác hẳn lỗi thật (sai key, model chết) nên tách riêng.
    private struct Busy: Error { let model: String; let retryAfter: Int }

    static func summarize(_ repo: Repo) async throws -> String {
        guard isConfigured else {
            throw NSError(domain: "ai", code: 401, userInfo: [NSLocalizedDescriptionKey:
                "Chưa có OPENROUTER_API_KEY — mở Cài đặt (⌘,) để điền."])
        }
        let prompt = """
        Repo GitHub: \(repo.full_name)
        Ngôn ngữ: \(repo.language ?? "?") — \(repo.stargazers_count) sao
        Mô tả: \(repo.description ?? "(trống)")

        Trả lời bằng tiếng Việt, tối đa 3 câu: nó làm gì, hợp với ai, có đáng thử không.
        Nói thẳng, không markdown, không rào đón.
        """
        var busy: Busy?
        for m in [model] + fallbacks.filter({ $0 != model }) {
            do {
                return try await save(await ask(m, prompt), for: repo)
            } catch let e as Busy {
                busy = e
                // Nó bảo chờ bao lâu thì chờ đúng bấy nhiêu, thử lại một lần rồi mới đổi model.
                try? await Task.sleep(nanoseconds: UInt64(min(max(e.retryAfter, 1), 10)) * 1_000_000_000)
                if let text = try? await ask(m, prompt) { return try await save(text, for: repo) }
            }
        }
        throw NSError(domain: "openrouter", code: 429, userInfo: [NSLocalizedDescriptionKey:
            "Mấy model free đang nghẽn (\(busy?.model ?? model) 429). Thử lại sau, hoặc chọn model khác trong ⌘,."])
    }

    /// Cache hỏng thì cũng đã có câu trả lời rồi, không chặn UI vì chuyện đó.
    private static func save(_ text: String, for repo: Repo) async throws -> String {
        try? await Store.saveSummary(text, for: String(repo.id))
        return text
    }

    /// AI chấm cả trang trong đúng một call: điểm đáng thử, nhãn loại, một câu lý do.
    struct Verdict: Codable { let id: String; let score: Int; let tag: String; let why: String }

    static func rank(_ repos: [Repo]) async throws -> [String: Verdict] {
        guard isConfigured else {
            throw NSError(domain: "ai", code: 401, userInfo: [NSLocalizedDescriptionKey:
                "Chưa có OPENROUTER_API_KEY — mở Cài đặt (⌘,) để điền."])
        }
        // Càng nhiều repo càng dễ vượt output limit của model free; 25 là mức chạy ổn.
        let batch = repos.prefix(25)
        let lines = batch.map {
            "\($0.id) | \($0.full_name) | \($0.language ?? "?") | \($0.stargazers_count)★ | "
                + ($0.description ?? "").prefix(140)
        }.joined(separator: "\n")
        let prompt = """
        Danh sách repo GitHub mới (id | tên | ngôn ngữ | sao | mô tả):
        \(lines)

        Với MỖI repo, chấm mức đáng thử cho một dev đang tìm tool/AI mới.
        Trả về DUY NHẤT một mảng JSON, không markdown, không giải thích ngoài JSON:
        [{"id":"<id>","score":<0-100>,"tag":"<agent|cli|lib|app|model|data|other>","why":"<1 câu tiếng Việt>"}]
        """
        var busy: Busy?
        for m in [model] + fallbacks.filter({ $0 != model }) {
            do {
                let raw = try await ask(m, prompt, maxTokens: 2000)
                let list = try decodeVerdicts(raw)
                return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            } catch let e as Busy { busy = e }
        }
        throw NSError(domain: "openrouter", code: 429, userInfo: [NSLocalizedDescriptionKey:
            "Không xếp hạng được — model free đang nghẽn (\(busy?.model ?? model)). Thử lại sau."])
    }

    /// Model free hay bọc JSON trong ```json ... ``` hoặc kèm lời dẫn — cắt lấy phần mảng.
    private static func decodeVerdicts(_ raw: String) throws -> [Verdict] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let list = try? JSONDecoder().decode([Verdict].self, from: data), !list.isEmpty
        else {
            throw NSError(domain: "openrouter", code: 422, userInfo: [NSLocalizedDescriptionKey:
                "Model trả JSON không đọc được — chọn model free khác trong ⌘,."])
        }
        return list
    }

    private static func ask(_ model: String, _ prompt: String, maxTokens: Int = 400) async throws -> String {
        var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Trending", forHTTPHeaderField: "X-Title")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 || code == 503 {
            throw Busy(model: model, retryAfter: retryAfter(data))
        }
        if code != 200 {
            throw NSError(domain: "openrouter", code: code, userInfo: [NSLocalizedDescriptionKey:
                "OpenRouter \(code): \(message(data))"])
        }
        let text = (try JSONDecoder().decode(Reply.self, from: data)
            .choices.first?.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Model free hết quota hay trả rỗng cũng coi như nghẽn, để nhảy sang cái kế.
        guard !text.isEmpty else { throw Busy(model: model, retryAfter: 1) }
        return text
    }

    /// Lấy chữ trong `{"error":{"message":...}}`, khỏi dội nguyên cục JSON lên UI.
    private static func errorObject(_ data: Data) -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["error"] as? [String: Any] ?? [:]
    }

    private static func message(_ data: Data) -> String {
        errorObject(data)["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
    }

    private static func retryAfter(_ data: Data) -> Int {
        let meta = errorObject(data)["metadata"] as? [String: Any]
        return meta?["retry_after_seconds"] as? Int ?? 5
    }
}

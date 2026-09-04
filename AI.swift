import Foundation

/// Tóm tắt repo qua OpenRouter (API kiểu OpenAI). Mặc định dùng model `:free`
/// nên không tốn tiền. Kết quả cache vào cột `items.ai_summary` — mỗi repo gọi
/// đúng một lần, ai mở app sau cũng thấy sẵn.
enum AI {
    /// Model free khác nếu cái này hết quota: minimax/minimax-m3:free,
    /// google/gemma-4-31b-it:free, nvidia/nemotron-3.5-lightning:free.
    static let defaultModel = "z-ai/glm-5.2:free"

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
        var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Trending", forHTTPHeaderField: "X-Title")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 400,
            "messages": [["role": "user", "content": prompt]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw NSError(domain: "openrouter", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey:
                "OpenRouter \(h.statusCode): \(String(data: data, encoding: .utf8) ?? "")"])
        }
        let text = (try JSONDecoder().decode(Reply.self, from: data)
            .choices.first?.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NSError(domain: "openrouter", code: 204, userInfo: [NSLocalizedDescriptionKey:
                "Model \(model) trả về rỗng — thử model free khác trong Cài đặt."])
        }
        // Cache hỏng thì cũng đã có câu trả lời rồi, không chặn UI vì chuyện đó.
        try? await Store.saveSummary(text, for: String(repo.id))
        return text
    }
}

import Foundation

/// Tóm tắt repo bằng Claude. Kết quả cache vào cột `items.ai_summary`
/// nên mỗi repo chỉ tốn tiền đúng một lần, ai mở app sau cũng thấy sẵn.
enum AI {
    static var key: String {
        get {
            let e = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
            return e.isEmpty ? (UserDefaults.standard.string(forKey: "ANTHROPIC_API_KEY") ?? "") : e
        }
        set { UserDefaults.standard.set(newValue, forKey: "ANTHROPIC_API_KEY") }
    }
    static var isConfigured: Bool { !key.isEmpty }

    private struct Reply: Codable {
        let content: [Block]
        struct Block: Codable { let text: String? }
    }

    static func summarize(_ repo: Repo) async throws -> String {
        guard isConfigured else {
            throw NSError(domain: "ai", code: 401, userInfo: [NSLocalizedDescriptionKey:
                "Chưa có ANTHROPIC_API_KEY — bấm nút bánh răng trên toolbar để điền."])
        }
        let prompt = """
        Repo GitHub: \(repo.full_name)
        Ngôn ngữ: \(repo.language ?? "?") — \(repo.stargazers_count) sao
        Mô tả: \(repo.description ?? "(trống)")

        Trả lời bằng tiếng Việt, tối đa 3 câu: nó làm gì, hợp với ai, có đáng thử không.
        Nói thẳng, không markdown, không rào đón.
        """
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-5",
            "max_tokens": 300,
            "messages": [["role": "user", "content": prompt]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw NSError(domain: "anthropic", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey:
                "Claude \(h.statusCode): \(String(data: data, encoding: .utf8) ?? "")"])
        }
        let text = try JSONDecoder().decode(Reply.self, from: data)
            .content.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // Cache hỏng thì cũng đã có câu trả lời rồi, không chặn UI vì chuyện đó.
        try? await Store.saveSummary(text, for: String(repo.id))
        return text
    }
}

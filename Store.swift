import Foundation

/// Supabase (PostgREST) thay cho file JSON cũ: snapshot sao được lưu vào bảng
/// `metrics`, item vào `items` — nhiều nguồn crawl sau này dùng chung 2 bảng đó.
enum Store {
    struct NotConfigured: LocalizedError {
        var errorDescription: String? =
            "Chưa cấu hình Supabase. Set SUPABASE_URL và SUPABASE_ANON_KEY (hoặc điền trong app)."
    }

    /// Env cho lúc chạy từ terminal, UserDefaults cho lúc mở bằng Finder.
    static var url: String {
        get { value("SUPABASE_URL") }
        set { UserDefaults.standard.set(newValue, forKey: "SUPABASE_URL") }
    }
    static var key: String {
        get { value("SUPABASE_ANON_KEY") }
        set { UserDefaults.standard.set(newValue, forKey: "SUPABASE_ANON_KEY") }
    }
    static var isConfigured: Bool { !url.isEmpty && !key.isEmpty }

    private static func value(_ k: String) -> String {
        let env = ProcessInfo.processInfo.environment[k] ?? ""
        return env.isEmpty ? (UserDefaults.standard.string(forKey: k) ?? "") : env
    }

    private static func request(_ path: String, method: String = "GET",
                                body: Data? = nil, prefer: String? = nil) throws -> URLRequest {
        guard isConfigured, let u = URL(string: url.trimmingCharacters(in: .whitespaces) + "/rest/v1/" + path)
        else { throw NotConfigured() }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.httpBody = body
        r.setValue(key, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let p = prefer { r.setValue(p, forHTTPHeaderField: "Prefer") }
        return r
    }

    private static func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw NSError(domain: "supabase", code: h.statusCode, userInfo: [
                NSLocalizedDescriptionKey:
                    "Supabase \(h.statusCode): \(String(data: data, encoding: .utf8) ?? "")"])
        }
        return data
    }

    private struct Row: Codable { let id: Int64; let external_id: String }
    private struct Metric: Codable { let item_id: Int64; let score: Int }

    /// Upsert item + snapshot sao hôm nay, trả về sao của hôm qua theo repo id GitHub.
    static func sync(_ repos: [Repo], source: String = "github") async throws -> [String: Int] {
        guard !repos.isEmpty else { return [:] }

        let items = repos.map { r -> [String: Any] in
            ["source": source, "external_id": String(r.id), "url": r.html_url,
             "title": r.full_name, "description": r.description as Any? ?? NSNull(),
             "meta": ["language": r.language as Any? ?? NSNull()]]
        }
        let rows = try JSONDecoder().decode([Row].self, from: try await send(try request(
            "items?on_conflict=source,external_id&select=id,external_id",
            method: "POST", body: try JSONSerialization.data(withJSONObject: items),
            prefer: "resolution=merge-duplicates,return=representation")))

        let idByExternal = Dictionary(uniqueKeysWithValues: rows.map { ($0.external_id, $0.id) })

        // Lấy snapshot hôm qua trước khi ghi hôm nay, để delta không tự so với chính nó.
        let ids = rows.map { String($0.id) }.joined(separator: ",")
        let prev = try JSONDecoder().decode([Metric].self, from: try await send(try request(
            "metrics?select=item_id,score&day=eq.\(day(-1))&item_id=in.(\(ids))")))
        let prevByItem = Dictionary(uniqueKeysWithValues: prev.map { ($0.item_id, $0.score) })

        let metrics = repos.compactMap { r -> [String: Any]? in
            guard let id = idByExternal[String(r.id)] else { return nil }
            return ["item_id": id, "day": day(0), "score": r.stargazers_count]
        }
        _ = try await send(try request("metrics?on_conflict=item_id,day", method: "POST",
                                       body: try JSONSerialization.data(withJSONObject: metrics),
                                       prefer: "resolution=merge-duplicates,return=minimal"))

        return Dictionary(uniqueKeysWithValues: repos.compactMap { r in
            idByExternal[String(r.id)].flatMap { prevByItem[$0] }.map { (String(r.id), $0) }
        })
    }

    static func day(_ offset: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
    }
}

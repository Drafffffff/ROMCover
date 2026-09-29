import Foundation

public struct NameResolution: Sendable {
    public let title: String?
    public let alternatives: [String]
    public let confidence: String

    public init(title: String?, alternatives: [String], confidence: String) {
        self.title = title
        self.alternatives = alternatives
        self.confidence = confidence
    }
}

public actor DeepSeekNameResolver {
    private let session: URLSession
    private var cache: [String: NameResolution] = [:]

    public init(session: URLSession = .shared) { self.session = session }

    public func resolve(game: ROMGame, apiKey: String) async throws -> NameResolution {
        let cacheKey = "\(game.system?.rawValue ?? "unknown"):\(game.stem)"
        if let cached = cache[cacheKey] { return cached }
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { throw ROMCoverError.server(0) }
        let header = ROMHeader.title(for: game)
        let userPayload: [String: String] = [
            "platform": game.system?.name ?? "unknown",
            "filename": String(game.stem.prefix(240)),
            "internal_title": header ?? ""
        ]
        let userJSON = try JSONSerialization.data(withJSONObject: userPayload, options: [.sortedKeys])
        let systemPrompt = """
        You identify the original English release title of a retro video game from a ROM filename. Ignore inventory numbers, translation-group names, region tags, file size and patch versions. Use the platform and internal title as clues. Do not invent a title when uncertain. Reply with one JSON object only: {"english_title": string or null, "alternate_titles": array of strings, "confidence": "high" or "medium" or "low"}. Keep at most two alternate titles. JSON is required.
        """
        let body: [String: Any] = [
            "model": "deepseek-flash",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": String(decoding: userJSON, as: UTF8.self)]
            ],
            "response_format": ["type": "json_object"],
            "thinking": ["type": "disabled"],
            "temperature": 0,
            "max_tokens": 160,
            "stream": false
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ROMCoverError.server(0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw ROMCoverError.invalidDeepSeekKey }
        guard http.statusCode == 200 else { throw ROMCoverError.server(http.statusCode) }
        let completion = try JSONDecoder().decode(Completion.self, from: data)
        guard completion.choices.first?.finishReason == "stop",
              let content = completion.choices.first?.message.content,
              let contentData = content.data(using: .utf8) else { throw ROMCoverError.unsupportedProfile("DeepSeek 未返回完整解析结果。") }
        let parsed = try JSONDecoder().decode(ParsedTitle.self, from: contentData)
        let title = clean(parsed.englishTitle)
        var seen = Set<String>()
        let alternatives = (parsed.alternateTitles ?? []).compactMap(clean)
            .filter { $0 != title && seen.insert($0).inserted }.prefix(2)
        let confidence = parsed.confidence.flatMap { ["high", "medium", "low"].contains($0) ? $0 : nil } ?? "low"
        let result = NameResolution(title: title, alternatives: Array(alternatives), confidence: confidence)
        cache[cacheKey] = result
        return result
    }

    private func clean(_ value: String?) -> String? {
        guard let title = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.count <= 120,
              title.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return nil }
        return title
    }

    private struct Completion: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let finishReason: String
            let message: Message
            enum CodingKeys: String, CodingKey { case finishReason = "finish_reason", message }
        }
        struct Message: Decodable { let content: String? }
    }

    private struct ParsedTitle: Decodable {
        let englishTitle: String?
        let alternateTitles: [String]?
        let confidence: String?
        enum CodingKeys: String, CodingKey {
            case englishTitle = "english_title", alternateTitles = "alternate_titles", confidence
        }
    }
}

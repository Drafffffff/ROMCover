import Foundation
import Security

public enum KeychainReadResult: Sendable {
    case value(String)
    case notFound
    case authorizationRequired
    case failed(OSStatus)
}

private enum KeychainStore {
    private static let account = "api-key"

    static func read(service: String) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .failed(errSecDecode)
            }
            return .value(value)
        case errSecItemNotFound: return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .authorizationRequired
        default: return .failed(status)
        }
    }

    static func save(_ key: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if key.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

public enum APIKeyStore {
    private static let service = "ROMCover.SteamGridDB"
    public static func read() -> KeychainReadResult { KeychainStore.read(service: service) }
    public static func save(_ key: String) throws { try KeychainStore.save(key, service: service) }
}

public enum DeepSeekKeyStore {
    private static let service = "ROMCover.DeepSeek"
    public static func read() -> KeychainReadResult { KeychainStore.read(service: service) }
    public static func save(_ key: String) throws { try KeychainStore.save(key, service: service) }
}

public actor ArtworkService {
    private let session: URLSession
    private struct IndexedArt {
        let name: String
        let normalized: String
        let url: URL
    }
    private var indexCache: [GameSystem: [IndexedArt]] = [:]
    private var ndsTitlesBySerial: [String: [String]]?

    public init(session: URLSession = .shared) { self.session = session }

    public func candidates(for game: ROMGame, order: [ArtworkSource], apiKey: String?) async throws -> [ArtworkCandidate] {
        guard let system = game.system else { throw ROMCoverError.noSystem }
        var collected: [ArtworkCandidate] = []
        var lastError: Error?
        for source in order {
            try Task.checkCancellation()
            do {
                let found: [ArtworkCandidate]
                switch source {
                case .libretro: found = try await libretroCandidates(game: game, system: system)
                case .steamGridDB:
                    guard let apiKey, !apiKey.isEmpty else { continue }
                    found = try await steamCandidates(game: game, key: apiKey)
                }
                collected.append(contentsOf: found)
                if !found.isEmpty { break }
            } catch { lastError = error }
        }
        if collected.isEmpty, let lastError { throw lastError }
        return collected
    }

    private func libretroCandidates(game: ROMGame, system: GameSystem) async throws -> [ArtworkCandidate] {
        if let index = try? await libretroIndex(for: system) {
            let header = ROMHeader.title(for: game)
            let queries: [(raw: String, normalized: String, weight: Double)] =
                ([(game.stem, 0.99), (game.searchTitle, 0.89)] +
                 (system == .nds ? [] : (header.map { [($0, 0.78)] } ?? [])))
                .map { ($0.0, TitleNormalizer.comparable($0.0), $0.1) }
            var scored: [(IndexedArt, Double, String)] = []
            for art in index {
                var best = 0.0
                var note = ""
                for query in queries {
                    guard query.normalized.count >= 5 else { continue }
                    let score: Double
                    if art.name.caseInsensitiveCompare(query.raw) == .orderedSame { score = query.weight }
                    else if art.normalized == query.normalized { score = min(query.weight, 0.89) }
                    else { continue }
                    if score > best {
                        best = score
                        note = query.raw == header ? "按 ROM 内部标题匹配，请核对版本" : (score >= 0.95 ? "文件名精确匹配" : "标题匹配，请核对地区版本")
                    }
                }
                if best > 0 { scored.append((art, best, note)) }
            }
            if scored.isEmpty, system == .nds,
               let serial = ROMHeader.ndsSerial(for: game),
               let titles = try? await ndsCatalogTitles(for: serial) {
                let keys = Set(titles.map(TitleNormalizer.comparable))
                let matches = index.filter { keys.contains($0.normalized) }
                let exactNames = Set(titles.map { $0.lowercased() })
                let exactCount = matches.filter { exactNames.contains($0.name.lowercased()) }.count
                for art in matches {
                    let exact = exactNames.contains(art.name.lowercased())
                    let uniqueExact = exact && exactCount == 1
                    scored.append((art, uniqueExact ? 0.97 : 0.92,
                        uniqueExact ? "按 NDS 游戏代码 \(serial) 与地区唯一匹配" : "按 NDS 游戏代码 \(serial) 匹配，请核对版本"))
                }
            }
            if scored.isEmpty, system == .nds, let header {
                let normalized = TitleNormalizer.comparable(header)
                if normalized.count >= 5 {
                    for art in index where art.normalized == normalized {
                        scored.append((art, 0.78, "按 ROM 内部标题匹配，请核对版本"))
                    }
                }
            }
            if scored.isEmpty {
                let fuzzyQueries = [game.searchTitle, header].compactMap { $0 }
                    .map(TitleNormalizer.comparable).filter { $0.count >= 6 }
                for art in index {
                    for query in fuzzyQueries where art.normalized.first == query.first && abs(art.normalized.count - query.count) <= 4 {
                        let similarity = TitleNormalizer.similarityComparable(query, art.normalized)
                        if similarity >= 0.84 { scored.append((art, similarity * 0.78, "近似匹配，请人工确认")) }
                    }
                }
            }
            return scored.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return coverPreference($0.0.name, filename: game.stem) >
                    coverPreference($1.0.name, filename: game.stem)
            }.prefix(6).map { art, confidence, note in
                ArtworkCandidate(id: "libretro-\(art.url.absoluteString)", source: .libretro,
                    gameTitle: art.name, imageURL: art.url, previewURL: art.url,
                    confidence: confidence, note: note)
            }
        }
        // Directory listings are not guaranteed by the server; exact URLs remain a fallback.
        let names = Array(NSOrderedSet(array: [game.stem, game.searchTitle])) as? [String] ?? [game.stem, game.searchTitle]
        for (index, name) in names.enumerated() {
            let safeName = name.replacingOccurrences(of: #"[&*/:`<>?\\|\"]"#, with: "_", options: .regularExpression)
            var components = URLComponents()
            components.scheme = "https"
            components.host = "thumbnails.libretro.com"
            components.path = "/\(system.libretroFolder)/Named_Boxarts/\(safeName).png"
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 404 { continue }
            guard http.statusCode == 200 else { throw ROMCoverError.server(http.statusCode) }
            guard data.starts(with: [0x89, 0x50, 0x4e, 0x47]) else { continue }
            return [ArtworkCandidate(id: "libretro-\(url.absoluteString)", source: .libretro,
                gameTitle: name, imageURL: url, previewURL: url,
                confidence: index == 0 ? 0.99 : 0.88,
                note: index == 0 ? "文件名精确匹配" : "简化标题匹配")]
        }
        return []
    }

    private func coverPreference(_ title: String, filename: String) -> Int {
        let lower = title.lowercased()
        let upperFile = filename.uppercased()
        var score = 0
        if lower.contains("(proto)") || lower.contains("(demo)") ||
           lower.contains("(beta)") || lower.contains("(kiosk)") { score -= 10 }
        if lower.contains("(rev ") { score -= 1 }
        if upperFile.contains("(JP)") && lower.contains("(japan)") { score += 5 }
        if upperFile.contains("(US)") && lower.contains("(usa)") { score += 5 }
        if upperFile.contains("(EU)") && lower.contains("(europe)") { score += 5 }
        return score
    }

    private func libretroIndex(for system: GameSystem) async throws -> [IndexedArt] {
        if let cached = indexCache[system] { return cached }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "thumbnails.libretro.com"
        components.path = "/\(system.libretroFolder)/Named_Boxarts/"
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return [] }
        let pattern = #"href="([^\"]+\.png)""#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var result: [IndexedArt] = []
        for match in regex.matches(in: html, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let href = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
            let decoded = href.removingPercentEncoding ?? href
            let name = URL(fileURLWithPath: decoded).deletingPathExtension().lastPathComponent
            guard let imageURL = URL(string: href, relativeTo: url)?.absoluteURL else { continue }
            result.append(IndexedArt(name: name, normalized: TitleNormalizer.comparable(name), url: imageURL))
        }
        indexCache[system] = result
        return result
    }

    private func ndsCatalogTitles(for serial: String) async throws -> [String] {
        if let ndsTitlesBySerial { return ndsTitlesBySerial[serial] ?? [] }
        ndsTitlesBySerial = [:]
        // Libretro imports the No-Intro catalogue; the DS serial survives most translation patches.
        guard let url = URL(string: "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/no-intro/Nintendo%20-%20Nintendo%20DS.dat") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return [] }
        let catalog = Self.parseNDSCatalogue(text)
        ndsTitlesBySerial = catalog
        return catalog[serial] ?? []
    }

    public static func parseNDSCatalogue(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var inGame = false
        var name: String?
        var serial: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "game (" {
                inGame = true
                name = nil
                serial = nil
            } else if line == ")" && inGame {
                if let name, let serial, serial.count == 4 {
                    if result[serial]?.contains(name) != true { result[serial, default: []].append(name) }
                }
                inGame = false
            } else if inGame {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if name == nil, trimmed.hasPrefix("name \""), trimmed.hasSuffix("\"") {
                    name = String(trimmed.dropFirst(6).dropLast())
                } else if serial == nil, trimmed.hasPrefix("serial \""), trimmed.hasSuffix("\"") {
                    serial = String(trimmed.dropFirst(8).dropLast())
                }
            }
        }
        return result
    }

    private struct SGDBResponse<T: Decodable>: Decodable { let success: Bool; let data: T }
    private struct SGDBGame: Decodable { let id: Int; let name: String }
    private struct SGDBGrid: Decodable {
        let id: Int
        let url: URL
        let thumb: URL?
        let width: Int?
        let height: Int?
        let score: Int?
    }

    private func steamCandidates(game: ROMGame, key: String) async throws -> [ArtworkCandidate] {
        let query = game.searchTitle.unicodeScalars.contains(where: { CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}").contains($0) })
            ? (ROMHeader.title(for: game) ?? game.searchTitle) : game.searchTitle
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let searchURL = URL(string: "https://www.steamgriddb.com/api/v2/search/autocomplete/\(encoded)") else { return [] }
        let search: SGDBResponse<[SGDBGame]> = try await steamRequest(searchURL, key: key)
        let matches = search.data.map { ($0, TitleNormalizer.similarity(query, $0.name)) }
            .filter { $0.1 >= 0.65 }.sorted { $0.1 > $1.1 }.prefix(3)
        var candidates: [ArtworkCandidate] = []
        for (match, similarity) in matches {
            try Task.checkCancellation()
            guard let url = URL(string: "https://www.steamgriddb.com/api/v2/grids/game/\(match.id)") else { continue }
            let result: SGDBResponse<[SGDBGrid]> = try await steamRequest(url, key: key)
            for grid in result.data.filter({ $0.width == nil || $0.height == nil || $0.height! > $0.width! }).prefix(3) {
                candidates.append(ArtworkCandidate(id: "sgdb-\(grid.id)", source: .steamGridDB,
                    gameTitle: match.name, imageURL: grid.url, previewURL: grid.thumb ?? grid.url,
                    confidence: min(0.84, similarity * 0.84), note: "请核对平台与版本"))
            }
        }
        return candidates
    }

    private func steamRequest<T: Decodable>(_ url: URL, key: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ROMCoverError.server(0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw ROMCoverError.invalidAPIKey }
        guard http.statusCode == 200 else { throw ROMCoverError.server(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func imageData(for candidate: ArtworkCandidate) async throws -> Data {
        var request = URLRequest(url: candidate.imageURL)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ROMCoverError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

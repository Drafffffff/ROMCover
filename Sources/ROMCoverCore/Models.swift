import Foundation

public enum GameSystem: String, CaseIterable, Codable, Identifiable, Sendable {
    case nes, snes, n64, gb, gbc, gba, nds, n3ds, gamecube, wii
    case masterSystem, megaDrive, gameGear, saturn, dreamcast
    case ps1, ps2, psp, atari2600, arcade, pcEngine, neoGeo, wonderswan, wonderswanColor
    case fds, virtualBoy, segaCD, sega32x, pcEngineCD, atari5200, atari7800, atariLynx, atari8bit
    case neoGeoCD, neoGeoPocket, neoGeoPocketColor, msx, dos, atomiswave, naomi, fbneo

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .nes: "NES / FC"
        case .snes: "SNES / SFC"
        case .n64: "Nintendo 64"
        case .gb: "Game Boy"
        case .gbc: "Game Boy Color"
        case .gba: "Game Boy Advance"
        case .nds: "Nintendo DS"
        case .n3ds: "Nintendo 3DS"
        case .gamecube: "GameCube"
        case .wii: "Wii"
        case .masterSystem: "Master System"
        case .megaDrive: "Mega Drive / Genesis"
        case .gameGear: "Game Gear"
        case .saturn: "Saturn"
        case .dreamcast: "Dreamcast"
        case .ps1: "PlayStation"
        case .ps2: "PlayStation 2"
        case .psp: "PSP"
        case .atari2600: "Atari 2600"
        case .arcade: "Arcade"
        case .pcEngine: "PC Engine / TurboGrafx-16"
        case .neoGeo: "Neo Geo"
        case .wonderswan: "WonderSwan"
        case .wonderswanColor: "WonderSwan Color"
        case .fds: "Famicom Disk System"
        case .virtualBoy: "Virtual Boy"
        case .segaCD: "Mega-CD / Sega CD"
        case .sega32x: "Sega 32X"
        case .pcEngineCD: "PC Engine CD"
        case .atari5200: "Atari 5200"
        case .atari7800: "Atari 7800"
        case .atariLynx: "Atari Lynx"
        case .atari8bit: "Atari 8-bit"
        case .neoGeoCD: "Neo Geo CD"
        case .neoGeoPocket: "Neo Geo Pocket"
        case .neoGeoPocketColor: "Neo Geo Pocket Color"
        case .msx: "MSX"
        case .dos: "DOS"
        case .atomiswave: "Atomiswave"
        case .naomi: "Naomi"
        case .fbneo: "FBNeo Arcade"
        }
    }

    public var libretroFolder: String {
        switch self {
        case .nes: "Nintendo - Nintendo Entertainment System"
        case .snes: "Nintendo - Super Nintendo Entertainment System"
        case .n64: "Nintendo - Nintendo 64"
        case .gb: "Nintendo - Game Boy"
        case .gbc: "Nintendo - Game Boy Color"
        case .gba: "Nintendo - Game Boy Advance"
        case .nds: "Nintendo - Nintendo DS"
        case .n3ds: "Nintendo - Nintendo 3DS"
        case .gamecube: "Nintendo - GameCube"
        case .wii: "Nintendo - Wii"
        case .masterSystem: "Sega - Master System - Mark III"
        case .megaDrive: "Sega - Mega Drive - Genesis"
        case .gameGear: "Sega - Game Gear"
        case .saturn: "Sega - Saturn"
        case .dreamcast: "Sega - Dreamcast"
        case .ps1: "Sony - PlayStation"
        case .ps2: "Sony - PlayStation 2"
        case .psp: "Sony - PlayStation Portable"
        case .atari2600: "Atari - 2600"
        case .arcade: "MAME"
        case .pcEngine: "NEC - PC Engine - TurboGrafx 16"
        case .neoGeo: "SNK - Neo Geo"
        case .wonderswan: "Bandai - WonderSwan"
        case .wonderswanColor: "Bandai - WonderSwan Color"
        case .fds: "Nintendo - Family Computer Disk System"
        case .virtualBoy: "Nintendo - Virtual Boy"
        case .segaCD: "Sega - Mega-CD - Sega CD"
        case .sega32x: "Sega - 32X"
        case .pcEngineCD: "NEC - PC Engine CD - TurboGrafx-CD"
        case .atari5200: "Atari - 5200"
        case .atari7800: "Atari - 7800"
        case .atariLynx: "Atari - Lynx"
        case .atari8bit: "Atari - 8-bit"
        case .neoGeoCD: "SNK - Neo Geo CD"
        case .neoGeoPocket: "SNK - Neo Geo Pocket"
        case .neoGeoPocketColor: "SNK - Neo Geo Pocket Color"
        case .msx: "Microsoft - MSX"
        case .dos: "DOS"
        case .atomiswave: "Atomiswave"
        case .naomi: "Sega - Naomi"
        case .fbneo: "FBNeo - Arcade Games"
        }
    }
}

public enum ExportProfile: String, CaseIterable, Identifiable, Sendable {
    case anbernicStock = "安伯尼克原厂 Linux"
    case nextUI = "NextUI"
    case garlic = "GarlicOS"
    case muos = "muOS"
    case emulationStation = "KNULLI / Batocera / ArkOS"
    case onion = "OnionOS"
    case retroArch = "RetroArch"

    public var id: String { rawValue }
    public var requiresGamelist: Bool { self == .emulationStation }

    public static func suggest(for url: URL) -> ExportProfile? {
        let fm = FileManager.default
        let roots = [url, url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent()]
        if roots.contains(where: {
            fm.fileExists(atPath: $0.appendingPathComponent("nextui.pak_store.pakz").path) ||
            fm.fileExists(atPath: $0.appendingPathComponent("nextui.updater.pakz").path)
        }) { return .nextUI }
        if roots.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("MUOS/info/assign").path) }) { return .muos }
        if roots.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("miyoo").path) }) { return .onion }
        if roots.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("CFW/config/coremapping.json").path) }) { return .garlic }
        if roots.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("batocera").path) }) { return .emulationStation }
        return nil
    }
}

public enum ArtworkSource: String, CaseIterable, Identifiable, Sendable {
    case libretro = "Libretro"
    case steamGridDB = "SteamGridDB"
    public var id: String { rawValue }
}

public struct ROMGame: Identifiable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let rootURL: URL
    public var system: GameSystem?
    public let stem: String
    public var searchTitle: String
    public let relativePath: String
    public var detectionNote: String

    public init(fileURL: URL, rootURL: URL, system: GameSystem?, detectionNote: String = "") {
        self.id = UUID()
        self.fileURL = fileURL
        self.rootURL = rootURL
        self.system = system
        self.stem = fileURL.deletingPathExtension().lastPathComponent
        self.searchTitle = TitleNormalizer.searchTitle(for: stem)
        self.relativePath = ROMPath.relative(fileURL, to: rootURL) ?? fileURL.lastPathComponent
        self.detectionNote = detectionNote
    }
}

public enum ROMPath {
    public static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func relative(_ file: URL, to root: URL) -> String? {
        let rootPath = canonical(root).path
        let filePath = canonical(file).path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }
}

public struct ArtworkCandidate: Identifiable, Sendable {
    public let id: String
    public let source: ArtworkSource
    public let gameTitle: String
    public let imageURL: URL
    public let previewURL: URL
    public let confidence: Double
    public let note: String

    public init(id: String, source: ArtworkSource, gameTitle: String, imageURL: URL, previewURL: URL, confidence: Double, note: String = "") {
        self.id = id
        self.source = source
        self.gameTitle = gameTitle
        self.imageURL = imageURL
        self.previewURL = previewURL
        self.confidence = confidence
        self.note = note
    }
}

public enum ArtworkSelection {
    public static func candidate(from candidates: [ArtworkCandidate], selectedID: String?) -> ArtworkCandidate? {
        if let selectedID, let selected = candidates.first(where: { $0.id == selectedID }) {
            return selected
        }
        return candidates.first
    }
}

public struct ExportLocation: Sendable {
    public let imageURL: URL
    public let gamelistURL: URL?
    public let romPathInGamelist: String?
}

public enum ROMCoverError: LocalizedError {
    case unsupportedProfile(String)
    case noSystem
    case invalidImage
    case insufficientSpace
    case notWritable
    case invalidAPIKey
    case invalidDeepSeekKey
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile(let reason): reason
        case .noSystem: "无法识别游戏平台，请手动指定。"
        case .invalidImage: "下载的文件不是可读取的图片。"
        case .insufficientSpace: "目标磁盘剩余空间不足。"
        case .notWritable: "目标目录不可写。"
        case .invalidAPIKey: "SteamGridDB API Key 无效。"
        case .invalidDeepSeekKey: "DeepSeek API Key 无效。"
        case .server(let status): "封面服务返回 HTTP \(status)。"
        }
    }
}

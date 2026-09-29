import Foundation

public enum TitleNormalizer {
    public static func searchTitle(for filename: String) -> String {
        var name = filename
        name = name.replacingOccurrences(of: #"^\s*(?:0\d{2,4}|[A-Z])\s+"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\([^)]*(?:USA|Europe|Japan|World|Rev|Beta|Proto|Disc|Disk|Track|Demo|Korea|Australia)[^)]*\)"#, with: " ", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(of: #"\((?:JP|JPN|US|EU|EUR|CN|CHN|KS|KOR|TW|HK|简|繁|简中|繁中|官方简中|神游|DSi修复|[0-9.]+\s*[MG]B|[^)]*(?:汉化|翻译|配音|补丁|修正|公测|测试版|正式版|典藏版)[^)]*)\)"#, with: " ", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(of: #"(?:\s*[-_.]\s*)?(?:disc|disk|cd)\s*\d+"#, with: " ", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(of: #"[_]+"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func comparable(_ title: String) -> String {
        searchTitle(for: title).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        similarityComparable(comparable(a), comparable(b))
    }

    public static func similarityComparable(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x == y { return 1 }
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        for (i, character) in x.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: y.count)
            for (j, other) in y.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (character == other ? 0 : 1))
            }
            previous = current
        }
        return max(0, 1 - Double(previous[y.count]) / Double(max(x.count, y.count)))
    }
}

public enum SystemDetector {
    private static let aliases: [GameSystem: [String]] = [
        .nes: ["nes", "fc", "famicom", "nintendoentertainmentsystem"],
        .snes: ["snes", "sfc", "superfamicom", "supernintendo"],
        .n64: ["n64", "nintendo64"],
        .gb: ["gb", "gameboy"], .gbc: ["gbc", "gameboycolor"], .gba: ["gba", "gameboyadvance"],
        .nds: ["nds", "nintendods", "ds"], .n3ds: ["3ds", "nintendo3ds"],
        .gamecube: ["gc", "gamecube", "ngc"], .wii: ["wii"],
        .masterSystem: ["sms", "mastersystem"],
        .megaDrive: ["md", "megadrive", "genesis", "segagenesis"],
        .gameGear: ["gg", "gamegear"], .saturn: ["saturn", "ss", "segasaturn"],
        .dreamcast: ["dc", "dreamcast"],
        .ps1: ["ps", "ps1", "psx", "playstation", "sonyplaystation"],
        .ps2: ["ps2", "playstation2"], .psp: ["psp", "playstationportable"],
        .atari2600: ["a2600", "atari2600"], .arcade: ["arcade", "mame"],
        .pcEngine: ["pce", "pcengine", "tg16", "turbografx16"],
        .neoGeo: ["neogeo", "snkneogeo"], .wonderswan: ["ws", "wonderswan"],
        .wonderswanColor: ["wsc", "wonderswancolor"],
        .fds: ["fds"], .virtualBoy: ["vb", "virtualboy"],
        .segaCD: ["mdcd", "segacd", "megacd"], .sega32x: ["sega32x", "32x"],
        .pcEngineCD: ["pcecd", "pcenginecd", "tgcd"],
        .atari5200: ["a5200", "atari5200"], .atari7800: ["a7800", "atari7800"],
        .atariLynx: ["lynx", "atarilynx"], .atari8bit: ["a800", "atari8bit"],
        .neoGeoCD: ["neocd", "neogeocd"], .neoGeoPocket: ["ngp", "neogeopocket"],
        .neoGeoPocketColor: ["ngpc", "neogeopocketcolor"],
        .msx: ["msx", "msx2"], .dos: ["dos"],
        .atomiswave: ["atomiswave"], .naomi: ["naomi"],
        .fbneo: ["fbneo", "fba", "cps1", "cps2", "cps3"]
    ]
    private static let extensions: [String: GameSystem] = [
        "nes": .nes, "fds": .fds, "sfc": .snes, "smc": .snes, "n64": .n64, "z64": .n64, "v64": .n64,
        "gb": .gb, "gbc": .gbc, "gba": .gba, "nds": .nds, "3ds": .n3ds, "cia": .n3ds,
        "gcm": .gamecube, "rvz": .gamecube, "wbfs": .wii, "wud": .wii,
        "sms": .masterSystem, "md": .megaDrive, "gen": .megaDrive, "gg": .gameGear,
        "gdi": .dreamcast, "cdi": .dreamcast, "pbp": .ps1, "cso": .psp, "zso": .psp,
        "a26": .atari2600, "a52": .atari5200, "a78": .atari7800, "lnx": .atariLynx,
        "pce": .pcEngine, "ngp": .neoGeoPocket, "ngc": .neoGeoPocketColor,
        "ws": .wonderswan, "wsc": .wonderswanColor, "vb": .virtualBoy, "32x": .sega32x
    ]
    public static let supportedExtensions: Set<String> = Set(extensions.keys).union([
        "zip", "7z", "chd", "cue", "m3u", "iso", "bin", "img", "ccd", "nrg", "wad"
    ])

    public static func detect(_ url: URL, root: URL) -> (GameSystem?, String) {
        let relative = ROMPath.relative(url, to: root) ?? url.lastPathComponent
        let folders = relative.split(separator: "/").dropLast().map(String.init)
        for folder in folders.reversed() {
            let key = folder.lowercased().filter { $0.isLetter || $0.isNumber }
            if let system = aliases.first(where: { $0.value.contains(key) })?.key { return (system, "按 ROM 目录识别") }
        }
        let ext = url.pathExtension.lowercased()
        if let system = extensions[ext] { return (system, "按文件格式识别") }
        if ext == "zip", let entry = firstArchiveEntry(url) {
            let innerExt = URL(fileURLWithPath: entry).pathExtension.lowercased()
            if let system = extensions[innerExt] { return (system, "按 ZIP 内文件识别") }
        }
        if let system = headerSystem(url) { return (system, "按文件头识别") }
        return (nil, "格式可识别，但平台需要手动指定")
    }

    private static func headerSystem(_ url: URL) -> GameSystem? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16)) ?? Data()
        if data.starts(with: [0x4e, 0x45, 0x53, 0x1a]) { return .nes }
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return nil }
        return nil
    }

    private static func firstArchiveEntry(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z", "-1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.split(separator: "\n")
                .map(String.init).first(where: { supportedExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) })
        } catch { return nil }
    }
}

public struct ROMScanner {
    public init() {}

    public func scan(root: URL) throws -> [ROMGame] {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let scanRoot = children.first { $0.lastPathComponent.lowercased() == "roms" && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) } ?? root
        guard let enumerator = fm.enumerator(at: scanRoot, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: nil) else { return [] }
        var files: [URL] = []
        let ignoredFolders: Set<String> = ["imgs", "images", "box", "preview", "screenshots", "media", "bios", "saves", "states", "system"]
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if ignoredFolders.contains(url.lastPathComponent.lowercased()) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, SystemDetector.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
        }
        let allPaths = Set(files.map(\.standardizedFileURL))
        var referenced = Set<URL>()
        for file in files where ["m3u", "cue"].contains(file.pathExtension.lowercased()) {
            let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for line in content.components(separatedBy: .newlines) {
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard !cleaned.isEmpty, !cleaned.hasPrefix("#") else { continue }
                let name: String
                if file.pathExtension.lowercased() == "cue" {
                    guard cleaned.uppercased().hasPrefix("FILE "),
                          let first = cleaned.firstIndex(of: "\""),
                          let last = cleaned.lastIndex(of: "\""), first != last else { continue }
                    name = String(cleaned[cleaned.index(after: first)..<last])
                } else { name = cleaned }
                let target = file.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
                if allPaths.contains(target) { referenced.insert(target) }
            }
        }
        return files.filter { !referenced.contains($0.standardizedFileURL) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { file in
                let (system, note) = SystemDetector.detect(file, root: root)
                return ROMGame(fileURL: file, rootURL: root, system: system, detectionNote: note)
            }
    }
}

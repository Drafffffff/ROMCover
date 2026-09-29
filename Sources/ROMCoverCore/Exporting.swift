import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ExportPlanner {
    public init() {}

    public func location(for game: ROMGame, profile: ExportProfile) throws -> ExportLocation {
        guard let system = game.system else { throw ROMCoverError.noSystem }
        let systemFolder = systemRoot(for: game)
        let stem = game.stem
        switch profile {
        case .garlic, .onion:
            return ExportLocation(imageURL: imagePath(in: systemFolder.appendingPathComponent("Imgs"), stem: stem), gamelistURL: nil, romPathInGamelist: nil)
        case .anbernicStock:
            let gamelist = systemFolder.appendingPathComponent("gamelist.xml")
            return ExportLocation(imageURL: imagePath(in: systemFolder.appendingPathComponent("Imgs"), stem: stem),
                gamelistURL: FileManager.default.fileExists(atPath: gamelist.path) ? gamelist : nil,
                romPathInGamelist: romPath(game.fileURL, relativeTo: systemFolder))
        case .emulationStation:
            return ExportLocation(imageURL: imagePath(in: systemFolder.appendingPathComponent("images"), stem: stem),
                gamelistURL: systemFolder.appendingPathComponent("gamelist.xml"),
                romPathInGamelist: romPath(game.fileURL, relativeTo: systemFolder))
        case .muos:
            let card = cardRoot(for: game)
            let catalogue = catalogueName(for: game, system: system, card: card)
            return ExportLocation(imageURL: card.appendingPathComponent("MUOS/info/catalogue/\(catalogue)/box/\(stem).png"),
                gamelistURL: nil, romPathInGamelist: nil)
        case .retroArch:
            let card = cardRoot(for: game)
            let installed = card.appendingPathComponent("RetroArch/.retroarch/thumbnails")
            let direct = card.appendingPathComponent("thumbnails")
            let base = FileManager.default.fileExists(atPath: installed.path) ? installed : direct
            let safe = stem.replacingOccurrences(of: #"[&*/:`<>?\\|\"]"#, with: "_", options: .regularExpression)
            return ExportLocation(imageURL: base.appendingPathComponent("\(system.libretroFolder)/Named_Boxarts/\(safe).png"),
                gamelistURL: nil, romPathInGamelist: nil)
        }
    }

    private func imagePath(in folder: URL, stem: String) -> URL {
        let fm = FileManager.default
        for ext in ["png", "jpg", "jpeg"] {
            let url = folder.appendingPathComponent("\(stem).\(ext)")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return folder.appendingPathComponent("\(stem).png")
    }

    private func systemRoot(for game: ROMGame) -> URL {
        let root = ROMPath.canonical(game.rootURL)
        let file = ROMPath.canonical(game.fileURL)
        var current = file.deletingLastPathComponent()
        while current.path != root.path && current.path.hasPrefix(root.path + "/") {
            if ["roms", "rom", "games"].contains(current.deletingLastPathComponent().lastPathComponent.lowercased()) { return current }
            current = current.deletingLastPathComponent()
        }
        // Selecting a single system folder is also supported.
        if file.deletingLastPathComponent() == root { return root }
        let relative = ROMPath.relative(file, to: root) ?? file.lastPathComponent
        if let first = relative.split(separator: "/").first, relative.contains("/") {
            return root.appendingPathComponent(String(first))
        }
        return file.deletingLastPathComponent()
    }

    private func cardRoot(for game: ROMGame) -> URL {
        let root = ROMPath.canonical(game.rootURL)
        if ["roms", "rom", "games"].contains(root.lastPathComponent.lowercased()) { return root.deletingLastPathComponent() }
        if ["roms", "rom", "games"].contains(root.deletingLastPathComponent().lastPathComponent.lowercased()) {
            return root.deletingLastPathComponent().deletingLastPathComponent()
        }
        return root
    }

    private func catalogueName(for game: ROMGame, system: GameSystem, card: URL) -> String {
        let assignRoot = card.appendingPathComponent("MUOS/info/assign")
        let folderName = systemRoot(for: game).lastPathComponent
        let direct = assignRoot.appendingPathComponent(folderName).appendingPathComponent("global.ini")
        if let name = iniCatalogue(at: direct) { return name }
        if let folders = try? FileManager.default.contentsOfDirectory(at: assignRoot, includingPropertiesForKeys: nil) {
            let key = folderName.lowercased().filter { $0.isLetter || $0.isNumber }
            for folder in folders where folder.lastPathComponent.lowercased().filter({ $0.isLetter || $0.isNumber }) == key {
                if let name = iniCatalogue(at: folder.appendingPathComponent("global.ini")) { return name }
            }
        }
        return system.name
    }

    private func iniCatalogue(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 && parts[0].lowercased() == "catalogue" && !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }

    private func romPath(_ file: URL, relativeTo root: URL) -> String {
        "./" + (ROMPath.relative(file, to: root) ?? file.lastPathComponent)
    }
}

public enum ExportResult: Equatable {
    case written, skippedExisting
}

public final class ExportWriter {
    private let fm: FileManager
    private var backups = Set<URL>()

    public init(fileManager: FileManager = .default) { self.fm = fileManager }

    public func write(imageData: Data, game: ROMGame, profile: ExportProfile, replace: Bool) throws -> ExportResult {
        let location = try ExportPlanner().location(for: game, profile: profile)
        let destination = location.imageURL
        if !replace, let gamelist = location.gamelistURL,
           let romPath = location.romPathInGamelist,
           existingReferencedArtwork(in: gamelist, romPath: romPath) {
            return .skippedExisting
        }
        let exists = fm.fileExists(atPath: destination.path)
        if exists && !replace {
            if let gamelist = location.gamelistURL, let romPath = location.romPathInGamelist {
                try mergeGamelist(gamelist, romPath: romPath, image: destination, replace: false)
            }
            return .skippedExisting
        }
        let encoded = try Self.encodedImageData(from: imageData, maxPixel: profile.maxPixel,
            type: ["jpg", "jpeg"].contains(destination.pathExtension.lowercased()) ? .jpeg : .png)
        let parent = destination.deletingLastPathComponent()
        let writableAncestor = nearestExistingAncestor(of: parent)
        guard fm.isWritableFile(atPath: writableAncestor.path) else { throw ROMCoverError.notWritable }
        let capacity = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ??
            (try? writableAncestor.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
        if let capacity, Int64(capacity) < Int64(encoded.count + 1_048_576) { throw ROMCoverError.insufficientSpace }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".romcover-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        try encoded.write(to: temp, options: .atomic)
        if exists {
            let backup = destination.appendingPathExtension("romcover-backup")
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: destination, to: backup) }
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temp, to: destination)
        if let gamelist = location.gamelistURL, let romPath = location.romPathInGamelist {
            try mergeGamelist(gamelist, romPath: romPath, image: destination, replace: replace)
        }
        return .written
    }

    private func nearestExistingAncestor(of url: URL) -> URL {
        var current = url
        while !fm.fileExists(atPath: current.path) && current.path != "/" { current = current.deletingLastPathComponent() }
        return current
    }

    private func existingReferencedArtwork(in url: URL, romPath: String) -> Bool {
        guard fm.fileExists(atPath: url.path),
              let document = try? XMLDocument(contentsOf: url, options: []),
              let root = document.rootElement() else { return false }
        let normalize: (String) -> String = { $0.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "./", with: "", options: .anchored) }
        guard let entry = root.elements(forName: "game").first(where: {
            guard let path = $0.elements(forName: "path").first?.stringValue else { return false }
            return normalize(path) == normalize(romPath)
        }), let imagePath = entry.elements(forName: "image").first?.stringValue, !imagePath.isEmpty else { return false }
        let imageURL = url.deletingLastPathComponent().appendingPathComponent(imagePath).standardizedFileURL
        return fm.fileExists(atPath: imageURL.path)
    }

    private static func encodedImageData(from data: Data, maxPixel: Int, type: UTType) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw ROMCoverError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw ROMCoverError.invalidImage
        }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ROMCoverError.invalidImage }
        return output as Data
    }

    private func mergeGamelist(_ url: URL, romPath: String, image: URL, replace: Bool) throws {
        let document: XMLDocument
        if fm.fileExists(atPath: url.path) {
            if !backups.contains(url) {
                let backup = url.appendingPathExtension("romcover-backup")
                if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
                backups.insert(url)
            }
            document = try XMLDocument(contentsOf: url, options: [])
        } else {
            document = XMLDocument(rootElement: XMLElement(name: "gameList"))
            document.version = "1.0"
            document.characterEncoding = "UTF-8"
        }
        guard let root = document.rootElement(), root.name == "gameList" else {
            throw ROMCoverError.unsupportedProfile("gamelist.xml 不是有效的 gameList 文件。")
        }
        let normalize: (String) -> String = { $0.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "./", with: "", options: .anchored) }
        let entry = root.elements(forName: "game").first { element in
            guard let path = element.elements(forName: "path").first?.stringValue else { return false }
            return normalize(path) == normalize(romPath)
        } ?? {
            let element = XMLElement(name: "game")
            element.addChild(XMLElement(name: "path", stringValue: romPath))
            root.addChild(element)
            return element
        }()
        let relativeImage = "./" + image.path.replacingOccurrences(of: url.deletingLastPathComponent().path + "/", with: "")
        if let node = entry.elements(forName: "image").first {
            if replace || (node.stringValue ?? "").isEmpty { node.stringValue = relativeImage }
        }
        else { entry.addChild(XMLElement(name: "image", stringValue: relativeImage)) }
        let data = document.xmlData(options: [.nodePrettyPrint])
        try data.write(to: url, options: .atomic)
    }
}

private extension ExportProfile {
    var maxPixel: Int {
        switch self {
        case .garlic, .onion, .retroArch, .anbernicStock: 512
        case .muos, .emulationStation: 800
        }
    }
}

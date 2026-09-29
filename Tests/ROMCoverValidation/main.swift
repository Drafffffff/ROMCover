import Foundation
import ROMCoverCore

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ROMCoverValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func fixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ROMCoverValidation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l5sAAAAASUVORK5CYII=")!

do {
    let first = ArtworkCandidate(id: "first", source: .libretro, gameTitle: "First",
        imageURL: URL(string: "https://example.org/first.png")!,
        previewURL: URL(string: "https://example.org/first.png")!, confidence: 0.7)
    let second = ArtworkCandidate(id: "second", source: .libretro, gameTitle: "Second",
        imageURL: URL(string: "https://example.org/second.png")!,
        previewURL: URL(string: "https://example.org/second.png")!, confidence: 0.6)
    try expect(ArtworkSelection.candidate(from: [first, second], selectedID: nil)?.id == "first", "未确认项目没有默认使用第一张候选")
    try expect(ArtworkSelection.candidate(from: [first, second], selectedID: "second")?.id == "second", "手动选择没有覆盖默认候选")
    try expect(ArtworkSelection.candidate(from: [], selectedID: nil) == nil, "未命中项目不应写入")

    try fixture { root in
        let ps = root.appendingPathComponent("Roms/PS")
        let gba = root.appendingPathComponent("Roms/GBA")
        try FileManager.default.createDirectory(at: ps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gba, withIntermediateDirectories: true)
        try "FILE \"Game.bin\" BINARY\n".write(to: ps.appendingPathComponent("Game.cue"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: ps.appendingPathComponent("Game.bin"))
        try "Game.cue\n".write(to: ps.appendingPathComponent("Game.m3u"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: gba.appendingPathComponent("Zelda (USA).gba"))
        let games = try ROMScanner().scan(root: root)
        try expect(Set(games.map(\.fileURL.lastPathComponent)) == ["Game.m3u", "Zelda (USA).gba"], "多光盘游戏没有正确合并")
        try expect(games.first { $0.stem == "Game" }?.system == .ps1, "PS 平台识别失败")
        try expect(games.first { $0.stem == "Zelda (USA)" }?.system == .gba, "GBA 平台识别失败")
        try expect(TitleNormalizer.searchTitle(for: "Zelda (USA) [!]") == "Zelda", "标题清理失败")
        try expect(TitleNormalizer.searchTitle(for: "1500 DS Spirits Vol.1 麻將(JP)(E.Wings汉化组)(64Mb)") == "1500 DS Spirits Vol.1 麻將", "NDS 汉化标签清理失败")
        try expect(TitleNormalizer.searchTitle(for: "99滴眼泪(JP)(99滴眼泪全民汉化组)(256Mb)") == "99滴眼泪", "NDS 中文标题清理失败")
    }

    try fixture { root in
        let file = root.appendingPathComponent("NDS/Linked.nds")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 16).write(to: file)
        let alias = root.deletingLastPathComponent().appendingPathComponent("ROMCoverAlias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        let game = ROMGame(fileURL: file, rootURL: alias, system: .nds)
        try expect(game.relativePath == "NDS/Linked.nds", "符号链接目录的 ROM 相对路径错误")
        let location = try ExportPlanner().location(for: game, profile: .anbernicStock)
        try expect(location.imageURL.path.hasSuffix("/NDS/Imgs/Linked.png"), "符号链接目录的封面输出路径错误")
        try expect(location.imageURL.path.hasPrefix(ROMPath.canonical(root).path + "/"), "封面路径越过所选目录")
    }

    try fixture { root in
        let file = root.appendingPathComponent("Chinese Name (JP).nds")
        var header = Data(repeating: 0, count: 16)
        header.replaceSubrange(0..<9, with: Data("TEST GAME".utf8))
        header.replaceSubrange(12..<16, with: Data("AB3J".utf8))
        try header.write(to: file)
        let game = ROMGame(fileURL: file, rootURL: root, system: .nds)
        try expect(ROMHeader.ndsSerial(for: game) == "AB3J", "NDS 游戏代码读取失败")
        let catalog = ArtworkService.parseNDSCatalogue("""
        game (
            name "Test Game (Japan)"
            region "Japan"
            serial "AB3J"
            rom ( name "Test Game.nds" serial "AB3J" )
        )
        """)
        try expect(catalog["AB3J"] == ["Test Game (Japan)"], "NDS 标准标题目录解析失败")
    }

    try fixture { root in
        let file = root.appendingPathComponent("Roms/GBA/Metroid (USA).gba")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        let game = ROMGame(fileURL: file, rootURL: root, system: .gba)
        let planner = ExportPlanner()
        try expect(try planner.location(for: game, profile: .garlic).imageURL.path.hasSuffix("Roms/GBA/Imgs/Metroid (USA).png"), "GarlicOS 路径不正确")
        try expect(try planner.location(for: game, profile: .emulationStation).imageURL.path.hasSuffix("Roms/GBA/images/Metroid (USA).png"), "ES 路径不正确")
        try expect(try planner.location(for: game, profile: .muos).imageURL.path.hasSuffix("MUOS/info/catalogue/Game Boy Advance/box/Metroid (USA).png"), "muOS 路径不正确")
        try expect(try planner.location(for: game, profile: .retroArch).imageURL.path.hasSuffix("thumbnails/Nintendo - Game Boy Advance/Named_Boxarts/Metroid (USA).png"), "RetroArch 路径不正确")
    }

    try fixture { root in
        let system = root.appendingPathComponent("Roms/GBA")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        let file = system.appendingPathComponent("Metroid.gba")
        try Data([0]).write(to: file)
        let gamelist = system.appendingPathComponent("gamelist.xml")
        let original = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gameList><game><path>./Metroid.gba</path><name>Custom name</name><image>./old/cover.png</image><rating>0.8</rating></game></gameList>
        """
        try original.write(to: gamelist, atomically: true, encoding: .utf8)
        let game = ROMGame(fileURL: file, rootURL: root, system: .gba)
        let writer = ExportWriter()
        try expect(try writer.write(imageData: png, game: game, profile: .emulationStation, replace: false) == .written, "首次写入失败")
        try expect(try writer.write(imageData: png, game: game, profile: .emulationStation, replace: false) == .skippedExisting, "重复写入没有跳过")
        let text = try String(contentsOf: gamelist, encoding: .utf8)
        try expect(text.contains("Custom name") && text.contains("./old/cover.png") && text.contains("<rating>0.8</rating>"), "原有元数据被覆盖")
        try expect(text.components(separatedBy: "<game>").count - 1 == 1, "重复创建了游戏条目")
        try expect(FileManager.default.fileExists(atPath: gamelist.appendingPathExtension("romcover-backup").path), "没有备份 gamelist")
    }

    try fixture { root in
        let system = root.appendingPathComponent("Roms/SFC")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        let file = system.appendingPathComponent("Chrono Trigger.sfc")
        try Data([0]).write(to: file)
        let game = ROMGame(fileURL: file, rootURL: root, system: .snes)
        let writer = ExportWriter()
        try expect(try writer.write(imageData: png, game: game, profile: .emulationStation, replace: false) == .written, "缺失封面没有写入")
        let text = try String(contentsOf: system.appendingPathComponent("gamelist.xml"), encoding: .utf8)
        try expect(text.contains("./images/Chrono Trigger.png"), "未将封面路径写入 gamelist")
    }

    try fixture { root in
        let system = root.appendingPathComponent("Roms/GBA")
        let oldArt = system.appendingPathComponent("media/existing.jpg")
        try FileManager.default.createDirectory(at: oldArt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xff, 0xd8]).write(to: oldArt)
        let file = system.appendingPathComponent("Existing.gba")
        try Data([0]).write(to: file)
        let xml = "<gameList><game><path>./Existing.gba</path><image>./media/existing.jpg</image></game></gameList>"
        try xml.write(to: system.appendingPathComponent("gamelist.xml"), atomically: true, encoding: .utf8)
        let game = ROMGame(fileURL: file, rootURL: root, system: .gba)
        try expect(try ExportWriter().write(imageData: png, game: game, profile: .emulationStation, replace: false) == .skippedExisting,
            "已有 gamelist 图片未跳过")
        try expect(!FileManager.default.fileExists(atPath: system.appendingPathComponent("images/Existing.png").path), "生成了无用的新图片")
    }

    try fixture { root in
        let system = root.appendingPathComponent("ROMS/NDS")
        try FileManager.default.createDirectory(at: system.appendingPathComponent("Imgs"), withIntermediateDirectories: true)
        let file = system.appendingPathComponent("Test.nds")
        let jpg = system.appendingPathComponent("Imgs/Test.jpg")
        try Data([0]).write(to: file)
        try Data([0xff, 0xd8, 0xff]).write(to: jpg)
        let game = ROMGame(fileURL: file, rootURL: root, system: .nds)
        try expect(try ExportPlanner().location(for: game, profile: .anbernicStock).imageURL == jpg, "原厂卡已有 JPG 未识别")
        let writer = ExportWriter()
        try expect(try writer.write(imageData: png, game: game, profile: .anbernicStock, replace: false) == .skippedExisting, "原厂卡已有封面未跳过")
        try expect(!FileManager.default.fileExists(atPath: system.appendingPathComponent("gamelist.xml").path), "原厂卡被新建了 gamelist")
        try expect(try writer.write(imageData: png, game: game, profile: .anbernicStock, replace: true) == .written, "JPG 替换失败")
        try expect(try Data(contentsOf: jpg).starts(with: [0xff, 0xd8]), "JPG 替换输出不是 JPEG")
    }

    if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--rgds-card" {
        let card = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let file = card.appendingPathComponent("ROMS/GB/A 奥特曼.gb")
        try expect(FileManager.default.fileExists(atPath: file.path), "RG DS Plus 样本文件不存在")
        let game = ROMGame(fileURL: file, rootURL: card, system: .gb)
        let location = try ExportPlanner().location(for: game, profile: .anbernicStock)
        try expect(FileManager.default.fileExists(atPath: location.imageURL.path), "RG DS Plus 已有封面未定位")
        try expect(location.gamelistURL == nil, "RG DS Plus 不应创建 gamelist")
        let games = try ROMScanner().scan(root: card)
        try expect(games.count > 100, "RG DS Plus ROM 目录没有被扫描")
        let planner = ExportPlanner()
        let existing = games.filter { game in
            guard let path = try? planner.location(for: game, profile: .anbernicStock).imageURL else { return false }
            return FileManager.default.fileExists(atPath: path.path)
        }.count
        print("RG DS Plus card layout verified read-only: \(games.count) ROM entries, \(existing) existing covers")
    }

    print("ROMCover validation passed")
} catch {
    fputs("ROMCover validation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

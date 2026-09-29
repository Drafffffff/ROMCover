import Foundation
import ROMCoverCore

@main
struct LiveValidation {
    static func main() async {
        do {
            let root = URL(fileURLWithPath: "/tmp/ROMCoverLiveValidation")
            let file = root.appendingPathComponent("Roms/GB/4-in-1 Fun Pak (USA, Europe).gb")
            let game = ROMGame(fileURL: file, rootURL: root, system: .gb)
            let service = ArtworkService()
            let candidates = try await service.candidates(for: game, order: [.libretro], apiKey: nil)
            guard candidates.first?.gameTitle == "4-in-1 Fun Pak (USA, Europe)" else {
                throw NSError(domain: "ROMCoverLiveValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Libretro 目录匹配失败"])
            }
            print("Libretro live lookup passed: \(candidates.count) candidates")
            if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--rgds-card" {
                let card = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                let sample = card.appendingPathComponent("ROMS/GB/A 奥特曼.gb")
                let chineseGame = ROMGame(fileURL: sample, rootURL: card, system: .gb)
                guard ROMHeader.title(for: chineseGame) == "ULTRAMAN" else {
                    throw NSError(domain: "ROMCoverLiveValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "ROM 内部标题提取失败"])
                }
                let art = try await service.candidates(for: chineseGame, order: [.libretro], apiKey: nil)
                guard art.contains(where: { $0.gameTitle.localizedCaseInsensitiveContains("Ultraman") }) else {
                    throw NSError(domain: "ROMCoverLiveValidation", code: 3, userInfo: [NSLocalizedDescriptionKey: "中文 ROM 未能通过内部标题找到候选"])
                }
                print("RG DS Plus Chinese ROM lookup passed: \(art.count) candidates")
            }
            if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--nds-sample" {
                let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                let games = try ROMScanner().scan(root: folder).filter { $0.system == .nds }
                var matched = 0
                var serialMatched = 0
                var autoSelected = 0
                var unmatched: [String] = []
                var toReview: [String] = []
                for game in games {
                    let results = try await service.candidates(for: game, order: [.libretro], apiKey: nil)
                    if !results.isEmpty {
                        matched += 1
                        if results.first?.note.contains("NDS 游戏代码") == true { serialMatched += 1 }
                        if (results.first?.confidence ?? 0) >= 0.95 &&
                           (results.dropFirst().first?.confidence ?? 0) < 0.95 { autoSelected += 1 }
                        else { toReview.append(game.stem) }
                    } else { unmatched.append(game.stem) }
                }
                guard games.count >= 100,
                      Double(matched) / Double(games.count) >= 0.9,
                      Double(serialMatched) / Double(games.count) >= 0.6,
                      Double(autoSelected) / Double(games.count) >= 0.4 else {
                    throw NSError(domain: "ROMCoverLiveValidation", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "NDS 样本匹配率不足：候选 \(matched)，代码 \(serialMatched)，预选 \(autoSelected)／\(games.count)"])
                }
                print("NDS sample lookup passed: \(matched)/\(games.count) ROMs have Libretro candidates; \(serialMatched) via serial; \(autoSelected) auto-selectable")
                if !toReview.isEmpty { print("Needs review examples: \(toReview.prefix(5).joined(separator: " | "))") }
                if !unmatched.isEmpty { print("No candidate: \(unmatched.prefix(8).joined(separator: " | "))") }
            }
            if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--selection-fixture" {
                let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                let games = try ROMScanner().scan(root: folder)
                guard let reviewGame = games.first(where: { $0.stem.contains("茶犬的房间DS") }),
                      let missingGame = games.first(where: { $0.stem.contains("未知游戏") }) else {
                    throw NSError(domain: "ROMCoverLiveValidation", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "临时验证样本不完整"])
                }
                let choices = try await service.candidates(for: reviewGame, order: [.libretro], apiKey: nil)
                guard choices.count >= 2,
                      let first = ArtworkSelection.candidate(from: choices, selectedID: nil),
                      first.id == choices[0].id else {
                    throw NSError(domain: "ROMCoverLiveValidation", code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "待确认游戏未使用首张候选"])
                }
                let missing = try await service.candidates(for: missingGame, order: [.libretro], apiKey: nil)
                guard ArtworkSelection.candidate(from: missing, selectedID: nil) == nil else {
                    throw NSError(domain: "ROMCoverLiveValidation", code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "未命中游戏不应写入"])
                }
                let location = try ExportPlanner().location(for: reviewGame, profile: .anbernicStock)
                guard location.imageURL.path.hasPrefix(ROMPath.canonical(folder).path + "/Imgs/") else {
                    throw NSError(domain: "ROMCoverLiveValidation", code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "输出路径越过临时目录：\(location.imageURL.path)"])
                }
                let data = try await service.imageData(for: first)
                let result = try ExportWriter().write(imageData: data, game: reviewGame, profile: .anbernicStock, replace: false)
                guard result == .written, FileManager.default.fileExists(atPath: location.imageURL.path) else {
                    throw NSError(domain: "ROMCoverLiveValidation", code: 9,
                        userInfo: [NSLocalizedDescriptionKey: "首张候选未写入临时目录"])
                }
                print("Default-candidate export passed: \(first.gameTitle) → \(location.imageURL.path)")
            }
        } catch {
            fputs("Live validation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

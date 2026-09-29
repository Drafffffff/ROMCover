import Foundation

public enum ROMHeader {
    public static func ndsSerial(for game: ROMGame) -> String? {
        guard game.system == .nds, game.fileURL.pathExtension.lowercased() == "nds",
              let handle = try? FileHandle(forReadingFrom: game.fileURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 12)
            guard let data = try handle.read(upToCount: 4), data.count == 4,
                  data.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) }) else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch { return nil }
    }

    public static func title(for game: ROMGame) -> String? {
        let range: (offset: UInt64, count: Int)
        switch game.system {
        case .gb, .gbc: range = (0x134, 16)
        case .gba: range = (0xA0, 12)
        case .nds: range = (0, 12)
        case .n64: range = (0x20, 20)
        default: return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: game.fileURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: range.offset)
            let data = try handle.read(upToCount: range.count) ?? Data()
            let bytes = data.prefix { $0 != 0 }
            guard bytes.count >= 5, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
            let title = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard TitleNormalizer.comparable(title).count >= 5 else { return nil }
            return title
        } catch { return nil }
    }
}

import SwiftUI
import AppKit
import ROMCoverCore

@main
struct ROMCoverApp: App {
    @StateObject private var model = LibraryModel()

    var body: some Scene {
        WindowGroup("ROMCover") { ContentView().environmentObject(model) }
            .defaultSize(width: 1220, height: 760)
            .windowStyle(.hiddenTitleBar)
        Settings { SettingsView().environmentObject(model) }
    }
}

enum RowState: Equatable {
    case unsearched, searching, resolving, ready, needsReview, missing, exported, skipped, failed(String)

    var text: String {
        switch self {
        case .unsearched: "待搜索"
        case .searching: "搜索中"
        case .resolving: "AI 解析中"
        case .ready: "待写入"
        case .needsReview: "待确认"
        case .missing: "未找到"
        case .exported: "已写入"
        case .skipped: "已有封面"
        case .failed(let message): "失败：\(message)"
        }
    }

    var tint: Color {
        switch self {
        case .ready, .exported: .green
        case .needsReview: .orange
        case .missing, .failed: .red
        case .skipped: .secondary
        default: .blue
        }
    }
}

enum GameStatusFilter: String, CaseIterable, Identifiable {
    case all, needsReview, missing, ready, skipped, exported, failed, pending

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部"
        case .needsReview: "待确认"
        case .missing: "未命中"
        case .ready: "待写入"
        case .skipped: "已有封面"
        case .exported: "已写入"
        case .failed: "失败"
        case .pending: "待处理"
        }
    }

    func includes(_ state: RowState) -> Bool {
        switch (self, state) {
        case (.all, _), (.needsReview, .needsReview), (.missing, .missing),
             (.ready, .ready), (.skipped, .skipped), (.exported, .exported),
             (.failed, .failed), (.pending, .unsearched),
             (.pending, .searching), (.pending, .resolving): true
        default: false
        }
    }
}

struct GameRow: Identifiable {
    var game: ROMGame
    var id: UUID { game.id }
    var candidates: [ArtworkCandidate] = []
    var selectedCandidateID: String?
    var aiSuggestion: String?
    var state: RowState = .unsearched
    var replace = false
    var selectedCandidate: ArtworkCandidate? { candidates.first { $0.id == selectedCandidateID } }
    var exportCandidate: ArtworkCandidate? {
        guard game.system != nil else { return nil }
        switch state {
        case .ready, .needsReview, .failed:
            return ArtworkSelection.candidate(from: candidates, selectedID: selectedCandidateID)
        default: return nil
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var rows: [GameRow] = []
    @Published var selectedID: UUID?
    @Published var profile: ExportProfile = .anbernicStock
    @Published var steamFirst = false
    @Published var apiKey = ""
    @Published var deepSeekAPIKey = ""
    @Published var steamKeyNeedsAuthorization = false
    @Published var deepSeekKeyNeedsAuthorization = false
    @Published var useDeepSeek = UserDefaults.standard.bool(forKey: "useDeepSeekNameResolution") {
        didSet { UserDefaults.standard.set(useDeepSeek, forKey: "useDeepSeekNameResolution") }
    }
    @Published var message = "选择 ROM 文件夹或掌机存储卡开始。"
    @Published var isBusy = false
    @Published var progress = 0.0

    private let service = ArtworkService()
    private let nameResolver = DeepSeekNameResolver()
    private var activeTask: Task<Void, Never>?
    private var securityScopedURL: URL?

    var selectedIndex: Int? { rows.firstIndex { $0.id == selectedID } }
    var canExport: Bool { rows.contains { $0.exportCandidate != nil } && !isBusy }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择 ROM 文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        activeTask?.cancel()
        if let securityScopedURL { securityScopedURL.stopAccessingSecurityScopedResource() }
        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        rootURL = url
        rows = []
        selectedID = nil
        profile = suggestProfile(at: url) ?? .anbernicStock
        isBusy = true
        message = "正在扫描…"
        activeTask = Task {
            do {
                let scanTask = Task.detached { try ROMScanner().scan(root: url) }
                let games = try await withTaskCancellationHandler {
                    try await scanTask.value
                } onCancel: {
                    scanTask.cancel()
                }
                try Task.checkCancellation()
                rows = games.map { GameRow(game: $0) }
                selectedID = rows.first?.id
                message = "找到 \(rows.count) 个游戏；\(rows.filter { $0.game.system == nil }.count) 个需要指定平台。"
                isBusy = false
                if !rows.isEmpty { search() }
            } catch is CancellationError { message = "扫描已取消。" }
            catch { message = "扫描失败：\(error.localizedDescription)" }
            if isBusy && rows.isEmpty { isBusy = false }
        }
    }

    func search() {
        guard !isBusy else { return }
        isBusy = true
        progress = 0
        message = "正在查找封面…"
        let order: [ArtworkSource] = steamFirst ? [.steamGridDB, .libretro] : [.libretro, .steamGridDB]
        activeTask = Task {
            let count = rows.count
            var aiAuthFailed = false
            for index in rows.indices {
                if Task.isCancelled { break }
                guard rows[index].game.system != nil, rows[index].state != .exported else { continue }
                if !rows[index].replace,
                   let location = try? ExportPlanner().location(for: rows[index].game, profile: profile),
                   FileManager.default.fileExists(atPath: location.imageURL.path) {
                    rows[index].state = .skipped
                    progress = Double(index + 1) / Double(max(count, 1))
                    continue
                }
                rows[index].state = .searching
                do {
                    let result = try await lookup(at: index, order: order, allowAI: !aiAuthFailed)
                    applyCandidates(result.candidates, at: index, aiTitle: result.aiTitle)
                } catch is CancellationError { break }
                catch ROMCoverError.invalidDeepSeekKey {
                    aiAuthFailed = true
                    rows[index].state = .failed(ROMCoverError.invalidDeepSeekKey.localizedDescription)
                }
                catch { rows[index].state = .failed(error.localizedDescription) }
                progress = Double(index + 1) / Double(max(count, 1))
            }
            if Task.isCancelled {
                message = "搜索已取消，可再次继续。"
            } else if steamKeyNeedsAuthorization || (useDeepSeek && deepSeekKeyNeedsAuthorization) {
                message = "搜索完成。已保存的 API Key 需要在 API 设置中授权读取。"
            } else {
                message = "搜索完成。待确认项目默认使用第一张候选，也可手动改选。"
            }
            isBusy = false
        }
    }

    func searchSelected(forceAI: Bool = false) {
        guard !isBusy, let index = selectedIndex, rows[index].game.system != nil else { return }
        let previous = rows[index]
        isBusy = true
        rows[index].state = .searching
        let order: [ArtworkSource] = steamFirst ? [.steamGridDB, .libretro] : [.libretro, .steamGridDB]
        activeTask = Task {
            do {
                let result = try await lookup(at: index, order: order, allowAI: true, forceAI: forceAI)
                applyCandidates(result.candidates, at: index, aiTitle: result.aiTitle)
                message = result.candidates.isEmpty ? "此游戏没有找到封面，请尝试英文标题。" : "找到 \(result.candidates.count) 张候选封面。"
            } catch is CancellationError { message = "搜索已取消。" }
            catch {
                if forceAI && !previous.candidates.isEmpty {
                    rows[index] = previous
                    message = "DeepSeek 解析失败：\(error.localizedDescription)。原有候选封面已保留。"
                } else {
                    rows[index].state = .failed(error.localizedDescription)
                    message = "搜索失败：\(error.localizedDescription)"
                }
            }
            isBusy = false
        }
    }

    private func lookup(at index: Int, order: [ArtworkSource], allowAI: Bool, forceAI: Bool = false) async throws -> (candidates: [ArtworkCandidate], aiTitle: String?) {
        let game = rows[index].game
        let initial = forceAI ? rows[index].candidates : try await service.candidates(for: game, order: order, apiKey: apiKey)
        guard (initial.isEmpty || forceAI), allowAI, (useDeepSeek || forceAI),
              !deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (initial, nil)
        }
        rows[index].state = .resolving
        let resolution = try await nameResolver.resolve(game: game, apiKey: deepSeekAPIKey)
        let titles = ([resolution.title] + resolution.alternatives.map(Optional.some)).compactMap { $0 }
        for title in titles {
            try Task.checkCancellation()
            var inferred = game
            inferred.searchTitle = title
            let found = try await service.candidates(for: inferred, order: order, apiKey: apiKey)
            if !found.isEmpty { return (found, title) }
        }
        return (initial, resolution.title)
    }

    private func applyCandidates(_ found: [ArtworkCandidate], at index: Int, aiTitle: String? = nil) {
        rows[index].candidates = found
        rows[index].aiSuggestion = aiTitle
        if let aiTitle { rows[index].game.searchTitle = aiTitle }
        let isUniqueExact = aiTitle == nil && (found.first.map { $0.confidence >= 0.95 && (found.dropFirst().first?.confidence ?? 0) < 0.95 } ?? false)
        if isUniqueExact, let first = found.first {
            rows[index].selectedCandidateID = first.id
            rows[index].state = .ready
        } else {
            rows[index].selectedCandidateID = nil
            rows[index].state = found.isEmpty ? .missing : .needsReview
        }
    }

    func export() {
        guard !isBusy else { return }
        isBusy = true
        progress = 0
        message = "正在写入封面…"
        let writer = ExportWriter()
        activeTask = Task {
            let eligible = rows.indices.filter { rows[$0].exportCandidate != nil }
            var written = 0, skipped = 0, failed = 0
            for (offset, index) in eligible.enumerated() {
                if Task.isCancelled { break }
                guard let candidate = rows[index].exportCandidate else { continue }
                do {
                    let data = try await service.imageData(for: candidate)
                    try Task.checkCancellation()
                    switch try writer.write(imageData: data, game: rows[index].game, profile: profile, replace: rows[index].replace) {
                    case .written: rows[index].state = .exported; written += 1
                    case .skippedExisting: rows[index].state = .skipped; skipped += 1
                    }
                } catch is CancellationError { break }
                catch { rows[index].state = .failed(error.localizedDescription); failed += 1 }
                progress = Double(offset + 1) / Double(max(eligible.count, 1))
            }
            message = "已写入 \(written)，已有跳过 \(skipped)，失败 \(failed)。" + (Task.isCancelled ? " 操作已取消。" : "")
            isBusy = false
        }
    }

    func cancel() { activeTask?.cancel() }

    func applySystemToUnknown(_ system: GameSystem) {
        for index in rows.indices where rows[index].game.system == nil {
            rows[index].game.system = system
            rows[index].game.detectionNote = "手动批量指定"
        }
    }

    func saveKey() {
        do {
            try APIKeyStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            steamKeyNeedsAuthorization = false
            message = "API Key 已保存到钥匙串。"
        }
        catch { message = "保存 API Key 失败：\(error.localizedDescription)" }
    }

    func saveDeepSeekKey() {
        do {
            try DeepSeekKeyStore.save(deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
            deepSeekKeyNeedsAuthorization = false
            message = "DeepSeek API Key 已保存到钥匙串。"
        }
        catch { message = "保存 DeepSeek API Key 失败：\(error.localizedDescription)" }
    }

    func authorizeSteamKey() {
        switch APIKeyStore.read() {
        case .value(let key):
            apiKey = key
            steamKeyNeedsAuthorization = false
            message = "已读取 SteamGridDB API Key。"
        case .notFound:
            steamKeyNeedsAuthorization = false
            message = "钥匙串中没有已保存的 SteamGridDB API Key。"
        case .authorizationRequired:
            steamKeyNeedsAuthorization = true
            message = "未获得读取 SteamGridDB API Key 的授权。"
        case .failed(let status):
            message = "读取 SteamGridDB API Key 失败（\(status)）。"
        }
    }

    func authorizeDeepSeekKey() {
        switch DeepSeekKeyStore.read() {
        case .value(let key):
            deepSeekAPIKey = key
            deepSeekKeyNeedsAuthorization = false
            message = "已读取 DeepSeek API Key。"
        case .notFound:
            deepSeekKeyNeedsAuthorization = false
            message = "钥匙串中没有已保存的 DeepSeek API Key。"
        case .authorizationRequired:
            deepSeekKeyNeedsAuthorization = true
            message = "未获得读取 DeepSeek API Key 的授权。"
        case .failed(let status):
            message = "读取 DeepSeek API Key 失败（\(status)）。"
        }
    }

    private func suggestProfile(at url: URL) -> ExportProfile? {
        let fm = FileManager.default
        let root = [url, url.deletingLastPathComponent()]
        if root.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("MUOS/info/assign").path) }) { return .muos }
        if root.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("miyoo").path) }) { return .onion }
        if root.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("CFW/config/coremapping.json").path) }) { return .garlic }
        if root.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent("batocera").path) }) { return .emulationStation }
        return nil
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.openSettings) private var openSettings
    @State private var bulkSystem: GameSystem = .nds
    @State private var statusFilter: GameStatusFilter = .all
    @State private var previewCandidate: ArtworkCandidate?
    @State private var retainedReviewID: UUID?

    private var filteredRows: [GameRow] {
        model.rows.filter { isVisible($0, in: statusFilter) }
    }

    private func isVisible(_ row: GameRow, in filter: GameStatusFilter) -> Bool {
        filter.includes(row.state) ||
            (filter == .needsReview && statusFilter == .needsReview &&
             row.id == retainedReviewID && row.state == .ready)
    }

    private func chooseCandidate(_ candidate: ArtworkCandidate, at index: Int) {
        if statusFilter == .needsReview && model.rows[index].state == .needsReview {
            retainedReviewID = model.rows[index].id
        }
        model.rows[index].selectedCandidateID = candidate.id
        model.rows[index].state = .ready
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 248, ideal: 270, max: 310)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    gameList.frame(minWidth: 390)
                    Divider()
                    detail.frame(width: 350)
                }
                Divider()
                footer
            }
            .navigationTitle("游戏库")
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openSettings() } label: {
                    Label("API 设置", systemImage: "gearshape")
                }
                Button { model.search() } label: {
                    Label("查找封面", systemImage: "magnifyingglass")
                }
                .disabled(model.rows.isEmpty || model.isBusy)
                Button { model.export() } label: {
                    Label("写入封面", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.canExport)
                .buttonStyle(.borderedProminent)
                if model.isBusy {
                    Button { model.cancel() } label: {
                        Label("取消", systemImage: "xmark.circle")
                    }
                }
            }
        }
        .frame(minWidth: 1050, minHeight: 620)
        .sheet(item: $previewCandidate) { candidate in
            CoverPreviewView(candidate: candidate) {
                if let index = model.selectedIndex {
                    chooseCandidate(candidate, at: index)
                }
                previewCandidate = nil
            } onClose: {
                previewCandidate = nil
            }
        }
        .onChange(of: statusFilter) { _, _ in
            retainedReviewID = nil
            keepSelectionVisible()
        }
        .onChange(of: model.selectedID) { _, newID in
            if let newID, newID != retainedReviewID { retainedReviewID = nil }
            if newID == nil { keepSelectionVisible() }
        }
        .onChange(of: model.rootURL) { _, _ in retainedReviewID = nil }
        .onChange(of: filteredRows.map(\.id)) { _, _ in keepSelectionVisible() }
    }

    private func keepSelectionVisible() {
        if !filteredRows.contains(where: { $0.id == model.selectedID }) {
            model.selectedID = filteredRows.first(where: { $0.id == retainedReviewID })?.id
                ?? filteredRows.first?.id
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ROMCover").font(.headline)
                    Text("复古游戏封面").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 32)
            .padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sourceSection
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("目标掌机系统")
                        Picker("目录预设", selection: $model.profile) {
                            ForEach(ExportProfile.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        Text("原厂 Linux 已按 RG DS Plus 卡核对 Imgs 路径；其他型号仍请核对右侧预览。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("封面来源")
                        Picker("优先来源", selection: $model.steamFirst) {
                            Text("Libretro 优先").tag(false)
                            Text("SteamGridDB 优先").tag(true)
                        }
                        .labelsHidden()
                        Text(model.apiKey.isEmpty
                             ? "SteamGridDB Key 可在 API 设置中读取或添加。"
                             : "SteamGridDB API Key 已就绪。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("批量修正平台")
                        Picker("游戏平台", selection: $bulkSystem) {
                            ForEach(GameSystem.allCases) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        Button("应用到未识别项目") { model.applySystemToUnknown(bulkSystem) }
                            .disabled(!model.rows.contains { $0.game.system == nil })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("当前来源")
            Text(model.rootURL?.path ?? "尚未选择文件夹")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            Button { model.chooseFolder() } label: {
                Label("选择文件夹…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var gameList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("游戏库").font(.title3.weight(.semibold))
                Spacer()
                Text("\(model.rows.count) 个游戏")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            HStack(spacing: 12) {
                Label("状态", systemImage: "line.3.horizontal.decrease")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("状态筛选", selection: $statusFilter) {
                    ForEach(GameStatusFilter.allCases) { item in
                        Text("\(item.title) (\(model.rows.filter { isVisible($0, in: item) }.count))")
                            .tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
                Spacer()
                Text("\(filteredRows.count) / \(model.rows.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            List(selection: $model.selectedID) {
                ForEach(filteredRows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.exportCandidate == nil ? "gamecontroller" : "photo")
                            .frame(width: 24).foregroundStyle(row.state.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.game.stem).lineLimit(1)
                            Text(row.game.system?.name ?? "未识别平台")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(row.id == retainedReviewID && statusFilter == .needsReview ? "待写入 · 当前" : row.state.text)
                            .font(.caption).foregroundStyle(row.state.tint).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .tag(row.id)
                }
            }
            .overlay {
                if model.rows.isEmpty {
                    ContentUnavailableView("等待扫描 ROM", systemImage: "opticaldisc",
                        description: Text("选择存储卡或 ROM 文件夹，应用会识别游戏平台并建立待刮削列表。"))
                } else if filteredRows.isEmpty {
                    ContentUnavailableView("没有\(statusFilter.title)项目", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let index = model.selectedIndex {
            let row = model.rows[index]
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(row.game.stem).font(.title3.bold())
                    Text(row.game.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Picker("游戏平台", selection: $model.rows[index].game.system) {
                        Text("未识别").tag(GameSystem?.none)
                        ForEach(GameSystem.allCases) { Text($0.name).tag(Optional($0)) }
                    }
                    Text(row.game.detectionNote).font(.caption).foregroundStyle(.secondary)
                    TextField("搜索标题", text: $model.rows[index].game.searchTitle)
                    if let aiTitle = row.aiSuggestion {
                        Label("DeepSeek 建议：\(aiTitle)。请核对游戏及版本。", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("按此标题查找") { model.searchSelected() }
                        .disabled(model.isBusy || row.game.system == nil)
                    Button("用 DeepSeek 解析") { model.searchSelected(forceAI: true) }
                        .disabled(model.isBusy || row.game.system == nil || model.deepSeekAPIKey.isEmpty)
                    Divider()
                    Text("候选封面").font(.headline)
                    if row.candidates.isEmpty {
                        Text("尚无候选图。先点击“查找封面”。")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("不手动选择时，写入会使用第一张候选。点击封面可查看大图。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(row.candidates) { candidate in
                            let isDefault = row.selectedCandidateID == nil &&
                                row.state == .needsReview && row.candidates.first?.id == candidate.id
                            HStack(alignment: .top, spacing: 12) {
                                Button { previewCandidate = candidate } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        AsyncImage(url: candidate.previewURL) { image in
                                            image.resizable().scaledToFit()
                                        } placeholder: {
                                            ProgressView().frame(width: 74, height: 96)
                                        }
                                        .frame(width: 74, height: 96)
                                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(candidate.gameTitle).fontWeight(.medium).multilineTextAlignment(.leading)
                                            Text(candidate.source.rawValue).font(.caption)
                                            Text(candidate.note).font(.caption2).foregroundStyle(.secondary)
                                            if isDefault {
                                                Label("默认用于写入", systemImage: "checkmark.circle")
                                                    .font(.caption2).foregroundStyle(.tint)
                                            }
                                            Label("查看大图", systemImage: "arrow.up.left.and.arrow.down.right")
                                                .font(.caption2).foregroundStyle(.tint)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                                Button {
                                    chooseCandidate(candidate, at: index)
                                } label: {
                                    Image(systemName: row.selectedCandidateID == candidate.id ? "checkmark.circle.fill" : (isDefault ? "checkmark.circle" : "circle"))
                                        .font(.title3)
                                        .foregroundStyle(row.selectedCandidateID == candidate.id || isDefault ? Color.accentColor : Color.secondary)
                                        .symbolEffect(.bounce, value: row.selectedCandidateID)
                                }
                                .buttonStyle(.plain)
                                .help("选择此封面")
                            }
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(row.selectedCandidateID == candidate.id || isDefault ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.12))
                            }
                        }
                    }
                    Toggle("替换已有封面", isOn: $model.rows[index].replace)
                    Divider()
                    Text("预计写入路径").font(.headline)
                    if let path = try? ExportPlanner().location(for: row.game, profile: model.profile) {
                        Text(path.imageURL.path).font(.caption.monospaced()).textSelection(.enabled)
                        if let gamelist = path.gamelistURL {
                            Text("游戏列表：\(gamelist.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } else { Text("请先指定游戏平台。").foregroundStyle(.orange) }
                    if case .failed(let error) = row.state {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("选择一个游戏", systemImage: "photo.on.rectangle.angled")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.message).font(.caption).lineLimit(1)
            Spacer()
            if model.isBusy { ProgressView(value: model.progress).frame(width: 150) }
            Text("\(model.rows.count) 个游戏").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

struct CoverPreviewView: View {
    let candidate: ArtworkCandidate
    let onChoose: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.gameTitle).font(.headline).lineLimit(2)
                    Text(candidate.source.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .help("关闭预览")
            }
            AsyncImage(url: candidate.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    ContentUnavailableView("图片加载失败", systemImage: "wifi.exclamationmark",
                        description: Text("检查网络连接，或尝试另一张候选封面。"))
                default:
                    ProgressView("正在载入封面…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Text(candidate.note).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("选择此封面", action: onChoose).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 620, height: 720)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        Form {
            SecureField("SteamGridDB API Key", text: $model.apiKey)
            HStack {
                Button("保存到钥匙串") { model.saveKey() }
                    .disabled(model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.apiKey.isEmpty {
                    Button("读取已存 Key") { model.authorizeSteamKey() }
                }
                Link("获取 API Key", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
            }
            if model.apiKey.isEmpty {
                Text("若之前已保存 Key，点击“读取已存 Key”。系统询问时可选“始终允许”，避免同一版本下次再询问。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("不填写时仍可使用 Libretro。密钥仅存储在本机钥匙串中。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("未匹配时用 DeepSeek Flash 解析名称", isOn: $model.useDeepSeek)
            SecureField("DeepSeek API Key", text: $model.deepSeekAPIKey)
            HStack {
                Button("保存 DeepSeek Key") { model.saveDeepSeekKey() }
                    .disabled(model.deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.deepSeekAPIKey.isEmpty {
                    Button("读取已存 Key") { model.authorizeDeepSeekKey() }
                }
                Link("获取 DeepSeek API Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
            }
            if model.deepSeekAPIKey.isEmpty {
                Text("若之前已保存 Key，点击“读取已存 Key”。系统询问时可选“始终允许”，避免同一版本下次再询问。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("仅在常规匹配无结果时发送平台、文件名和 ROM 内部标题；解析结果需要人工确认，调用可能产生费用。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 440)
    }
}

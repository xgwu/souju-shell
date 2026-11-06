import Foundation
import Combine

/// 离线下载引擎。
///
/// 支持两种片源：
///  - HLS（.m3u8，含 master playlist / AES-128 加密 / fMP4 init 段）
///  - 直链 mp4
///
/// HLS 的做法是把 playlist 里的每个 URI 下载到本地，然后把 playlist 重写成
/// 相对路径的 `local.m3u8`，最后交给 AVPlayer 播本地文件 —— 不依赖任何服务端。
///
/// 注意：`download.enqueue` 的入参形状我们没拿到（在站点的懒加载路由 chunk 里），
/// 所以这里用 `PayloadScanner` 宽容抓取媒体地址，并把原始 payload 记进控制台，
/// 后续对齐只需要看一眼日志。
final class DownloadManager: ObservableObject {

    static let shared = DownloadManager()

    @Published private(set) var tasks: [DownloadTask] = []
    /// 站点请求打开下载管理器时置 true，UI 侧监听它弹面板
    @Published var managerRequested = false

    /// 状态变化通知网页（download.taskDidChange / progressDidChange ...）
    var onEvent: ((String, [String: Any]) -> Void)?

    private let session: URLSession
    private let maxConcurrentSegments = 4
    private var runningIDs = Set<String>()

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 3600
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
        loadManifest()
    }

    // MARK: - 桥接口

    func enqueue(_ params: [String: Any]) -> [String: Any] {
        let urls = PayloadScanner.mediaURLs(in: params)
        guard !urls.isEmpty else {
            return ["ok": false, "code": "NO_MEDIA_URL", "message": "payload 中没有可下载的媒体地址"]
        }

        let baseTitle = PayloadScanner.title(in: params)
        let movieID = PayloadScanner.firstString(in: params, keys: ["movieId", "movie_id", "id"])
        let episodeID = PayloadScanner.firstString(in: params, keys: ["episodeId", "episode_id", "episode"])
        let cover = PayloadScanner.firstString(in: params, keys: ["cover", "coverUrl", "cover_url", "poster"])

        var accepted: [[String: Any]] = []
        for (offset, url) in urls.enumerated() {
            let id = UUID().uuidString
            var task = DownloadTask(
                id: id,
                title: baseTitle ?? defaultTitle(for: url, offset: offset, total: urls.count),
                remoteURL: url
            )
            task.movieID = movieID
            task.episodeID = episodeID
            task.coverURL = cover
            task.isHLS = url.lowercased().contains(".m3u8")

            tasks.insert(task, at: 0)
            accepted.append(["taskId": id, "id": id, "url": url, "title": task.title, "state": task.state.rawValue])
            start(id: id)
        }

        saveManifest()
        emit("download.queueDidChange", payload: ["count": tasks.count])
        return ["ok": true, "accepted": accepted, "tasks": accepted, "queued": accepted.count]
    }

    func existsBatch(_ params: [String: Any]) -> [String: Any] {
        let urls = PayloadScanner.mediaURLs(in: params)
        let matched = urls.compactMap { url -> [String: Any]? in
            guard let task = tasks.first(where: { $0.remoteURL == url }) else { return nil }
            return [
                "url": url,
                "taskId": task.id,
                "exists": task.state == .completed,
                "state": task.state.rawValue,
                "progress": task.progress
            ]
        }
        return ["ok": true, "results": matched, "items": matched]
    }

    func stateSnapshot() -> [String: Any] {
        let snapshots = tasks.map(snapshot)
        return [
            "ok": true,
            "tasks": snapshots,
            "items": snapshots,
            "total": tasks.count,
            "active": tasks.filter { $0.state == .running || $0.state == .queued }.count
        ]
    }

    func play(_ params: [String: Any]) -> [String: Any] {
        let taskID = PayloadScanner.firstString(in: params, keys: ["taskId", "task_id", "id"])
        let urls = PayloadScanner.mediaURLs(in: params)

        let task = tasks.first { $0.id == taskID }
            ?? tasks.first { urls.contains($0.remoteURL) && $0.isPlayable }
            ?? tasks.first { task in urls.contains { task.remoteURL.contains($0) } && task.isPlayable }
            ?? tasks.first { $0.isPlayable }

        guard let playable = task, playable.isPlayable else {
            return ["ok": false, "code": "NOT_DOWNLOADED", "message": "本地没有可播放的离线文件"]
        }
        return ["ok": true, "taskId": playable.id, "playing": true, "title": playable.title]
    }

    func storeCover(_ params: [String: Any]) -> [String: Any] {
        guard let url = PayloadScanner.firstString(in: params, keys: ["cover", "coverUrl", "cover_url", "poster", "url"]) else {
            return ["ok": false, "code": "NO_COVER"]
        }
        if let movieID = PayloadScanner.firstString(in: params, keys: ["movieId", "movie_id", "id"]) {
            for index in tasks.indices where tasks[index].movieID == movieID {
                tasks[index].coverURL = url
            }
            saveManifest()
        }
        return ["ok": true]
    }

    func requestManager() {
        onMain { self.managerRequested = true }
    }

    // MARK: - UI 操作

    func task(with id: String) -> DownloadTask? {
        tasks.first { $0.id == id }
    }

    func retry(id: String) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        runningIDs.remove(id)
        start(id: id)
    }

    func remove(id: String) {
        guard let task = task(with: id) else { return }
        runningIDs.remove(id)
        try? FileManager.default.removeItem(at: task.directoryURL)
        tasks.removeAll { $0.id == id }
        saveManifest()
        emit("download.queueDidChange", payload: ["count": tasks.count])
    }

    func removeAll() {
        for task in tasks {
            try? FileManager.default.removeItem(at: task.directoryURL)
        }
        tasks.removeAll()
        runningIDs.removeAll()
        saveManifest()
    }

    // MARK: - 下载调度

    private func start(id: String) {
        guard !runningIDs.contains(id), let task = task(with: id) else { return }
        runningIDs.insert(id)

        update(id) { item in
            item.state = .running
            item.progress = 0
            item.errorText = nil
        }
        emit("download.taskDidChange", payload: snapshot(task))

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.perform(taskID: id)
                self.update(id) { item in
                    item.state = .completed
                    item.progress = 1
                }
                self.onMain { self.runningIDs.remove(id) }
                self.saveManifest()
                if let done = self.task(with: id) {
                    self.emit("download.taskDidChange", payload: self.snapshot(done))
                }
            } catch {
                self.update(id) { item in
                    item.state = .failed
                    item.errorText = error.localizedDescription
                }
                self.onMain { self.runningIDs.remove(id) }
                self.saveManifest()
                if let failed = self.task(with: id) {
                    self.emit("download.taskDidChange", payload: self.snapshot(failed))
                }
            }
        }
    }

    private func perform(taskID: String) async throws {
        guard let task = task(with: taskID) else { return }
        let dir = task.directoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if task.remoteURL.lowercased().contains(".m3u8") {
            let entry = try await downloadHLS(remote: task.remoteURL, into: dir, taskID: taskID)
            update(taskID) { item in
                item.isHLS = true
                item.entryFile = entry
            }
        } else {
            let entry = try await downloadDirect(remote: task.remoteURL, into: dir, taskID: taskID)
            update(taskID) { item in
                item.isHLS = false
                item.entryFile = entry
            }
        }
    }

    // MARK: - HLS

    private func downloadHLS(remote: String, into dir: URL, taskID: String) async throws -> String {
        guard let startURL = URL(string: remote) else { throw DownloadError.badURL }

        var (text, base) = try await fetchText(startURL)

        // master playlist → 选码率最高的一档
        if text.contains("#EXT-X-STREAM-INF") {
            let variants = HLSPlaylist.variants(in: text, base: base)
            guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw DownloadError.badPlaylist
            }
            (text, base) = try await fetchText(best.url)
        }

        guard text.contains("#EXTINF") || text.contains("#EXT-X-TARGETDURATION") else {
            throw DownloadError.badPlaylist
        }

        var lines = text.components(separatedBy: "\n")
        var segments: [(remote: URL, localName: String)] = []
        var resourceIndex = 0

        for index in lines.indices {
            let raw = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }

            // 加密 key：下到本地，URI 改成相对文件名
            if raw.hasPrefix("#EXT-X-KEY") {
                if let uri = HLSPlaylist.attribute("URI", in: raw),
                   let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    let name = String(format: "key_%03d.bin", resourceIndex)
                    resourceIndex += 1
                    try await downloadFile(url, to: dir.appendingPathComponent(name))
                    lines[index] = raw.replacingOccurrences(of: uri, with: name)
                }
                continue
            }

            // fMP4 init 段
            if raw.hasPrefix("#EXT-X-MAP") {
                if let uri = HLSPlaylist.attribute("URI", in: raw),
                   let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    let name = String(format: "init_%03d.mp4", resourceIndex)
                    resourceIndex += 1
                    try await downloadFile(url, to: dir.appendingPathComponent(name))
                    lines[index] = raw.replacingOccurrences(of: uri, with: name)
                }
                continue
            }

            if raw.hasPrefix("#") { continue }

            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL else { continue }
            let ext = url.pathExtension.isEmpty ? "ts" : url.pathExtension
            let name = String(format: "seg_%05d", segments.count) + "." + ext
            segments.append((url, name))
            lines[index] = name
        }

        guard !segments.isEmpty else { throw DownloadError.emptyPlaylist }

        let entryName = "local.m3u8"
        try lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent(entryName), atomically: true, encoding: .utf8)

        update(taskID) { item in
            item.isHLS = true
            item.segmentCount = segments.count
        }

        var done = 0
        while done < segments.count {
            let upper = min(done + maxConcurrentSegments, segments.count)
            let batch = Array(segments[done..<upper])

            try await withThrowingTaskGroup(of: Void.self) { group in
                for segment in batch {
                    let target = dir.appendingPathComponent(segment.localName)
                    let source = segment.remote
                    group.addTask {
                        try await self.downloadFile(source, to: target)
                    }
                }
                try await group.waitForAll()
            }

            done = upper
            let fraction = Double(done) / Double(segments.count)
            let bytes = DownloadManager.directorySize(dir)
            update(taskID) { item in
                item.progress = fraction
                item.bytesWritten = bytes
                item.bytesTotal = bytes
            }
            if let partial = task(with: taskID) {
                emit("download.progressDidChange", payload: [
                    "taskId": partial.id,
                    "progress": fraction,
                    "bytesWritten": bytes
                ])
            }
        }

        return entryName
    }

    // MARK: - 直链

    private func downloadDirect(remote: String, into dir: URL, taskID: String) async throws -> String {
        guard let url = URL(string: remote) else { throw DownloadError.badURL }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let name = "media." + ext
        let destination = dir.appendingPathComponent(name)

        try await downloadFile(url, to: destination)

        let size = DownloadManager.fileSize(destination)
        update(taskID) { item in
            item.progress = 1
            item.bytesWritten = size
            item.bytesTotal = size
        }
        return name
    }

    // MARK: - 网络原子操作

    private func fetchText(_ url: URL) async throws -> (String, URL) {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw DownloadError.http(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DownloadError.badPlaylist
        }
        return (text, response.url ?? url)
    }

    private func downloadFile(_ url: URL, to destination: URL) async throws {
        let (temporary, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw DownloadError.http(http.statusCode)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    // MARK: - 状态维护

    private func update(_ id: String, _ block: @escaping (inout DownloadTask) -> Void) {
        onMain {
            guard let index = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            block(&self.tasks[index])
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func emit(_ name: String, payload: [String: Any]) {
        onEvent?(name, payload)
    }

    private func snapshot(_ task: DownloadTask) -> [String: Any] {
        [
            "taskId": task.id,
            "id": task.id,
            "title": task.title,
            "url": task.remoteURL,
            "state": task.state.rawValue,
            "progress": task.progress,
            "bytesWritten": task.bytesWritten,
            "bytesTotal": task.bytesTotal,
            "movieId": task.movieID ?? "",
            "episodeId": task.episodeID ?? "",
            "playable": task.isPlayable
        ]
    }

    private func defaultTitle(for url: String, offset: Int, total: Int) -> String {
        let stem = URL(string: url)?.deletingPathExtension().lastPathComponent ?? "视频"
        return total > 1 ? "\(stem) #\(offset + 1)" : stem
    }

    // MARK: - 持久化

    private func loadManifest() {
        guard let data = try? Data(contentsOf: DownloadPaths.manifest),
              let decoded = try? JSONDecoder().decode([DownloadTask].self, from: data) else { return }
        // 上次被杀进程时还在下载的，重置为排队
        tasks = decoded.map { task in
            var copy = task
            if copy.state == .running { copy.state = .queued; copy.progress = 0 }
            return copy
        }
        // 清理文件夹已丢失的记录
        tasks.removeAll { task in
            !FileManager.default.fileExists(atPath: task.directoryURL.path)
        }
    }

    private func saveManifest() {
        let snapshotTasks = tasks
        let url = DownloadPaths.manifest
        onMain {
            guard let data = try? JSONEncoder().encode(snapshotTasks) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - 工具

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - 错误

enum DownloadError: LocalizedError {
    case badURL
    case badPlaylist
    case emptyPlaylist
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址无效"
        case .badPlaylist: return "playlist 解析失败"
        case .emptyPlaylist: return "playlist 里没有分片"
        case .http(let code): return "HTTP \(code)"
        }
    }
}

// MARK: - HLS 解析

enum HLSPlaylist {

    struct Variant {
        let url: URL
        let bandwidth: Int
    }

    static func variants(in text: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        var pendingBandwidth: Int?

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = intAttribute("BANDWIDTH", in: line) ?? 0
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let bandwidth = pendingBandwidth,
               let url = URL(string: line, relativeTo: base)?.absoluteURL {
                result.append(Variant(url: url, bandwidth: bandwidth))
                pendingBandwidth = nil
            }
        }
        return result
    }

    /// 取 `NAME="value"` 里的 value
    static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: name + "=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    /// 取 `NAME=12345` 里的数字
    static func intAttribute(_ name: String, in line: String) -> Int? {
        guard let start = line.range(of: name + "=") else { return nil }
        let rest = line[start.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}

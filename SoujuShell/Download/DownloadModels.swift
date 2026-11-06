import Foundation

/// 一个离线任务。字段刻意保持扁平 + 全部 Codable，
/// 直接序列化成 `Documents/Downloads/manifest.json`，重装前不丢。
struct DownloadTask: Codable, Identifiable, Equatable {

    enum State: String, Codable {
        case queued
        case running
        case completed
        case failed

        var label: String {
            switch self {
            case .queued: return "排队中"
            case .running: return "下载中"
            case .completed: return "已完成"
            case .failed: return "失败"
            }
        }
    }

    var id: String
    var title: String
    var remoteURL: String
    var movieID: String?
    var episodeID: String?
    var coverURL: String?

    var state: State = .queued
    var progress: Double = 0
    var bytesWritten: Int64 = 0
    var bytesTotal: Int64 = 0

    /// 相对 `Downloads/<id>/` 的入口文件名，通常是 `local.m3u8` 或 `media.mp4`
    var entryFile: String?
    var isHLS: Bool = false
    var segmentCount: Int = 0

    var createdAt: Date = Date()
    var errorText: String?

    // MARK: - 派生

    var directoryURL: URL {
        DownloadPaths.root.appendingPathComponent(id, isDirectory: true)
    }

    var entryURL: URL? {
        guard let entryFile = entryFile else { return nil }
        return directoryURL.appendingPathComponent(entryFile)
    }

    var isPlayable: Bool {
        guard state == .completed, let url = entryURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var sizeText: String {
        let bytes = bytesTotal > 0 ? bytesTotal : bytesWritten
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var progressText: String {
        switch state {
        case .running: return "\(Int((progress * 100).rounded()))%"
        case .queued: return "等待中"
        case .completed: return sizeText
        case .failed: return "失败"
        }
    }
}

enum DownloadPaths {
    static var root: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var manifest: URL {
        root.appendingPathComponent("manifest.json")
    }
}

// MARK: - 入参宽容解析

/// 站点侧 `download.enqueue` 的 payload 形状在懒加载路由 chunk 里，
/// 静态分析拿不到（我们只确认了它会原样把 params 透传给壳）。
/// 因此这里不猜字段名，而是**递归抓取所有像媒体地址的字符串**，
/// 再按优先级排序。抓错了最多是多下一个文件，不会崩。
enum PayloadScanner {

    private static let urlKeys = [
        "url", "playUrl", "play_url", "downloadUrl", "download_url",
        "src", "source", "hlsUrl", "hls_url", "m3u8", "file", "mediaUrl"
    ]

    static func mediaURLs(in any: Any) -> [String] {
        var found: [String] = []
        walk(any, into: &found)
        // 去重但保持顺序
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    private static func walk(_ any: Any, into found: inout [String]) {
        switch any {
        case let string as String:
            if looksLikeMedia(string) { found.append(string) }
        case let dict as [String: Any]:
            // 已知字段优先
            for key in urlKeys {
                if let value = dict[key] as? String, looksLikeMedia(value) {
                    found.append(value)
                }
            }
            for (key, value) in dict {
                if urlKeys.contains(key) { continue }
                walk(value, into: &found)
            }
        case let array as [Any]:
            for item in array { walk(item, into: &found) }
        default:
            break
        }
    }

    static func looksLikeMedia(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return false }
        let lower = s.lowercased()
        if lower.contains(".m3u8") || lower.contains(".mp4") { return true }
        if lower.contains("/hls/") || lower.contains("playlist") { return true }
        return false
    }

    /// 从 payload 里尽量捞标题
    static func title(in any: Any) -> String? {
        guard let dict = any as? [String: Any] else { return nil }
        for key in ["title", "name", "movieTitle", "episodeTitle", "episodeName", "label"] {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func firstString(in any: Any, keys: [String]) -> String? {
        guard let dict = any as? [String: Any] else { return nil }
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? Int { return String(value) }
        }
        return nil
    }
}

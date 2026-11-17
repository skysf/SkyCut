import Darwin
import Foundation
import os

// MARK: - 素材书签的会话缓存
//
// 管什么：存盘时每个素材的系统书签（`MediaRecord.bookmark`）—— 同一个文件在这次会话里
// 建过就拿旧的，不再每次自动保存都重建一遍。
// 不管什么：书签怎么解、素材怎么重链接（VideoEditProjectFile.swift 的四层线索）。
//
// 为什么：建书签很贵，系统要去查 LaunchServices 的隔离属性。2026-09-24 在用户 57 个素材的
// 工程上实测：一次自动保存在主线程上花约 55ms，几乎全在建书签 —— 而自动保存是每改一下、
// 停 2 秒就来一次，改得勤就隔一会儿卡一下。
//
// 什么时候必须重建：书签记的是 inode + 卷，所以**只要这个路径上还是同一个 inode**，旧书签
// 就还是对的；路径上换成了别的文件（重新导出盖掉了、删了又放回一个同名的），就得重建 ——
// 不然以后这个文件被挪走时，书签会把工程指回旧的那个（比如废纸篓里那份）。所以缓存按
// 「路径 + inode + 卷」认，变了一样就重建。

enum MediaBookmarkCache {
    private struct Entry {
        var inode: UInt64
        var device: Int32
        var bookmark: Data
    }

    private static let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())
    private static let created = OSAllocatedUnfairLock(initialState: 0)

    /// 这次会话里实际建了几个书签。自检数它，确认「同一个文件只建一次」。
    static var creations: Int { created.withLock { $0 } }

    /// 这个文件此刻的书签。文件不在（读不到 inode）或者建不出来就返回 nil ——
    /// 由调用方拿上次存的那份兜底（`MediaRecord` 的「旧记录只能补，不能覆盖成 nil」）。
    static func bookmark(for url: URL) -> Data? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let inode = UInt64(info.st_ino)
        let device = info.st_dev
        if let cached = entries.withLock({ $0[url.path] }), cached.inode == inode, cached.device == device {
            return cached.bookmark
        }
        guard let fresh = try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return nil }
        created.withLock { $0 += 1 }
        entries.withLock { $0[url.path] = Entry(inode: inode, device: device, bookmark: fresh) }
        return fresh
    }
}

// Persistent location clues and their bookmark-preserving writer share the cache above. Resolution stays in ProjectIO.
/// 一个素材的定位信息：存三种线索，从快到慢依次试。
struct MediaRecord: Codable, Sendable {
    /// 存盘时的绝对路径。素材没动过就直接命中，这是绝大多数情况。
    var path: String
    /// 系统书签：记的是文件的 inode + 卷标识，不是路径。素材改名、移到同一个盘
    /// 的任何角落，甚至又改名又移动，都能靠它解回来 —— 这是 macOS 自带的能力。
    var bookmark: Data?
    /// 相对工程文件的位置。整个文件夹（工程 + 素材）一起搬走或拷到别的机器时，
    /// 书签会失效（inode 变了），这条还在。
    var relativePath: String?
    /// 最后的线索：按文件名找，用大小验一下是不是同一个。
    var fileName: String
    var byteSize: Int64?

    private enum CodingKeys: String, CodingKey {
        case path, bookmark, relativePath, fileName, byteSize
    }

    /// - Parameter previous: 上次存盘时这个素材的记录。
    ///
    ///   **旧记录只能补，不能覆盖成 nil。** 素材此刻不可达时（在工程打开期间被
    ///   移走、外接盘拔了），`bookmarkData()` 会失败返回 nil；要是就这么存下去，
    ///   本来还能定位到它的那份书签就被自己抹掉了 —— 而且随便哪个素材触发一次
    ///   自动保存，就会连带抹掉**其他**丢失素材的线索。
    init(url: URL, projectDirectory: URL?, previous: MediaRecord? = nil) {
        path = url.path
        fileName = url.lastPathComponent
        // 同一个文件（同一个 inode）这次会话里建过书签就用旧的：建书签很贵，自动保存
        // 每次都重建的话主线程每次卡约 55ms（`MediaBookmarkCache`）。
        let fresh = MediaBookmarkCache.bookmark(for: url)
        bookmark = fresh ?? previous?.bookmark
        // 相对路径纯粹是路径运算，文件在不在都算得出来，可以放心重算。
        relativePath = projectDirectory.flatMap { MediaRecord.relativePath(from: $0, to: url) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        byteSize = size ?? previous?.byteSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
            ?? (path as NSString).lastPathComponent
        byteSize = try c.decodeIfPresent(Int64.self, forKey: .byteSize)
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// 从工程所在目录走到素材的相对路径。最多往上走三层 —— 再远就不像是
    /// 「一起搬走」的关系了，留着反而会误配到别的文件。
    static func relativePath(from directory: URL, to file: URL) -> String? {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let target = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var shared = 0
        while shared < base.count, shared < target.count, base[shared] == target[shared] {
            shared += 1
        }
        let up = base.count - shared
        guard up <= 3 else { return nil }
        return (Array(repeating: "..", count: up) + target[shared...]).joined(separator: "/")
    }
}

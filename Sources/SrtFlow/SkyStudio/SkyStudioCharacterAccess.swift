import Foundation
import CryptoKit

// 只缓存公开角色页 / 详情，不缓存图像字节。实际 Key 的摘要和 epoch 同时隔离迟到的旧账户请求。
@MainActor
final class SkyStudioCharacterCache {
    static let shared = SkyStudioCharacterCache()
    private var keyDigest: String?
    private var epoch = 0
    private var pages: [String: (SkyStudioCharacterPage, Date)] = [:]
    private var details: [String: SkyStudioCharacter] = [:]
    private var storedCapabilities: (SkyStudioCharacterCapabilities, Date)?

    func capabilities(key: String, api: SkyStudioAPI = SkyStudioAPI(), now: Date = Date()) async throws -> SkyStudioCharacterCapabilities {
        bind(key)
        if let (value, at) = storedCapabilities, now >= at, now.timeIntervalSince(at) < 30 { return value }
        let observed = epoch
        let value = try await api.characterCapabilities(key: key)
        if observed == epoch { storedCapabilities = (value, now) }
        return value
    }

    nonisolated static func digest(_ key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }

    func page(limit: Int, cursor: String?, status: String, key: String, api: SkyStudioAPI = SkyStudioAPI(), now: Date = Date()) async throws -> SkyStudioCharacterPage {
        bind(key)
        let cacheKey = "\(limit):\(cursor ?? ""): \(status)"
        if let (page, at) = pages[cacheKey], now >= at, now.timeIntervalSince(at) < 30 { return page }
        let observed = epoch
        let page = try await api.characters(limit: limit, cursor: cursor, status: status, key: key)
        if observed == epoch {
            pages[cacheKey] = (page, now)
            for item in page.characters { details[item.id] = item }
        }
        return page
    }

    /// 详情总是现读，尤其换图后不能让热缓存冒充最新 revision。
    func character(_ id: String, key: String, api: SkyStudioAPI = SkyStudioAPI()) async throws -> SkyStudioCharacter {
        bind(key)
        let observed = epoch
        let value = try await api.character(id, key: key)
        if observed == epoch { details[value.id] = value }
        return value
    }

    func cached(_ id: String) -> SkyStudioCharacter? { details[id] }

    func forget() { epoch += 1; keyDigest = nil; pages = [:]; details = [:]; storedCapabilities = nil }

    private func bind(_ key: String) {
        let digest = Self.digest(key)
        if keyDigest != digest { forget(); keyDigest = digest }
    }
}

// 账户变化还要废掉待确认的收费身份；恢复单据不删除，原单只能在原账户下读取。
@MainActor
enum SkyStudioCharacterAccess {
    private(set) static var epoch = 0
    static func stamp(_ key: String) -> String { "\(epoch):" + SkyStudioCharacterCache.digest(key) }
    static func invalidate() {
        epoch += 1
        SkyStudioCharacterCache.shared.forget()
        AIConfirmations.shared.discard(prefix: "skystudio:")
        SkyStudioOfficialPrepared.shared.forget()
    }

    static func invalidateLibrary(characterID: String) {
        SkyStudioCharacterCache.shared.forget()
        AIConfirmations.shared.discard(prefix: "skystudio:", containing: characterID)
        SkyStudioOfficialPrepared.shared.forget(characterID: characterID)
    }
}

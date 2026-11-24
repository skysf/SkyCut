import Foundation
import SrtFlowMCPKit

// MARK: - 调 Sky Studio 给 SkyCut 的接口（`https://skystudioai.com/api/skycut/v1`）
//
// 管什么：发请求（认证头、版本号、机器号）、读回答、没问成时说清楚是哪一种（服务器回了错 / 没连上 / 回的不像话）。
// **SkyCut 里只有这里碰 Sky Studio 的地址**（checks/sky-studio-wiring.sh 钉着）。合同以 Sky Studio 仓库的 docs/agents/skycut-api.md 为准
// （2026-10-28 上线，从 Sky Studio main 的 5c8d6a0d 起冻结）。
// 接口：`GET /me`（授权，收费方案第 5 刀）；生成、upscale、克隆的 `/models`、`/quote`、`/uploads`（+ 把文件 PUT 到它给的地址）、`/jobs`、
// `/jobs/{id}`、`/jobs/{id}/cancel`，和把成品下载下来（第 6 刀）。传文件流着发 / 收、带字节进度，借 fal 那边的传输代理（CloudTransferDelegate，
// 第 7 刀删 fal 时改名留下）；**Key 只发给 Sky Studio**，上传的签名地址和成品地址都不带它。
// An upload's PUT that the network breaks is tried again, up to three tries; an answer the storage gave stands (SkyStudioUploadRetry;
// 2026-11-23). A paid result's download the network breaks is resumed or tried again, up to three GETs; an expired address is renewed
// once from the original job (SkyStudioDownloadRetry; 2026-11-24).
// 声音库的 `/voices`、`/voices/consent-grant` 在 SkyStudioVoiceAPI（用这里的 request / send）。
// Content for SkyCut (`/content`, `/content/styles/{id}`) is in SkyStudioContentAPI (request + conditionalGet, uncachedSession).
// 不管什么：Key 存哪（SkyStudioKey）、回答还算不算数（SkyCutLicense）、什么时候问（SkyStudioAccount）、等一个任务做完（SkyStudioJobRun）。
//
// 自检和冒烟用 `SRTFLOW_SKYSTUDIO_API_BASE` 把地址指到本机的假服务器，**只认回环地址**（Key 不会因此发到别处）。

struct SkyStudioAPI: Sendable {
    static let productionBase = URL(string: "https://skystudioai.com/api/skycut/v1")!
    static let baseEnvironmentKey = "SRTFLOW_SKYSTUDIO_API_BASE"
    /// 一次请求最多等多久（AI 的调用碰上授权没问到时也最多等这么久，SkyStudioAccount.settledLicense）。
    static let requestTimeout: TimeInterval = 20
    /// 交任务那一个请求等多久（见 `submit`）。
    static let submitTimeout: TimeInterval = 120

    let session: URLSession
    let base: URL
    let version: String
    let machine: String?
    /// How a PUT the network breaks is tried again (`upload`; checks shorten the pauses).
    let uploadRetry: SkyStudioUploadRetry
    /// How a result's GET the network breaks is resumed or tried again (`download`; checks shorten the pauses).
    let downloadRetry: SkyStudioDownloadRetry

    init(
        session: URLSession = .shared, base: URL = SkyStudioAPI.configuredBase(ProcessInfo.processInfo.environment),
        version: String = SkyStudioAPI.appVersion, machine: String? = SkyStudioMachine.current, uploadRetry: SkyStudioUploadRetry = .standard,
        downloadRetry: SkyStudioDownloadRetry = .standard
    ) {
        self.session = session
        self.base = base
        self.version = version
        self.machine = machine
        self.uploadRetry = uploadRetry
        self.downloadRetry = downloadRetry
    }

    /// 显示用的完整构建版本；请求头在 `request` 边界只取数字三段，不改包里的来源标记。
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Sky Studio 只收 major.minor.patch；本地 / 预发布 / 构建后缀不参与最低版本比较。
    /// 必须先认完整格式；不认识的原样交给服务器严格拒绝，不能把坏输入伪装成有效版本。
    private static func transportVersion(_ version: String) -> String {
        let number = #"(?:0|[1-9][0-9]*)"#
        let identifiers = #"[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*"#
        let pattern = #"\A"# + number + #"\."# + number + #"\."# + number
            + "(?:-" + identifiers + ")?(?:\\+" + identifiers + #")?\z"#
        guard version.range(of: pattern, options: .regularExpression) != nil else { return version }
        return String(version.prefix { $0 != "-" && $0 != "+" })
    }

    /// 地址：环境变量指到本机的假服务器时用它（只认 http(s)://回环地址），别的一律正式地址。
    static func configuredBase(_ environment: [String: String]) -> URL {
        guard let text = environment[baseEnvironmentKey], let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, isLoopback(host) else { return productionBase }
        return url
    }

    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    // MARK: 接口

    /// `GET /me`：这个 Key 是谁、余额、SkyCut 的授权。账号第一次来时服务器顺手开始体验（这台 Mac 没体验过的话）。
    func me(key: String) async throws -> SkyStudioMe {
        let data = try await send(request("me", key: key))
        do {
            return try SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: data)
        } catch {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
    }

    /// `GET /models`：能请求的模型、给人看的价、能收的参数和上限。
    func models(key: String) async throws -> SkyStudioCatalog {
        guard let catalog = SkyStudioCatalog(json: try Self.json(try await send(request("models", key: key)))) else {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
        return catalog
    }

    /// `POST /quote`：只报价、不扣钱（和 `/jobs` 扣钱同一个计价函数）。
    func quote(_ job: SkyStudioJobRequest, key: String) async throws -> SkyStudioQuote {
        try SkyStudioOfficialRequest.validate(job, submitting: false)
        let body = try job.quoteBody.encodedData()
        guard let quote = SkyStudioQuote(json: try Self.json(try await send(request("quote", key: key, method: "POST", body: body)))) else {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
        if let film = job.film {
            guard let official = quote.officialRecipe, (try? official.seamReview.validate(for: film)) != nil else {
                throw SkyStudioFailure.badAnswer(status: 200)
            }
        }
        if let character = job.character {
            guard let usage = quote.characterUsage, usage.id == character.id else { throw SkyStudioFailure.badAnswer(status: 200) }
        }
        // 读稿整段报价（`params.batches`）：要回服务器选的模型和每一批的价，批数对得上（每批交的时候拿它当 max_credits）。
        if let asked = job.params["batches"]?.arrayValue {
            guard let voice = quote.voice, voice.plan != nil, voice.batches.count == asked.count else { throw SkyStudioFailure.badAnswer(status: 200) }
        }
        return quote
    }

    /// `POST /jobs`：提交，回任务号（扣钱在这一步：失败、取消只退一次）。合同说立刻回，但 2026-10-28 Sky Studio 在本机的 vercel dev 上
    /// 量到图片、音乐的提交一直等到做完才回（55 秒、40 秒），线上还没量过：这一个请求多等一会儿（`submitTimeout`），真超时了
    /// 保留同一个 idempotency_key 待核查，不自动重放收费 POST。
    func submit(_ job: SkyStudioJobRequest, key: String) async throws -> SkyStudioJobStatus {
        if job.character != nil, job.character?.revision == nil { throw SkyStudioCharacterError.changed }
        try SkyStudioOfficialRequest.validate(job, submitting: true)
        var post = request(try job.nativeCharacter?.path ?? "jobs", key: key, method: "POST", body: try job.jobBody.encodedData())
        post.timeoutInterval = Self.submitTimeout
        return try Self.status(try await send(post))
    }

    /// `GET /jobs/{id}`：立刻回（没有长轮询），带 `poll_after_seconds`。
    func job(_ id: String, key: String) async throws -> SkyStudioJobStatus {
        let status = try Self.status(try await send(request(try Self.jobPath(id), key: key)))
        guard status.jobID == id else { throw SkyStudioFailure.badAnswer(status: 200) }
        return status
    }

    /// `POST /jobs/{id}/cancel`：只有排着队的能取消（退钱）；开始了 / 结束了的是 `notCancellable`。
    func cancel(_ id: String, key: String) async throws -> SkyStudioCancel {
        do {
            let path = try Self.jobPath(id) + "/cancel"
            let answer = try Self.json(try await send(request(path, key: key, method: "POST", body: Data("{}".utf8))))
            return .cancelled(refunded: answer["credits_refunded"]?.doubleValue)
        } catch SkyStudioFailure.server(let error) where error.code == SkyStudioServerError.notCancellable {
            return .notCancellable(status: error.fields["status"]?.stringValue)
        }
    }

    /// `POST /uploads` 拿到地址，把文件 PUT 上去（流着发，不整个读进内存）；回 `/jobs` 的 inputs 要的那个 `file_url`。
    /// `purpose`：`video`（mp4 / mov，≤ 200 MB）、`image`、`audio`，声音的 `voice_reference`（VoiceReferenceSample）、
    /// `voice_convert_source`（SkyStudioVoiceUpload；两种各 ≤ 35 MB）。PUT 只带服务器给的头，**不带 Key**（那是存储桶的签名地址）。
    /// A PUT the network breaks (`SkyStudioUploadRetry.classify`) is tried again on a fresh task, `uploadRetry.attempts` tries in all
    /// after a short pause, at the same signed address while it is known to stay valid (a new ticket from `/uploads` otherwise); progress
    /// starts again from 0. Once the storage has answered, its answer stands; a connection that does not work at all and a cancel end it
    /// too. Giving up is `SkyStudioFailure.uploadFailed` (nothing was submitted). `named`: the file as the user knows it (a cut's source).
    func upload(
        fileURL: URL, contentType: String, purpose: String, key: String, named: String? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int else {
            throw SkyStudioFailure.network("could not read \(fileURL.lastPathComponent)")
        }
        var fields: [String: JSONValue] = [
            "filename": .string(fileURL.lastPathComponent), "content_type": .string(contentType),
            "bytes": .number(Double(size)), "purpose": .string(purpose)
        ]
        if purpose == "character_role" { fields["filename"] = nil }
        let body = try JSONValue.object(fields).encodedData()
        let name = named ?? fileURL.lastPathComponent
        func failed(_ kind: SkyStudioUploadFailure.Kind, puts: Int, _ detail: String, server: SkyStudioServerError? = nil) -> SkyStudioFailure {
            .uploadFailed(SkyStudioUploadFailure(fileName: name, kind: kind, attempts: puts, lastError: detail, server: server))
        }
        var ticket: SkyStudioUploadTicket
        do {
            ticket = try await uploadTicket(body, key: key)
        } catch let broken as SkyStudioUploadRetry.Broken {
            throw failed(.interrupted, puts: 0, broken.detail)
        } catch let unreachable as SkyStudioUploadRetry.Unreachable {
            throw failed(.unreachable, puts: 0, unreachable.detail)
        } catch let declined as SkyStudioUploadRetry.Declined {
            throw failed(.declined(status: declined.status), puts: 0, declined.detail, server: declined.server)
        }
        var puts = 0
        var lastTry: TimeInterval = 0
        var lastError = ""
        for attempt in 1...max(1, uploadRetry.attempts) {
            if attempt > 1 {
                try Task.checkCancellation()
                onProgress(0)   // the broken try's bytes are lost: progress starts again
                try await uploadRetry.pause(before: attempt)
            }
            let started = Date()
            do {
                if attempt > 1, ticket.needsRenewal(now: started, lastTry: lastTry, margin: uploadRetry.renewalMargin) {
                    ticket = try await uploadTicket(body, key: key)
                }
                puts += 1
                try await put(fileURL, ticket: ticket, onProgress: onProgress)
                onProgress(1)
                return ticket.fileURL
            } catch let broken as SkyStudioUploadRetry.Broken {
                lastTry = Date().timeIntervalSince(started)
                lastError = broken.detail
            } catch let unreachable as SkyStudioUploadRetry.Unreachable {
                throw failed(.unreachable, puts: puts, unreachable.detail)
            } catch let refused as SkyStudioUploadRetry.Refused {
                throw failed(.refused(status: refused.status), puts: puts, "HTTP \(refused.status)")
            } catch let declined as SkyStudioUploadRetry.Declined {
                throw failed(.declined(status: declined.status), puts: puts, declined.detail, server: declined.server)
            }
        }
        try Task.checkCancellation()
        throw failed(.interrupted, puts: puts, lastError)
    }

    /// `POST /uploads`: the signed address and the `file_url`. A transport error comes back classified (`Broken`, `Unreachable`);
    /// a refusal, an HTTP error or an answer without an address is `Declined` (Sky Studio's own refusal kept inside).
    private func uploadTicket(_ body: Data, key: String) async throws -> SkyStudioUploadTicket {
        let answer: (data: Data, response: HTTPURLResponse?)
        do {
            answer = try await respond(request("uploads", key: key, method: "POST", body: body), retryable: true)
        } catch SkyStudioFailure.server(let refusal) {
            throw SkyStudioUploadRetry.Declined(status: refusal.status, server: refusal, detail: refusal.code + ": " + refusal.message)
        } catch SkyStudioFailure.badAnswer(let status) {
            throw SkyStudioUploadRetry.Declined(status: status, server: nil, detail: "HTTP \(status)")
        }
        guard let json = try? JSONValue.decode(answer.data), let ticket = SkyStudioUploadTicket(json, received: Date(),
              serverDate: answer.response?.value(forHTTPHeaderField: "Date")) else {
            throw SkyStudioUploadRetry.Declined(status: answer.response?.statusCode ?? 200, server: nil, detail: "no upload address in the answer")
        }
        return ticket
    }

    /// One PUT on a fresh task with fresh progress, never redirected (a signed address does not redirect; following would be a second
    /// PUT): `Broken` when the network broke it, `Unreachable` when the connection does not work. Once the storage began to answer
    /// (even only its head, which the system then holds back), that answer stands: success or `Refused`, never retried.
    private func put(_ file: URL, ticket: SkyStudioUploadTicket, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        #if DEBUG
        // SRTFLOW_TEST_UPLOAD_DROPS (debug builds only): this try loses its connection after part of the body went out.
        if CloudUploadFault.claimDrop() {
            let cut = CloudTransferDelegate(moveDestination: nil, followsRedirects: false, onProgress: onProgress)
            try await transported(retryable: true) { try await CloudUploadFault.drop(ticket.request, file: file, session: session, delegate: cut) }
        }
        #endif
        let delegate = CloudTransferDelegate(moveDestination: nil, followsRedirects: false, onProgress: onProgress)
        var request = ticket.request
        request.timeoutInterval = uploadRetry.putTimeout
        let task = session.uploadTask(with: request, fromFile: file)
        do {
            try await transfer(task, delegate: delegate, retryable: true)
        } catch where !(error is CancellationError) && (task.response is HTTPURLResponse || delegate.answerStarted) {
            // The storage answered before the error: its status below decides (0 when only its head came and was held back).
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SkyStudioUploadRetry.Refused(status: status) }
    }

    /// 把成品下载到 `destination`（先下到它旁边的临时文件再挪过去，下到一半断了不留半个文件）。成品地址不带 Key。
    /// `onProgress`：收到的字节比例（服务器说了总长才有），做完一定报 1。
    /// A GET the network breaks (SkyStudioUploadRetry.isTransient) is tried again after a short pause, `downloadRetry.attempts` GETs
    /// in all: resumed where it stopped when the system kept what arrived (its own resume data, never anyone else's), otherwise from
    /// the start (progress back to 0). An HTTP answer is never tried again as it is: a 403 / 404 / 410 asks `renew` once for a fresh
    /// address (the original job's GET; nothing is ever submitted) and tries it when it differs; any other answer, a cancel and a
    /// connection that does not work end the download. Giving up is `SkyStudioDownloadFailure`: Sky Studio made and charged the
    /// result, nothing more was charged, and downloading it again is free.
    func download(
        _ url: URL, to destination: URL, renew: (@Sendable () async throws -> URL?)? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).part-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: partial) }
        var address = url
        var resumeData: Data?
        var renewed = false
        var gets = 0
        var lastError = ""
        var pausesFirst = false
        func failed(_ kind: SkyStudioDownloadFailure.Kind) -> SkyStudioDownloadFailure {
            SkyStudioDownloadFailure(kind: kind, attempts: gets, lastError: lastError, renewed: renewed)
        }
        let attempts = max(1, downloadRetry.attempts)
        for attempt in 1...attempts {
            if pausesFirst {
                try Task.checkCancellation()
                try await downloadRetry.pause(before: attempt)
            }
            gets += 1
            switch try await fetch(address, resuming: resumeData, into: partial, onProgress: onProgress) {
            case .done:
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: partial, to: destination)
                } catch {
                    throw SkyStudioFailure.network(error.localizedDescription)
                }
                onProgress(1)
                return
            case .broken(let detail, let kept):
                lastError = detail
                resumeData = kept
                if kept == nil { onProgress(0) }   // nothing was kept: the next try starts from the beginning
                pausesFirst = true
            case .answered(let status):
                lastError = "HTTP \(status)"
                guard SkyStudioDownloadRetry.renewableStatuses.contains(status), !renewed, attempt < attempts, let renew else {
                    throw failed(.refused(status: status))
                }
                renewed = true
                let fresh: URL?
                do { fresh = try await renew() } catch is CancellationError { throw CancellationError() } catch { fresh = nil }
                try Task.checkCancellation()
                guard let fresh, fresh != address else { throw failed(.refused(status: status)) }
                address = fresh
                resumeData = nil
                onProgress(0)
                pausesFirst = false
            case .unreachable(let detail):
                lastError = detail
                throw failed(.unreachable)
            }
        }
        try Task.checkCancellation()
        throw failed(.interrupted)
    }

    /// One GET on a fresh task with fresh progress (resumed from `resumeData` when the system kept the last try's bytes), the result
    /// moved into `partial` once whole. `.broken` when the network broke it (with the system's resume data, if any), `.answered` for a
    /// status that is not 2xx (even when its body then broke), `.unreachable` when the connection does not work; a cancel stays one.
    private func fetch(
        _ url: URL, resuming resumeData: Data?, into partial: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> SkyStudioDownloadRetry.Try {
        let delegate = CloudTransferDelegate(moveDestination: partial, onProgress: onProgress)
        var get = URLRequest(url: url)
        get.timeoutInterval = downloadRetry.getTimeout
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: get)
        var transfer: () async throws -> Void = { try await CloudTransfer.perform(task, delegate: delegate) }
        #if DEBUG
        // SRTFLOW_TEST_DOWNLOAD_DROPS (debug builds only): this try is cut once part of the body arrived.
        if CloudDownloadFault.claimDrop() { transfer = { try await CloudDownloadFault.drop(task, delegate: delegate) } }
        #endif
        do {
            try await transfer()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // An answer that began before the error stands as that answer: a 403 whose body broke is a 403, never a broken try.
            if let status = (task.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                return .answered(status: status)
            }
            let detail = SkyStudioUploadRetry.describe(error)
            guard SkyStudioUploadRetry.isTransient(error) else { return .unreachable(detail: detail) }
            return .broken(detail: detail, resumeData: (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return .answered(status: status) }
        guard let file = delegate.downloadedFile,
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 0 else {
            throw SkyStudioFailure.network("the download did not produce a file")
        }
        return .done
    }

    // MARK: 发请求

    func request(_ path: String, key: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.transportVersion(version), forHTTPHeaderField: "X-SkyCut-Version")
        if let machine { request.setValue(machine, forHTTPHeaderField: "X-SkyCut-Machine") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// 发出去、拿回 2xx 的正文；别的都换成 `SkyStudioFailure`（取消照旧是 CancellationError）。
    func send(_ request: URLRequest) async throws -> Data {
        try await respond(request).data
    }

    /// `send` that keeps the answer's headers too (the upload ticket reads `Date`); `retryable` as in `transported`.
    private func respond(_ request: URLRequest, retryable: Bool = false) async throws -> (data: Data, response: HTTPURLResponse?) {
        let (data, response) = try await exchange(request, retryable: retryable)
        let status = response?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.failure(status: status, data: data) }
        return (data, response)
    }

    /// Content for SkyCut (editing styles, later craft cards) never goes into the system URL cache: SkyCut's own copy
    /// (SkyStudioContentCache) is the only one on this Mac and is deleted when the licence ends; a URL cache would also hand back
    /// an `immutable` answer without asking the server whether this key may still read it.
    static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// A GET that may answer 304 Not Modified: `etag` goes out as If-None-Match and a 304 comes back as a nil body (the copy
    /// held is still current). Every other answer reads as `send` reads it; a 2xx returns its body and its ETag.
    func conditionalGet(_ request: URLRequest, etag: String?) async throws -> (body: Data?, etag: String?) {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await exchange(request)
        let status = response?.statusCode ?? 0
        if status == 304 { return (nil, etag) }
        guard (200..<300).contains(status) else { throw Self.failure(status: status, data: data) }
        return (data, response?.value(forHTTPHeaderField: "ETag"))
    }

    private func exchange(_ request: URLRequest, retryable: Bool = false) async throws -> (Data, HTTPURLResponse?) {
        try await transported(retryable: retryable) {
            let (data, response) = try await session.data(for: request)
            return (data, response as? HTTPURLResponse)
        }
    }

    /// 跑一个传文件的任务：Task 被取消 / URLSession 报 cancelled 都换成 CancellationError，别的网络错换成「没连上」。
    private func transfer(_ task: URLSessionTask, delegate: CloudTransferDelegate, retryable: Bool = false) async throws {
        try await transported(retryable: retryable) { try await CloudTransfer.perform(task, delegate: delegate) }
    }

    /// What went wrong on the wire: a cancel stays a cancel; inside an upload (`retryable`) the error is classified
    /// (`SkyStudioUploadRetry.classify`: the network broke this try, or the connection does not work); elsewhere it is "could not reach".
    private func transported<T>(retryable: Bool, _ run: () async throws -> T) async throws -> T {
        do {
            return try await run()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch where retryable {
            throw SkyStudioUploadRetry.classify(error)
        } catch {
            throw SkyStudioFailure.network(error.localizedDescription)
        }
    }

    /// 任务号是服务器给的：只当一节路径用，带斜杠、点点的不认（不许拼出别的地址）。
    private static func jobPath(_ id: String) throws -> String {
        guard !id.isEmpty, !id.contains("/"), !id.contains(".."), !id.contains("?"), !id.contains("#") else {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
        return "jobs/" + id
    }

    private static func json(_ data: Data) throws -> JSONValue {
        guard let json = try? JSONValue.decode(data) else { throw SkyStudioFailure.badAnswer(status: 200) }
        return json
    }

    private static func status(_ data: Data) throws -> SkyStudioJobStatus {
        guard let status = SkyStudioJobStatus(json: try json(data)) else { throw SkyStudioFailure.badAnswer(status: 200) }
        return status
    }

    /// 不是 2xx：服务器照约好的回了 `{"error": {"code", "message", …}}` 就原样留着，不是就是「回的不像话」。
    static func failure(status: Int, data: Data) -> SkyStudioFailure {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(var error)? = body["error"],
              let code = error["code"]?.stringValue, !code.isEmpty else {
            return .badAnswer(status: status)
        }
        let message = error["message"]?.stringValue ?? code
        error["code"] = nil
        error["message"] = nil
        if let billing = body["billing"] { error["billing"] = billing }
        return .server(SkyStudioServerError(status: status, code: code, message: message, fields: error))
    }
}

/// 服务器照约好的格式回的错。`message` 是写给人看的英文，SkyCut 原样给用户 / AI 看。
struct SkyStudioServerError: Equatable, Sendable {
    static let invalidKey = "invalid_key"
    static let upgradeRequired = "upgrade_required"
    /// 同时开着的任务满了（`limit`、`running`）：等一个做完再交。
    static let tooManyJobs = "too_many_jobs"
    /// 取消一个已经开始 / 已经结束的任务（`status`）。
    static let notCancellable = "not_cancellable"

    let status: Int
    let code: String
    let message: String
    /// 附加的字段（`min_version`、`download_url`、`balance`、`retry_after`…），原样留着。
    let fields: [String: JSONValue]

    var downloadURL: URL? { SkyStudioLinks.webURL(fields["download_url"]?.stringValue) }
}

/// 问 Sky Studio 没问成。给人看的话在界面那一层按语言换（SkyStudioAccount），服务器的 message 原样带上。
enum SkyStudioFailure: Error, Equatable, Sendable {
    /// 服务器回了错（Key 不对、版本太老、余额不够……）。
    case server(SkyStudioServerError)
    /// 没连上：断网、超时、找不到主机。
    case network(String)
    /// 回的不是约好的样子（不是 JSON、少了字段）。
    case badAnswer(status: Int)
    /// A file's upload to Sky Studio's storage did not happen (`upload`: interrupted, could not connect, refused). Nothing was
    /// submitted, nothing charged.
    case uploadFailed(SkyStudioUploadFailure)
}

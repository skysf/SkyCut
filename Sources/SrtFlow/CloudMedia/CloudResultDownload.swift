import Foundation

// MARK: - A paid result's download: the GETs behind SkyStudioAPI.download
//
// What it covers (2026-11-24, backlog B40 and the review of PR #554): one result downloaded into a partial file beside its destination
// and moved over only when it is whole.
// - A GET the network broke is resumed from the system's own resume data, or started again; three GETs in all, redirects included
//   (the system never follows one by itself here, so every GET is counted).
// - A resumed answer that does not finish the result (a 206 short of the last byte, a size that does not add up) is thrown away and
//   the result started again from nothing.
// - A 403 / 404 / 410, and an answer that began but whose status the system held back before its body broke, ask the original job
//   once for its current address (`renew`, only a read); any other answer, a cancel and a connection that does not work end it.
// - Giving up is SkyStudioDownloadFailure.
// What it does not cover: who may download (only SkyStudioAPI.download calls this), the numbers and pure checks
// (SkyStudioDownloadRetry), progress and the task delegate (CloudTransfer).
// Rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

struct CloudResultDownload {
    let session: URLSession
    let retry: SkyStudioDownloadRetry

    func run(
        _ url: URL, to destination: URL, renew: (@Sendable () async throws -> URL?)?, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).part-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: partial) }
        var address = url
        var resumeData: Data?
        var asked = false
        var triedFresh = false
        var gets = 0
        var lastError = ""
        var pausesFirst = false
        func failed(_ kind: SkyStudioDownloadFailure.Kind) -> SkyStudioDownloadFailure {
            SkyStudioDownloadFailure(kind: kind, attempts: gets, lastError: lastError, triedFreshAddress: triedFresh)
        }
        /// Asks the original job for its current address, once per download; true when it differs and the next GET goes there.
        func moveToFreshAddress() async throws -> Bool {
            guard !asked, let renew else { return false }
            asked = true
            let fresh: URL?
            do { fresh = try await renew() } catch is CancellationError { throw CancellationError() } catch { fresh = nil }
            try Task.checkCancellation()
            guard let fresh, fresh != address else { return false }
            address = fresh
            resumeData = nil
            triedFresh = true
            onProgress(0)
            pausesFirst = false
            return true
        }
        let attempts = max(1, retry.attempts)
        for attempt in 1...attempts {
            if pausesFirst {
                try Task.checkCancellation()
                try await retry.pause(before: attempt)
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
            case .heldBack(let detail, let kept):
                lastError = detail
                if attempt < attempts, try await moveToFreshAddress() { continue }
                resumeData = kept
                if kept == nil { onProgress(0) }
                pausesFirst = true
            case .answered(let status):
                lastError = "HTTP \(status)"
                guard SkyStudioDownloadRetry.renewableStatuses.contains(status), attempt < attempts, try await moveToFreshAddress() else {
                    throw failed(.refused(status: status))
                }
            case .redirected(let status, let target):
                lastError = "HTTP \(status)"
                guard attempt < attempts else { throw failed(.refused(status: status)) }
                address = target
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

    /// One GET on a fresh task with fresh progress (resumed from `resumeData` when the system kept the last try's bytes), never
    /// redirected by the system, the result moved into `partial` once it arrived. What it ended as: SkyStudioDownloadRetry.Try.
    private func fetch(
        _ url: URL, resuming resumeData: Data?, into partial: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> SkyStudioDownloadRetry.Try {
        let delegate = CloudTransferDelegate(moveDestination: partial, followsRedirects: false, onProgress: onProgress)
        var get = URLRequest(url: url)
        get.timeoutInterval = retry.getTimeout
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
            let answer = task.response as? HTTPURLResponse
            if let status = answer?.statusCode, !(200..<300).contains(status) { return .answered(status: status) }
            let detail = SkyStudioUploadRetry.describe(error)
            guard SkyStudioUploadRetry.isTransient(error) else { return .unreachable(detail: detail) }
            let kept = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            return answer == nil && delegate.answerStarted ? .heldBack(detail: detail, resumeData: kept) : .broken(detail: detail, resumeData: kept)
        }
        let answer = task.response as? HTTPURLResponse
        let status = answer?.statusCode ?? 0
        if let target = SkyStudioDownloadRetry.redirectTarget(status: status, location: answer?.value(forHTTPHeaderField: "Location"), from: url) {
            return .redirected(status: status, to: target)
        }
        guard (200..<300).contains(status) else { return .answered(status: status) }
        guard let file = delegate.downloadedFile,
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 0 else {
            throw SkyStudioFailure.network("the download did not produce a file")
        }
        let encoding = answer?.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        if let problem = SkyStudioDownloadRetry.incompleteness(status: status, contentRange: answer?.value(forHTTPHeaderField: "Content-Range"),
                expectedLength: answer?.expectedContentLength ?? -1, size: size, encoded: encoding.map { $0 != "identity" } ?? false) {
            return .broken(detail: problem, resumeData: nil)   // thrown away: the next try starts the result from nothing
        }
        return .done
    }
}

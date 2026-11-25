import Foundation

// MARK: - A paid result's download: the GETs behind SkyStudioAPI.download
//
// What it covers (2026-11-24, backlog B40 and the reviews of PR #554): one result downloaded into a private file next to where it goes
// (CloudResultPlace) and placed only when it is whole, and usable by the flow's own check.
// - Every GET asks for the bytes as they are (`Accept-Encoding: identity`). A GET the network broke is resumed from the system's own
//   resume data (never an encoded answer's), or started again; three GETs in all, redirects included (the system never follows one by
//   itself here, so every GET is counted).
// - What arrived must be the whole result (SkyStudioDownloadRetry.wholeness: never empty, a 206 to the last byte with the whole length
//   on disk and never encoded, a 200 holding its length) and pass the flow's `check` (an image that decodes: a length-less answer
//   holding 8 bytes of a PNG once passed); anything else is thrown away and the result started again from nothing.
// - It takes its name without replacing or removing anything (CloudResultPlace.place: the next free number of its series when the name
//   is taken); this Mac could not keep it (moving the download in, placing it, the disk): `notSaved`, not tried again.
// - A 403 / 404 / 410 asks the original job once for its current address (`renew`, only a read). An answer that began but whose
//   status the system held back counts as an answer too: at most that one GET at the job's current address, never the same address
//   again. Any other answer, a cancel and a connection that does not work end it.
// - Giving up is SkyStudioDownloadFailure, a stop included (`stopped`, with the GETs sent).
// What it does not cover: who may download (only SkyStudioAPI.download calls this), the numbers and pure checks
// (SkyStudioDownloadRetry), progress and the task delegate (CloudTransfer).
// Rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

struct CloudResultDownload {
    let session: URLSession
    let retry: SkyStudioDownloadRetry

    /// Downloads `url` into `place`; returns the file it became and the GETs it sent. `check`: the flow's own check of the whole
    /// result in its private file, before it takes a name (it may correct the extension: an image's bytes say what it is).
    func run(
        _ url: URL, into place: CloudResultPlace, check: (@Sendable (URL) async throws -> String?)?, renew: (@Sendable () async throws -> URL?)?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudResultFile {
        let partial = place.partial()
        defer { CloudResultPlace.removePrivateFile(partial) }   // its private name; only a regular file, never a folder that took it
        var address = url
        var resumeData: Data?
        var asked = false
        var triedFresh = false
        var gets = 0
        var lastError = ""
        var lastKind = SkyStudioDownloadFailure.Kind.interrupted
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
        do {
            for attempt in 1...attempts {
                if pausesFirst { try await retry.pause(before: attempt) }
                try Task.checkCancellation()   // a GET is counted only once it is really sent
                gets += 1
                switch try await fetch(address, resuming: resumeData, into: partial, onProgress: onProgress) {
                case .done:
                    var corrected: String?
                    if let check {
                        do {
                            corrected = try await check(partial)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Not usable by the flow's own check: thrown away, the next GET starts it again.
                            let reason = (error as? CloudResultUnusable)?.reason ?? error.localizedDescription
                            (lastError, lastKind) = ("what came down is not a usable result: \(reason)", .incomplete)
                            resumeData = nil
                            onProgress(0)
                            pausesFirst = true
                            continue
                        }
                    }
                    let file: CloudResultFile
                    do {
                        file = CloudResultFile(file: try await place.place(partial, pathExtension: corrected), gets: gets)
                    } catch {
                        lastError = error.localizedDescription
                        throw failed(.notSaved)
                    }
                    onProgress(1)
                    return file
                case .broken(let detail, let kept):
                    (lastError, lastKind) = (detail, .interrupted)
                    resumeData = kept
                    if kept == nil { onProgress(0) }   // nothing was kept: the next try starts from the beginning
                    pausesFirst = true
                case .incomplete(let detail):
                    (lastError, lastKind) = (detail, .incomplete)
                    resumeData = nil
                    onProgress(0)
                    pausesFirst = true
                case .heldBack(let detail):
                    lastError = detail
                    // An answer whose status never came through: one GET at the job's current address at most, never this one again.
                    guard attempt < attempts, try await moveToFreshAddress() else { throw failed(.interrupted) }
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
                case .notSaved(let detail):
                    lastError = detail
                    throw failed(.notSaved)
                }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw SkyStudioDownloadFailure.stopped(attempts: gets)   // the GETs really sent, even when the stop came in a pause
        }
        throw failed(lastKind)
    }

    /// One GET on a fresh task with fresh progress (resumed from `resumeData` when the system kept the last try's bytes), never
    /// redirected by the system, the result moved into `partial` once it arrived. What it ended as: SkyStudioDownloadRetry.Try.
    private func fetch(
        _ url: URL, resuming resumeData: Data?, into partial: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> SkyStudioDownloadRetry.Try {
        let delegate = CloudTransferDelegate(moveDestination: partial, followsRedirects: false, onProgress: onProgress)
        var get = URLRequest(url: url)
        get.timeoutInterval = retry.getTimeout
        // The bytes as they are: a resumed range of an encoded answer would not be the file's bytes (a resume keeps this request).
        get.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
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
            if answer == nil && delegate.answerStarted { return .heldBack(detail: detail) }
            // An encoded answer is started again without a Range: a range of it could never be checked (SkyStudioDownloadRetry.wholeness).
            let encoded = SkyStudioDownloadRetry.isEncoded(answer?.value(forHTTPHeaderField: "Content-Encoding"))
            let kept = encoded ? nil : (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            return .broken(detail: detail, resumeData: kept)
        }
        let answer = task.response as? HTTPURLResponse
        let status = answer?.statusCode ?? 0
        if let target = SkyStudioDownloadRetry.redirectTarget(status: status, location: answer?.value(forHTTPHeaderField: "Location"), from: url) {
            return .redirected(status: status, to: target)
        }
        guard (200..<300).contains(status) else { return .answered(status: status) }
        // This Mac could not keep the file the system downloaded (the disk): not the network's doing, so it is not tried again.
        if let local = delegate.downloadMoveError { return .notSaved(detail: local.localizedDescription) }
        let size = delegate.downloadedFile.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int } ?? 0
        switch SkyStudioDownloadRetry.wholeness(status: status, contentRange: answer?.value(forHTTPHeaderField: "Content-Range"),
                                                expectedLength: answer?.expectedContentLength ?? -1, size: size,
                                                encoding: answer?.value(forHTTPHeaderField: "Content-Encoding")) {
        case .checked, .unchecked: return .done   // the flow's own check, if any, comes next
        case .incomplete(let problem): return .incomplete(detail: problem)   // thrown away: the next try starts the result from nothing
        }
    }
}

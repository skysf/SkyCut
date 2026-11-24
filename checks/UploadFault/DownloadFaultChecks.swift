import Foundation
import SrtFlowMCPKit

// SRTFLOW_TEST_DOWNLOAD_DROPS, the debug-only hook that cuts a paid result's download mid-body on purpose
// (Sources/SrtFlow/CloudMedia/CloudDownloadFault.swift). Compiled into the same -D DEBUG binary as the upload hook's checks (main.swift
// calls this), run against the local server sending slowly (32 KB every 10 ms), so a cut is seen mid-body. One drop: the next GET
// resumes from the system's resume data and the file is whole. Three: the download ends as download_network after three GETs, and the
// next download in the process is not cut. A body that arrived whole before the cut is still dropped (the next GET starts from
// nothing); an HTTP answer stands. Unset, zero or garbage: nothing is cut. That builds without DEBUG carry no trace of the hook is
// checked by scripts/check-sky-studio.sh with scripts/debug-hook-probe.sh.

func runDownloadFaultChecks(_ server: UploadServer, folder: URL) async {
    let size = 2_000_000
    let result = Data((0..<size).map { UInt8(($0 * 5) % 247) })
    func cuts(_ value: String?) {
        if let value { setenv(CloudDownloadFault.environmentKey, value, 1) } else { unsetenv(CloudDownloadFault.environmentKey) }
        CloudDownloadFault.reset()
    }
    func gets() -> [UploadServer.Seen] { server.log.filter { $0.method == "GET" } }
    func offset(_ seen: UploadServer.Seen) -> Int? { seen.headers["range"].flatMap { Int($0.dropFirst(6).prefix { $0 != "-" }) } }

    // One cut: the first GET is cut once part of the body arrived; the second resumes (Range) and the file is byte-identical.
    cuts("1")
    server.configureDownload(gets: [.slow], result: result)
    let once = folder.appendingPathComponent("once.mp4")
    do { try await api(server).download(server.resultURL("a.mp4"), to: once) } catch { check(false, "one cut: the download works, got \(error)") }
    checkEqual(try? Data(contentsOf: once), result, "one cut: the file is byte-identical")
    let resumed = gets()
    let from = resumed.count == 2 ? offset(resumed[1]) : nil
    check(resumed.count == 2 && resumed[0].headers["range"] == nil && (from.map { $0 > 0 && $0 < size } ?? false),
          "the cut GET stopped mid-body and the next one resumed from there: \(resumed.map { $0.headers["range"] ?? "-" })")
    check(!CloudDownloadFault.claimDrop(), "the one cut is used up")

    // Three cuts: interrupted after three GETs; the next download in the process is not cut.
    cuts("3")
    server.configureDownload(gets: [.slow], result: result)
    let failed = folder.appendingPathComponent("three.mp4")
    do {
        try await api(server).download(server.resultURL("a.mp4"), to: failed)
        check(false, "three cuts end the download")
    } catch let failure as SkyStudioDownloadFailure {
        check(failure.kind == .interrupted && failure.attempts == 3 && failure.code == "download_network"
                && failure.lastError == "NSURLErrorDomain -1005",
              "three cut GETs: interrupted, download_network, a lost connection as on the wire: \(failure)")
    } catch {
        check(false, "three cuts end as a download failure, got \(error)")
    }
    checkEqual(gets().count, 3, "three GETs, never a fourth")
    check(!FileManager.default.fileExists(atPath: failed.path), "no file where the cut result would go")
    server.configureDownload(gets: [.file], result: result)
    do { try await api(server).download(server.resultURL("a.mp4"), to: failed) } catch { check(false, "after the N cuts: \(error)") }
    checkEqual(try? Data(contentsOf: failed), result, "after the N cuts, downloads work again")

    // A small body that arrives whole before the cut: still dropped (at its end), so the next GET starts from nothing.
    cuts("1")
    let small = Data(result.prefix(10_000))
    server.configureDownload(gets: [.file], result: small)
    let quick = folder.appendingPathComponent("quick.mp4")
    do { try await api(server).download(server.resultURL("a.mp4"), to: quick) } catch { check(false, "a quick cut body: \(error)") }
    checkEqual(try? Data(contentsOf: quick), small, "a body whole before the cut: dropped once, then whole")
    check(gets().count == 2 && gets().allSatisfy { $0.headers["range"] == nil }, "nothing kept from a body dropped at its end: \(gets().count) GETs")

    // An HTTP answer stands: the hook never turns a 404 into a lost connection.
    cuts("1")
    server.configureDownload(gets: [.status(404)], result: result)
    do {
        try await api(server).download(server.resultURL("a.mp4"), to: folder.appendingPathComponent("missing.mp4"))
        check(false, "a 404 under the hook fails")
    } catch let failure as SkyStudioDownloadFailure {
        check(failure.kind == .refused(status: 404) && failure.attempts == 1, "a 404 under the hook stays a 404 after one GET: \(failure)")
    } catch {
        check(false, "a 404 under the hook is a download failure, got \(error)")
    }

    // A cut GET whose connection fails before the body (its TLS fails on this plain server): the cutter ends at once, never spinning.
    cuts("1")
    server.configureDownload(gets: [.file], result: result)
    _ = try? await api(server).download(server.resultURL("a.mp4", tls: true), to: folder.appendingPathComponent("tls.mp4"))
    let before = cpuSeconds()
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let spent = cpuSeconds() - before
    check(spent < 0.3, "after a cut GET that failed before the body, nothing spins: \(String(format: "%.2f", spent)) CPU s in 1 s")

    for value in [nil, "", "0", "abc", "-2"] as [String?] {
        cuts(value)
        check(!CloudDownloadFault.claimDrop(), "\(CloudDownloadFault.environmentKey)=\(value ?? "(unset)") cuts nothing")
    }
    cuts(nil)
}

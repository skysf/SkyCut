import Foundation
import SrtFlowMCPKit

// SRTFLOW_TEST_UPLOAD_DROPS, the debug-only hook that makes an upload lose its connection on purpose
// (Sources/SrtFlow/CloudMedia/CloudUploadFault.swift). Compiled by scripts/check-sky-studio.sh with -D DEBUG, like the smoke app, and
// run against the local upload server (checks/SkyStudio/UploadServer.swift) reading slowly, so a cut try is seen arriving with part
// of its body. One drop: the next try works at the same address. Three: the upload ends as upload_network after three tries, nothing
// whole arrived, and the next upload in the process is not dropped. Unset, zero or garbage: nothing is dropped. That builds without
// DEBUG (as release) carry no trace of the hook is checked by the same script with `strings`.
// The download hook (SRTFLOW_TEST_DOWNLOAD_DROPS, 2026-11-24) is checked in the same binary: DownloadFaultChecks.swift.

let key = "sk-" + String(repeating: "A", count: 43)
let size = 2_000_000

/// Waits between tries are not slept: the hook's own cut is what is tested here.
func api(_ server: UploadServer) -> SkyStudioAPI {
    var retry = SkyStudioUploadRetry()
    retry.sleep = { _ in }
    var downloads = SkyStudioDownloadRetry()
    downloads.sleep = { _ in }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    return SkyStudioAPI(session: URLSession(configuration: configuration), base: URL(string: "http://127.0.0.1:\(server.port)/api/skycut/v1")!,
                        version: "0.18.50", machine: nil, uploadRetry: retry, downloadRetry: downloads)
}

func drops(_ value: String?) {
    if let value { setenv(CloudUploadFault.environmentKey, value, 1) } else { unsetenv(CloudUploadFault.environmentKey) }
    CloudUploadFault.reset()
}

func puts(_ server: UploadServer) -> [UploadServer.Seen] { server.log.filter { $0.method == "PUT" } }

/// CPU seconds this process has used (user + system).
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skystudio-upload-fault-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let file = folder.appendingPathComponent("reference.png")
try? Data((0..<size).map { UInt8($0 % 239) }).write(to: file)

do {
    let server = try UploadServer()
    defer { server.stop() }

    // One drop: the first try is cut after part of the body, the second arrives whole at the same address.
    drops("1")
    server.configure(puts: [.ok], slowRead: true)
    let link = try? await api(server).upload(fileURL: file, contentType: "image/png", purpose: "image", key: key)
    checkEqual(link?.absoluteString, server.fileURL(1), "one drop: the next try works at the same address")
    let first = puts(server)
    let part = CloudUploadFault.partSize(of: size)
    check(first.count == 2 && !first[0].complete && first[0].bodyBytes > 0 && first[0].bodyBytes <= part
            && first[1].complete && first[1].bodyBytes == size,
          "the cut try arrived with part of its body (at most \(part) bytes), the next one whole: \(first.map { ($0.bodyBytes, $0.complete) })")
    check(!CloudUploadFault.claimDrop(), "the one drop is used up")

    // Three drops: three cut tries, the plain error, and the next upload in the process goes through.
    drops("3")
    server.configure(puts: [.ok], slowRead: true)
    let failure = await expectFailure("three drops") {
        _ = try await api(server).upload(fileURL: file, contentType: "image/png", purpose: "image", key: key)
    }
    if case .uploadFailed(let upload)? = failure {
        checkEqual(upload.kind, .interrupted, "three cut tries: interrupted")
        checkEqual(upload.attempts, 3, "three tries")
        checkEqual(upload.lastError, "NSURLErrorDomain -1005", "a cut try is a lost connection, as on the wire")
        checkEqual(upload.code, "upload_network", "the code the smoke test reads in get_job")
    } else {
        check(false, "three drops end as uploadFailed, got \(String(describing: failure))")
    }
    // The client gives up at once after the third cut while the slow server is still reading what arrived: wait for its log.
    let logged = Date().addingTimeInterval(5)
    while puts(server).count < 3, Date() < logged { try? await Task.sleep(nanoseconds: 20_000_000) }
    let cut = puts(server)
    check(cut.count == 3 && cut.allSatisfy { !$0.complete && $0.bodyBytes <= part },
          "no cut try arrived whole, none sent more than its part: \(cut.map { ($0.bodyBytes, $0.complete) })")
    let after = try? await api(server).upload(fileURL: file, contentType: "image/png", purpose: "image", key: key)
    checkEqual(after?.absoluteString, server.fileURL(2), "after the N drops, uploads work again")

    // A dropped try whose connection fails before any of the body went out (its TLS fails on this plain server): the hook ends at
    // once and its watcher stops instead of spinning until its 5 s deadline (it once burned about a CPU second each second).
    drops("1")
    server.configure(puts: [.ok], tickets: [.ticket(life: 900, tls: true)])
    _ = try? await api(server).upload(fileURL: file, contentType: "image/png", purpose: "image", key: key)
    let before = cpuSeconds()
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let spent = cpuSeconds() - before
    check(spent < 0.3, "after a drop that failed before the body, nothing spins: \(String(format: "%.2f", spent)) CPU s in 1 s")

    // Unset, zero or garbage: nothing is dropped.
    for value in [nil, "", "0", "abc", "-2"] as [String?] {
        drops(value)
        check(!CloudUploadFault.claimDrop(), "\(CloudUploadFault.environmentKey)=\(value ?? "(unset)") drops nothing")
    }
    await runDownloadFaultChecks(server, folder: folder)
} catch {
    check(false, "the local upload server starts: \(error)")
}
drops(nil)
try? FileManager.default.removeItem(at: folder)

if failures > 0 {
    print("✗ \(failures) of \(checks) upload fault checks failed.")
    exit(1)
}
print("All \(checks) upload fault checks passed.")

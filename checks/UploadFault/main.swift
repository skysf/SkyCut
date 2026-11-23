import Foundation
import SrtFlowMCPKit

// SRTFLOW_TEST_UPLOAD_DROPS, the debug-only hook that makes an upload lose its connection on purpose
// (Sources/SrtFlow/CloudMedia/CloudUploadFault.swift). Compiled by scripts/check-sky-studio.sh with -D DEBUG, like the smoke app, and
// run against the local upload server (checks/SkyStudio/UploadServer.swift) reading slowly, so a cut try is seen arriving with part
// of its body. One drop: the next try works at the same address. Three: the upload ends as upload_network after three tries, nothing
// whole arrived, and the next upload in the process is not dropped. Unset, zero or garbage: nothing is dropped. That builds without
// DEBUG (as release) carry no trace of the hook is checked by the same script with `strings`.

let key = "sk-" + String(repeating: "A", count: 43)
let size = 2_000_000

/// Waits between tries are not slept: the hook's own cut is what is tested here.
func api(_ server: UploadServer) -> SkyStudioAPI {
    var retry = SkyStudioUploadRetry()
    retry.sleep = { _ in }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    return SkyStudioAPI(session: URLSession(configuration: configuration), base: URL(string: "http://127.0.0.1:\(server.port)/api/skycut/v1")!,
                        version: "0.18.50", machine: nil, uploadRetry: retry)
}

func drops(_ value: String?) {
    if let value { setenv(CloudUploadFault.environmentKey, value, 1) } else { unsetenv(CloudUploadFault.environmentKey) }
    CloudUploadFault.reset()
}

func puts(_ server: UploadServer) -> [UploadServer.Seen] { server.log.filter { $0.method == "PUT" } }

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
    check(first.count == 2 && !first[0].complete && first[0].bodyBytes > 0 && first[0].bodyBytes < size
            && first[1].complete && first[1].bodyBytes == size,
          "the cut try arrived with part of its body, the next one whole: \(first.map { ($0.bodyBytes, $0.complete) })")
    check(!CloudUploadFault.claimDrop(), "the one drop is used up")

    // Three drops: three cut tries, the plain error, and the next upload in the process goes through.
    drops("3")
    server.configure(puts: [.ok], slowRead: true)
    let failure = await expectFailure("three drops") {
        _ = try await api(server).upload(fileURL: file, contentType: "image/png", purpose: "image", key: key)
    }
    if case .uploadInterrupted(let interruption)? = failure {
        checkEqual(interruption.attempts, 3, "three tries")
        checkEqual(interruption.lastError, "NSURLErrorDomain -1005", "a cut try is a lost connection, as on the wire")
        checkEqual(interruption.fields(retry: "x")["code"], "upload_network", "the code the smoke test reads in get_job")
    } else {
        check(false, "three drops end as uploadInterrupted, got \(String(describing: failure))")
    }
    checkEqual(puts(server).filter(\.complete).count, 0, "no try arrived whole")
    let after = try? await api(server).upload(fileURL: file, contentType: "image/png", purpose: "image", key: key)
    checkEqual(after?.absoluteString, server.fileURL(2), "after the N drops, uploads work again")

    // Unset, zero or garbage: nothing is dropped.
    for value in [nil, "", "0", "abc", "-2"] as [String?] {
        drops(value)
        check(!CloudUploadFault.claimDrop(), "\(CloudUploadFault.environmentKey)=\(value ?? "(unset)") drops nothing")
    }
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

import Foundation

// 自检只捕获真实 ffmpeg 的解码计数；输出落文件，避免管道写满；结束回调等待，不阻塞协作线程池。
enum ExportProfileRunner {
    static func run(_ executable: URL, _ arguments: [String], directory: URL, log: URL) async throws -> String {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
            process.standardError = handle; process.standardOutput = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { process in
                try? handle.close()
                continuation.resume(returning: process.terminationStatus)
            }
            do { try process.run() } catch { try? handle.close(); continuation.resume(throwing: error) }
        }
        let text = try String(contentsOf: log, encoding: .utf8)
        guard status == 0 else { throw NSError(domain: "ExportProfileCheck", code: Int(status), userInfo: [NSLocalizedDescriptionKey: text.suffix(3000)]) }
        return text
    }
}

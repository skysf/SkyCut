import Foundation
import SrtFlowMCPKit

// Resolve the App's socket and provider marker together. The staged E2E bundle owns a short
// path beside itself so its socket never needs the real home or the long-path fallback.
enum AIBridgeLocation {
    static var supportForE2E: URL? {
        let bundle = Bundle.main
        guard let id = bundle.bundleIdentifier,
              id.range(of: #"\Acom\.srtflow\.e2e[0-9]+\.skystudiosmoke\z"#, options: .regularExpression) != nil else {
            return nil
        }
        return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("bridge", isDirectory: true)
    }

    static var socketPath: String {
        supportForE2E?.appendingPathComponent("mcp.sock").path
            ?? MCPBridge.socketPath(bundleIdentifier: bundleIdentifier)
    }

    static var providerMarker: URL {
        supportForE2E?.appendingPathComponent("mcp-providers.json")
            ?? MCPProviderMarker.url(bundleIdentifier: bundleIdentifier)
    }

    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow"
    }
}

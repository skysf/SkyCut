import Foundation

// MARK: - The lock written into the page itself (pure)
//
// Owns: the Content-Security-Policy and DNS-prefetch meta tags and where they go — before any of the page's own markup,
// so no page script runs ahead of them. They sit right after a leading doctype (keeps standards mode) or at the very
// start. Inserted without a line break, so the line numbers in the page's error messages stay the page's own.
// Does not own: the locks that are not in the page (content rules, navigation policy, WebKit switches: the helper's
// `Lockdown`). docs/architecture/web-motion-renderer.md「锁」.

public enum WebMotionPageHTML {
    /// Only the page's own inline script and style run; images only from data:/blob: (no network). Fonts are the Mac's
    /// own (same fonts as SkyCut's text, so the version fingerprint means something); no fetch, socket, frame, worker,
    /// plugin, form, base URL or eval.
    public static let contentSecurityPolicy = [
        "default-src 'none'", "script-src 'unsafe-inline'", "style-src 'unsafe-inline'", "img-src data: blob:",
        "font-src 'none'", "connect-src 'none'", "media-src 'none'", "frame-src 'none'", "child-src 'none'",
        "worker-src 'none'", "object-src 'none'", "manifest-src 'none'", "form-action 'none'", "base-uri 'none'",
    ].joined(separator: "; ")

    public static let lockTags =
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
        + "<meta http-equiv=\"x-dns-prefetch-control\" content=\"off\">"

    /// The page with the lock tags in front of its first markup.
    public static func locked(_ html: String) -> String {
        var result = html
        result.insert(contentsOf: lockTags, at: insertionPoint(in: html))
        return result
    }

    /// Right after a doctype that is preceded only by whitespace and comments; otherwise the very start.
    static func insertionPoint(in html: String) -> String.Index {
        var index = html.startIndex
        while index < html.endIndex {
            let rest = html[index...]
            if let first = rest.first, first.isWhitespace || first == "\u{FEFF}" {
                index = html.index(after: index)
            } else if rest.hasPrefix("<!--"), let close = rest.range(of: "-->") {
                index = close.upperBound
            } else if rest.prefix(9).lowercased() == "<!doctype", let close = rest.firstIndex(of: ">") {
                return html.index(after: close)
            } else {
                break
            }
        }
        return html.startIndex
    }
}

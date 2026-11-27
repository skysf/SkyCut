import Foundation
import Security

// MARK: - Is this copy of the app bundle the app it was copied from?
//
// What it does: checks a copied bundle's code signature the strict way (every architecture, nested code such as the
// helpers, sealed resources) against the designated requirement of the bundle it was copied from: for the Developer ID
// the same identifier and team, for an ad-hoc build the same code hash. Nothing goes over the network.
// The updater asks the same check of a downloaded new version, together with Apple's notarization
// (`verify(_:matchesNotarized:network:)`, AppUpdateVerifier).
// What it doesn't: copy (AppBundleMover) or decide anything about Gatekeeper; the running original already passed it.
// Rules: docs/build/build-and-packaging.md "Installing from the DMG", docs/architecture/code-signing-and-permissions.md,
// docs/architecture/app-updates.md "Verifying".

enum AppBundleSignature {
    struct Failure: LocalizedError, Equatable, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }

    /// Throws unless `copy` is validly signed and satisfies `original`'s designated requirement.
    static func verify(_ copy: URL, matches original: URL) throws {
        try verify(copy, satisfies: designatedRequirement(of: original), network: false)
    }

    /// Throws unless `copy` satisfies `original`'s designated requirement and is notarized (`notarized` in the same
    /// requirement: its stapled ticket offline; with `network` macOS may also ask Apple whether the ticket still stands).
    /// For the Developer ID the designated requirement names the team, so a new build of the team passes.
    static func verify(_ copy: URL, matchesNotarized original: URL, network: Bool) throws {
        try verify(copy, satisfies: notarizedRequirement(of: original), network: network)
    }

    /// `original`'s designated requirement with `notarized` in the same requirement. Throws when the original can't be read
    /// (the updater then knows the running app, not the copy, is the problem: AppUpdateVerifier).
    static func notarizedRequirement(of original: URL) throws -> SecRequirement {
        var text: CFString?
        let designated = try designatedRequirement(of: original)
        guard SecRequirementCopyString(designated, [], &text) == errSecSuccess, let text else {
            throw Failure(description: "the original's designated requirement could not be read")
        }
        var combined: SecRequirement?
        let status = SecRequirementCreateWithString("(\(text as String)) and notarized" as CFString, [], &combined)
        guard status == errSecSuccess, let combined else { throw Failure(description: message(status, nil)) }
        return combined
    }

    /// Throws unless `copy` is validly signed (strictly: every architecture, nested code, sealed resources) and satisfies
    /// `requirement`.
    static func verify(_ copy: URL, satisfies requirement: SecRequirement, network: Bool) throws {
        let code = try staticCode(at: copy)
        var flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        if !network { flags.formUnion(.noNetworkAccess) }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            throw Failure(description: message(status, error?.takeRetainedValue()))
        }
    }

    private static func designatedRequirement(of bundle: URL) throws -> SecRequirement {
        let code = try staticCode(at: bundle)
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw Failure(description: message(status, nil) + " (the original's designated requirement)")
        }
        return requirement
    }

    private static func staticCode(at bundle: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw Failure(description: message(status, nil) + " (\(bundle.lastPathComponent))")
        }
        return code
    }

    private static func message(_ status: OSStatus, _ error: CFError?) -> String {
        if let error { return (error as Error).localizedDescription }
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
        return "\(text) (\(status))"
    }
}

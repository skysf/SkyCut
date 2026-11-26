import Foundation
import Security

// MARK: - Is this copy of the app bundle the app it was copied from?
//
// What it does: checks a copied bundle's code signature the strict way (every architecture, nested code such as the
// helpers, sealed resources) against the designated requirement of the bundle it was copied from: for the Developer ID
// the same identifier and team, for an ad-hoc build the same code hash. Nothing goes over the network.
// What it doesn't: copy (AppBundleMover) or decide anything about Gatekeeper; the running original already passed it.
// Rules: docs/build/build-and-packaging.md "Installing from the DMG", docs/architecture/code-signing-and-permissions.md.

enum AppBundleSignature {
    struct Failure: LocalizedError, Equatable, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }

    /// Throws unless `copy` is validly signed and satisfies `original`'s designated requirement.
    static func verify(_ copy: URL, matches original: URL) throws {
        let requirement = try designatedRequirement(of: original)
        let code = try staticCode(at: copy)
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            .union(.noNetworkAccess)
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

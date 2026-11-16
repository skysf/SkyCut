import Foundation

// MARK: - When SkyCut kills a render for memory (pure)
//
// WebKit has no public way to cap a page's memory (the probe watched a page grow to 1.5 GB). So SkyCut measures the
// render's footprint itself — the helper plus the WebKit processes it reported (WebContent, GPU, Networking) — and the
// Mac's memory pressure, and kills the helper when this policy says so. Owns: the decision only. Does not own: reading
// the numbers or killing (`WebMotionMemoryWatch` in the App). docs/architecture/web-motion-renderer.md「内存」.

/// The kernel's memory pressure level (`kern.memorystatus_vm_pressure_level`: 1, 2, 4).
public enum WebMotionMemoryPressure: Int, Codable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

public enum WebMotionMemoryVerdict: Equatable, Sendable {
    case keepGoing
    /// The render alone uses more than its budget.
    case overBudget(limit: UInt64)
    /// The Mac is at "warning" and the render uses more than the smaller warning budget.
    case overWarningBudget(limit: UInt64)
    /// The Mac is out of memory: the render is the one thing SkyCut can give back right away.
    case machineCritical
}

public struct WebMotionMemoryPolicy: Sendable, Equatable {
    /// The render's footprint cap at normal pressure.
    public var budget: UInt64
    /// The cap while the Mac is at "warning".
    public var warningBudget: UInt64

    public init(budget: UInt64, warningBudget: UInt64) {
        self.budget = budget
        self.warningBudget = min(warningBudget, budget)
    }

    static let gibibyte: UInt64 = 1 << 30

    /// A normal render measured 300–600 MB in all (helper 70–130, GPU 200–280, each page ~25): 3 GB is far above that
    /// and still a quarter of a 16 GB Mac. Smaller Macs get a quarter of their memory.
    public static func standard(physicalMemory: UInt64) -> WebMotionMemoryPolicy {
        let budget = min(3 * gibibyte, max(physicalMemory / 4, gibibyte / 2))
        return WebMotionMemoryPolicy(budget: budget, warningBudget: gibibyte)
    }

    public func verdict(pressure: WebMotionMemoryPressure, footprint: UInt64) -> WebMotionMemoryVerdict {
        if pressure == .critical { return .machineCritical }
        if footprint > budget { return .overBudget(limit: budget) }
        if pressure == .warning, footprint > warningBudget { return .overWarningBudget(limit: warningBudget) }
        return .keepGoing
    }
}

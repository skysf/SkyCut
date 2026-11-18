import Foundation

// Discovers process changes from live page sources even while JavaScript is loading or awaiting ready. It does not
// inspect process identity or memory; the parent owns those. Finishing takes the last sample before terminal output.
@MainActor
final class PageProcessTracker {
    private let read: () -> [Int32]
    private let emit: ([Int32]) -> Void
    private var published: Set<Int32> = []
    private var timer: Timer?
    private var stopped = false

    init(read: @escaping () -> [Int32], emit: @escaping ([Int32]) -> Void) {
        self.read = read
        self.emit = emit
    }

    func start() {
        guard timer == nil, !stopped else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func sample() {
        guard !stopped else { return }
        let added = Set(read().filter { $0 > 0 }).subtracting(published).sorted()
        guard !added.isEmpty else { return }
        published.formUnion(added)
        emit(added)
    }

    func finish() {
        guard !stopped else { return }
        timer?.invalidate()
        timer = nil
        sample()
        stopped = true
    }
}

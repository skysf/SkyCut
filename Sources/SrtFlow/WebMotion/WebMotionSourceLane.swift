import Foundation

// The source clip's lane and visibility at an async boundary. Lane indexes may change when tracks are reordered;
// stable identities distinguish a reorder from a newer vertical move. Clip values and document identity are guarded separately.
struct WebMotionSourceLane: Equatable, Sendable {
    private enum Identity: Equatable, Sendable {
        case main
        case overlay(UUID)
        case audio(UUID)
    }

    private var identity: Identity
    private var isHidden: Bool

    static func capture(_ id: UUID?, in state: TimelineState) -> Self? {
        guard let id, let location = state.location(of: id) else { return nil }
        switch location.track {
        case .main:
            return Self(identity: .main, isHidden: state.mainHidden)
        case .overlay(let index) where state.overlayTracks.indices.contains(index):
            let lane = state.overlayTracks[index]
            return Self(identity: .overlay(lane.id), isHidden: lane.isHidden)
        case .audio(let index) where state.audioTracks.indices.contains(index):
            let lane = state.audioTracks[index]
            return Self(identity: .audio(lane.id), isHidden: lane.isHidden)
        default:
            return nil
        }
    }
}

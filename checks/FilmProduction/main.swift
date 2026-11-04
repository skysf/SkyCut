import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-production-values-\(UUID().uuidString)")
do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try runProductionRecordChecks()
    try runProductionReaderChecks(root: root)
    try runProductionSnapshotChecks(root: root)
    try runProductionGeometryChecks(root: root)
    try runProductionTransitionSnapshotChecks(root: root)
    try runProductionCanvasChecks(root: root)
    try runProductionPersistenceChecks(root: root)
    try await runSourceFrameChecks()
    try runSourceFrameReaderChecks()
    try runAnchorReaderChecks()
    try runProductionSamplingChecks()
    try runProductionReferenceChecks()
    try await runCatalogCacheChecks()
} catch { check(false, "Production checks threw: \(error)") }
print("Production state: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)

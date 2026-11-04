import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 从存盘的公开数据恢复并验证整个故事图；不读媒体、不改工程、不存任何收费凭据。
// 需要将 SkyStudioFilmReader.readRender 从 private 收窄开放到模块内，复用唯一严格入口。
enum AIFilmProductionGraph {
    struct Shot: Sendable {
        var record: FilmProductionState.Shot
        var film: SkyStudioFilm
        var render: SkyStudioFilm.Render
    }

    static func decode(_ value: FilmProductionState) throws -> [Shot] {
        guard (1...100_000).contains(value.revision), !value.shots.isEmpty, value.shots.count <= 100 else {
            throw SkyStudioFilmReader.error("production", "Invalid stored revision or shot count.")
        }
        _ = try SkyStudioFilmReader.text(.string(value.story), at: "production.story", maximum: 2000)
        let shots = try value.shots.map { record -> Shot in
            guard record.film.count <= 131_072, record.render.count <= 32_768 else {
                throw SkyStudioFilmReader.error("production", "Stored public declarations are too large.")
            }
            let film = try JSONDecoder().decode(SkyStudioFilm.self, from: record.film)
            let renderJSON = try JSONDecoder().decode(JSONValue.self, from: record.render)
            let render = try SkyStudioFilmReader.readRender(renderJSON, at: "production.render")
            guard film.context == render.context else {
                throw SkyStudioFilmReader.error("production.render.context", "Current render and film contexts must match.")
            }
            return Shot(record: record, film: film, render: render)
        }
        guard Set(shots.map { $0.film.shot.id }).count == shots.count else {
            throw SkyStudioFilmReader.error("production.shots", "Shot ids must be unique.")
        }
        let outputs = shots.compactMap { $0.record.outputClipID }
        guard Set(outputs).count == outputs.count else {
            throw SkyStudioFilmReader.error("production.shots", "An output clip cannot belong to two shots.")
        }
        for (index, shot) in shots.enumerated() {
            guard shot.film.shot.index == index, shot.film.shot.total == shots.count else {
                throw SkyStudioFilmReader.error("production.shots", "Shot index/total must match the authoritative ordered list.")
            }
            if index > 0 { try neighbor(shot.film.previous, matches: shots[index - 1], previous: true) }
            if index + 1 < shots.count { try neighbor(shot.film.next, matches: shots[index + 1], previous: false) }
            if index > 0, shot.film.previous?.cut != shots[index - 1].film.next?.cut {
                throw SkyStudioFilmReader.error("production.shots", "Both declarations of the same cut must agree.")
            }
        }
        try AIFilmProductionRecords.validate(value, graph: shots)
        return shots
    }

    private static func neighbor(_ value: SkyStudioFilm.Neighbor?, matches shot: Shot, previous: Bool) throws {
        guard let value, value.shotID == shot.film.shot.id, value.render == shot.render,
              value.soundBedID == shot.film.sound.bedID,
              value.state == (previous ? shot.film.shot.exit : shot.film.shot.entry) else {
            throw SkyStudioFilmReader.error("production.shots", "Neighbor id/render/state/sound bed must match the authoritative shot.")
        }
    }

    static func revisions(_ proposed: [Shot], after previous: [Shot]) throws {
        let prior = Dictionary(uniqueKeysWithValues: previous.map { ($0.film.shot.id, $0) })
        for current in proposed {
            guard let old = prior[current.film.shot.id] else {
                guard current.film.shot.revision == 1 else {
                    throw SkyStudioFilmReader.error("production.shot.revision", "A new shot starts at revision 1.")
                }
                continue
            }
            var normalized = current.film
            normalized.shot.revision = old.film.shot.revision
            let changed = normalized != old.film || current.render != old.render
            guard current.film.shot.revision == old.film.shot.revision + (changed ? 1 : 0) else {
                throw SkyStudioFilmReader.error("production.shot.revision", "Changed shot declarations advance by exactly one; unchanged shots keep their revision.")
            }
        }
    }
}

import Foundation

// 研究时的 numpy 版（tools/stoi.py、tools/music_features.py、盲听 tools/bt_lib.py 的 resample、照 tools/masker_attribution.py 的算法）
// 在 `scripts/check-listening.sh --dump <目录>` 写出来的同一份输入上算的数，ParityChecks.swift 拿 Swift 版和它们比。
// 不是手写的：改了 ParityCases.swift / TraitChecks.swift 里的信号就要重算，办法见 docs/architecture/listening-engine.md「和 Python 版对」。
enum PythonReference {
    struct ESTOIValues {
        let score: Double
        let worst: Double
        let segments: Int
        let frames: Int
        let first: Double
        let middle: Double
        let last: Double
    }

    struct GainValues {
        let id: String
        let removed: Double
        let lowered: Double
        let level: Double
    }

    struct FeatureValues {
        let centroid: Double
        let flat: Double
        let low: Double
        let chroma3: Double
        let chromaStab: Double?
        let pitch: Double?
        let pulse: Double?
        let steady: Double
        let mod4: Double
    }

    static let estoi: [String: ESTOIValues] = [
        "white_0dB": ESTOIValues(score: 0.5949274727475883, worst: 0.5849907814255365, segments: 160, frames: 189,
                                   first: 0.4089385558666103, middle: 0.6832236605555778, last: 0.4160482574011988),
        "shaped_-5dB": ESTOIValues(score: 0.33434112551526896, worst: 0.24919985200206057, segments: 160, frames: 189,
                                   first: 0.312341166302344, middle: 0.32346154450489334, last: 0.16282636176356713),
        "rumble_0dB": ESTOIValues(score: 0.629816510707246, worst: 0.6086030166431159, segments: 160, frames: 189,
                                   first: 0.5870150481504937, middle: 0.646120375769024, last: 0.5707094613946242),
        "babble_0dB": ESTOIValues(score: 0.6035428017931788, worst: 0.5940948093249624, segments: 160, frames: 189,
                                   first: 0.5227853618734456, middle: 0.6245449118653857, last: 0.45528778464312103),
        "music_-3dB": ESTOIValues(score: 0.5512929473825141, worst: 0.5152661812187231, segments: 160, frames: 189,
                                   first: 0.38488829880885395, middle: 0.630911636706167, last: 0.5779765776628017),
        "long_babble_3dB": ESTOIValues(score: 0.6726031937751453, worst: 0.4472302758351428, segments: 428, frames: 457,
                                   first: 0.7837078796450128, middle: 0.8095279183634534, last: 0.6197424044036933),
        "48k_music_0dB": ESTOIValues(score: 0.5682720804016602, worst: 0.5202026434104357, segments: 151, frames: 180,
                                   first: 0.5639036403078764, middle: 0.3681269424411891, last: 0.5944121657421643),
        "48k_white_5dB": ESTOIValues(score: 0.8747178282799769, worst: 0.8489342879903643, segments: 151, frames: 180,
                                   first: 0.8779169675310743, middle: 0.8118387697327172, last: 0.8888400752733909)
    ]

    static let maskerBase = 0.3434653887483421
    static let maskerGains: [GainValues] = [
        GainValues(id: "babble", removed: 0.20512571042758787, lowered: 0.11159322925059939, level: -18.26937962688128),
        GainValues(id: "rumble", removed: 0.05784431479024521, lowered: 0.025351121305309976, level: -20.000000007506053),
        GainValues(id: "music", removed: 0.017550049323833916, lowered: 0.012355981313567299, level: -23.000856725798716),
        GainValues(id: "sub", removed: -0.0007829915791304209, lowered: -0.0003524739356000617, level: -14.000000000952094)
    ]

    static let features: [String: FeatureValues] = [
        "rumble": FeatureValues(centroid: 218.6952793521044, flat: 3.983871910597005e-12, low: 0.733755429123097, chroma3: 0.4989936278172455,
                                   chromaStab: 0.9743848871245755, pitch: 0.24070634138408525, pulse: 0.3427270762983909,
                                   steady: 1.6804578541660888, mod4: 0.16183112119059442),
        "noise": FeatureValues(centroid: 4014.503078921635, flat: 0.5622520045720424, low: 0.035526907029312736, chroma3: 0.3662360039544173,
                                   chromaStab: 0.9885298273595456, pitch: 0.07117474180890915, pulse: 0.15840948133456922,
                                   steady: 0.15797826797185457, mod4: 0.14975030198567651),
        "chord": FeatureValues(centroid: 382.1520475484529, flat: 0.0018119976454250167, low: 0.48625663964736726, chroma3: 0.8302720335981921,
                                   chromaStab: 0.9898519724002183, pitch: 0.4193611995614825, pulse: 0.17755039485795707,
                                   steady: 0.41123609071668193, mod4: 0.045984515649597296),
        "clicks": FeatureValues(centroid: 3998.9021056670413, flat: 0.555985462586915, low: 0.03139715961117399, chroma3: 0.3798565726140806,
                                   chromaStab: 0.9289437702730352, pitch: 0.07864083981336886, pulse: 0.7367073556086741,
                                   steady: 12.040152707019724, mod4: 0.5182833618925294),
        "speech": FeatureValues(centroid: 1334.5560327152334, flat: 0.021708306544049844, low: 0.1802043987782638, chroma3: 0.6818851513088283,
                                   chromaStab: 0.59413139795829, pitch: 0.5174404503821346, pulse: 0.17741941435951322,
                                   steady: 5.780445182700567, mod4: 0.39116924818361265),
        "music": FeatureValues(centroid: 363.74278808417836, flat: 0.0006699068897552697, low: 0.7346363375236585, chroma3: 0.7764645588281515,
                                   chromaStab: 0.9909935630665188, pitch: 0.42870643218276266, pulse: 0.7220612905993845,
                                   steady: 3.89065272289778, mod4: 0.6846574671859498)
    ]
}

"""Author the reference cut through public MCP calls and assert edit and review behavior."""

from pathlib import Path

from mix_export import near
from reference_media import FPS, PAGE


def clips(timeline, track):
    return next(lane["clips"] for lane in timeline["tracks"] if lane["track"] == track)


def read(session):
    return session.edit("get_timeline")


def subtitles(session):
    return session.edit("get_subtitles", track="original")["original"]["lines"]


def inspect(session, **arguments):
    return session.job(session.edit("inspect_video", image=False, **arguments))


def add_picture(session):
    session.edit("set_canvas", fps=FPS)
    added = session.edit("add_clips", clips=[
        {"file": "amber.mp4", "track": "V1", "source_in": 0.5, "source_out": 2.5},
        {"file": "blue.mp4", "track": "V1", "source_in": 0.5, "source_out": 2.5},
        {"file": "slate.mp4", "track": "V1", "source_in": 0.5, "source_out": 2.5},
        {"file": "alpha.mov", "track": "V2", "start": 0.5, "source_out": 0.75},
        {"file": "still.png", "track": "V2", "start": 1.375, "source_out": 0.5},
        {"file": "caption.srt"},
    ])
    assert [row["track"] for row in added["added"]] == ["V1", "V1", "V1", "V2", "V2"], added
    reminder, = added["source_cuts"]
    assert reminder["clip"] == added["added"][0]["id"] and reminder["source_frame"] == 58, reminder
    assert reminder["frames_after_cut"] == 2 and reminder["suggested_source_out"] == 2.417, reminder
    return added["added"][0]["id"]


def check_delivery_marks(session):
    scope = {"from": 1.5, "to": 2.5}
    report = inspect(session, **scope, sounds={"V1": "ambience"})
    by_kind = {item["kind"]: item for item in report["findings"] if 1.80 <= item["from"] <= 2.02}
    assert "source_cut" in by_kind and "audio_cut_jump" in by_kind, report["findings"]
    source = by_kind["source_cut"]
    near(source["from"], 2 - 2 / FPS, 0.002, "delivery source cut")
    jump = by_kind["audio_cut_jump"]
    near(jump["at"], 2, 0.002, "delivery audio cut jump")
    assert jump["jump_db"] >= 6 and jump["loudest_layers"], jump

    reason = "Two frames intentionally lead into the next cut"
    session.edit("inspect_video", intentional={"job_id": report["job_id"], "key": source["key"], "reason": reason})
    marked = inspect(session, **scope, sounds={"V1": "ambience"})
    assert not any(item["kind"] == "source_cut" for item in marked["findings"]), marked["findings"]
    assert any(item["key"] == source["key"] and item["intentional_reason"] == reason and item["reproduced"]
               for item in marked["intentional"]), marked["intentional"]
    assert any(item["kind"] == "audio_cut_jump" for item in marked["findings"]), marked["findings"]


def picture_geometry(timeline):
    return [(row["file"], row["start"], row["end"], row["source_in"], row["source_out"])
            for row in clips(timeline, "V1")]


def check_freeze_and_ripple(session, picture):
    before = read(session)
    assert before["linkage"], "Reference edit requires the normal linkage default"
    frozen = session.edit("freeze_frame", clip_id=picture, time=0.75, duration=0.25)
    held = read(session)
    assert frozen["start"] == 0.75 and frozen["end"] == 1, frozen
    assert next(row for row in clips(held, "V1") if row["id"] == frozen["freeze_id"])["kind"] == "image"
    assert [row["start"] for row in clips(held, "V1")[-2:]] == [2.25, 4.25]
    assert subtitles(session)[0]["start"] == 4.5, "Caption should follow picture shifted by the freeze"

    session.edit("delete_items", ids=[frozen["freeze_id"]], ripple=True)
    assert [row["start"] for row in clips(read(session), "V1")[-2:]] == [2, 4]
    assert subtitles(session)[0]["start"] == 4.25, "Caption should follow the ripple"
    session.edit("undo", steps=2)
    assert picture_geometry(read(session)) == picture_geometry(before)


def read_mix(session, layers, **scope):
    result = session.edit("listen", mix=True, layers=layers, frames=True, silence_db=-55, **scope)
    if "job_id" in result:
        return session.job(result)
    return result


def edit_sound(session, picture):
    picture_before = picture_geometry(read(session))
    joined = session.edit("set_transition", after_clip_id=picture, sound="crossfade", frames=6)
    assert picture_geometry(read(session)) == picture_before, "A sound-only crossfade moved picture"
    assert joined["picture"] == "unchanged", joined

    # Point the placement at an accent actually detected in the source.
    beats = session.edit("listen", file="accents.wav", beats=True)
    hit = min(beats["strongest_accents"], key=lambda at: abs(at - 1.5))
    near(hit, 1.5, 0.05, "strong music accent")
    audio = session.edit("add_clips", clips=[
        {"file": "narrator.wav", "track": "A3", "start": 0.25},
        {"file": "accents.wav", "track": "A4", "source_out": 5.25, "hit": hit, "hit_at": 2},
        {"sound_effect": {"preset": "tick", "volume_db": -10}, "track": "A5", "hit_at": 3.5},
    ])["added"]
    voice, music, effect = audio
    assert [row["track"] for row in audio] == ["A3", "A4", "A5"], audio
    near(music["start"] + hit, 2, 0.002, "music source attack mapped to the cut")
    near(effect["hit_at"], 3.5, 0.002, "synthesized effect landing")
    assert effect["sound_effect"] == "tick" and effect["end"] > effect["start"], effect

    scope = {"from": 0.75, "to": 0.95}
    before = read_mix(session, ["A3", "A4"], **scope)
    session.edit("set_track", track="A3", duck_others_db=-10, duck_tracks="A4")
    session.edit("edit_clip", clip_id=voice["id"], voice_band_db=-12)
    after = read_mix(session, ["A3", "A4"], **scope)
    voice_before, bed_before = before["layers"]
    voice_after, bed_after = after["layers"]
    near(bed_before["level_db"] - bed_after["level_db"], 10, 0.4, "music ducking under narration")
    assert voice_before["bands_db"]["high_mid"] - voice_after["bands_db"]["high_mid"] > 8, after
    near(voice_after["bands_db"]["low"], voice_before["bands_db"]["low"], 2, "low voice band stays")
    near(voice_after["bands_db"]["high"], voice_before["bands_db"]["high"], 2, "high voice band stays")
    cut, = joined["cuts"]
    assert cut["cut"] == 2 and cut["shape"] == "equal_power", cut
    assert cut["in"]["offset_frames"] == -6 and cut["out"]["offset_frames"] == 6, cut


def add_titles(session):
    session.edit("set_text", text="CUT STUDY", small_text="TAKE ONE", motion_preset="frame_reveal",
                 hit_at=2.5, duration=1.5)
    before = read(session)
    assert {row.get("motion_preset") for row in before["texts"]} == {"frame_reveal"}, before["texts"]
    session.edit("set_canvas", ratio="9:16")
    framed = read(session)
    assert framed["canvas"]["ratio"] == "9:16", framed["canvas"]
    assert len(before["texts"]) == len(framed["texts"]), framed["texts"]
    for original, reframed in zip(before["texts"], framed["texts"]):
        assert (reframed["id"], reframed["x"], reframed["y"]) == (original["id"], original["x"], original["y"])
        # Text sizes are stored at 1080 reference height. Account for the canvas height when comparing to its short side.
        old, new = before["canvas"], framed["canvas"]
        near(reframed["font_size"] * new["height"] / min(new["width"], new["height"]),
             original["font_size"] * old["height"] / min(old["width"], old["height"]), 1, "native preset size relative to short side")
    session.edit("undo")
    assert read(session)["texts"] == before["texts"]

    motion = dict(name="Ink plate", page=PAGE, duration=0.75, hit=0.25, at=3.25, track="V3",
                  parameters={"ink": "#DE18B0"}, fields=[{"key": "ink", "label": "Ink", "type": "color"}])
    question, error = session.client.call("set_motion", dict(motion, project=session.project), timeout=30)
    assert not error and question.get("status") == "needs_confirmation", question
    result = session.edit("set_motion", **motion, confirm_token=question["confirm_token"])
    if "job_id" in result:
        result = session.job(result)["result"]
    assert result["start"] == 3.25 and result["end"] == 4 and result["track"] == "V3", result
    assert len(result["checks"]) == 6 and all(item["passed"] for item in result["checks"]), result


def check_save_and_versions(session, document):
    before = read(session)
    saved = session.edit("save_project")
    assert Path(saved["saved"]).resolve() == document
    session.edit("close_project")
    session.project = session.call("open_project", path=str(document))["project"]
    reopened = read(session)
    compare_timeline(before, reopened)

    picture = clips(reopened, "V1")[0]["id"]
    changed = session.edit("edit_clip", clip_id=picture, opacity=0.5)
    version = changed["before_round_version"]["id"]
    assert version in {row["id"] for row in session.edit("get_status")["project"]["versions"]}
    altered = read(session)
    assert altered["tracks"] != reopened["tracks"]
    session.edit("undo", version=version)
    compare_timeline(read(session), reopened)
    session.edit("undo", steps=1)
    compare_timeline(read(session), altered)
    session.edit("undo", version=version)
    compare_timeline(read(session), reopened)

    collision = document.with_name("Existing.skycut")
    collision.write_bytes(b"preserve this project")
    copy = Path(session.edit("save_project", path=str(collision))["saved"]).resolve()
    assert copy.parent == collision.parent and copy != collision and copy.is_file()
    assert collision.read_bytes() == b"preserve this project", "Save As replaced an existing project"


def compare_timeline(left, right):
    for field in ("canvas", "duration", "tracks", "texts", "shapes", "subtitles"):
        assert left[field] == right[field], f"Project save/restore changed {field}: {left[field]} vs {right[field]}"

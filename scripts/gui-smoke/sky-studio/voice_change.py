"""真实 App / MCP 的免费变声冒烟（声音 PR 9）；先运行同目录 run.sh。结果保留在测试目录。
假 Sky Studio 把传上去的那段源音频原样当成「变声后的人声」和「背景」两个文件回来：验的是 change_voice 走全程——先报价再上传
（单声道 WAV、voice_convert_source、不带 Key）、一次 voice_convert 任务、做完两条新音频轨、原段静音、三段链接、撤销一步回去，
不认识的声音收费之前就拒；不验声音像不像（那要真 Sky Studio、花积分，见 docs/architecture/voice-library.md 第十一节的人工回归）。"""
import json
import os
from pathlib import Path
import sys
import time
import urllib.request
import wave

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcpclient import MCP

D = Path(os.environ.get("SKYSTUDIO_SMOKE_DIR", "/private/tmp/srtflow-skystudio-smoke"))
WORK = D / "work"
SERVER = "http://127.0.0.1:" + os.environ.get("SKYSTUDIO_SMOKE_PORT", "18766")
VOICE = "voice_" + "5" * 32
mcp = MCP(str(D / "SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp"), env={**os.environ, "SRTFLOW_MCP_NO_LAUNCH": "1"})


def call(tool, args=None, fails=False):
    value, error = mcp.call(tool, args, timeout=90)
    print(json.dumps({"tool": tool, "error": error, "result": value}, ensure_ascii=False), flush=True)
    assert bool(error) == fails, (tool, value)
    return value


def server_log():
    return json.load(urllib.request.urlopen(SERVER + "/__log"))


def ledger():
    return call("get_status")["generation"]["spent_today_credits"]


def audio_tracks(timeline):
    return [track for track in timeline.get("tracks", []) if track.get("kind") == "audio"]


try:
    log_start = len(server_log())
    assert "change_voice" in mcp.tools(), "change_voice must be listed"
    call("open_folder", {"path": str(WORK)})
    call("set_view", {"mode": "background"})
    call("new_project", {"version": str(time.time_ns())})
    added = call("add_clips", {"clips": [{"file": "voice-sample.wav"}]})
    clip = added["added"][0]["id"]
    before = ledger()
    timeline_before = call("get_timeline")
    assert len(audio_tracks(timeline_before)) == 1, timeline_before

    # 走全程：声音库的声音，语言由 AI 给。
    started = call("change_voice", {"clip_id": clip, "voice": VOICE, "language": "en"})
    assert started["status"] == "started" and started["kind"] == "voice_change" and started["credits"] == 3, started
    assert started["credits_expected"] == 2 and started["voice_name"] == "Smoke voice" and started["target_language"] == "en", started
    done = mcp.wait_job(started["job_id"], 120)
    print(json.dumps({"job": done}, ensure_ascii=False), flush=True)
    assert done["status"] == "done" and done["model"] == "chatterbox-hd" and done["credits_charged"] == 2, done
    assert done["voice_track"] == "A2" and done["background_track"] == "A3", done
    assert ledger() == before + 2, "the books hold what Sky Studio charged"
    timeline = call("get_timeline")
    tracks = audio_tracks(timeline)
    assert len(tracks) == 3 and all(len(track["clips"]) == 1 for track in tracks), timeline
    original, voice, background = (track["clips"][0] for track in tracks)
    assert original["id"] == done["clip_id"] and original.get("muted") is True, original
    assert voice["id"] == done["voice_clip_id"] and background["id"] == done["background_clip_id"], (voice, background)
    assert voice["start"] == original["start"] == background["start"] and abs(voice["end"] - original["end"]) < 0.05, (original, voice)
    for name in (done["voice_file"], done["background_file"]):
        file = Path(name) if Path(name).is_absolute() else WORK / name
        with wave.open(str(file)) as audio:
            assert audio.getnchannels() == 1 and audio.getnframes() > 0, name
    # 上一次跑留下的文件还在时撞名加编号（「… 2.wav」），不覆盖。
    voice_name = Path(done["voice_file"]).name
    assert voice_name.startswith("voice-sample - Smoke voice") and voice_name.endswith(".wav"), voice_name

    # 一步撤销回去；重做再回来。
    call("undo")
    undone = call("get_timeline")
    assert len(audio_tracks(undone)) == 1 and audio_tracks(undone)[0]["clips"][0].get("muted") is not True, undone
    assert ledger() == before + 2, "undo never refunds: the files and the charge stay"

    # 请求的样子：先报价（按源秒数）、再上传（单声道 WAV、不带 Key）、再交一次任务。
    logs = server_log()[log_start:]
    quotes = [i for i, row in enumerate(logs) if row["method"] == "POST" and row["path"].endswith("/quote") and row["body"]["kind"] == "voice_convert"]
    tickets = [i for i, row in enumerate(logs) if row["method"] == "POST" and row["path"].endswith("/uploads")]
    puts = [row for row in logs if row["method"] == "PUT"]
    submits = [(i, row) for i, row in enumerate(logs) if row["method"] == "POST" and row["path"].endswith("/jobs")]
    assert len(quotes) == 1 and len(tickets) == 1 and len(puts) == 1 and len(submits) == 1, (quotes, tickets, len(puts), submits)
    assert quotes[0] < tickets[0] < submits[0][0], "quote, then upload, then the job"
    quote = logs[quotes[0]]["body"]
    assert quote["model"] == "auto" and quote["params"]["target_voice"] == VOICE and quote["params"]["target_language"] == "en", quote
    assert quote["params"]["source"]["seconds"] > 10 and not quote.get("inputs"), quote
    ticket = logs[tickets[0]]["body"]
    assert ticket["purpose"] == "voice_convert_source" and ticket["content_type"] == "audio/wav", ticket
    assert not puts[0]["has_auth"], "the upload goes to the signed address without the key"
    job = submits[0][1]["body"]
    assert job["kind"] == "voice_convert" and job["model"] == "auto" and job["max_credits"] == 3, job
    assert job["inputs"]["source_audio_url"].endswith(".wav") and job["params"]["target_voice"] == VOICE, job
    with wave.open(str(D / "assets" / Path(job["inputs"]["source_audio_url"]).name)) as sent:
        assert sent.getnchannels() == 1 and sent.getsampwidth() == 2, "the upload is mono 16-bit"
        assert abs(sent.getnframes() / sent.getframerate() - quote["params"]["source"]["seconds"]) < 0.01, "and exactly the clip's source"

    # 不是声音库的声音、也不是预设：收费之前就拒（每日额度、静音、超长这些由 scripts/check-voice-recovery.sh 的真 App 对象回归钉着）。
    posts = len([row for row in server_log() if row["method"] == "POST" and row["path"].endswith("/jobs")])
    refused = call("change_voice", {"clip_id": clip, "voice": "eleven:Daniel"}, fails=True)
    assert "list_voices" in json.dumps(refused), refused
    assert len([row for row in server_log() if row["method"] == "POST" and row["path"].endswith("/jobs")]) == posts
    assert ledger() == before + 2

    (D / "voice-change-results.json").write_text(json.dumps(dict(started=started, done=done), ensure_ascii=False, indent=2))
    print("PASS actual App: change_voice quotes before uploading a mono WAV as voice_convert_source without the key, sends one "
          "voice_convert job, lands the voice and the background on two new audio tracks with the original muted, one undo, "
          "the charge settled at what Sky Studio billed, an unsupported voice refused before paying")
finally:
    mcp.close()

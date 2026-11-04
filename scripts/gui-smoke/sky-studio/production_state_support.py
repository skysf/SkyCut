"""Background MCP production acceptance primitives; no launcher or media implementation.

All project mutations use the existing official_client.Session. Evidence contains public
plans and observations only; opaque preparation/quote tokens remain in process memory.
"""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import time


SENSITIVE = {"recipe_pin", "quote_token", "prepared_references", "confirm_token", "api_key", "secret"}


def public(value):
    if isinstance(value, dict):
        return {key: public(item) for key, item in value.items() if key not in SENSITIVE}
    if isinstance(value, list):
        return [public(item) for item in value]
    return value


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def save_json(path, value):
    path = Path(path)
    path.write_text(json.dumps(public(value), indent=2, allow_nan=False) + "\n")
    path.chmod(0o600)
    return str(path)


def keyed(rows, field="shot_id"):
    return {row[field]: row for row in rows}


def media_rows(timeline, track):
    return next((row["clips"] for row in timeline["tracks"] if row["track"] == track), [])


def unchanged_timeline(value):
    # Playhead/status prose may change independently; retain all authored timeline fields.
    return {key: value[key] for key in ("tracks", "texts", "filters", "subtitles", "shapes", "canvas", "fps", "production") if key in value}


def verify_contract(session):
    tools = session.mcp.request("tools/list")["result"]["tools"]
    schemas = {row["name"]: row["inputSchema"].get("properties", {}) for row in tools}
    required = {
        "get_status": ["models", "film_contract"], "new_project": ["name", "version"],
        "open_project": ["path"], "close_project": ["project"], "get_timeline": ["project"],
        "save_project": ["production", "expected_revision"], "undo": ["steps"],
        "set_view": ["mode"], "open_folder": ["path"], "set_canvas": ["fps"],
        "add_clips": ["clips"], "edit_clip": ["clip_id", "file", "source_in", "source_out", "speed", "muted"],
        "freeze_frame": ["clip_id", "time", "duration"], "set_track": ["track", "volume_db"],
        "look": ["file", "times", "image"], "listen": ["file", "source_in", "source_out"],
        "export_video": ["preset", "name"], "inspect_video": ["file", "from", "to", "image"],
        "generate_media": ["prepare_references", "prepared_references", "quote_only", "film"],
    }
    for name, fields in required.items():
        assert name in schemas and set(fields) <= schemas[name].keys(), ("MCP contract mismatch", name, fields)
    properties = schemas["add_clips"]["clips"]["items"]["properties"]
    assert {"file", "track", "start", "source_in", "source_out"} <= properties.keys()
    status = session.call("get_status", {"models": True, "film_contract": True})
    contract = status["film_contract"]
    assert "production_schema" in contract and "production_readback" in contract
    assert "source_geometry" in json.dumps(contract), "Use an App with exact production source geometry"
    save_json(session.evidence / "mcp-contract.json", {"schemas": schemas, "contract": contract,
                                                       "catalog": status.get("generation_models"), "app_version": status.get("app_version"), "mcp_catalog": status.get("mcp_catalog")})
    return status


class StateRun:
    def __init__(self, session, workspace, network):
        self.s = session
        self.work = Path(workspace).resolve()
        self.network = network
        self.tag = "production-" + str(time.time_ns())
        self.project = self.sentinel = None
        self.path = self.sentinel_path = None
        self.sentinel_before = None
        self.pending = None
        self.stage = "setup"
        self.base = self.prepared = None
        self.cost_before = session.spent()
        self.admitted_before = network.admitted()
        self.log_start = len(network.log())
        self.owned_paths = []
        self.events = []
        self.fixture_modes = {}

    def evidence(self, label, value):
        return save_json(self.s.evidence / (label + ".json"), value)

    def read(self):
        return self.s.call("get_timeline", {"project": self.project})

    def production(self):
        return self.read().get("production")

    def save(self, plan):
        before = self.production()
        mark = len(self.network.log())
        self.s.call("save_project", {"project": self.project, "production": plan,
                                    "expected_revision": before["revision"] if before else 0})
        traffic = self.network.log()[mark:]
        assert not traffic, "Saving production must not query/upload/submit behind the caller's back"
        self.background()
        return self.production()

    def new(self, name):
        result = self.s.call("new_project", {"name": name, "version": self.tag})
        project = result["project"]
        path = result["created"]
        assert Path(path).resolve().is_relative_to(self.work), "Scratch project escaped the dedicated workspace"
        self.owned_paths.append(path)
        self.s.background(project)
        return project, path

    def background(self):
        self.s.background(self.project)
        if self.sentinel:
            self.s.background(self.sentinel)
            current = self.s.call("get_timeline", {"project": self.sentinel})
            assert unchanged_timeline(current) == self.sentinel_before, "Another owned project changed"

    def case(self, label, evidence=None):
        self.background()
        assert self.s.spent() == self.cost_before and self.network.admitted() == self.admitted_before
        assert not self.network.posts(self.network.log()[self.log_start:]), "State acceptance must admit no provider job"
        self.events.append(label)
        if evidence is not None:
            self.evidence("case-" + str(len(self.events)), {"case": label, "evidence": evidence})
        self.s.passed_case(label)
        self.evidence("progress", {"stage": self.stage, "cases": self.events, "project": self.project,
                                   "path": self.path, "sentinel": self.sentinel, "owned_paths": self.owned_paths})

    def refused(self, name, args):
        before = unchanged_timeline(self.read())
        mark, spent = len(self.network.log()), self.s.spent()
        result, error = self.s.mcp.call(name, args, timeout=90)
        assert error, ("Expected explicit refusal", name, public(result))
        assert unchanged_timeline(self.read()) == before, "Refusal mutated the project"
        assert not self.network.posts(self.network.log()[mark:]) and self.s.spent() == spent
        return result

    def refuse_plan(self, plan, expected=None):
        current = self.production()
        return self.refused("save_project", {"project": self.project, "production": plan,
                                             "expected_revision": current["revision"] if expected is None else expected})

    def reopen(self):
        before = self.production()
        self.s.call("save_project", {"project": self.project})
        self.s.call("close_project", {"project": self.project})
        result = self.s.call("open_project", {"path": self.path})
        self.project = result["project"]
        after = self.production()
        # Short IDs are assigned afresh; compare author data after reading canonical IDs from this reopened project.
        def logical(value):
            value = deepcopy(value)
            for row in value["plan"]["shots"]:
                row.pop("clip_id", None)
            for cue in value["plan"]["sound_cues"]:
                cue.pop("audio_clip_id", None)
            return value
        assert logical(after) == logical(before), "Saved production/evidence changed on reopen"
        self.background()
        return after

    def prepare(self, image, last_image):
        base = dict(project=self.project, kind="image_to_video", model="minimax-h3",
                    prompt="An original abstract science fiction field, uniformly steel blue, no actors or visible action.",
                    duration=3, resolution="768p", image=str(image), last_image=str(last_image), name=self.tag)
        mark = len(self.network.log())
        start = self.s.call("generate_media", {**base, "prepare_references": True, "idempotency_key": self.tag + "-prepare-" + str(time.time_ns())})
        assert start["status"] == "preparing_references"
        result = self.s.wait(start["job_id"])
        assert result["charged"] is False and result["inputs"] == result["prepared_render"]["inputs"]
        assert not self.network.posts(self.network.log()[mark:])
        assert all(str(url).startswith("https://assets.skycut-smoke.invalid/originals/local-smoke/")
                   for url in result["inputs"].values()), "State driver requires fake account originals"
        return base, result

    def quote(self, expect_refusal=False):
        film = self.production()["plan"]["shots"][1]["film"]
        args = {**self.base, "project": self.project, "film": film,
                "prepared_references": self.prepared["prepared_references"], "quote_only": True,
                "idempotency_key": self.tag + "-quote-" + str(time.time_ns())}
        mark = len(self.network.log())
        if expect_refusal:
            result = self.refused("generate_media", args)
            assert "production" in json.dumps(result).lower(), "Refusal did not reach the production authority boundary"
            assert not self.network.posts(self.network.log()[mark:], "quote"), "Stale authority reached official quote"
        else:
            result = self.s.call("generate_media", args)
            assert result["status"] == "quoted" and result["charged"] is False and result["uploaded"] is False
            assert all(result["seam_review"][side] for side in ("previous", "next"))
            assert result["official_recipe"]["preflight_only"] is True
        assert not self.network.posts(self.network.log()[mark:], "uploads")
        self.evidence("last-quote", result)
        return result

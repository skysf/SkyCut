"""官方合同的公开合成夹具：原图归属、请求 pin 和双侧预检；没有生产配方或提供方。"""
import datetime
import hashlib
import json
import secrets
from urllib.parse import urlsplit


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class OfficialRecipes:
    def __init__(self, root):
        self.root = root
        self.uploads = {}
        self.pins = {}

    def original(self, account, name):
        url = f"https://assets.skycut-smoke.invalid/originals/{account}/{name}"
        self.uploads[url] = account, name
        return url

    def validate_inputs(self, inputs, account):
        urls = [inputs[key] for key in ("image_url", "last_frame_url") if key in inputs]
        for reference in inputs.get("references", []):
            if reference.get("type") != "image":
                raise ValueError("original_images_only")
            urls.append(reference.get("url"))
        if set(inputs) - {"image_url", "last_frame_url", "references"}:
            raise ValueError("original_images_only")
        for url in urls:
            record = self.uploads.get(url)
            parsed = urlsplit(url)
            if not record or record[0] != account or parsed.scheme != "https":
                raise ValueError("original_owner_mismatch")
            file = self.root / record[1]
            if not file.is_file() or file.stat().st_size == 0:
                raise ValueError("original_upload_incomplete")

    def validate_film(self, request, account):
        film = request["film"]
        self.validate_inputs(request.get("inputs", {}), account)
        shot = film["shot"]
        expected = {"previous": shot["index"] > 0, "next": shot["index"] < shot["total"] - 1}
        for side, needed in expected.items():
            neighbor = film.get(side)
            if bool(neighbor) != needed:
                raise ValueError("missing_neighbor")
            if neighbor:
                self.validate_inputs(neighbor["render"].get("inputs", {}), account)
        return film

    @staticmethod
    def identity(request, account):
        return digest({"account": account, **{key: request.get(key) for key in ("kind", "model", "prompt", "params", "inputs", "film")}})

    def quote(self, request, account, credits, control):
        if control.get("official_failure") == "unavailable":
            return 503, "recipe_unavailable"
        if control.get("official_failure") == "unsupported":
            return 400, {"error": {"code": "invalid_request", "field": "film.context", "message": "Unsupported fixture context."}}
        try:
            film = self.validate_film(request, account)
        except (ValueError, KeyError, TypeError) as error:
            return 400, str(error)
        identity = self.identity(request, account)
        review = {side: digest({"request": identity, "side": side}) if film.get(side) else None for side in ("previous", "next")}
        seconds = control.get("official_quote_seconds", 300)
        expiry = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=seconds)
        pin = "fixture-" + secrets.token_urlsafe(24)
        self.pins[pin] = dict(identity=identity, review=review, credits=credits, expiry=expiry)
        return 200, {"credits": credits, "typical_seconds": 5, "official_recipe": {
            "recipe_pin": pin, "expires_at": expiry.isoformat(), "seam_review": review}}

    def submit(self, request, account, control):
        if control.get("official_failure") == "unavailable":
            return "recipe_unavailable"
        try:
            self.validate_film(request, account)
            pinned = self.pins.get(request.get("recipe_pin"))
            if not pinned or pinned["identity"] != self.identity(request, account):
                return "recipe_pin_mismatch"
            if pinned["expiry"] <= datetime.datetime.now(datetime.timezone.utc):
                return "recipe_pin_expired"
            if pinned["review"] != request.get("seam_review"):
                return "seam_review_mismatch"
            if pinned["credits"] != request.get("max_credits"):
                return "quote_price_changed"
        except (ValueError, KeyError, TypeError) as error:
            return str(error)
        return None

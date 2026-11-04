"""Pure float-boundary guard only; imports no App/session and never calls MCP."""
import math
import sys

sys.dont_write_bytecode = True
from native_anchor_capture import supports_exact_in_out

check_window = (lambda _: True) if "--reverse" in sys.argv[1:] else supports_exact_in_out
regular = {"source_in": 0.5, "source_out": 1.5, "source_duration": 1.0}
one_ulp = {**regular, "source_duration": math.nextafter(1.0, 0.0)}
assert one_ulp["source_in"] + one_ulp["source_duration"] == one_ulp["source_out"]
assert math.nextafter(one_ulp["source_duration"], math.inf) == regular["source_duration"]
checks = [(check_window(regular), "exact in/out duration is usable"),
          (not check_window(one_ulp), "one-ULP changed duration is refused, not hidden by tolerance")]
for passed, message in checks:
    if not passed:
        print("FAIL " + message)
failures = sum(not passed for passed, _ in checks)
print(f"Native helper exact window: {len(checks)} checks, {failures} failures")
raise SystemExit(1 if failures else 0)

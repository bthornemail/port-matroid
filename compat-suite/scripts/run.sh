#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# Snapshot hash checks (csnp + .hash)
for csnp in "$ROOT"/fixtures/snapshots/*.csnp; do
  hash_file="${csnp%.csnp}.hash"
  if [ ! -f "$hash_file" ]; then
    echo "missing hash file for $csnp" >&2
    exit 1
  fi
  expected=$(tr -d '\n' < "$hash_file")
  actual=$(python3 - <<PY
import hashlib
from pathlib import Path
p = Path("$csnp")
data = p.read_bytes()
if len(data) < 32:
    raise SystemExit("file too small for hash")
preimage = data[:-32]
print(hashlib.sha256(preimage).hexdigest())
PY
)
  if [ "$expected" != "$actual" ]; then
    echo "hash mismatch for $csnp: expected $expected got $actual" >&2
    exit 1
  fi
  echo "ok snapshot hash $csnp"
done

# Event hash validation (ULP trace events)
python3 - <<'PY'
import base64
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["ROOT"])
events_dir = root / "fixtures" / "events"
events_bad_dir = events_dir / "bad"

def b64_nopad(data: bytes) -> bytes:
    return base64.b64encode(data).rstrip(b"=")

def parse_hash(text: str) -> bytes:
    if not text.startswith("sha256:"):
        raise ValueError("hash must start with sha256:")
    return bytes.fromhex(text[len("sha256:"):])

def canonical_bytes(ev: dict) -> bytes:
    version = int(ev["v"]).to_bytes(8, "big", signed=False)
    seq = int(ev["seq"]).to_bytes(8, "big", signed=False)
    time = ev["time"].encode("utf-8")
    etype = ev["type"].encode("utf-8")
    actor = ev["actor"].encode("utf-8")
    payload_b64 = ev["payload_b64"].encode("utf-8")
    prev_hash = b64_nopad(parse_hash(ev["prev"]))
    return b"".join([version, seq, time, etype, actor, payload_b64, prev_hash])

def check_file(path: Path) -> None:
    required = {"v", "seq", "time", "type", "actor", "payload_b64", "prev", "hash"}
    for idx, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        ev = json.loads(line)
        if not isinstance(ev, dict) or set(ev.keys()) != required:
            raise ValueError(f"event schema mismatch {path}:{idx}: keys={sorted(ev.keys()) if isinstance(ev, dict) else type(ev)}")
        want = ev["hash"]
        got = "sha256:" + hashlib.sha256(canonical_bytes(ev)).hexdigest()
        if want != got:
            raise ValueError(f"event hash mismatch {path}:{idx}: expected {want} got {got}")

for path in events_dir.glob("*.ndjson"):
    check_file(path)
    print(f"ok event hashes {path}")

for path in events_bad_dir.glob("*.ndjson"):
    try:
        check_file(path)
    except Exception:
        print(f"ok must-reject (schema/hash mismatch detected) {path}")
    else:
        raise SystemExit(f"expected hash mismatch but file validated: {path}")
PY

# Segment window validation (distributed sync)
python3 - <<'PY'
import base64
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["ROOT"])
seg_root = root / "fixtures" / "segments"
seg_accept = seg_root / "accept"
seg_bad = seg_root / "bad"

def b64_nopad(data: bytes) -> bytes:
    return base64.b64encode(data).rstrip(b"=")

def parse_hash(text: str) -> bytes:
    if not text.startswith("sha256:"):
        raise ValueError("hash must start with sha256:")
    return bytes.fromhex(text[len("sha256:"):])

def canonical_bytes(ev: dict) -> bytes:
    version = int(ev["v"]).to_bytes(8, "big", signed=False)
    seq = int(ev["seq"]).to_bytes(8, "big", signed=False)
    time = ev["time"].encode("utf-8")
    etype = ev["type"].encode("utf-8")
    actor = ev["actor"].encode("utf-8")
    payload_b64 = ev["payload_b64"].encode("utf-8")
    prev_hash = b64_nopad(parse_hash(ev["prev"]))
    return b"".join([version, seq, time, etype, actor, payload_b64, prev_hash])

def load_events(path: Path, caps: dict):
    required = {"v", "seq", "time", "type", "actor", "payload_b64", "prev", "hash"}
    out = []
    for idx, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        if "max_line_len" in caps and len(line.encode("utf-8")) > int(caps["max_line_len"]):
            raise ValueError(f"segment line too long {path}:{idx}")
        ev = json.loads(line)
        if not isinstance(ev, dict) or set(ev.keys()) != required:
            raise ValueError(f"event schema mismatch {path}:{idx}")
        if "max_payload_b64_len" in caps and len(ev.get("payload_b64", "")) > int(caps["max_payload_b64_len"]):
            raise ValueError(f"segment payload_b64 too long {path}:{idx}")
        want = ev["hash"]
        got = "sha256:" + hashlib.sha256(canonical_bytes(ev)).hexdigest()
        if want != got:
            raise ValueError(f"event hash mismatch {path}:{idx}: expected {want} got {got}")
        out.append(ev)
        if "max_events" in caps and len(out) > int(caps["max_events"]):
            raise ValueError(f"segment too many events {path}: max_events={caps['max_events']}")
    if not out:
        raise ValueError(f"empty segment: {path}")
    return out

def validate_segment(path: Path, meta: dict):
    # Caps are enforced before full validation where possible.
    if "max_bytes" in meta:
        sz = path.stat().st_size
        if sz > int(meta["max_bytes"]):
            raise ValueError(f"segment too large: bytes={sz} max_bytes={meta['max_bytes']}")

    caps = {k: meta[k] for k in ("max_events", "max_line_len", "max_payload_b64_len") if k in meta}
    evs = load_events(path, caps)
    from_seq = int(meta["from_seq"])
    from_hash = meta["from_hash"]
    if evs[0]["seq"] != from_seq + 1:
        raise ValueError("segment start seq mismatch")
    if evs[0]["prev"] != from_hash:
        raise ValueError("segment start prev mismatch")

    if meta.get("require_start_checkpoint", False) and evs[0]["type"] != "Checkpoint":
        raise ValueError("segment must start with Checkpoint")
    if meta.get("require_end_checkpoint", False) and evs[-1]["type"] != "Checkpoint":
        raise ValueError("segment must end with Checkpoint")

    # Chain continuity inside the segment
    for i in range(1, len(evs)):
        if evs[i]["seq"] != evs[i-1]["seq"] + 1:
            raise ValueError("segment seq not contiguous")
        if evs[i]["prev"] != evs[i-1]["hash"]:
            raise ValueError("segment prev chain broken")

def meta_for(seg: Path) -> dict:
    meta_path = seg.with_suffix(".meta.json")
    if not meta_path.exists():
        raise ValueError(f"missing meta for segment: {seg}")
    meta = json.loads(meta_path.read_text())
    required = {"from_seq", "from_hash"}
    if not isinstance(meta, dict) or not required <= set(meta.keys()):
        raise ValueError(f"invalid meta schema: {meta_path}")
    return meta

if seg_accept.exists():
    for seg in sorted(seg_accept.glob("*.ndjson")):
        validate_segment(seg, meta_for(seg))
        print(f"ok segment window {seg}")

seg_fork = seg_root / "fork"
if seg_fork.exists():
    for seg in sorted(seg_fork.glob("*.ndjson")):
        # Fork fixtures are must-accept segments by themselves.
        validate_segment(seg, meta_for(seg))
        print(f"ok fork segment {seg}")

    # Selection record fixtures for fork candidates.
    sel_root = seg_fork / "selections"
    sel_accept = sel_root / "accept"
    sel_bad = sel_root / "bad"

    def segment_digest(path: Path) -> str:
        return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()

    def terminal_hash_from_segment(path: Path) -> str:
        # last non-empty line's "hash"
        for line in reversed(path.read_text().splitlines()):
            if line.strip():
                return json.loads(line)["hash"]
        raise ValueError("empty segment")

    def validate_selection(sel_path: Path, seg_path: Path):
        sel = json.loads(sel_path.read_text())
        required = {"anchor_hash", "terminal_hash", "policy", "actor", "segment_digest"}
        if not isinstance(sel, dict) or set(sel.keys()) != required:
            raise ValueError("selection schema mismatch")
        for k in required:
            if not isinstance(sel[k], str):
                raise ValueError("selection schema mismatch")
        allowed_policies = {"manual", "majority_peer", "stake_weighted"}
        if sel["policy"] not in allowed_policies:
            raise ValueError("selection policy invalid")
        if not sel["anchor_hash"].startswith("sha256:") or not sel["terminal_hash"].startswith("sha256:") or not sel["segment_digest"].startswith("sha256:"):
            raise ValueError("selection schema mismatch")
        if sel["terminal_hash"] != terminal_hash_from_segment(seg_path):
            raise ValueError("selection terminal mismatch")
        if sel["segment_digest"] != segment_digest(seg_path):
            raise ValueError("selection digest mismatch")

    if sel_accept.exists():
        for p in sorted(sel_accept.glob("*.selection.json")):
            base = p.name.replace(".selection.json", "")
            seg_path = seg_fork / f"{base}.ndjson"
            if not seg_path.exists():
                raise SystemExit(f"missing fork segment for selection: {p}")
            validate_selection(p, seg_path)
            print(f"ok fork selection {p}")

    if sel_bad.exists():
        for p in sorted(sel_bad.glob("*.selection.json")):
            # Convention: branch_<name>.*.selection.json refers to branch_<name>.ndjson
            base = p.name.split(".", 1)[0]
            seg_path = seg_fork / f"{base}.ndjson"
            try:
                validate_selection(p, seg_path)
            except Exception:
                print(f"ok must-reject (selection invalid) {p}")
            else:
                raise SystemExit(f"expected selection rejection but validated: {p}")

if seg_bad.exists():
    for seg in sorted(seg_bad.glob("*.ndjson")):
        try:
            validate_segment(seg, meta_for(seg))
        except Exception:
            print(f"ok must-reject (segment invalid) {seg}")
        else:
            raise SystemExit(f"expected segment rejection but validated: {seg}")
PY

# Manifest CRC validation (if crc present)
python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["ROOT"])
manifests_dir = root / "fixtures" / "manifests"
manifests_bad_dir = manifests_dir / "bad"

ALLOWED_KEYS = {"gen", "snapshot", "wal", "crc"}
REQUIRED_KEYS = {"gen", "snapshot", "wal"}

def crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xEDB88320
            else:
                crc >>= 1
    return crc ^ 0xFFFFFFFF

def parse_manifest(path: Path):
    raw_lines = [l for l in path.read_text().splitlines() if l.strip() and not l.lstrip().startswith("#")]
    kv = {}
    payload_lines = []
    for line in raw_lines:
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip()
        kv[k] = v
        if k != "crc":
            payload_lines.append(f"{k}={v}")
    payload = "\n".join(payload_lines) + "\n"
    return kv, payload

for path in manifests_dir.glob("*.txt"):
    kv, payload = parse_manifest(path)
    keys = set(kv.keys())
    unknown = sorted(keys - ALLOWED_KEYS)
    if unknown:
        raise SystemExit(f"manifest schema mismatch {path}: unknown_keys={unknown}")
    if not REQUIRED_KEYS <= keys:
        raise SystemExit(f"manifest missing fields: {path}")
    if "crc" in kv:
        want = int(kv["crc"])
        got = crc32(payload.encode())
        if want != got:
            raise SystemExit(f"manifest crc mismatch {path}: expected {want} got {got}")
    print(f"ok manifest {path}")

for path in manifests_bad_dir.glob("*.txt"):
    kv, payload = parse_manifest(path)
    keys = set(kv.keys())
    unknown = sorted(keys - ALLOWED_KEYS)
    if unknown:
        print(f"ok must-reject (unknown keys) {path}")
        continue
    if not REQUIRED_KEYS <= keys:
        print(f"ok must-reject (missing required keys) {path}")
        continue
    if "crc" in kv:
        want = int(kv["crc"])
        got = crc32(payload.encode())
        if want == got:
            raise SystemExit(f"expected crc mismatch but validated: {path}")
        print(f"ok must-reject (crc mismatch detected) {path}")
        continue
    # If it's in the must-reject corpus, it must fail for a structural reason (unknown/missing)
    # or CRC mismatch (if CRC is present). A manifest missing CRC is not invalid by itself.
    raise SystemExit(f"bad manifest did not violate structure or crc: {path}")
PY

# Seam envelope validation (Producer boundary; fail-closed)
python3 - <<'PY'
import json
import os
import re
from pathlib import Path

root = Path(os.environ["ROOT"])
env_root = root / "fixtures" / "envelopes"
env_accept = env_root / "accept"
env_bad = env_root / "bad"

ENVELOPE_KEYS = {"namespace", "authority", "meta", "payload"}
AUTH_KEYS = {"kind", "basis"}
META_KEYS = {"writer", "epoch", "gen"}

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
NS_RE = re.compile(r"^ulp\.trace\.[a-z0-9_]+(?:\.[a-z0-9_]+)*\.v[0-9]+$")

MAX_PAYLOAD_BYTES = 1024  # constitutional cap for this compat fixture corpus
MAX_LINE_BYTES = 2048

def canonical_json(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)

def validate_payload(payload: dict, *, path: Path, idx: int) -> None:
    if not isinstance(payload, dict) or "op" not in payload or not isinstance(payload["op"], str):
        raise ValueError(f"payload schema mismatch {path}:{idx}")

    op = payload["op"]
    if op == "create_entity":
        req = {"op", "eid", "etype", "owner_mask"}
        if set(payload.keys()) != req:
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        if not isinstance(payload["eid"], int):
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        if not isinstance(payload["etype"], str):
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        if not isinstance(payload["owner_mask"], int):
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        return

    if op == "set_component_string":
        req = {"op", "eid", "key", "value"}
        if set(payload.keys()) != req:
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        if not isinstance(payload["eid"], int) or not isinstance(payload["key"], str) or not isinstance(payload["value"], str):
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        if not KEY_RE.match(payload["key"]):
            raise ValueError(f"invalid component key {path}:{idx}")
        return

    if op == "remove_component":
        req = {"op", "eid", "key"}
        if set(payload.keys()) != req:
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        if not isinstance(payload["eid"], int) or not isinstance(payload["key"], str):
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        if not KEY_RE.match(payload["key"]):
            raise ValueError(f"invalid component key {path}:{idx}")
        return

    if op == "delete_entity":
        req = {"op", "eid"}
        if set(payload.keys()) != req or not isinstance(payload["eid"], int):
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        return

    if op == "advance_tick":
        req = {"op", "delta"}
        if set(payload.keys()) != req or not isinstance(payload["delta"], int):
            raise ValueError(f"payload schema mismatch {path}:{idx}")
        return

    raise ValueError(f"unknown op {path}:{idx}")

def validate_file(path: Path) -> None:
    for idx, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        if len(line.encode("utf-8")) > MAX_LINE_BYTES:
            raise ValueError(f"envelope line too long {path}:{idx}")
        env = json.loads(line)
        if not isinstance(env, dict) or set(env.keys()) != ENVELOPE_KEYS:
            raise ValueError(f"envelope schema mismatch {path}:{idx}")

        if not isinstance(env["namespace"], str):
            raise ValueError(f"envelope schema mismatch {path}:{idx}")
        if not NS_RE.match(env["namespace"]):
            raise ValueError(f"namespace invalid {path}:{idx}")
        producer = env["namespace"].split(".")[2]
        key_prefix = producer + "__"

        auth = env["authority"]
        if not isinstance(auth, dict) or set(auth.keys()) != AUTH_KEYS:
            raise ValueError(f"envelope schema mismatch {path}:{idx}")
        if auth["kind"] != "direct":
            raise ValueError(f"authority kind mismatch {path}:{idx}")
        if not isinstance(auth["basis"], list):
            raise ValueError(f"envelope schema mismatch {path}:{idx}")

        meta = env["meta"]
        if not isinstance(meta, dict) or set(meta.keys()) != META_KEYS:
            raise ValueError(f"envelope schema mismatch {path}:{idx}")
        if not isinstance(meta["writer"], str) or not isinstance(meta["epoch"], int) or not isinstance(meta["gen"], int):
            raise ValueError(f"envelope schema mismatch {path}:{idx}")

        payload = env["payload"]
        pb = canonical_json(payload).encode("utf-8")
        if len(pb) > MAX_PAYLOAD_BYTES:
            raise ValueError(f"payload too large {path}:{idx}")
        validate_payload(payload, path=path, idx=idx)

        # Component-key producer qualification (v0 containment against semantic collisions).
        if isinstance(payload, dict) and payload.get("op") in ("set_component_string", "remove_component"):
            k = payload.get("key", "")
            if not isinstance(k, str) or not k.startswith(key_prefix):
                raise ValueError(f"component key missing/wrong producer prefix {path}:{idx}")

if env_accept.exists():
    for p in sorted(env_accept.glob("*.ndjson")):
        validate_file(p)
        print(f"ok seam envelopes {p}")

if env_bad.exists():
    for p in sorted(env_bad.glob("*.ndjson")):
        try:
            validate_file(p)
        except Exception:
            print(f"ok must-reject (envelope invalid) {p}")
        else:
            raise SystemExit(f"expected envelope rejection but validated: {p}")
PY

echo "ulp-compat-suite: basic checks passed"

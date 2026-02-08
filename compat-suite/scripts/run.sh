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

echo "ulp-compat-suite: basic checks passed"

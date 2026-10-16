#!/usr/bin/env bash
# Measures POST /records latency, cold and warm separately.
# 1. A burst of BURST concurrent signed requests (fresh execution environments right after a deploy are cold).
# 2. SEQ sequential signed requests (served by warm environments).
# Each trace is classified from the Lambda logs: the first invocation in a log stream carries "Init Duration".
# Client latency = curl time_total from the test machine to the API in eu-west-1, signed request included.
# Server figures come from the Lambda REPORT lines (Init Duration, Duration).
# Run from infra/stack with management account credentials.
set -uo pipefail
BURST=${BURST:-10}
SEQ=${SEQ:-30}
API=$(terraform output -raw api_endpoint)
eval "$(aws configure export-credentials --format env)"
OUT=$(mktemp -d)
start_ms=$(( $(date +%s) * 1000 - 5000 ))

post() { # phase index
  curl -s --aws-sigv4 "aws:amz:eu-west-1:execute-api" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
    ${AWS_SESSION_TOKEN:+-H "x-amz-security-token: $AWS_SESSION_TOKEN"} \
    -X POST "${API}records" -H 'content-type: application/json' \
    -d '{"tenant_id":"synthetic-eu-01","payload":{"note":"latency sample"}}' \
    -o "$OUT/$1-$2.json" -w '%{http_code} %{time_total}\n' > "$OUT/$1-$2.meta"
}
export -f post; export API OUT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

for i in $(seq 1 "$BURST"); do post burst "$i" & done; wait
for i in $(seq 1 "$SEQ"); do post seq "$i"; done
sleep 20
aws logs filter-log-events --region eu-west-1 --log-group-name /aws/lambda/data-residency-router \
  --start-time "$start_ms" --output json > "$OUT/logs.json"

python3 - "$OUT" <<'PY'
import json, re, sys, glob, statistics, os
out = sys.argv[1]
samples = {}
for meta in glob.glob(f"{out}/*.meta"):
    name = os.path.basename(meta)[:-5]
    code, total = open(meta).read().split()
    body = json.load(open(f"{out}/{name}.json"))
    samples[body.get("trace_id")] = {"phase": name.split("-")[0], "http": int(code), "client_ms": float(total) * 1000, "outcome": body.get("outcome"), "storage_region": body.get("storage_region")}

events = json.load(open(f"{out}/logs.json"))["events"]
streams = {}
for e in events:
    streams.setdefault(e["logStreamName"], []).append(e)
for evs in streams.values():
    evs.sort(key=lambda e: (e["timestamp"], e["eventId"]))
    pending = None
    for e in evs:
        msg = e["message"]
        if msg.startswith('{"type":"otel-span"'):
            span = json.loads(msg)
            if span["name"] == "pii.write":
                pending = span["trace_id"]
        elif msg.startswith("REPORT") and pending in samples:
            s = samples[pending]
            s["cold"] = "Init Duration" in msg
            s["duration_ms"] = float(re.search(r"\tDuration: ([\d.]+) ms", msg).group(1))
            m = re.search(r"Init Duration: ([\d.]+) ms", msg)
            s["init_ms"] = float(m.group(1)) if m else None
            pending = None

def stats(values):
    v = sorted(values)
    return f"n={len(v):2d}  min={v[0]:7.1f}  median={statistics.median(v):7.1f}  max={v[-1]:7.1f}" if v else "n= 0"

ok = [s for s in samples.values() if s["http"] == 201 and "cold" in s]
cold = [s for s in ok if s["cold"]]
warm = [s for s in ok if not s["cold"]]
print(f"Requests: {len(samples)} sent ({sum(1 for s in samples.values() if s['phase']=='burst')} concurrent burst, {sum(1 for s in samples.values() if s['phase']=='seq')} sequential), "
      f"{sum(1 for s in samples.values() if s['http']==201)} returned 201, {len(ok)} matched to a REPORT line")
print(f"All stored in: {sorted({s['storage_region'] for s in ok})}")
print("Values in milliseconds.")
print(f"COLD client latency (end to end, signed request from the test machine): {stats([s['client_ms'] for s in cold])}")
print(f"COLD Lambda Init Duration (runtime start + module init):              {stats([s['init_ms'] for s in cold])}")
print(f"COLD Lambda Duration (handler, incl. first AssumeRole):                 {stats([s['duration_ms'] for s in cold])}")
print(f"WARM client latency (end to end, signed request from the test machine): {stats([s['client_ms'] for s in warm])}")
print(f"WARM Lambda Duration (handler, cached writer credentials):            {stats([s['duration_ms'] for s in warm])}")
PY

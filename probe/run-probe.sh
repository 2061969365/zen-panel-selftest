#!/usr/bin/env bash
set -uo pipefail

PAYLOAD='{"model":"deepseek-v4.1-flash-free","messages":[{"role":"user","content":"请只回复：ok"}],"max_tokens":32,"stream":true}'
MODEL='deepseek-v4.1-flash-free'
KEY='test-key'

ip=$(curl -s --max-time 10 https://api.ipify.org || true)
echo "=== shard=${SHARD:-?} runner_ip=${ip:-?} time=$(date -u +%FT%TZ) ==="
curl -s --max-time 10 "https://ipwho.is/${ip}" | head -c 300
echo

wait_live() {
  local base="$1" tries="${2:-30}" i
  for i in $(seq 1 "$tries"); do
    if curl -sf --max-time 5 "$base/healthz" >/dev/null 2>&1 || curl -sf --max-time 5 "$base/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_models() {
  local base="$1" tries="${2:-30}" i
  for i in $(seq 1 "$tries"); do
    if curl -s --max-time 10 -H "Authorization: Bearer $KEY" "$base/v1/models" | grep -q "$MODEL"; then
      echo "models ready after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "models not ready; /v1/models head:"
  curl -s --max-time 10 -H "Authorization: Bearer $KEY" "$base/v1/models" | head -c 300
  echo
  return 1
}

start_o2a() {
  local name="$1" port="$2" cfg="$3" dir="/tmp/o2a-$1" pid
  mkdir -p "$dir"
  cp "$cfg" "$dir/config.json"
  /tmp/o2a/opencode2api -config "$dir/config.json" > "$dir/gw.log" 2>&1 &
  pid=$!
  echo "$pid" > "$dir/pid"
  for i in $(seq 1 60); do
    if curl -sf --max-time 5 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[$name] exited early:"; tail -30 "$dir/gw.log"; return 1
    fi
    sleep 1
  done
  echo "[$name] healthz timeout:"; tail -30 "$dir/gw.log"; return 1
}

probe() {
  local name="$1" url="$2" i code
  for i in 1 2 3; do
    code=$(curl -sS -o "/tmp/$name.$i.body" -D "/tmp/$name.$i.hdr" -w '%{http_code} %{time_total}' \
      --max-time 120 -H 'Content-Type: application/json' -H "Authorization: Bearer $KEY" \
      --data-binary "$PAYLOAD" "$url" 2>/dev/null || echo '000 0')
    echo "[$name #$i] $code | $(head -c 240 "/tmp/$name.$i.body" 2>/dev/null | tr '\n' ' ')"
    grep -iE '^(retry-after|x-ratelimit|cf-ray):' "/tmp/$name.$i.hdr" 2>/dev/null | sed 's/^/    /'
  done
}

# ---------- 1) our gateway binary, same runner IP ----------
echo "=== our gateway v0.9.5 (local process, same runner IP) ==="
PORT=18090 ZEN_TLS=bun DIRECT_SIDECAR=off ZEN_RUN_ID="probe-${SHARD:-0}" LOG_FILE=/tmp/ours.log \
  ./bin/zen-direct >/tmp/ours.stdout 2>&1 &
OURS_PID=$!
if wait_live http://127.0.0.1:18090 30; then
  curl -s --max-time 10 http://127.0.0.1:18090/health | head -c 320
  echo
  probe ours http://127.0.0.1:18090/v1/chat/completions
else
  echo "[ours] /health timeout"; tail -20 /tmp/ours.stdout
fi
kill "$OURS_PID" 2>/dev/null || true

# ---------- 2) opencode2api anonymous, direct ----------
echo "=== opencode2api v1.4.5 anonymous (direct) ==="
if start_o2a direct 18080 probe/config.direct.json; then
  wait_models http://127.0.0.1:18080 30 || true
  probe o2a-direct http://127.0.0.1:18080/v1/chat/completions
  echo "[direct healthz] $(curl -s --max-time 5 http://127.0.0.1:18080/healthz | head -c 500)"
fi
kill "$(cat /tmp/o2a-direct/pid 2>/dev/null)" 2>/dev/null || true

# ---------- 3) opencode2api anonymous + WARP ipv6 ----------
echo "=== opencode2api v1.4.5 anonymous + WARP (ipv6, pool 4) ==="
if start_o2a warp 18082 probe/config.warp.json; then
  wait_models http://127.0.0.1:18082 60 || true
  probe o2a-warp http://127.0.0.1:18082/v1/chat/completions
  echo "[warp healthz] $(curl -s --max-time 5 http://127.0.0.1:18082/healthz | head -c 700)"
else
  echo "[warp] startup failed (UDP 2408 blocked?)"
fi
kill "$(cat /tmp/o2a-warp/pid 2>/dev/null)" 2>/dev/null || true

# ---------- 4) official opencode CLI ----------
echo "=== official opencode CLI (@opencode/cli 2.2.0) ==="
if npm i -g @opencode/cli@2.2.0 >/tmp/npm.log 2>&1; then
  echo "installed @opencode/cli@2.2.0"
else
  tail -5 /tmp/npm.log || true
fi
mkdir -p /tmp/oc/config /tmp/oc/data
XDG_CONFIG_HOME=/tmp/oc/config XDG_DATA_HOME=/tmp/oc/data timeout 150 \
  opencode run --model "opencode/$MODEL" "请只回复：ok" 2>&1 | tail -25
echo "cli_exit=${PIPESTATUS[0]}"

# ---------- 5) deployed three domains, same runner IP ----------
echo "=== deployed domains (zen / zen1 / zen2) ==="
for host in zen.uflash.ccwu.cc zen1.uflash.ccwu.cc zen2.uflash.ccwu.cc; do
  code=$(curl -sS -o "/tmp/dom-$host.body" -D "/tmp/dom-$host.hdr" -w '%{http_code} %{time_total}' \
    --max-time 90 -H 'Content-Type: application/json' -H 'Authorization: Bearer public' \
    -H 'User-Agent: opencode/2.0.29' --data-binary "$PAYLOAD" "https://$host/v1/chat/completions" 2>/dev/null || echo '000 0')
  echo "[$host] $code | $(head -c 180 "/tmp/dom-$host.body" 2>/dev/null | tr '\n' ' ')"
  grep -iE '^(retry-after|cf-ray):' "/tmp/dom-$host.hdr" 2>/dev/null | sed 's/^/    /'
done

echo "=== shard=${SHARD:-?} done ==="

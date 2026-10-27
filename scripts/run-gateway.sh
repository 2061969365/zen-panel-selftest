#!/usr/bin/env bash
# 一台 runner 的生命周期：
#   起网关 -> 起隧道 -> 真 chat 探活（必须 200）-> 周期探活 + 日志盯 429 -> 到点/中招就交班。
# 交班由 workflow 最后一步 dispatch 下一次运行（新 runner = 新 IP）。
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
RUN="$ROOT/run"
BIN="$ROOT/bin"
mkdir -p "$RUN"

GW_LOG="$RUN/gateway.log"
GW_STDIO="$RUN/gateway.stdio.log"
CF_LOG="$RUN/cloudflared.log"
FLAG="$RUN/rotate.flag"
REASON="$RUN/rotate.reason"

PORT="${PORT:-8081}"
PROBE_MODEL="${PROBE_MODEL:-deepseek-v4.1-flash-free}"
PROBE_INTERVAL="${PROBE_INTERVAL_SEC:-300}"
MAX_RUN="${MAX_RUN_SEC:-13500}"
PROBE_PAYLOAD="$(printf '{"model":"%s","messages":[{"role":"user","content":"ping"}],"max_tokens":8,"stream":false}' "$PROBE_MODEL")"

GW_PID=""
CF_PID=""
WATCH_PID=""
PUBLIC_URL=""
ok_count=0
fail_count=0
limit_count=0

say()  { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
note() { say "NOTE $*";  echo "::notice::$*"; }
warn() { say "WARN $*";  echo "::warning::$*"; }

stop_proc() {
  local pid="$1" name="$2" i
  if [ -z "$pid" ]; then return 0; fi
  if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
  kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 15); do
    if ! kill -0 "$pid" 2>/dev/null; then
      say "$name 已退出（${i}s）"
      return 0
    fi
    sleep 1
  done
  warn "$name 15s 没退，SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  trap - EXIT
  # 顺序有讲究：先断隧道（告诉 Cloudflare 这个 connector 走了），再停网关，
  # 免得下一个 run 接同一个命名隧道时还被路由到这个已经空掉的 connector。
  stop_proc "$CF_PID" cloudflared
  stop_proc "$GW_PID" gateway
  stop_proc "$WATCH_PID" log-watcher
  wait 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT
# 被平台 SIGTERM/SIGINT 收走时也让 EXIT 清理跑起来（软超时、手动取消）
trap 'exit 143' TERM
trap 'exit 130' INT

finish_stats() {
  printf '%dh%02dm%02ds\n' $((SECONDS / 3600)) $(((SECONDS % 3600) / 60)) $((SECONDS % 60)) > "$RUN/uptime.txt"
  printf 'ok=%d limit=%d fail=%d\n' "$ok_count" "$limit_count" "$fail_count" > "$RUN/probe-stats.txt"
}

# 交班：写原因 -> 记统计 -> 退出。workflow 的收尾步骤负责 dispatch 下一个 run。
# 第二个参数 fast：429 是确定结论，直接走，不等防抖；只有「原因不明」的失败才守 180s。
rotate() {
  local reason="$1" fast="${2:-}" floor=180
  if [ "$fast" = "fast" ]; then floor=0; fi
  printf '%s\n' "$reason" > "$FLAG"
  note "交班：$reason"
  finish_stats
  # 冷启动就失败时别狂换 runner（每次换都烧一次 Actions 调度）
  if [ "$SECONDS" -lt "$floor" ]; then
    say "起步过快，等 $((floor - SECONDS))s 再交班"
    sleep $((floor - SECONDS))
  fi
  exit 0
}

start_gateway() {
  PORT="$PORT" \
  LOG_FILE="$GW_LOG" \
  SHIM_SESSION_FILE="$RUN/shim_sessions.json" \
  DIRECT_DIAG=1 \
  DIRECT_DEBUG=0 \
  DIRECT_CONCURRENCY=16 \
  DIRECT_FREELIMIT_COOLDOWN=0 \
  ZEN_TLS=bun \
  DIRECT_SIDECAR=off \
  "$BIN/zen-direct" >>"$GW_STDIO" 2>&1 &
  GW_PID=$!
  say "gateway pid=$GW_PID port=$PORT model=$PROBE_MODEL"
}

http_code() {
  local url="$1" t="${2:-5}" c
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$t" "$url" 2>/dev/null || true)"
  printf '%s' "${c:-000}"
}

wait_local_health() {
  local deadline=$((SECONDS + ${1:-120}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(http_code "http://127.0.0.1:$PORT/health" 5)" = "200" ]; then return 0; fi
    if ! kill -0 "$GW_PID" 2>/dev/null; then return 1; fi
    sleep 2
  done
  return 1
}

start_tunnel() {
  : > "$CF_LOG"
  if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
    "$BIN/cloudflared" tunnel --no-autoupdate --loglevel info run --token "$CF_TUNNEL_TOKEN" >>"$CF_LOG" 2>&1 &
    CF_PID=$!
    if [ -n "${ZEN_PUBLIC_HOST:-}" ]; then PUBLIC_URL="https://$ZEN_PUBLIC_HOST"; fi
    say "named tunnel pid=$CF_PID host=${PUBLIC_URL:-<未设置 ZEN_PUBLIC_HOST>}"
    if [ -z "$PUBLIC_URL" ]; then
      # 没配 ZEN_PUBLIC_HOST 时，尽量从 cloudflared 拉到的远端配置里抠出域名
      local j
      for j in $(seq 1 10); do
        PUBLIC_URL="$(grep -oE '"hostname":"[^"]+"' "$CF_LOG" 2>/dev/null | head -n1 | sed -E 's/.*:"([^"]+)"/\1/' || true)"
        if [ -n "$PUBLIC_URL" ]; then PUBLIC_URL="https://$PUBLIC_URL"; break; fi
        if ! kill -0 "$CF_PID" 2>/dev/null; then break; fi
        sleep 2
      done
      if [ -n "$PUBLIC_URL" ]; then
        note "从隧道配置里读到域名：$PUBLIC_URL"
      else
        warn "没设 ZEN_PUBLIC_HOST，也没从隧道配置里读到域名，公网自检将跳过"
      fi
    fi
  else
    warn "没有 CF_TUNNEL_TOKEN，用临时隧道（URL 每次都会变）"
    "$BIN/cloudflared" tunnel --no-autoupdate --loglevel info --url "http://127.0.0.1:$PORT" >>"$CF_LOG" 2>&1 &
    CF_PID=$!
    local i
    for i in $(seq 1 60); do
      PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -n1 || true)"
      if [ -n "$PUBLIC_URL" ]; then break; fi
      if ! kill -0 "$CF_PID" 2>/dev/null; then warn "cloudflared 提前退出"; break; fi
      sleep 2
    done
  fi
  if [ -n "$PUBLIC_URL" ]; then printf '%s\n' "$PUBLIC_URL" > "$RUN/public-url.txt"; fi
}

wait_public_health() {
  if [ -z "$PUBLIC_URL" ]; then return 0; fi
  local deadline=$((SECONDS + 180))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(http_code "$PUBLIC_URL/health" 10)" = "200" ]; then
      note "公网已通：$PUBLIC_URL"
      return 0
    fi
    sleep 3
  done
  return 1
}

watch_logs() {
  (
    tail -n 0 -F "$GW_LOG" 2>/dev/null \
      | grep --line-buffered -E 'FreeUsageLimitError|free-usage 429 .*turns=' \
      | while IFS= read -r line; do
          say "LOG-429 $line"
          printf '%s\n' "$line" > "$REASON"
        done
  ) &
  WATCH_PID=$!
}

probe_once() {
  local base="${1:-http://127.0.0.1:$PORT}"
  local max="${2:-90}"
  local out="$RUN/probe.json"
  PROBE_CODE="$(curl -sS -o "$out" -w '%{http_code}' --max-time "$max" \
    -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer public' \
    -H 'User-Agent: opencode/2.0.29' \
    --data-binary "$PROBE_PAYLOAD" \
    --dump-header "$RUN/probe.hdr" \
    "$base/v1/chat/completions" 2>>"$RUN/probe.err" || echo 000)"
  PROBE_BODY="$(head -c 300 "$out" 2>/dev/null || true)"
  PROBE_BODY="${PROBE_BODY//$'\n'/ }"
}

# ok / limit / fail
verdict() {
  if [ "$PROBE_CODE" = "200" ]; then printf 'ok'; return; fi
  if [ "$PROBE_CODE" = "429" ]; then printf 'limit'; return; fi
  case "$PROBE_BODY" in
    *FreeUsageLimitError*) printf 'limit'; return ;;
  esac
  printf 'fail'
}

say "run start pid=$$ max=${MAX_RUN}s probe_interval=${PROBE_INTERVAL}s"

start_gateway
if ! wait_local_health 120; then
  tail -n 40 "$GW_LOG" 2>/dev/null || true
  rotate "本地 /health 120s 没起来"
fi

watch_logs
start_tunnel
if ! wait_public_health; then
  tail -n 30 "$CF_LOG" 2>/dev/null || true
  rotate "隧道 180s 没打通 ${PUBLIC_URL:-<无 URL>}"
fi

curl -sS --max-time 20 "http://127.0.0.1:$PORT/ip" -o "$RUN/ip.json" 2>/dev/null || true
EGRESS="$(sed -n 's/.*"ip":"\([^"]*\)".*/\1/p' "$RUN/ip.json" 2>/dev/null || true)"
if [ -n "$EGRESS" ]; then printf '%s\n' "$EGRESS" > "$RUN/egress-ip.txt"; fi
note "出口 IP：${EGRESS:-未知}"

# 起手必须打一条真 chat 拿到 200，否则这个 IP 不可用。
# 有公网地址就先走公网，一次同时验证「隧道」和「IP 额度」。
BOOT_BASE="http://127.0.0.1:$PORT"
boot_ok=0
if [ -n "$PUBLIC_URL" ]; then
  note "起手探测走公网：$PUBLIC_URL"
  probe_once "$PUBLIC_URL"
  boot_v="$(verdict)"
  say "boot probe (public) -> $PROBE_CODE ($boot_v)"
  case "$boot_v" in
    ok) boot_ok=1 ;;
    limit) rotate "起手公网探测 429：${PROBE_BODY:0:200}" fast ;;
    *)
      if grep -qi 'cf-mitigated' "$RUN/probe.hdr" 2>/dev/null; then
        warn "Cloudflare 把探针当机器人挑战了（cf-mitigated），改走本地判定"
      else
        warn "公网探测 $PROBE_CODE，本地再确认一次"
      fi
      ;;
  esac
else
  say "起手探测走本地（没有公网地址）"
fi

attempt=0
v="fail"
if [ "$boot_ok" = "0" ]; then
  while [ "$attempt" -lt 6 ]; do
    attempt=$((attempt + 1))
    probe_once "$BOOT_BASE"
    v="$(verdict)"
    say "boot probe #$attempt -> $PROBE_CODE ($v)"
    case "$v" in
      ok) boot_ok=1; break ;;
      limit) rotate "起手探测 429：${PROBE_BODY:0:200}" fast ;;
      *) sleep 20 ;;
    esac
  done
fi
if [ "$boot_ok" = "0" ]; then
  rotate "起手探测 6 次没拿到 200（最后一次 $PROBE_CODE）"
fi
ok_count=$((ok_count + 1))
note "IP 可用，开始服务"

next_probe=$((SECONDS + PROBE_INTERVAL))
gw_restarts=0
cf_restarts=0

while :; do
  sleep 15

  if [ -s "$REASON" ]; then
    rotate "日志命中 429：$(head -c 200 "$REASON")" fast
  fi

  if [ "$SECONDS" -ge "$MAX_RUN" ]; then
    rotate "到点交班（已跑 ${SECONDS}s）"
  fi

  if ! kill -0 "$GW_PID" 2>/dev/null; then
    gw_restarts=$((gw_restarts + 1))
    warn "gateway 进程没了（第 $gw_restarts 次）"
    if [ "$gw_restarts" -gt 3 ]; then rotate "gateway 反复退出"; fi
    start_gateway
    wait_local_health 120 || rotate "gateway 重启后 /health 不通"
  fi

  if ! kill -0 "$CF_PID" 2>/dev/null; then
    cf_restarts=$((cf_restarts + 1))
    warn "cloudflared 进程没了（第 $cf_restarts 次），重连"
    if [ "$cf_restarts" -gt 5 ]; then rotate "cloudflared 反复退出"; fi
    start_tunnel
    wait_public_health || warn "重连后公网还没通，继续等"
  fi

  if [ "$SECONDS" -ge "$next_probe" ]; then
    probe_once
    v="$(verdict)"
    case "$v" in
      ok)
        ok_count=$((ok_count + 1))
        fail_count=0
        ;;
      limit)
        limit_count=$((limit_count + 1))
        rotate "周期探测 429：${PROBE_BODY:0:200}" fast
        ;;
      *)
        fail_count=$((fail_count + 1))
        warn "周期探测 $PROBE_CODE（连续失败 $fail_count/3）"
        ;;
    esac
    if [ "$fail_count" -ge 3 ]; then
      rotate "连续 3 次探测非 200（最后 $PROBE_CODE）"
    fi
    next_probe=$((SECONDS + PROBE_INTERVAL))
    finish_stats
  fi
done

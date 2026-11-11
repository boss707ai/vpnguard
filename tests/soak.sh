#!/bin/bash
# Обкатка vpnguard под нагрузкой — условия, в которых ошибки сетевого фильтра проявляются чаще всего: много
# сокетов создаётся и закрывается одновременно, отказы через lo0 (входной поток ядра), multicast
# (mDNS), TCP через туннель и напрямую в российские сети, по желанию — контейнер Docker с сетью.
# Root не нужен. Запуск:
#   bash "/Library/Application Support/VPNGuard/tests/soak.sh" [часов, по умолчанию 24] [--docker]
# Журнал: ~/Library/Logs/vpnguard-soak.log. Остановить раньше — Ctrl-C (всё запущенное уберёт за собой).
# Доказать, что ошибок в ядре нет, обкатка не может; она проверяет, что под той же нагрузкой сеть
# и сторож живы часами.
set -u
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin   # docker — из brew или Docker.app
BASE="/Library/Application Support/VPNGuard"
HOURS=24; DOCKER=0
for a in "$@"; do
  case $a in
    --docker) DOCKER=1 ;;
    *) [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= 72 )) || { echo "часов: от 1 до 72"; exit 1; }; HOURS=$a ;;
  esac
done
[ "$(id -u)" != 0 ] || { echo "Запускай от своего пользователя, без sudo."; exit 1; }
LOGF="$HOME/Library/Logs/vpnguard-soak.log"
END=$(( $(date +%s) + HOURS * 3600 ))
PIDS=""; CONTAINER=""

say() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGF"; }
st()  { sed -n "s/^$1=//p" "$BASE/status" 2>/dev/null | head -1; }

cleanup() {
  local p
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  for p in $PIDS; do wait "$p" 2>/dev/null; done
  if [ -n "$CONTAINER" ]; then docker rm -f "$CONTAINER" >/dev/null 2>&1; say "контейнер $CONTAINER убран"; fi
  say "обкатка остановлена"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

start() { "$@" & PIDS="$PIDS $!"; }

# 1. TCP: через туннель (зарубежное) и напрямую (российское), 4 потока
tcp_worker() {
  local urls=(https://ya.ru https://vk.com https://api.anthropic.com https://www.apple.com https://ipinfo.io/ip) i=$1
  while :; do
    curl -s -o /dev/null --max-time 8 "${urls[$((i % ${#urls[@]}))]}"
    i=$((i + 1)); sleep 0.2
  done
}
# 2. Сокеты: UDP-сокет создать, «подключить», закрыть; TCP к закрытому порту на 127.0.0.1 —
#    отказ приходит через lo0 во входной поток ядра (там и была вторая сторона взаимоблокировки)
socket_churn() {
  while :; do
    { exec 3>/dev/udp/127.0.0.1/9; } 2>/dev/null; exec 3>&- 2>/dev/null
    { exec 4<>/dev/tcp/127.0.0.1/1; } 2>/dev/null; exec 4>&- 2>/dev/null
  done
}
# 3. Multicast: запросы mDNS — ответы устройств сети приходят входящим multicast.
#    dns-sd сам не завершается: при остановке гасим его (wait прерывается сигналом, sleep — нет)
mdns_worker() {
  local d="" s=""
  trap 'kill $d $s 2>/dev/null; exit 0' TERM INT
  while :; do
    dns-sd -B _services._dns-sd._udp local. >/dev/null 2>&1 & d=$!
    sleep 20 & s=$!; wait "$s"
    kill "$d" 2>/dev/null; wait "$d" 2>/dev/null; d=""
  done
}
# 4. DNS: системный (через туннель) и к DNS Karing напрямую
dns_worker() {
  local n=0
  while :; do
    dig +short +time=1 +tries=1 "soak-$RANDOM.example.com" >/dev/null 2>&1
    dig +short +time=1 +tries=1 @8.8.8.8 ya.ru >/dev/null 2>&1
    n=$((n + 1)); sleep 0.5
  done
}

say "== обкатка на $HOURS ч, до $(date -r "$END" '+%Y-%m-%d %H:%M'); журнал: $LOGF"
say "защита: $(st mode) · pf: $(st pf) · правила: $(st rules) · серверы: $(st servers)"
for i in 0 1 2 3; do start tcp_worker "$i"; done
for i in 0 1; do start socket_churn; done
start mdns_worker
start dns_worker
if [ "$DOCKER" = 1 ]; then
  if docker info >/dev/null 2>&1; then
    CONTAINER=vpnguard-soak
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    if docker run -d --rm --name "$CONTAINER" alpine sh -c 'while true; do wget -q -T 8 -O /dev/null http://ya.ru; wget -q -T 8 -O /dev/null https://ipinfo.io/ip; sleep 0.3; done' >/dev/null 2>&1; then
      say "контейнер Docker $CONTAINER запущен (сеть из контейнера)"
    else
      CONTAINER=""; say "контейнер Docker не запустился — продолжаю без него"
    fi
  else
    say "Docker не отвечает (запусти Docker Desktop) — продолжаю без контейнера"
  fi
fi

PROBES=0; SLOW=0; FAILS=0; ALERTS=0; MAXT=0; LAST_FULL=0
while (( $(date +%s) < END )); do
  sleep 10
  now=$(date +%s)
  beat=$(st heartbeat); pf=$(st pf)
  if [ "$pf" = hung ]; then say "ТРЕВОГА: pf не отвечает (сторож: pf=hung) — похоже, зависло ядро"; ALERTS=$((ALERTS + 1)); fi
  if (( now - ${beat:-0} > 30 )); then say "ТРЕВОГА: сторож не обновлял статус $((now - ${beat:-0})) с"; ALERTS=$((ALERTS + 1)); fi
  t=$(curl -s -o /dev/null --max-time 15 -w '%{time_total}' https://ya.ru 2>/dev/null); rc=$?
  PROBES=$((PROBES + 1))
  if [ "$rc" != 0 ]; then FAILS=$((FAILS + 1)); say "проба ya.ru не прошла (curl rc=$rc)"
  else
    ms=$(awk -v t="$t" 'BEGIN { printf "%d", t * 1000 }')
    (( ms > MAXT )) && MAXT=$ms
    (( ms > 5000 )) && { SLOW=$((SLOW + 1)); say "медленно: ya.ru за $ms мс"; }
  fi
  if (( now - LAST_FULL >= 1800 )); then
    LAST_FULL=$now
    say "--- $(st mode)/$(st pf)/$(st rules) · починок $(st repairs) · проб $PROBES, неудач $FAILS, медленных $SLOW, макс $MAXT мс, тревог $ALERTS"
  fi
done
say "== итог: проб $PROBES, неудач $FAILS, медленных $SLOW, макс $MAXT мс, тревог $ALERTS"
[ "$ALERTS" = 0 ]

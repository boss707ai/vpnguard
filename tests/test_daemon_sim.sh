#!/bin/bash
# Симуляция сторожа и CLI без root: pfctl/sysctl/launchctl/id/sudo/dig — заглушки, всё в песочнице.
# Проверяет переходы состояний: старт, починки, пауза, автовозврат, off, запрос on без пароля,
# перезапуск в той же загрузке, новая загрузка; адреса из Karing (таблицы, уведомления, подмена,
# мусор в настройках), зависание pfctl. Запуск: bash tests/test_daemon_sim.sh
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIM=$(mktemp -d "${TMPDIR:-/tmp}/vgsim.XXXXXX")
export SIM
mkdir -p "$SIM/stub" "$SIM/base" "$SIM/dns" "$SIM/home/Library/Group Containers/group.com.nebula.karing"
cp "$DIR/pf/vpnguard.rules" "$SIM/base/"
echo 'dummy srs' > "$SIM/karing-ru.srs"
SRS_SHA=$(shasum -a 256 "$SIM/karing-ru.srs" | awk '{print $1}')
printf '# тест\n# sha256 источника: %s\n2.56.0.0/14\n5.255.255.0/24\n' "$SRS_SHA" > "$SIM/base/ru.cidr"
sed -e "s|^VG_ADDR_TTL=43200|VG_ADDR_TTL=5|" "$DIR/lib/state.sh" > "$SIM/base/state.sh"
sed -e "s|^VG_PROVIDER_RU_SRC=.*|VG_PROVIDER_RU_SRC=\"$SIM/karing-ru.srs\"|" "$DIR/providers/karing/provider.sh" > "$SIM/base/provider.sh"
KCONF="$SIM/home/Library/Group Containers/group.com.nebula.karing/service_core.json"
cp "$DIR/tests/fixtures/karing-service_core.json" "$KCONF"
echo "203.0.113.20" > "$SIM/dns/vpn.example.net"
echo "8.8.8.8 8.8.4.4" > "$SIM/dns/dns.google"
echo 'anchor "com.apple/*" all' > "$SIM/main"
echo 'BOOT-AAAA' > "$SIM/bootid"

# --- заглушки ---
cat > "$SIM/stub/pfctl" <<'EOF'
#!/bin/bash
# «ядро зависло»: вызов не возвращается, пока есть $SIM/hang
while [ -e "$SIM/hang" ]; do sleep 0.2; done
anchor=""; cmd=""; file=""; tok=""; table=""; tcmd=""; dry=0; all="$*"
while [ $# -gt 0 ]; do
  case $1 in
    -a) anchor=$2; shift 2 ;;
    -s) cmd="show_$2"; shift 2 ;;
    -sr|-vsr) cmd=show_rules; shift ;;
    -sA) cmd=show_A; shift ;;
    -nf) dry=1; cmd=load; file=$2; shift 2 ;;
    -f) cmd=load; file=$2; shift 2 ;;
    -F) cmd="flush_$2"; shift 2 ;;
    -E) cmd=enable; shift ;;
    -X) cmd=release; tok=$2; shift 2 ;;
    -d) cmd=disable; shift ;;
    -t) table=$2; shift 2 ;;
    -T) tcmd=$2; shift 2 ;;
    *) shift ;;
  esac
done
echo "$all" >> "$SIM/pfctl.calls"
refs="$SIM/refs"; touch "$refs"
if [ -n "$table" ]; then
  if [ "$tcmd" = show ]; then
    [ -f "$SIM/tables/$table" ] || { echo "pfctl: Table does not exist." >&2; exit 1; }
    sed 's/^/   /' "$SIM/tables/$table"
  fi
  exit 0
fi
case $cmd in
  show_info) if [ -s "$refs" ]; then echo "Status: Enabled for 0 days 00:00:01"; else echo "Status: Disabled"; fi ;;
  show_rules) echo "No ALTQ support in kernel" >&2   # как настоящий pfctl: шум в stderr
              if [ "$anchor" = com.apple/foreign ]; then cat "$SIM/foreign_rules" 2>/dev/null
              elif [ -n "$anchor" ]; then cat "$SIM/anchor" 2>/dev/null; else cat "$SIM/main" 2>/dev/null; fi ;;
  show_A) echo "  com.apple"; echo "  com.apple/999.vpnguard"; [ -f "$SIM/foreign_rules" ] && echo "  com.apple/foreign" ;;
  load)
    [ -f "$file" ] || exit 1
    if [ -s "$SIM/badaddr" ] && grep -q "$(cat "$SIM/badaddr")" "$file"; then echo "syntax error" >&2; exit 1; fi
    [ "$dry" = 1 ] && exit 0
    # «-n прошёл, а настоящая загрузка — нет» для наборов с таблицей РФ из файла
    if [ -e "$SIM/failfile" ] && grep -q '<vg_ru> const file' "$file"; then echo "cannot load" >&2; exit 1; fi
    if [ -n "$anchor" ]; then
      grep -v -e '^#' -e '^$' -e '^table ' "$file" > "$SIM/anchor"
      rm -rf "$SIM/tables"; mkdir -p "$SIM/tables"
      grep '^table <' "$file" | while read -r line; do
        name=$(printf '%s\n' "$line" | sed 's/^table <\([a-z_]*\)>.*/\1/')
        if [[ $line == *' file "'* ]]; then
          f=$(printf '%s\n' "$line" | sed 's/.* file "\(.*\)"$/\1/'); grep -v -e '^#' -e '^$' "$f" > "$SIM/tables/$name"
        else
          printf '%s\n' "$line" | sed -n 's/.*{ \(.*\) }.*/\1/p' | tr ',' '\n' | tr -d ' ' | grep -v '^$' > "$SIM/tables/$name"
        fi
      done
    elif [ ! -e "$SIM/hook_broken" ]; then echo 'anchor "com.apple/*" all' > "$SIM/main"; fi ;;
  flush_rules) : > "$SIM/anchor" ;;
  flush_Tables) rm -rf "$SIM/tables" ;;
  enable) t="$RANDOM$RANDOM"; echo "$t" >> "$refs"; echo "pf enabled" >&2; echo "Token : $t" >&2 ;;
  release) grep -v "^$tok\$" "$refs" > "$refs.tmp"; mv "$refs.tmp" "$refs" ;;
  disable) : > "$refs"; echo "pf disabled" >&2 ;;
esac
EOF
cat > "$SIM/stub/sudo" <<'EOF'
#!/bin/bash
# sudo [-n] -u ПОЛЬЗОВАТЕЛЬ команда … → команда … (так сторож читает от имени пользователя; в песочнице
# пользователь один). Повышение прав (sudo -k …) — как настоящий sudo без пароля и терминала: отказ.
user=""
while [ $# -gt 0 ]; do case $1 in -n|-k|-K|-H) shift ;; -u) user=$2; shift 2 ;; *) break ;; esac; done
[ -n "$user" ] || { echo "sudo: a terminal is required to read the password" >&2; exit 1; }
exec "$@"
EOF
cat > "$SIM/stub/curl" <<'EOF'
#!/bin/bash
# DNS-over-HTTPS: https://РЕЗОЛВЕР/(dns-query|resolve)?name=ИМЯ&type=A|AAAA → JSON с адресами из
# $SIM/dns/ИМЯ (A) или $SIM/dns/ИМЯ.v6 (AAAA); к какому резолверу спросили — в $SIM/doh.calls
url=""; for a in "$@"; do case $a in https://*) url=$a ;; esac; done
host=${url#https://}; host=${host%%/*}
name=$(printf '%s\n' "$url" | sed -n 's/.*[?&]name=\([^&]*\).*/\1/p')
type=$(printf '%s\n' "$url" | sed -n 's/.*[?&]type=\([A-Z]*\).*/\1/p')
echo "$host $name $type" >> "$SIM/doh.calls"
f="$SIM/dns/$name"; [ "$type" = AAAA ] && f="$f.v6"; t=1; [ "$type" = AAAA ] && t=28
if [ -f "$f" ]; then
  printf '{"Status":0,"Answer":['; sep=""
  for ip in $(cat "$f"); do printf '%s{"name":"%s","type":%s,"data":"%s"}' "$sep" "$name" "$t" "$ip"; sep=","; done
  printf ']}'
else printf '{"Status":3}'; fi
EOF
cat > "$SIM/stub/sysctl" <<'EOF'
#!/bin/bash
if [ "$*" = "-n kern.bootsessionuuid" ]; then cat "$SIM/bootid"; else /usr/sbin/sysctl "$@"; fi
EOF
cat > "$SIM/stub/launchctl" <<'EOF'
#!/bin/bash
[ "$1" = kill ] && [ -f "$SIM/daemon.pid" ] && kill -USR1 "$(cat "$SIM/daemon.pid")" 2>/dev/null
exit 0
EOF
cat > "$SIM/stub/id" <<'EOF'
#!/bin/bash
if [ "$*" = "-u" ]; then echo "${FAKE_UID:-0}"; else /usr/bin/id "$@"; fi
EOF
chmod +x "$SIM/stub/"*

# --- копии под тест: BASE, PATH, LOG, интервалы ---
patch() {
  sed -e "s|^BASE=\"/Library/Application Support/VPNGuard\"|BASE=\"$SIM/base\"|" \
      -e "s|^export PATH=/sbin:/usr/sbin:/bin:/usr/bin|export PATH=\"$SIM/stub:/sbin:/usr/sbin:/bin:/usr/bin\"|" \
      -e "s|^LOG=/Library/Logs/VPNGuard.log|LOG=\"$SIM/vpnguard.log\"|" \
      -e "s|^INTERVAL=2|INTERVAL=0.2|" -e "s|^PF_TIMEOUT=10|PF_TIMEOUT=1|" \
      -e "s|^RESOLVE_EVERY=60|RESOLVE_EVERY=1|" -e "s|^RU_VERIFY_EVERY=60|RU_VERIFY_EVERY=1|" \
      -e "s|^RU_SRC_EVERY=600|RU_SRC_EVERY=1|" -e "s|^OWNER_CHECK_EVERY=300|OWNER_CHECK_EVERY=1|" "$1" > "$2"
  chmod +x "$2"
}
patch "$DIR/daemon/vpnguardd" "$SIM/base/vpnguardd"
patch "$DIR/cli/vpnguard" "$SIM/base/vpnguard"
VG="$SIM/base/vpnguard"

PASSN=0; FAILN=0
ok()   { PASSN=$((PASSN + 1)); echo "PASS $1"; }
bad()  { FAILN=$((FAILN + 1)); echo "FAIL $1"; }
st()   { sed -n "s/^$1=//p" "$SIM/base/status" 2>/dev/null; }
sk()   { sed -n "s/^$1=//p" "$SIM/base/state" 2>/dev/null; }
anchor_loaded() { [ -s "$SIM/anchor" ]; }
pf_on()  { [ -s "$SIM/refs" ]; }
expect() { # секунд описание условие...
  local t=$1 what=$2 i; shift 2
  for ((i = 0; i < t * 10; i++)); do "$@" && { ok "$what"; return 0; }; sleep 0.1; done
  bad "$what"; return 1
}
start_daemon() { bash "$SIM/base/vpnguardd" 2>> "$SIM/daemon.err" & echo $! > "$SIM/daemon.pid"; }
stop_daemon()  { kill "$(cat "$SIM/daemon.pid")" 2>/dev/null; wait "$(cat "$SIM/daemon.pid")" 2>/dev/null; rm -f "$SIM/daemon.pid"; }
in_log() { grep -q "$1" "$SIM/vpnguard.log"; }
in_events() { grep -q "$1" "$SIM/base/events" 2>/dev/null; }
tbl() { cat "$SIM/tables/$1" 2>/dev/null | sort | paste -sd' ' -; }
tbl_has() { grep -qx "$2" "$SIM/tables/$1" 2>/dev/null; }
client_sync() { HOME="$SIM/home" FAKE_UID=501 "$VG" sync "$@"; }
trap 'rm -f "$SIM/hang"; stop_daemon; rm -rf "$SIM"' EXIT

echo "== 1. Первый старт"
start_daemon
expect 6 "1.1 правила загружены" anchor_loaded   # 6 с: под нагрузкой первый цикл медленнее
expect 3 "1.2 pf включён" pf_on
expect 3 "1.3 статус on/loaded/Enabled" bash -c '[ "$(sed -n s/^mode=//p "$SIM/base/status" 2>/dev/null)" = on ] && grep -q "^rules=loaded" "$SIM/base/status" && grep -q "^pf=Enabled" "$SIM/base/status"'
[ "$(sk mode)" = on ] && [ "$(sk boot)" = BOOT-AAAA ] && ok "1.4 состояние on, boot=BOOT-AAAA" || bad "1.4 состояние: $(cat "$SIM/base/state")"
in_log "старт после загрузки" && ok "1.5 лог: старт после загрузки" || bad "1.5 лог"
[ "$(wc -l < "$SIM/base/pf.tokens" | tr -d ' ')" = 1 ] && ok "1.6 один токен" || bad "1.6 токенов: $(cat "$SIM/base/pf.tokens")"
grep -q 'user\|group' "$SIM/anchor" && bad "1.7 в правилах нет проверок владельца" || ok "1.7 в правилах нет проверок владельца"
[ "$(tbl vg_ru)" = "2.56.0.0/14 5.255.255.0/24" ] && ok "1.8 таблица РФ из ru.cidr" || bad "1.8 vg_ru: $(tbl vg_ru)"
[ -z "$(tbl vg_servers)" ] && ok "1.9 до выжимки из Karing серверов нет (Karing не подключится, утечки нет)" || bad "1.9 vg_servers: $(tbl vg_servers)"

echo "== 1b. Адреса из Karing"
out=$(client_sync 2>&1); echo "   $out"
[[ $out == *"серверов 2, DNS 2"* ]] && ok "1b.1 CLI sync передал выжимку" || bad "1b.1 CLI: $out"
expect 5 "1b.2 серверы в таблице (имя разрешено через DoH)" bash -c '[ "$(sort "$SIM/tables/vg_servers" 2>/dev/null | paste -sd" " -)" = "198.51.100.10 203.0.113.20" ]'
[ "$(tbl vg_dns)" = "1.1.1.1 8.8.8.8" ] && ok "1b.3 DNS Karing (только адресом) и резолверы сторожа" || bad "1b.3 vg_dns: $(tbl vg_dns)"
[ -z "$(awk '$1 != "1.1.1.1" && $1 != "8.8.8.8"' "$SIM/doh.calls" 2>/dev/null)" ] && [ -s "$SIM/doh.calls" ] && ok "1b.3a имена спрашиваются только у зашитых резолверов" || bad "1b.3a doh: $(sort -u "$SIM/doh.calls" | head -3)"
in_events "Защита взяла адреса из Karing" && ok "1b.4 уведомление о первом списке" || bad "1b.4 events: $(cat "$SIM/base/events")"
expect 3 "1b.5 статус показывает серверы" bash -c 'grep -q "^servers=.*vpn.example.net (203.0.113.20)" "$SIM/base/status"'
out=$(client_sync 2>&1); m1=$(stat -f %m "$SIM/base/request/client")
sleep 1.1; client_sync -q; m2=$(stat -f %m "$SIM/base/request/client")
[ "$m1" = "$m2" ] && ok "1b.6 без изменений выжимка не переписывается" || bad "1b.6 переписана: $m1 → $m2"
HOME="$SIM/home" FAKE_UID=501 "$VG" karing -q && [ "$(stat -f %m "$SIM/base/request/client")" = "$m2" ] &&
  ok "1b.7 прежнее имя команды (vpnguard karing) работает" || bad "1b.7 vpnguard karing"
expect 3 "1b.8 в статусе — название клиента из адаптера" bash -c 'grep -q "^provider=Karing$" "$SIM/base/status"'

echo "== 2. Починки"
: > "$SIM/anchor"
expect 3 "2.1 снесённые правила вернулись" anchor_loaded
expect 2 "2.2 repairs=1" bash -c '[ "$(sed -n s/^repairs=//p "$SIM/base/status")" = 1 ]'
"$SIM/stub/pfctl" -d >/dev/null
expect 3 "2.3 pf снова включён после -d" pf_on
expect 2 "2.4 repairs=2" bash -c '[ "$(sed -n s/^repairs=//p "$SIM/base/status")" = 2 ]'
echo 'pass out all # подмена' > "$SIM/anchor"
expect 3 "2.5 подменённые правила заменены эталоном" bash -c 'grep -q "block return out log quick all" "$SIM/anchor"'
: > "$SIM/main"
expect 3 "2.6 хук anchor com.apple/* восстановлен" bash -c 'grep -q "com.apple" "$SIM/main"'
expect 2 "2.7 все починки в логе" bash -c 'grep -q "ПОЧИНКА: правила" "$SIM/vpnguard.log" && grep -q "ПОЧИНКА: pf был выключен" "$SIM/vpnguard.log" && grep -q "ПОЧИНКА: в основном наборе" "$SIM/vpnguard.log"'

echo "== 3. Пауза через CLI (как root)"
out=$(FAKE_UID=0 "$VG" pause 1m 2>&1); echo "   $out"
[[ $out == Пауза\ до* ]] && ok "3.1 CLI подтвердил паузу" || bad "3.1 CLI: $out"
anchor_loaded && bad "3.2 правила сняты" || ok "3.2 правила сняты"
pf_on && bad "3.3 pf отпущен (все токены, включая устаревший)" || ok "3.3 pf отпущен (все токены, включая устаревший)"
[ ! -e "$SIM/base/pf.tokens" ] && ok "3.4 файл токенов удалён" || bad "3.4 токены: $(cat "$SIM/base/pf.tokens")"
[ "$(st mode)" = paused ] && ok "3.5 статус paused" || bad "3.5 статус $(st mode)"
grep -q "команда: pause 1m" "$SIM/vpnguard.log" && ok "3.6 аудит команды" || bad "3.6 аудит"

echo "== 4. Автовозврат после паузы"
printf 'mode=paused\nuntil=%s\nboot=BOOT-AAAA\n' $(( $(date +%s) + 2 )) > "$SIM/base/state"
expect 5 "4.1 пауза кончилась — правила вернулись" anchor_loaded
expect 2 "4.2 состояние снова on" bash -c '[ "$(sed -n s/^mode=//p "$SIM/base/state")" = on ]'
in_log "пауза кончилась" && ok "4.3 лог: пауза кончилась" || bad "4.3 лог"

echo "== 5. Выключить совсем и включить без пароля"
out=$(FAKE_UID=0 "$VG" off 2>&1); echo "   $out"
anchor_loaded && bad "5.1 off: правила сняты" || ok "5.1 off: правила сняты"
sleep 1
anchor_loaded && bad "5.2 off держится" || ok "5.2 off держится"
out=$(FAKE_UID=501 "$VG" on 2>&1); echo "   $out"
[ "$out" = "Защита включена." ] && ok "5.3 on без пароля (через запрос)" || bad "5.3 on: $out"
[ ! -e "$SIM/base/request/on" ] && ok "5.4 запрос убран" || bad "5.4 запрос висит"
in_log "включено по запросу пользователя" && ok "5.5 лог запроса" || bad "5.5 лог"
out=$(FAKE_UID=501 "$VG" pause 1m 2>&1 </dev/null); rc=$?
[ $rc != 0 ] && anchor_loaded && ok "5.6 пауза без root не прошла (уходит в sudo)" || bad "5.6 пауза без root: rc=$rc $out"
out=$(FAKE_UID=0 "$VG" pause 30s 2>&1); rc=$?
[ $rc != 0 ] && anchor_loaded && ok "5.7 срок меньше минуты отклонён" || bad "5.7 rc=$rc $out"

echo "== 6. Перезапуск в той же загрузке сохраняет off"
FAKE_UID=0 "$VG" off >/dev/null 2>&1
stop_daemon
start_daemon
sleep 1
anchor_loaded && bad "6.1 после перезапуска off сохранён" || ok "6.1 после перезапуска off сохранён"
in_log "перезапуск в той же загрузке" && ok "6.2 лог перезапуска" || bad "6.2 лог"

echo "== 7. Новая загрузка сбрасывает в on"
stop_daemon
echo 'BOOT-BBBB' > "$SIM/bootid"
: > "$SIM/refs"   # ядро после перезагрузки: ссылок pf нет
echo "STALE_TOKEN" > "$SIM/base/pf.tokens"
start_daemon
expect 3 "7.1 после загрузки защита включена, хотя была off" anchor_loaded
[ "$(sk boot)" = BOOT-BBBB ] && ok "7.2 boot обновлён" || bad "7.2 boot=$(sk boot)"
grep -q STALE_TOKEN "$SIM/base/pf.tokens" && bad "7.3 токены прошлой загрузки сброшены" || ok "7.3 токены прошлой загрузки сброшены"

echo "== 8. Остановка сторожа оставляет правила"
stop_daemon
anchor_loaded && ok "8.1 правила на месте после остановки" || bad "8.1 правила пропали"
in_log "сторож остановлен" && ok "8.2 лог остановки" || bad "8.2 лог"

echo "== 9. CLI status"
# Статус сторож пишет в конце прохода. В п. 8 сторожа из п. 7 остановили посреди первого прохода, и в
# файле мог остаться статус п. 6 (off). Поэтому ждём статус нового сторожа, а не фиксированную секунду:
# на медленном Mac первый проход дольше
rm -f "$SIM/base/status"
start_daemon
for i in $(seq 1 100); do [ -s "$SIM/base/status" ] && break; sleep 0.1; done   # до 10 с: под нагрузкой первый проход медленнее (ср. п. 1.1)
out=$(FAKE_UID=501 "$VG" status 2>&1); rc=$?
echo "$out" | sed 's/^/   /'
[ $rc = 0 ] && [[ $out == *"Защита: ВКЛЮЧЕНА"* ]] && ok "9.1 status on, rc=0" || bad "9.1 rc=$rc $(sed -n 's/^mode=//p' "$SIM/base/status" 2>/dev/null)"

echo "== 10. Своя ссылка pf, даже если pf уже включён чужим токеном"
stop_daemon
rm -f "$SIM/base/pf.tokens"; echo FOREIGN > "$SIM/refs"
start_daemon
expect 3 "10.1 сторож взял свою ссылку при уже включённом pf" bash -c '[ -s "$SIM/base/pf.tokens" ]'
"$SIM/stub/pfctl" -X FOREIGN
pf_on && ok "10.2 чужой pfctl -X не выключил pf" || bad "10.2 pf выключился от чужого -X"

echo "== 11. «Запрос» в виде каталога не залипает"
FAKE_UID=0 "$VG" off >/dev/null 2>&1
mkdir "$SIM/base/request/on"
expect 3 "11.1 каталог-запрос исполнен как on и удалён" bash -c '[ ! -e "$SIM/base/request/on" ] && [ -s "$SIM/anchor" ]'
out=$(FAKE_UID=0 "$VG" pause 1m 2>&1); rc=$?
sleep 1
[ $rc = 0 ] && ! anchor_loaded && ok "11.2 после этого пауза держится" || bad "11.2 rc=$rc $out"

echo "== 12. Нет anchor com.apple/* и не восстанавливается — статус честный"
FAKE_UID=0 "$VG" on >/dev/null 2>&1
touch "$SIM/hook_broken"; : > "$SIM/main"
expect 3 "12.1 статус hook=absent" bash -c 'grep -q "^hook=absent" "$SIM/base/status"'
out=$(FAKE_UID=501 "$VG" status 2>&1); rc=$?
[ $rc = 2 ] && [[ $out == *"правила не действуют"* ]] && ok "12.2 CLI status предупреждает, rc=2" || bad "12.2 rc=$rc $out"
# hook=absent в статусе бывает раньше строки в журнале (хук сломан посреди прохода): ждём строку, потом — что она одна
for i in $(seq 1 30); do [ "$(grep -c 'перечитать /etc/pf.conf не вышло' "$SIM/vpnguard.log")" -ge 1 ] && break; sleep 0.1; done; sleep 1
[ "$(grep -c 'перечитать /etc/pf.conf не вышло' "$SIM/vpnguard.log")" = 1 ] && ok "12.3 ошибка в логе один раз, без спама" || bad "12.3 строк: $(grep -c 'не вышло' "$SIM/vpnguard.log")"
rm -f "$SIM/hook_broken"
expect 3 "12.4 хук вернулся" bash -c 'grep -q "^hook=present" "$SIM/base/status"'

echo "== 13. Состояние от чужой загрузки → on"
FAKE_UID=0 "$VG" off >/dev/null 2>&1
printf 'mode=off\nuntil=0\nboot=BOOT-OLD\n' > "$SIM/base/state"
expect 3 "13.1 сторож включил защиту" anchor_loaded
[ "$(sk boot)" = BOOT-BBBB ] && ok "13.2 состояние переписано текущей загрузкой" || bad "13.2 boot=$(sk boot)"

echo "== 14. Новый сервер в профиле Karing"
jq '.outbounds += [{"type":"vless","tag":"n","server":"new.example","server_port":443}]' "$KCONF" > "$KCONF.t" && mv "$KCONF.t" "$KCONF"
echo "203.0.113.5" > "$SIM/dns/new.example"
client_sync -q
expect 5 "14.1 новый сервер в таблице" tbl_has vg_servers 203.0.113.5
expect 2 "14.2 уведомление о новом сервере" in_events "добавлен VPN-сервер new.example (203.0.113.5)"
tbl_has vg_servers 198.51.100.10 && tbl_has vg_servers 203.0.113.20 && ok "14.3 прежние серверы на месте" || bad "14.3 vg_servers: $(tbl vg_servers)"

echo "== 15. У сервера сменился адрес (меняет администратор)"
echo "203.0.113.99" > "$SIM/dns/vpn.example.net"
expect 5 "15.1 новый адрес в таблице" tbl_has vg_servers 203.0.113.99
tbl_has vg_servers 203.0.113.20 && ok "15.2 прежний адрес пока оставлен (Karing помнит адрес до 12 ч)" || bad "15.2 vg_servers: $(tbl vg_servers)"
expect 2 "15.3 уведомление о новом адресе" in_events "У VPN-сервера vpn.example.net новый адрес: 203.0.113.99"
expect 9 "15.4 через срок жизни прежний адрес убран" bash -c '! grep -qx 203.0.113.20 "$SIM/tables/vg_servers"'

echo "== 15a. Подмена резолвера и DNS по имени через настройки Karing не работает"
: > "$SIM/doh.calls"
jq '.dns.servers += [{"type":"udp","tag":"evil","server":"203.0.113.53"},{"type":"https","tag":"evil2","server":"api.anthropic.com"}]' "$KCONF" > "$KCONF.t" && mv "$KCONF.t" "$KCONF"
echo "160.79.104.10" > "$SIM/dns/api.anthropic.com"
client_sync -q
expect 4 "15a.1 DNS-адрес из настроек — в таблице, с уведомлением" in_events "добавлен DNS-сервер 203.0.113.53"
sleep 2
[ -z "$(awk '$1 != "1.1.1.1" && $1 != "8.8.8.8"' "$SIM/doh.calls")" ] && ok "15a.2 к подложенному резолверу сторож не ходит" || bad "15a.2 doh: $(sort -u "$SIM/doh.calls" | head -3)"
tbl_has vg_dns 160.79.104.10 || tbl_has vg_servers 160.79.104.10 && bad "15a.3 DNS по имени не открыл адрес AI-сервиса" || ok "15a.3 DNS по имени не открыл адрес AI-сервиса"
in_log "DNS-серверы Karing по имени не беру" && ok "15a.4 в журнале — пропущенный DNS по имени" || bad "15a.4 журнал"
jq '.dns.servers |= map(select(.tag != "evil" and .tag != "evil2"))' "$KCONF" > "$KCONF.t" && mv "$KCONF.t" "$KCONF"
client_sync -q

echo "== 16. Мусор и подлог в настройках Karing не проходят"
jq '.outbounds += [{"type":"vless","server":"0.0.0.0/0"},{"type":"vless","server":"x.ru\nserver 160.79.104.10"},{"type":"vless","server":"a b.ru"}]' "$KCONF" > "$KCONF.t" && mv "$KCONF.t" "$KCONF"
client_sync -q
expect 4 "16.1 в журнале — пропущенные странные адреса" in_log "пропустил странные адреса"
sleep 1
grep -q -e '160\.79' -e '0\.0\.0\.0' "$SIM/tables/vg_servers" && bad "16.2 подлог не попал в таблицу" || ok "16.2 подлог не попал в таблицу"
printf '# vpnguard sync\nserver 1.2.3.4/0\nserver evil.example;rm\ndns udp 0.0.0.0/1\n' > "$SIM/base/request/client"
sleep 1.5
grep -q -e '1\.2\.3\.4' -e '0\.0\.0\.0' "$SIM/tables/vg_servers" "$SIM/tables/vg_dns" && bad "16.3 подложенная руками выжимка не прошла" || ok "16.3 подложенная руками выжимка не прошла"
client_sync -q

echo "== 16a. Выжимку с чужими правами или симлинк сторож не берёт"
printf '# vpnguard sync\nserver 198.51.100.7\n' > "$SIM/base/request/client"; chmod 666 "$SIM/base/request/client"
expect 3 "16a.1 запись для всех — не берёт (client=foreign)" bash -c 'grep -q "^client=foreign" "$SIM/base/status"'
tbl_has vg_servers 198.51.100.7 && bad "16a.2 адрес из такой выжимки не прошёл" || ok "16a.2 адрес из такой выжимки не прошёл"
printf 'server 198.51.100.8\n' > "$SIM/evil"; rm -f "$SIM/base/request/client"; ln -s "$SIM/evil" "$SIM/base/request/client"
sleep 1.5
tbl_has vg_servers 198.51.100.8 && bad "16a.3 симлинк не прошёл" || ok "16a.3 симлинк не прошёл"
rm -f "$SIM/base/request/client"; client_sync -q
expect 3 "16a.4 нормальная выжимка — снова ok" bash -c 'grep -q "^client=ok" "$SIM/base/status"'
in_events "Файл с адресами из Karing подложил не ты" && ok "16a.5 уведомление о подложенном файле" || bad "16a.5 events"
chmod 666 "$SIM/base/request/client"
expect 3 "16a.6 права испортились — foreign" bash -c 'grep -q "^client=foreign" "$SIM/base/status"'
chmod 644 "$SIM/base/request/client"   # содержимое и время изменения прежние — сторож должен перечитать сам
expect 4 "16a.7 права вернули — сторож перечитал без изменения файла" bash -c 'grep -q "^client=ok" "$SIM/base/status"'
rm -f "$SIM/base/request/client"; mkfifo "$SIM/base/request/client"
# статус без изменений сторож переписывает раз в 10 с (write_status): если канал он обработал раньше,
# чем мы прочли b1, сердцебиение сдвинется только через 10 с. Зависший сторож не сдвинет его вовсе
b1=$(st heartbeat); hb_after() { [ "$(st heartbeat)" -gt "$1" ]; }
expect 12 "16a.8 канал (FIFO) вместо файла не вешает сторожа" hb_after "$b1" || echo "  heartbeat $b1 → $(st heartbeat)"
rm -f "$SIM/base/request/client"; client_sync -q
expect 3 "16a.9 после FIFO — снова ok" bash -c 'grep -q "^client=ok" "$SIM/base/status"'

echo "== 17. macOS не пускает к настройкам Karing"
printf '# error: denied\n' > "$SIM/base/request/client"
expect 3 "17.1 статус client=denied" bash -c 'grep -q "^client=denied" "$SIM/base/status"'
in_events "macOS не даёт VPN Guard читать настройки Karing" && ok "17.2 уведомление" || bad "17.2 events"
tbl_has vg_servers 198.51.100.10 && ok "17.3 прежние адреса держатся" || bad "17.3 vg_servers: $(tbl vg_servers)"
out=$(FAKE_UID=501 "$VG" status 2>&1); [[ $out == *"macOS не даёт VPN Guard читать настройки Karing"* ]] && ok "17.4 CLI status предупреждает" || bad "17.4 $out"
client_sync -q
expect 3 "17.5 доступ вернулся — client=ok" bash -c 'grep -q "^client=ok" "$SIM/base/status"'

echo "== 18. Подмена таблиц сторож чинит"
r0=$(st repairs)
echo "9.9.9.9" >> "$SIM/tables/vg_servers"
expect 3 "18.1 лишний адрес убран" bash -c '! grep -qx 9.9.9.9 "$SIM/tables/vg_servers"'
expect 2 "18.2 это починка" bash -c '[ "$(sed -n s/^repairs=//p "$SIM/base/status")" -gt '"$r0"' ]'
rm -f "$SIM/tables/vg_ru"
expect 4 "18.3 пропавшая таблица РФ вернулась" bash -c '[ -s "$SIM/tables/vg_ru" ]'

echo "== 19. pf не принял адрес — грузим без адресов Karing, потом снова пробуем"
echo "203.0.113.66" > "$SIM/dns/new.example"; echo "203.0.113.66" > "$SIM/badaddr"
expect 5 "19.1 набор без адресов Karing (туннеля нет — утечки нет)" bash -c '[ ! -s "$SIM/tables/vg_servers" ] && [ -s "$SIM/anchor" ]'
expect 2 "19.2 уведомление" in_events "Защита не смогла принять адреса серверов"
: > "$SIM/badaddr"
expect 5 "19.3 pf снова принимает — адреса вернулись" tbl_has vg_servers 198.51.100.10

echo "== 19a. Повреждён файл правил — аварийный набор, не пустой якорь"
mv "$SIM/base/vpnguard.rules" "$SIM/rules.bak"
# Подмена якоря — повод перезагрузить. Загрузка, которая ещё шла, может затереть подмену, а подмену сразу
# после загрузки сторож примет за эталон (он перечитывает якорь). Поэтому раз в секунду и каждый раз другим текстом
tamper_until() { # секунд вариант
  local i
  for ((i = 0; i < $1 * 10; i++)); do
    grep -q "^variant=$2" "$SIM/base/status" && return 0
    (( i % 10 )) || echo "pass out all # $i" > "$SIM/anchor"
    sleep 0.1
  done
  return 1
}
tamper_until 6 emergency && ok "19a.1 загружен аварийный набор" || bad "19a.1 загружен аварийный набор"
expect 3 "19a.2 в якоре правила с финальным отказом" bash -c 'grep -q "block return out log quick all" "$SIM/anchor" && grep -q "on lo0" "$SIM/anchor"'
expect 3 "19a.3 VPN-серверы в аварийном наборе есть — Karing подключится" tbl_has vg_servers 198.51.100.10 || echo "  vg_servers: $(tbl vg_servers)"
in_events "Правила защиты повреждены" && ok "19a.4 уведомление" || bad "19a.4 events"
head -n 20 "$SIM/rules.bak" > "$SIM/base/vpnguard.rules"   # обрезанный файл — тоже повреждён
echo 'pass out all' > "$SIM/anchor"
sleep 1.5
grep -q "^variant=emergency" "$SIM/base/status" && ok "19a.5 обрезанный файл правил — тоже аварийный набор" || bad "19a.5 $(grep variant "$SIM/base/status")"
mv "$SIM/rules.bak" "$SIM/base/vpnguard.rules"
expect 4 "19a.6 файл вернули — основной набор" bash -c 'grep -q "^variant=full" "$SIM/base/status"'

echo "== 19b. Нет списка РФ / не грузится из файла"
mv "$SIM/base/ru.cidr" "$SIM/ru.bak"; echo 'pass out all' > "$SIM/anchor"
expect 4 "19b.1 уведомление: пропал список российских сетей" in_events "Пропал список российских сетей"
[ -s "$SIM/anchor" ] && grep -q "^variant=full" "$SIM/base/status" && ok "19b.2 правила на месте (таблица РФ пустая)" || bad "19b.2"
mv "$SIM/ru.bak" "$SIM/base/ru.cidr"
sleep 1.5   # дать сторожу закончить прошлую перезагрузку и снять эталон
touch "$SIM/failfile"; echo 'pass out all' > "$SIM/anchor"
expect 4 "19b.3 -n прошёл, загрузка нет — вариант без файла РФ" bash -c 'grep -q "^variant=noru" "$SIM/base/status"' ||
  { echo "   статус: $(grep variant "$SIM/base/status")"; tail -n 6 "$SIM/vpnguard.log" | sed 's/^/   журнал: /'; tail -n 4 "$SIM/pfctl.calls" | sed 's/^/   pfctl: /'; }
in_events "не смогла загрузить список российских сетей" && ok "19b.4 уведомление по настоящей причине" || bad "19b.4 events"
rm -f "$SIM/failfile"
expect 4 "19b.5 снова основной набор" bash -c 'grep -q "^variant=full" "$SIM/base/status"'

echo "== 20. pfctl завис в ядре"
nlog=$(wc -l < "$SIM/vpnguard.log"); nev=$(wc -l < "$SIM/base/events")
echo 'pass out all' > "$SIM/anchor"   # пусть зависание придётся на цикл с перезагрузкой набора
touch "$SIM/hang"
expect 5 "20.1 статус pf=hung" bash -c 'grep -q "^pf=hung" "$SIM/base/status"'
expect 2 "20.2 уведомление «похоже, зависло ядро»" in_events "похоже, зависло ядро"
b1=$(st heartbeat); sleep 2.5; b2=$(st heartbeat)
[ -n "$b1" ] && [ "$b2" -ge "$b1" ] && in_log "не ответил за 1 с" && ok "20.3 сторож жив и пишет статус" || bad "20.3 heartbeat $b1 → $b2"
n=$(pgrep -f "$SIM/stub/pfctl" | wc -l | tr -d ' ')
[ "$n" = 1 ] && ok "20.4 новые pfctl не плодятся (висит один)" || bad "20.4 висящих pfctl: $n"
out=$(FAKE_UID=501 "$VG" status 2>&1); rc=$?
[ $rc = 2 ] && [[ $out == *"pf не отвечает"* ]] && ok "20.5 CLI status: pf не отвечает, rc=2" || bad "20.5 rc=$rc $out"
newlog=$(tail -n +$((nlog + 1)) "$SIM/vpnguard.log"); newev=$(tail -n +$((nev + 1)) "$SIM/base/events")
printf '%s\n' "$newlog$newev" | grep -q -e "ПОЧИНКА" -e "не смогла принять" -e "нет anchor com.apple" -e "аварийный" &&
  bad "20.5a без ложных починок и ошибок при зависании: $(printf '%s\n' "$newlog" | grep -e ПОЧИНКА -e 'нет anchor' | head -2)" ||
  ok "20.5a без ложных починок и ошибок при зависании"
rm -f "$SIM/hang"
expect 5 "20.6 pf ожил — статус Enabled" bash -c 'grep -q "^pf=Enabled" "$SIM/base/status"'
in_events "pf снова отвечает" && ok "20.7 уведомление «снова отвечает»" || bad "20.7 events"

echo "== 21. Karing обновил свой geoip:ru"
echo 'новая версия' > "$SIM/karing-ru.srs"
expect 4 "21.1 статус ru_src=changed" bash -c 'grep -q "^ru_src=changed" "$SIM/base/status"'
in_events "Karing обновил список российских IP" && ok "21.2 уведомление" || bad "21.2 events"
[ "$(grep -c 'Karing обновил список российских IP' "$SIM/base/events")" = 1 ] && ok "21.3 уведомление одно, без спама" || bad "21.3 много уведомлений"
rm -f "$SIM/karing-ru.srs"; mkfifo "$SIM/karing-ru.srs"
b1=$(st heartbeat)
expect 12 "21.4 канал (FIFO) вместо файла клиента не вешает сторожа" hb_after "$b1" || echo "  heartbeat $b1 → $(st heartbeat)"
rm -f "$SIM/karing-ru.srs"; echo 'новая версия' > "$SIM/karing-ru.srs"

echo "== 22a. Чужие правила с проверкой владельца в pf"
expect 3 "22a.1 сейчас таких нет" bash -c 'grep -q "^owner_rules=none" "$SIM/base/status"'
echo "pass out quick proto tcp from any to any user = 0 no state" > "$SIM/foreign_rules"
expect 4 "22a.2 нашёл чужое правило с user" bash -c 'grep -q "^owner_rules=present" "$SIM/base/status"'
in_events "чужие правила с проверкой владельца пакета (якорь: com.apple/foreign)" && ok "22a.3 уведомление с именем якоря" || bad "22a.3 events: $(tail -2 "$SIM/base/events")"
rm -f "$SIM/foreign_rules"
expect 4 "22a.4 правило убрали — снова none" bash -c 'grep -q "^owner_rules=none" "$SIM/base/status"'

echo "== 22. Уведомления пронумерованы по порядку"
awk -F'\t' 'NR > 1 && $1 != prev + 1 { bad = 1 } { prev = $1 } END { exit bad }' "$SIM/base/events" && ok "22.1 номера подряд" || bad "22.1 $(cut -f1 "$SIM/base/events" | paste -sd' ' -)"

echo "== 23. Сторож жив до конца, без ошибок bash"
kill -0 "$(cat "$SIM/daemon.pid")" 2>/dev/null && ok "23.1 процесс сторожа жив" || bad "23.1 сторож упал"
LC_ALL=C grep -q -e 'unbound variable' -e 'syntax error' -e 'command not found' "$SIM/daemon.err" 2>/dev/null &&
  bad "23.2 ошибки bash в stderr сторожа: $(LC_ALL=C grep -e unbound -e syntax -e 'not found' "$SIM/daemon.err" | head -3)" || ok "23.2 ошибок bash в stderr сторожа нет"

echo
echo "PASS=$PASSN FAIL=$FAILN"
[ "$FAILN" = 0 ]

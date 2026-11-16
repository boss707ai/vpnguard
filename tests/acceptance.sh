#!/bin/bash
# Приёмка vpnguard после установки. Ставится в root-каталог вместе с vpnguard; запуск:
#   sudo "/Library/Application Support/VPNGuard/tests/acceptance.sh" [--vpn-off]
# Без флага — сценарии при включённом VPN-клиенте (≈2 мин, есть ожидание конца паузы).
# С флагом — плюс интерактивная часть: попросит выключить и снова включить VPN-клиент.
# (--karing-off — прежнее имя флага, работает так же.)
# Журнал: /Library/Application Support/VPNGuard/tests/acceptance.log (читается без пароля).
set -u
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
[ "$(id -u)" = 0 ] || { echo "Нужен sudo."; exit 1; }
U="${SUDO_USER:-}"
[ -n "$U" ] && [ "$U" != root ] || { echo "Запусти через sudo из-под своего пользователя."; exit 1; }
BASE="/Library/Application Support/VPNGuard"
. "$BASE/state.sh"
. "$BASE/provider.sh"
T="${VG_PROVIDER_TITLE:-VPN-клиент}"
VG="$BASE/vpnguard"
PROBE="$BASE/tests/nwprobe"
# физический интерфейс — как у сторожа: маршрут по умолчанию не через туннель (Wi-Fi или Ethernet);
# его тип — для зонда Network.framework
WIFI=$(netstat -rn -f inet 2>/dev/null | vg_phys_iface)
[ -n "$WIFI" ] || { echo "Не нашёл физический интерфейс с маршрутом по умолчанию (Wi-Fi или Ethernet)."; exit 1; }
KIND=$(networksetup -listallhardwareports | awk -v d="$WIFI" '/^Hardware Port:/{p=$0} $0=="Device: "d{print (p ~ /Wi-Fi/) ? "wifi" : "wired"}')
ROUTER=$(ipconfig getoption "$WIFI" router 2>/dev/null)
WIFI_IP=$(ipconfig getifaddr "$WIFI" 2>/dev/null)
LOGF="$BASE/tests/acceptance.log"   # root-каталог: симлинком не подменить
exec > >(tee "$LOGF") 2>&1
trap 'sudo -u "$U" /usr/bin/sudo -K 2>/dev/null || true' EXIT   # сбросить кэш sudo пользователя
CURL=(curl -sS --max-time 8 -w " [%{time_total}s]")

PASSN=0; FAILN=0; LAST_OUT=""
check() { # label expect rc out
  local res
  if { [ "$2" = ok ] && [ "$3" = 0 ]; } || { [ "$2" = block ] && [ "$3" != 0 ]; }; then
    res=PASS; PASSN=$((PASSN + 1)); else res=FAIL; FAILN=$((FAILN + 1)); fi
  printf '%-4s %-58s ждём=%-5s → %s\n' "$res" "$1" "$2" "$(printf '%s' "$4" | tr '\n' ' ' | cut -c1-100)"
}
probe() { # user|root label expect cmd...
  local who=$1 label=$2 expect=$3 out rc; shift 3
  if [ "$who" = user ]; then out=$(sudo -u "$U" "$@" 2>&1); rc=$?; else out=$("$@" 2>&1); rc=$?; fi
  if [ "$(basename "$1")" = dig ]; then
    printf '%s' "$out" | grep -Eq '^[0-9]+(\.[0-9]+){3}$' && rc=0 || rc=1
  fi
  check "$label" "$expect" "$rc" "$out"
  LAST_OUT=$out
}
wait_for() { # секунд описание условие...
  local t=$1 what=$2 i; shift 2
  for ((i = 0; i < t * 2; i++)); do
    if "$@"; then check "$what" ok 0 "за ~$((i / 2)) с"; return 0; fi
    sleep 0.5
  done
  check "$what" ok 1 "не дождался за $t с"; return 1
}
st()           { sed -n "s/^$1=//p" "$BASE/status"; }
pf_state()     { pfctl -s info 2>/dev/null | awk '/^Status/{print $2}'; }
rules_loaded() { [ -n "$(pfctl -a "$VG_ANCHOR" -sr 2>/dev/null)" ]; }
rules_absent() { ! rules_loaded; }
pf_enabled()   { [ "$(pf_state)" = Enabled ]; }
pf_as_before() { [ "$(pf_state)" = "$(cat "$BASE/pf-before")" ]; }
tunnel_up()    { vg_is_tunnel "$(vg_default_iface "$(route -n get default 2>/dev/null)")"; }
tunnel_works() { sudo -u "$U" curl -sS --max-time 5 -o /dev/null https://ipinfo.io/ip 2>/dev/null; }
dns_block_count() { # пакеты, заблокированные правилом «остальной DNS (udp 53)»
  pfctl -a "$VG_ANCHOR" -vsr 2>/dev/null | awk '/^block return out quick proto udp from any to any port = 53$/{getline; for (i = 1; i <= NF; i++) if ($i == "Packets:") print $(i + 1)}'
}
owned_by_root() { [ "$(stat -f %Su "$1")" = root ] && [ "$(stat -f %Su "$(dirname "$1")")" = root ]; }
table_n() { pfctl -a "$VG_ANCHOR" -t "$1" -T show 2>/dev/null | wc -l | tr -d ' '; }
tables_full() { [ "$(table_n vg_servers)" -gt 0 ] && [ "$(table_n vg_ru)" -gt 1000 ]; }
owner_rules() { # правила с проверкой владельца пакета во всём наборе pf: они могут увести ядро macOS во взаимоблокировку
  local a
  for a in "" $(pfctl -sA -v 2>/dev/null); do
    pfctl ${a:+-a "$a"} -sr 2>/dev/null | grep -E ' (user|group) |\(([a-z, ]*)?user' | sed "s|^|[${a:-основной}] |"
  done
}
PROXY_DIRECT=${VG_PROVIDER_PROXY_DIRECT:-}   # локальный прокси клиента «всё напрямую» (из адаптера; пусто — нет)

echo "== Предусловия"
[ "$(st mode)" = on ] || { echo "Защита не в режиме on — включи: vpnguard on"; exit 1; }
tunnel_up || { echo "$T выключен — включи его и запусти снова"; exit 1; }
PF_BEFORE=$(cat "$BASE/pf-before")
echo "защита on, $T работает, pf до установки: $PF_BEFORE"

echo
echo "== 0. Установка"
owned_by_root "$BASE/VPN Guard.app/Contents/MacOS/VPNGuard"; check "0.1 приложение принадлежит root" ok $? ""
owned_by_root /Library/LaunchAgents/local.vpnguard.menubar.plist; check "0.2 LaunchAgent принадлежит root" ok $? ""
[ -s "$BASE/pf.tokens" ]; check "0.3 сторож держит свою ссылку pf" ok $? "$(wc -l < "$BASE/pf.tokens" 2>/dev/null | tr -d ' ') токен(ов)"
[ "$(st hook)" = present ]; check "0.4 anchor com.apple/* в основном наборе" ok $? "hook=$(st hook)"
bad=""
for a in $(pfctl -a com.apple -sA -v 2>/dev/null); do
  [ "$a" = "$VG_ANCHOR" ] && continue
  hits=$(pfctl -a "$a" -sr 2>/dev/null | grep -E '^pass out' | grep -w quick | grep -v -E ' on (awdl0|llw0|lo0) ')
  [ -n "$hits" ] && bad="$bad [$a: $hits]"
done
[ -z "$bad" ]; check "0.5 якоря Apple без «pass out quick» мимо наших правил" ok $? "${bad:-нет}"
own=$(owner_rules)
[ -z "$own" ]; check "0.6 во всём pf нет проверок владельца (user/group)" ok $? "${own:-нет}"
[ "$(table_n vg_servers)" -gt 0 ]; check "0.7 таблица VPN-серверов из $T не пуста" ok $? "$(pfctl -a "$VG_ANCHOR" -t vg_servers -T show 2>/dev/null | tr -d ' ' | paste -sd' ' -)"
[ "$(table_n vg_dns)" -gt 0 ]; check "0.8 таблица DNS $T не пуста" ok $? "$(pfctl -a "$VG_ANCHOR" -t vg_dns -T show 2>/dev/null | tr -d ' ' | paste -sd' ' -)"
[ "$(table_n vg_ru)" = "$(vg_ru_count "$BASE/ru.cidr")" ]; check "0.9 таблица РФ загружена целиком" ok $? "$(table_n vg_ru) из $(vg_ru_count "$BASE/ru.cidr")"
[ "$(st client)" = ok ]; check "0.10 сторож получил адреса из $T" ok $? "client=$(st client)"
t0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000'); pfctl -s info >/dev/null 2>&1; t1=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')
(( t1 - t0 < 1000 )); check "0.11 pf отвечает быстро" ok $? "pfctl -s info за $((t1 - t0)) мс"

echo
echo "== 1. $T включён — всё работает"
probe user "1.1 IP через туннель"                         ok    "${CURL[@]}" https://ipinfo.io/ip
probe user "1.2 ya.ru ($T → напрямую)"                ok    "${CURL[@]}" -o /dev/null https://ya.ru
probe user "1.3 api.anthropic.com через туннель"          ok    "${CURL[@]}" -o /dev/null https://api.anthropic.com
probe user "1.4 ping 8.8.8.8 через туннель"               ok    ping -c1 -t3 8.8.8.8
probe user "1.5 DNS системный (туннель)"                  ok    dig ya.ru +short +time=2 +tries=1

echo
echo "== 2. Принудительный обход туннеля через $WIFI — режется (кроме российских сетей)"
probe user "2.1 curl через $WIFI (зарубежный адрес)"       block "${CURL[@]}" --interface "$WIFI" https://ipinfo.io/ip
probe user "2.2 Network.framework через $WIFI"            block "$PROBE" ipinfo.io 443 "$KIND"
probe user "2.3 DNS к роутеру"                             block dig @"$ROUTER" ya.ru +short +time=2 +tries=1
probe user "2.4 DNS к 8.8.8.8 с адреса $WIFI — разрешён (DNS $T)" ok dig -b "$WIFI_IP" @8.8.8.8 ya.ru +short +time=2 +tries=1
probe user "2.5 ping 8.8.8.8 через $WIFI"                  block ping -c1 -t2 -b "$WIFI" 8.8.8.8
probe user "2.6 ping роутера (локалка открыта)"            ok    ping -c1 -t2 "$ROUTER"
probe root "2.7 root через $WIFI — тоже режется (раньше root пропускали)" block "${CURL[@]}" --interface "$WIFI" https://ipinfo.io/ip
probe user "2.8 через $WIFI в российскую сеть (ya.ru) — открыто" ok "${CURL[@]}" --interface "$WIFI" -o /dev/null https://ya.ru
probe user "2.8a IPv6 через $WIFI — режется"               block "${CURL[@]}" -6 --interface "$WIFI" -o /dev/null https://www.google.com
if [ -n "$PROXY_DIRECT" ] && nc -z -G 2 "${PROXY_DIRECT%:*}" "${PROXY_DIRECT#*:}" >/dev/null 2>&1; then
  probe user "2.9 прокси $T «напрямую» → зарубежный адрес — режется" block "${CURL[@]}" -x "socks5h://$PROXY_DIRECT" https://ipinfo.io/ip
  probe user "2.10 прокси $T «напрямую» → ya.ru — открыто"   ok    "${CURL[@]}" -x "socks5h://$PROXY_DIRECT" -o /dev/null https://ya.ru
else
  echo "     2.9 и 2.10 пропущены: у $T нет прокси «напрямую» или он не слушает (${PROXY_DIRECT:-не задан})"
fi

echo
echo "== 4. Сторож чинит"
# ПОЧИНКУ сторож пишет в журнал после перепроверки загруженного набора, то есть позже, чем правила видны
# в pf (4.1). Поэтому 4.3 ждёт запись не раньше начала этого раздела: без 4.2 (pf был включён до установки)
# разовая проверка сразу после 4.1 опережала журнал. Смотрим и .1: журнал мог смениться на 1 МБ
T4=$(date '+%Y-%m-%d %H:%M:%S')
repair_logged() {
  cat /Library/Logs/VPNGuard.log.1 /Library/Logs/VPNGuard.log 2>/dev/null |
    awk -v t="$T4" 'substr($0, 1, 19) >= t && /ПОЧИНКА/ { f = 1 } END { exit !f }'
}
pfctl -a "$VG_ANCHOR" -F rules >/dev/null 2>&1
wait_for 5 "4.1 правила вернулись после сноса"                rules_loaded
if [ "$PF_BEFORE" = Disabled ]; then
  # pfctl -d аннулирует ссылки всех держателей pf — делаем, только если до нас pf никто не держал
  pfctl -d >/dev/null 2>&1
  wait_for 5 "4.2 pf включился после pfctl -d"                pf_enabled
else
  echo "     4.2 пропущен: до установки pf был включён кем-то ещё — pfctl -d сломал бы чужие ссылки"
fi
wait_for 5 "4.3 в журнале есть ПОЧИНКА"                         repair_logged
pfctl -a "$VG_ANCHOR" -F Tables >/dev/null 2>&1
wait_for 5 "4.4 таблицы адресов вернулись после сноса"         tables_full

echo
echo "== 5. Пауза, выключение, включение"
"$VG" pause 1m >/dev/null
wait_for 5 "5.1 пауза: правила сняты"                          rules_absent
pf_as_before; r=$?   # $? — сразу: подстановка $(...) в метке его затёрла бы
check "5.2 пауза: pf как до установки ($PF_BEFORE)" ok "$r" "сейчас $(pf_state)"
probe user "5.3 пауза: обход через $WIFI работает, как без защиты" ok "${CURL[@]}" --interface "$WIFI" https://ipinfo.io/ip
echo "   жду конца паузы (~60 с)…"
wait_for 75 "5.4 пауза кончилась — защита включилась сама"    rules_loaded
probe user "5.5 после паузы обход снова закрыт"                block "${CURL[@]}" --interface "$WIFI" https://ipinfo.io/ip
"$VG" off >/dev/null
wait_for 5 "5.6 выключено: правила сняты"                      rules_absent
sleep 6
rules_absent; check "5.7 выключено: держится через 6 с" ok $? "mode=$(st mode)"
sudo -u "$U" "$VG" on >/dev/null
wait_for 5 "5.8 «включить» без пароля сработало"               rules_loaded

if [ "${1:-}" = --vpn-off ] || [ "${1:-}" = --karing-off ]; then
  echo
  echo "== 3. $T выключен — у программ интернета нет"
  read -r -p ">>> Выключи $T и нажми Enter… " _ </dev/tty
  sleep 2
  tunnel_up; check "3.1 маршрут по умолчанию — не туннель" block $? "$(vg_default_iface "$(route -n get default 2>/dev/null)")"
  probe user "3.2 сайт (ipinfo)"                             block "${CURL[@]}" https://ipinfo.io/ip
  probe user "3.3 ya.ru"                                     block "${CURL[@]}" -o /dev/null https://ya.ru
  probe user "3.4 ping 8.8.8.8"                              block ping -c1 -t2 8.8.8.8
  probe user "3.5 DNS (dig по resolv.conf)"                  block dig ya.ru +short +time=2 +tries=1
  probe user "3.6 DNS к 8.8.8.8 — разрешён (им $T ищет сервер)" ok dig @8.8.8.8 ya.ru +short +time=2 +tries=1
  probe user "3.7 Network.framework (зарубежный IP)"         block "$PROBE" 34.117.59.81 443
  # 77.88.55.242 — один из адресов ya.ru (российская сеть); имени нет — DNS закрыт, поэтому по адресу
  probe user "3.7a российский IP по адресу — открыт (так задумано)" ok "${CURL[@]}" -o /dev/null http://77.88.55.242/
  before=$(dns_block_count)
  sudo -u "$U" dscacheutil -q host -a name "vg-$(uuidgen | tr 'A-Z' 'a-z').example.com" >/dev/null 2>&1
  sleep 1
  after=$(dns_block_count)
  [ "${after:-0}" -gt "${before:-0}" ]; check "3.8 системный резолвер (mDNSResponder) к роутеру режется" ok $? "счётчик правила DNS: $before → $after"
  read -r -p ">>> Включи $T (защита остаётся включённой) и нажми Enter… " _ </dev/tty
  wait_for 30 "3.9 $T подключился при включённой защите"   tunnel_works
fi

echo
echo "== Итог: PASS=$PASSN FAIL=$FAILN"
echo "Журнал сторожа (хвост):"; tail -n 12 /Library/Logs/VPNGuard.log
[ "$FAILN" = 0 ]

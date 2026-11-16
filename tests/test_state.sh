#!/bin/bash
# Юнит-тесты lib/state.sh. Запуск: bash tests/test_state.sh (root не нужен).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DIR/lib/state.sh"
# macOS 14: встроенного jq нет — берём bin/jq из исходников (tools/get-jq.sh; при установке — копия в
# каталоге root, сверенная установщиком). Встроенный /usr/bin/jq vg_jq всё равно предпочтёт.
[ -x "$DIR/bin/jq" ] && VG_JQ_LOCAL="$DIR/bin/jq"
PASSN=0; FAILN=0
eq() { # label expected actual
  if [ "$2" = "$3" ]; then PASSN=$((PASSN+1))
  else FAILN=$((FAILN+1)); printf 'FAIL %s: ждали [%s], получили [%s]\n' "$1" "$2" "$3"; fi
}
rc() { "$@" >/dev/null 2>&1; echo $?; }

# vg_parse_duration
eq "15m" 900 "$(vg_parse_duration 15m)"
eq "без единиц = минуты" 300 "$(vg_parse_duration 5)"
eq "1h" 3600 "$(vg_parse_duration 1h)"
eq "90s" 90 "$(vg_parse_duration 90s)"
eq "24h ок" 86400 "$(vg_parse_duration 24h)"
eq "ведущие нули" 480 "$(vg_parse_duration 08m)"
eq "25h — больше суток" 1 "$(rc vg_parse_duration 25h)"
eq "30s — меньше минуты" 1 "$(rc vg_parse_duration 30s)"
eq "мусор" 1 "$(rc vg_parse_duration abc)"
eq "пусто" 1 "$(rc vg_parse_duration '')"
eq "инъекция" 1 "$(rc vg_parse_duration '5m;rm')"
eq "слишком длинное число" 1 "$(rc vg_parse_duration 99999999999999999999)"

# vg_effective_mode
eq "on" on "$(vg_effective_mode on 0 100)"
eq "off" off "$(vg_effective_mode off 0 100)"
eq "пауза идёт" paused "$(vg_effective_mode paused 200 100)"
eq "пауза кончилась" on "$(vg_effective_mode paused 100 100)"
eq "пауза без срока → on" on "$(vg_effective_mode paused '' 100)"
eq "мусор → on" on "$(vg_effective_mode zzz 0 100)"
eq "пусто → on" on "$(vg_effective_mode '' '' 100)"

# vg_kv
eq "kv mode" paused "$(printf 'mode=paused\nuntil=5\n' | vg_kv mode)"
eq "kv нет ключа" "" "$(printf 'mode=on\n' | vg_kv until)"
eq "kv первое совпадение" a "$(printf 'mode=a\nmode=b\n' | vg_kv mode)"

# vg_boot_id — непустой и стабильный в пределах загрузки
B1=$(vg_boot_id); B2=$(vg_boot_id)
eq "boot id непустой" 0 "$(rc test -n "$B1")"
eq "boot id стабилен" "$B1" "$B2"

# vg_state_render ↔ vg_kv
S=$(vg_state_render paused 123 456)
eq "render mode" paused "$(printf '%s\n' "$S" | vg_kv mode)"
eq "render until" 123 "$(printf '%s\n' "$S" | vg_kv until)"
eq "render boot" 456 "$(printf '%s\n' "$S" | vg_kv boot)"

# vg_default_iface / vg_is_tunnel
R=$'   route to: default\ndestination: default\n  interface: utun6\n      flags: <UP,DONE>'
eq "iface" utun6 "$(vg_default_iface "$R")"
eq "iface пусто" "" "$(vg_default_iface 'route: writing to routing socket: not in table')"
eq "utun — туннель" 0 "$(rc vg_is_tunnel utun6)"
eq "ipsec — туннель" 0 "$(rc vg_is_tunnel ipsec0)"
eq "ppp — туннель" 0 "$(rc vg_is_tunnel ppp0)"
eq "en0 — не туннель" 1 "$(rc vg_is_tunnel en0)"
eq "пусто — не туннель" 1 "$(rc vg_is_tunnel '')"

# vg_fmt_left
eq "fmt 754" "12:34" "$(vg_fmt_left 754)"
eq "fmt 3700" "1:01:40" "$(vg_fmt_left 3700)"
eq "fmt <0" "0:00" "$(vg_fmt_left -5)"

T=$(mktemp -d "${TMPDIR:-/tmp}/vgstate.XXXXXX")
trap 'rm -rf "$T"' EXIT

# vg_is_ipv4 / vg_is_ipv6 / vg_is_host
eq "ipv4" 0 "$(rc vg_is_ipv4 198.51.100.10)"
eq "ipv4 ведущие нули — нет (pf прочёл бы 010 как 8)" 1 "$(rc vg_is_ipv4 010.001.002.003)"
eq "ipv4 нули без ведущих" 0 "$(rc vg_is_ipv4 10.0.0.0)"
eq "ipv4 > 255" 1 "$(rc vg_is_ipv4 1.2.3.256)"
eq "ipv4 CIDR — нет" 1 "$(rc vg_is_ipv4 0.0.0.0/0)"
eq "ipv4 три октета" 1 "$(rc vg_is_ipv4 1.2.3)"
eq "ipv4 хвост" 1 "$(rc vg_is_ipv4 '1.2.3.4 ')"
eq "ipv6" 0 "$(rc vg_is_ipv6 2001:db8::1)"
eq "ipv6 полный" 0 "$(rc vg_is_ipv6 2001:0db8:0000:0000:0000:0000:0000:0001)"
eq "ipv6 CIDR — нет" 1 "$(rc vg_is_ipv6 ::/0)"
eq "ipv6 без двоеточий" 1 "$(rc vg_is_ipv6 abcd)"
eq "ipv6 тройное двоеточие" 1 "$(rc vg_is_ipv6 1:::2)"
eq "ipv6 два ::" 1 "$(rc vg_is_ipv6 1::2::3)"
eq "ipv6 девять групп" 1 "$(rc vg_is_ipv6 1:2:3:4:5:6:7:8:9)"
eq "ipv6 группа из 5 цифр" 1 "$(rc vg_is_ipv6 12345::1)"
eq "host" 0 "$(rc vg_is_host vpn.example.net)"
eq "host с дефисом" 0 "$(rc vg_is_host a-b.example.com)"
eq "host без точки" 1 "$(rc vg_is_host localhost)"
eq "host с пробелом" 1 "$(rc vg_is_host 'a b.ru')"
eq "host с ;" 1 "$(rc vg_is_host 'a.ru;rm')"
eq "host — IP не имя" 1 "$(rc vg_is_host 1.2.3.4)"
eq "host дефис в начале" 1 "$(rc vg_is_host -a.ru)"

# vg_parse_extract: выжимке адаптера не доверяем — проходят только адреса и имена хостов
P=$(printf 'server 203.0.113.5\nserver vpn.example.net\ndns udp 192.0.2.53\ndns https dns.example.com\nserver evil;rm\ndns udp 0.0.0.0/0\n%s\n' 'что-то' | vg_parse_extract)
eq "выжимка: серверы" "203.0.113.5 vpn.example.net" "$(printf '%s\n' "$P" | awk '$1=="server"{print $2}' | tr '\n' ' ' | sed 's/ $//')"
eq "выжимка: DNS адресом" "192.0.2.53" "$(printf '%s\n' "$P" | awk '$1=="dns"{print $2}')"
eq "выжимка: DNS по имени — отдельно" "dns.example.com" "$(printf '%s\n' "$P" | awk '$1=="dnsname"{print $2}')"
eq "выжимка: мусор — bad" 2 "$(printf '%s\n' "$P" | grep -c '^bad ')"

# Контракт адаптеров (docs/ADAPTERS.md): у каждого providers/ИМЯ/provider.sh имя совпадает с папкой,
# есть название и обе функции, а подключение через «.» ничего не печатает и ничего не делает
for pf in "$DIR"/providers/*/provider.sh; do
  [ -f "$pf" ] || continue
  pn=$(basename "$(dirname "$pf")")
  eq "адаптер $pn: подключается молча" "" "$( . "$pf" 2>&1 )"
  eq "адаптер $pn: интерфейс" "ok" "$( . "$pf"; [ "${VG_PROVIDER:-}" = "$pn" ] && [ -n "${VG_PROVIDER_TITLE:-}" ] &&
    declare -F vg_provider_extract >/dev/null && declare -F vg_provider_precheck >/dev/null && echo ok )"
done

# Адаптер Karing: конфиг sing-box → серверы, DNS (в установке с другим адаптером его файла нет — пропуск)
if [ -f "$DIR/providers/karing/provider.sh" ]; then
. "$DIR/providers/karing/provider.sh"
cat > "$T/karing.json" <<'EOF'
{"outbounds":[
  {"type":"vless","tag":"a","server":"198.51.100.10","server_port":8443},
  {"type":"vless","tag":"b","server":"vpn.example.net","server_port":10443},
  {"type":"vless","tag":"c","server":"vpn.example.net","server_port":8443},
  {"type":"trojan","tag":"d","server":"0.0.0.0/0"},
  {"type":"vless","tag":"e","server":"evil.ru\nserver 160.79.104.10"},
  {"type":"vless","tag":"f","server":"a b.ru"},
  {"type":"urltest","tag":"u","outbounds":["a","b"]},
  {"type":"direct","tag":"direct_out"},
  {"type":"vless","tag":"g","server":12345},
  "мусор"
 ],
 "dns":{"servers":[
  {"type":"udp","tag":"x","server":"8.8.8.8"},
  {"type":"local","tag":"local"},
  {"type":"dhcp","tag":"dhcp://auto"},
  {"type":"https","tag":"y","server":"1.1.1.1"},
  {"type":"https","tag":"z","server":"dns.google"},
  {"type":"https","tag":"w","server":"1.1.1.1","detour":"a"},
  {"type":"udp","tag":"v","server":"9.9.9.9","detour":"a"},
  {"type":"tcp","tag":"t","server":"2001:4860:4860::8888"},
  {"type":"batch","tag":"b","servers":["x","local"]},
  {"type":"hosts","tag":"h"}
 ]}}
EOF
P=$(vg_karing_extract "$T/karing.json" | vg_parse_extract)
eq "серверы из конфига" "198.51.100.10 vpn.example.net" "$(printf '%s\n' "$P" | awk '$1=="server"{print $2}' | tr '\n' ' ' | sed 's/ $//')"
eq "DNS без detour, только адресом (local/dhcp/batch — мимо)" "1.1.1.1 2001:4860:4860::8888 8.8.8.8" "$(printf '%s\n' "$P" | awk '$1=="dns"{print $2}' | tr '\n' ' ' | sed 's/ $//')"
eq "DNS по имени — отдельно, сторож его не берёт" "dns.google" "$(printf '%s\n' "$P" | awk '$1=="dnsname"{print $2}')"
eq "резолверов из конфига больше нет" "" "$(printf '%s\n' "$P" | grep '^resolver')"
eq "мусорные адреса отброшены, не протекли" "" "$(printf '%s\n' "$P" | grep -v '^bad ' | grep -E '160\.79|0\.0\.0\.0|a b' )"
eq "отброшенные посчитаны" 1 "$(printf '%s\n' "$P" | awk '$1=="bad"' | wc -l | awk '{print ($1 >= 2)}')"
eq "не JSON → пусто, rc=0" "" "$(printf 'не json' > "$T/bad.json"; vg_karing_extract "$T/bad.json" | vg_parse_extract)"
eq "JSON-массив → пусто" "" "$(printf '[1,2]' > "$T/arr.json"; vg_karing_extract "$T/arr.json" | vg_parse_extract)"
eq "vg_provider_extract: выжимка" "$(vg_karing_extract "$T/karing.json")" "$(HOME="$T/h" ; mkdir -p "$T/h/$(dirname "$VG_PROVIDER_CONF")"; cp "$T/karing.json" "$T/h/$VG_PROVIDER_CONF"; HOME="$T/h" vg_provider_extract)"
eq "vg_provider_extract: нет конфига → error missing, rc=1" "error missing 1" "$(HOME="$T/none" vg_provider_extract | cut -d' ' -f1-2 | tr '\n' ' '; HOME="$T/none" vg_provider_extract >/dev/null; echo $?)"
fi

# DNS-over-HTTPS: адрес запроса и разбор ответа
eq "doh url cloudflare" "https://1.1.1.1/dns-query?name=a.ru&type=A" "$(vg_doh_url 1.1.1.1 a.ru A)"
eq "doh url google" "https://8.8.8.8/resolve?name=a.ru&type=AAAA" "$(vg_doh_url 8.8.8.8 a.ru AAAA)"
J='{"Status":0,"Answer":[{"name":"a.ru","type":5,"data":"b.ru."},{"name":"b.ru","type":1,"data":"203.0.113.20"},{"type":28,"data":"2001:db8::5"},{"type":16,"data":"txt"}]}'
eq "doh: A и AAAA, без CNAME/TXT" "203.0.113.20 2001:db8::5" "$(printf '%s' "$J" | vg_jq -r "$VG_DOH_JQ" | paste -sd' ' -)"
eq "doh: NXDOMAIN — пусто" "" "$(printf '{"Status":3}' | vg_jq -r "$VG_DOH_JQ")"
eq "doh: мусор — пусто" "" "$(printf 'oops' | vg_jq -r "$VG_DOH_JQ" 2>/dev/null)"

# jq: есть встроенный или bin/jq (macOS 14: ./tools/get-jq.sh); список сумм для установщика — строгий.
# Обновление с версии без tools/jq.sha256 идёт прежней копией установщика, а она этот файл не копирует:
# тогда проверки списка пропускаем (как блок Karing при другом адаптере)
eq "jq запускается (macOS 14 — ./tools/get-jq.sh)" 0 "$(rc vg_jq --version)"
JL="$DIR/tools/jq.sha256"
if [ -f "$JL" ]; then
  eq "jq.sha256: строки — комментарий или «sha256  jq-macos-amd64|arm64»" "" "$(grep -v -e '^#' -e '^$' "$JL" | grep -v -E '^[0-9a-f]{64}  jq-macos-(amd64|arm64)$')"
  eq "jq.sha256: по сумме на каждый процессор" "jq-macos-amd64 jq-macos-arm64" "$(grep -v '^#' "$JL" | awk 'NF {print $2}' | sort -u | paste -sd' ' -)"
  eq "jq.sha256: версия для tools/get-jq.sh" 1 "$(grep -c -E '^# Официальные сборки jq [0-9.]+: https://github\.com/jqlang/jq/releases/tag/jq-[0-9.]+$' "$JL")"
  if [ -f "$DIR/bin/jq" ]; then
    eq "bin/jq — из списка jq.sha256" 1 "$(h=$(shasum -a 256 "$DIR/bin/jq" | awk '{print $1}'); grep -c "^$h " "$JL")"
  fi
fi
N=$'Internet:\nDestination        Gateway            Flags               Netif Expire\ndefault            link#24            UCSg                utun6\ndefault            192.168.1.1        UGScIg                en0\n'
eq "физический интерфейс — не туннель" en0 "$(printf '%s' "$N" | vg_phys_iface)"
eq "только туннель — пусто" "" "$(printf 'default link#24 UCSg utun6\n' | vg_phys_iface)"

# vg_rules_complete / vg_emergency_rules
eq "правила целы" 0 "$(rc vg_rules_complete "$DIR/pf/vpnguard.rules")"
head -n 20 "$DIR/pf/vpnguard.rules" > "$T/trunc.rules"
eq "обрезанные правила — не целы" 1 "$(rc vg_rules_complete "$T/trunc.rules")"
eq "нет файла правил — не цел" 1 "$(rc vg_rules_complete "$T/none.rules")"
E=$(vg_emergency_rules "198.51.100.10" "8.8.8.8")
eq "аварийный набор без проверок владельца" "" "$(printf '%s\n' "$E" | grep -E ' (user|group) ')"
eq "аварийный набор кончается отказом" "block return out log quick all" "$(printf '%s\n' "$E" | tail -n 1)"
if [ -x /sbin/pfctl ]; then
  printf '%s\n' "$E" > "$T/emerg"; eq "аварийный набор: pfctl -n принимает" 0 "$(rc /sbin/pfctl -nf "$T/emerg")"
  vg_emergency_rules "" "" > "$T/emerg0"; eq "аварийный набор без адресов: pfctl -n принимает" 0 "$(rc /sbin/pfctl -nf "$T/emerg0")"
fi

# vg_words_uniq
eq "uniq" "1.1.1.1 8.8.8.8" "$(vg_words_uniq '8.8.8.8 1.1.1.1 8.8.8.8')"
eq "uniq пусто" "" "$(vg_words_uniq '')"

# vg_map_addrs: карта «вид имя адреса» → адреса вида
cat > "$T/map" <<'EOF'
server 198.51.100.10 198.51.100.10
server vpn.example.net 203.0.113.20
server unresolved.example -
dns 8.8.8.8 8.8.8.8
dns dns.google 8.8.4.4,8.8.8.8
EOF
eq "адреса серверов" "198.51.100.10 203.0.113.20" "$(vg_map_addrs "$T/map" server)"
eq "адреса DNS (без дублей)" "8.8.4.4 8.8.8.8" "$(vg_map_addrs "$T/map" dns)"
eq "нет карты → пусто" "" "$(vg_map_addrs "$T/nomap" server)"

# vg_addr_diff: что поменялось между картами → события
cat > "$T/new" <<'EOF'
server 198.51.100.10 198.51.100.10
server vpn.example.net 203.0.113.99
server new.example 203.0.113.5
dns dns.google 8.8.4.4,8.8.8.8
EOF
D=$(vg_addr_diff "$T/map" "$T/new" | sort)
eq "diff: новый сервер" "+ server new.example 203.0.113.5" "$(printf '%s\n' "$D" | grep '^+')"
eq "diff: сменился адрес" "~ server vpn.example.net 203.0.113.20 203.0.113.99" "$(printf '%s\n' "$D" | grep '^~')"
eq "diff: убраны" "- dns 8.8.8.8 8.8.8.8|- server unresolved.example -" "$(printf '%s\n' "$D" | grep '^-' | tr '\n' '|' | sed 's/|$//')"
eq "diff: без изменений — пусто" "" "$(vg_addr_diff "$T/map" "$T/map")"
eq "diff: старой карты нет — всё новое" 5 "$(vg_addr_diff "$T/nomap" "$T/map" | grep -c '^+')"

# vg_ru_meta: из шапки ru.cidr — sha источника и число сетей
printf '# x\n# sha256 источника: abc123\n10.0.0.0/8\n192.0.2.0/24\n\n' > "$T/ru"
eq "ru sha" abc123 "$(vg_ru_sha "$T/ru")"
eq "ru count" 2 "$(vg_ru_count "$T/ru")"
eq "ru нет файла → 0" 0 "$(vg_ru_count "$T/none")"

# vg_compose_rules: таблицы + статичные правила; разбор pfctl -n (root не нужен)
C=$(vg_compose_rules "198.51.100.10 203.0.113.20" "8.8.8.8 2001:4860:4860::8888" "$T/ru" "$DIR/pf/vpnguard.rules")
eq "compose: таблица серверов" "table <vg_servers> const { 198.51.100.10, 203.0.113.20 }" "$(printf '%s\n' "$C" | grep '^table <vg_servers>')"
eq "compose: таблица DNS" "table <vg_dns> const { 8.8.8.8, 2001:4860:4860::8888 }" "$(printf '%s\n' "$C" | grep '^table <vg_dns>')"
eq "compose: таблица РФ из файла" "table <vg_ru> const file \"$T/ru\"" "$(printf '%s\n' "$C" | grep '^table <vg_ru>')"
eq "compose: пустой список — таблица без адресов" "table <vg_servers> const" "$(vg_compose_rules "" "" "$T/ru" "$DIR/pf/vpnguard.rules" | grep '^table <vg_servers>')"
eq "compose: нет файла РФ — пустая таблица" "table <vg_ru> const" "$(vg_compose_rules "" "" "$T/none" "$DIR/pf/vpnguard.rules" | grep '^table <vg_ru>')"
eq "compose: правила целиком после таблиц" "$(cat "$DIR/pf/vpnguard.rules")" "$(printf '%s\n' "$C" | sed 1,3d)"
if [ -x /sbin/pfctl ]; then
  printf '%s\n' "$C" > "$T/composed"
  eq "compose: pfctl -n принимает набор" 0 "$(rc /sbin/pfctl -nf "$T/composed")"
  vg_compose_rules "" "" "$T/ru" "$DIR/pf/vpnguard.rules" > "$T/composed0"
  eq "compose: pfctl -n принимает пустые таблицы" 0 "$(rc /sbin/pfctl -nf "$T/composed0")"
fi

echo "PASS=$PASSN FAIL=$FAILN"
[ "$FAILN" = 0 ]

# vpnguard — общие чистые функции (без побочных эффектов). Подключается через `.`.
# Используется демоном (root), CLI и тестами. Только bash 3.2-совместимый синтаксис.

VG_BASE="/Library/Application Support/VPNGuard"
VG_ANCHOR="com.apple/999.vpnguard"
VG_MAX_PAUSE=86400   # сутки
# jq. В macOS 15 и новее — встроенный /usr/bin/jq. В macOS 14 его нет: install.sh ставит копию root —
# официальную сборку, сверив её sha256 со списком tools/jq.sha256. jq из каталогов пользователя
# (Homebrew и т. п.) отсюда не берём никогда: сторож от root исполнил бы файл, который может подменить
# любой процесс пользователя. Тесты и precheck (от пользователя) подставляют сюда bin/jq из исходников.
VG_JQ_LOCAL="$VG_BASE/bin/jq"

# vg_parse_duration "15m" → секунды. Форматы: N (минуты), Ns, Nm, Nh. От 60 с до 24 ч, иначе rc=1.
vg_parse_duration() {
  local n unit secs
  [[ $1 =~ ^([0-9]{1,6})([smh]?)$ ]] || return 1
  n=$((10#${BASH_REMATCH[1]})); unit=${BASH_REMATCH[2]}
  case $unit in
    s) secs=$n ;;
    h) secs=$((n * 3600)) ;;
    *) secs=$((n * 60)) ;;
  esac
  (( secs >= 60 && secs <= VG_MAX_PAUSE )) || return 1
  echo "$secs"
}

# vg_effective_mode MODE UNTIL NOW → on|paused|off. Всё неизвестное → on (безопасная сторона).
vg_effective_mode() {
  case $1 in
    off) echo off ;;
    paused) if [[ $2 =~ ^[0-9]+$ ]] && (( $3 < $2 )); then echo paused; else echo on; fi ;;
    *) echo on ;;
  esac
}

# vg_jq АРГУМЕНТЫ… → jq с этими аргументами: встроенный, иначе копия VPN Guard (нет обоих — rc=127)
vg_jq() { if [ -x /usr/bin/jq ]; then /usr/bin/jq "$@"; else "$VG_JQ_LOCAL" "$@"; fi; }

# vg_kv KEY < текст → значение первой строки KEY=...
vg_kv() { sed -n "s/^$1=//p" | head -1; }

# vg_boot_id → идентификатор текущей загрузки (не чистая: читает sysctl).
# kern.boottime не годится: ядро сдвигает его при коррекции часов — была бы ложная «новая загрузка».
vg_boot_id() { sysctl -n kern.bootsessionuuid 2>/dev/null || sysctl -n kern.boottime; }

# vg_state_render MODE UNTIL BOOT → содержимое файла состояния
vg_state_render() { printf 'mode=%s\nuntil=%s\nboot=%s\n' "$1" "$2" "$3"; }

# vg_default_iface "<route -n get default>" → интерфейс маршрута по умолчанию
vg_default_iface() { printf '%s\n' "$1" | sed -n 's/^ *interface: *//p' | head -1; }

# vg_is_tunnel IFACE → rc=0 для utunN / ipsecN / pppN
vg_is_tunnel() { [[ $1 =~ ^(utun|ipsec|ppp)[0-9]+$ ]]; }

# vg_fmt_left SECS → "M:SS" или "H:MM:SS"
vg_fmt_left() {
  local s=$1
  (( s < 0 )) && s=0
  if (( s >= 3600 )); then printf '%d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
  else printf '%d:%02d' $((s / 60)) $((s % 60)); fi
}

# --- Адреса из VPN-клиента: кого pf пропускает напрямую мимо туннеля ---
# Откуда их брать, знает адаптер клиента (providers/ИМЯ/provider.sh → $BASE/provider.sh): он отдаёт
# выжимку, ядро проверяет каждую строку (vg_parse_extract) и само узнаёт адреса имён.
# Решение только по адресу назначения. Проверок владельца (user/group) в pf нет: с ними pf под своей
# блокировкой лезет в таблицу сокетов, и ядро macOS может уйти во взаимоблокировку.

VG_MAX_NAMES=64   # больше серверов и DNS в конфиге — подозрительно, лишние не берём
# Адреса имён серверов сторож узнаёт только у этих публичных резолверов — по DNS-over-HTTPS напрямую
# через физический интерфейс. Не у резолверов из конфига VPN-клиента (его может поправить агент) и не
# через туннель (там DNS перехватывает сам клиент). Провайдер видит лишь соединение с резолвером, не имя.
VG_RESOLVERS="1.1.1.1 8.8.8.8"
VG_ADDR_TTL=43200 # прежний адрес имени держим 12 ч (клиент может помнить старый адрес), потом убираем

# vg_is_ipv4 S → rc=0 для a.b.c.d (каждое от 0 до 255, без ведущих нулей: 010 pf прочёл бы как 8), без маски
vg_is_ipv4() {
  [[ $1 =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
  local i
  for i in 1 2 3 4; do (( BASH_REMATCH[i] <= 255 )) || return 1; done
}

# vg_is_ipv6 S → rc=0 для адреса IPv6 без маски (группы от 1 до 4 hex, не больше одного «::»)
vg_is_ipv6() {
  local s=$1 t g n=0 IFS=:
  [[ $s =~ ^[0-9A-Fa-f:]{2,39}$ ]] && [[ $s == *:* ]] || return 1
  case $s in *:::*|*::*::*) return 1 ;; esac
  if [[ $s == :* && $s != ::* ]] || [[ $s == *: && $s != *:: ]]; then return 1; fi
  t=${s/::/:}
  for g in $t; do
    [ -z "$g" ] && continue
    [ ${#g} -le 4 ] || return 1
    n=$((n + 1))
  done
  if [[ $s == *::* ]]; then (( n <= 7 )); else (( n == 8 )); fi
}

# vg_is_host S → rc=0 для имени хоста: метки из букв, цифр и дефиса, есть точка, последняя метка с буквы
vg_is_host() {
  [ ${#1} -le 253 ] || return 1
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

# vg_parse_extract < выжимка адаптера («server АДРЕС», «dns ТИП АДРЕС», «bad …») → «server ИМЯ|IP»,
# «dns IP», «dnsname ИМЯ», «bad …». Выжимке не доверяем: всё, что не адрес и не имя хоста, — «bad».
# DNS-серверы — только адресом: DNS по имени разрешился бы во что угодно и открыл бы к этому адресу
# порты DNS (443 в том числе), поэтому «dnsname» сторож не берёт, только пишет в журнал.
# Отсортировано, без повторов.
vg_parse_extract() {
  local kind a b
  while read -r kind a b; do
    case $kind in
      server)
        if vg_is_ipv4 "$a" || vg_is_ipv6 "$a" || vg_is_host "$a"; then echo "server $a"; else echo "bad $a"; fi ;;
      dns)
        if vg_is_ipv4 "$b" || vg_is_ipv6 "$b"; then echo "dns $b"
        elif vg_is_host "$b"; then echo "dnsname $b"
        else echo "bad $b"; fi ;;
      bad) echo "bad $a${b:+ $b}" ;;
    esac
  done | sort -u
}

# Фильтр jq для ответа DNS-over-HTTPS в JSON (Cloudflare /dns-query, Google /resolve): адреса A и AAAA
VG_DOH_JQ='.Answer[]? | select(.type == 1 or .type == 28) | .data | strings'

# vg_doh_url РЕЗОЛВЕР ИМЯ ТИП → адрес запроса DNS-over-HTTPS в JSON (имя — только после vg_is_host)
vg_doh_url() {
  case $1 in
    8.8.8.8|8.8.4.4) printf 'https://%s/resolve?name=%s&type=%s\n' "$1" "$2" "$3" ;;
    *)               printf 'https://%s/dns-query?name=%s&type=%s\n' "$1" "$2" "$3" ;;
  esac
}

# vg_phys_iface < netstat -rn -f inet → физический интерфейс маршрута по умолчанию (не туннель)
vg_phys_iface() { awk '$1 == "default" && $NF !~ /^(utun|ipsec|ppp|lo)[0-9]*$/ { print $NF; exit }'; }

# vg_words_uniq "a b a" → "a b": слова через пробел, по порядку сортировки, без повторов
vg_words_uniq() { printf '%s\n' "$1" | tr ' ' '\n' | grep -v '^$' | sort -u | paste -sd' ' - ; }

# vg_map_addrs КАРТА ВИД → адреса вида через пробел. Карта — строки «вид имя адрес,адрес» («-» — неизвестны).
vg_map_addrs() {
  [ -f "$1" ] || return 0
  awk -v k="$2" '$1 == k && $3 != "-" { n = split($3, a, ","); for (i = 1; i <= n; i++) print a[i] }' "$1" | sort -u | paste -sd' ' -
}

# vg_addr_diff СТАРАЯ НОВАЯ → «+ вид имя адреса» (новое), «~ вид имя старые новые» (сменились адреса),
# «- вид имя старые» (пропало). Нет старой карты — всё новое.
vg_addr_diff() {
  local new=$2
  [ -f "$new" ] || new=/dev/null
  awk -v oldf="$1" '
    BEGIN { while ((getline l < oldf) > 0) { split(l, f, " "); if (f[1] != "") old[f[1] " " f[2]] = f[3] } }
    NF >= 3 { k = $1 " " $2; seen[k] = 1
              if (!(k in old)) print "+", k, $3
              else if (old[k] != $3) print "~", k, old[k], $3 }
    END { for (k in old) if (!(k in seen)) print "-", k, old[k] }' "$new"
}

# vg_ru_sha ФАЙЛ → sha256 источника списка из шапки ru.cidr (у Karing — его geoip/ru.srs)
vg_ru_sha() { sed -n 's/^# sha256 источника: *\([0-9a-f]*\).*/\1/p' "$1" 2>/dev/null | head -1; }

# vg_ru_count ФАЙЛ → число сетей в ru.cidr (строки без # и не пустые); нет файла → 0
vg_ru_count() {
  [ -f "$1" ] || { echo 0; return 0; }
  grep -c -v -e '^#' -e '^[[:space:]]*$' "$1" || true
}

# vg_table_line ИМЯ "адрес адрес …" → строка pf «table <ИМЯ> const { адрес, адрес }» (пусто — без скобок)
vg_table_line() {
  local list
  list=$(printf '%s' "$2" | tr -s ' ' | sed 's/^ //; s/ $//; s/ /, /g')
  if [ -n "$list" ]; then printf 'table <%s> const { %s }\n' "$1" "$list"; else printf 'table <%s> const\n' "$1"; fi
}

# vg_rules_complete ФАЙЛ_ПРАВИЛ → rc=0, если файл правил цел: последняя содержательная строка —
# финальный отказ. Набор из одних таблиц pf считает правильным, и якорь остался бы без правил.
vg_rules_complete() {
  [ -s "$1" ] && [ "$(grep -v -e '^#' -e '^[[:space:]]*$' "$1" | tail -n 1)" = "block return out log quick all" ]
}

# vg_emergency_rules "серверы" "DNS" → аварийный набор, не зависящий от файлов: петля, туннели,
# VPN-серверы и DNS клиента (если переданы), DHCP, локалка, остальное — отказ. Грузится, когда
# основной набор собрать или загрузить не вышло: лучше без российских сайтов, чем без защиты.
vg_emergency_rules() {
  local i t=""
  for i in $(seq 0 63); do t="$t utun$i"; done
  printf 'tun_if = "{%s ipsec0 ipsec1 ipsec2 ipsec3 ppp0 ppp1 ppp2 ppp3 }"\n' "$t"
  vg_table_line vg_servers "$1"
  vg_table_line vg_dns "$2"
  printf '%s\n' 'pass out quick on lo0 all no state' 'pass out quick on $tun_if all no state' \
    'pass out quick to <vg_servers> no state' \
    'pass out quick proto { tcp udp } to <vg_dns> port { 53 443 853 } no state' \
    'block return out quick proto { tcp udp } to any port { 53 853 }' \
    'pass out quick to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255, fe80::/10, fc00::/7, ff00::/8 } no state' \
    'pass out quick proto udp from any port 68 to any port 67 no state' \
    'block return out log quick all'
}

# vg_compose_rules "серверы" "DNS" ФАЙЛ_РФ ФАЙЛ_ПРАВИЛ → полный набор для якоря: три таблицы + правила.
# Нет файла РФ — таблица пустая: российские сайты напрямую не откроются, но набор загрузится
# (иначе ошибка загрузки оставила бы якорь без правил — без защиты).
vg_compose_rules() {
  vg_table_line vg_servers "$1"
  vg_table_line vg_dns "$2"
  if [ -r "$3" ]; then printf 'table <vg_ru> const file "%s"\n' "$3"; else vg_table_line vg_ru ""; fi
  cat "$4"
}

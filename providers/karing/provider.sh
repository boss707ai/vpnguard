# Адаптер VPN Guard для Karing (https://github.com/KaringX/karing), ядро Karing — sing-box.
# Подключается через `.` (CLI, сторож, precheck, тесты): только определения, без команд на верхнем
# уровне. Установщик ставит его как "$BASE/provider.sh" (root, 644); как и весь код, он проходит diff и «y».
# Что адаптер должен определить и как сделать свой — docs/ADAPTERS.md.

VG_PROVIDER=karing
VG_PROVIDER_TITLE="Karing"
# Конфиг ядра, который Karing пишет при подключении (путь от домашнего каталога пользователя)
VG_PROVIDER_CONF="Library/Group Containers/group.com.nebula.karing/service_core.json"
# Файл, из которого Karing берёт свой список российских IP. Его sha256 записан в шапке pf/ru.cidr:
# установщик, precheck и сторож сверяют, не обновил ли Karing список. Пусто — сверки нет.
VG_PROVIDER_RU_SRC="/Applications/Karing.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/datas/geoip/ru.srs"
# Локальный прокси клиента «всё напрямую»: самотест и приёмка проверяют, что через него за рубеж
# не уйти. Пусто — такого прокси у клиента нет.
VG_PROVIDER_PROXY_DIRECT="127.0.0.1:3065"
# Строка, по которой VPN клиента находится в scutil --nc list (precheck: подключён ли клиент)
VG_PROVIDER_NC_MATCH="com.nebula.karing"

# Фильтр jq: конфиг sing-box от Karing → «server АДРЕС», «dns ТИП АДРЕС», «bad <значение в JSON>».
# Серверы — все outbounds с полем server. DNS — только без detour (те, к которым ядро Karing ходит
# напрямую) и сетевых типов; local/dhcp/hosts/batch — мимо. Строка с переводом строки или пробелом
# становится «bad» в виде JSON и не может выдать себя за другую запись.
VG_KARING_JQ='
def cls($kind): if (type == "string") and test("^[A-Za-z0-9.:-]{1,253}$") then "\($kind) \(.)" else "bad " + (tojson | .[0:80]) end;
(try (.outbounds[]? | objects | select(has("server")) | .server | cls("server")) catch empty),
(try (.dns.servers[]? | objects | select((.detour // "") == "")
      | select((.type // "") | strings | test("^(udp|tcp|tls|https|quic|h3)$"))
      | select(has("server")) | .type as $t | .server | cls("dns \($t)")) catch empty)'

# vg_karing_extract ФАЙЛ → строки фильтра VG_KARING_JQ (не JSON или чужая структура → пусто)
vg_karing_extract() { /usr/bin/jq -r "$VG_KARING_JQ" "$1" 2>/dev/null || true; }

# vg_provider_extract → выжимка для сторожа. Запускается от пользователя, не от root: данные других
# приложений macOS отдаёт только процессам пользователя с разрешением. Успех — строки «server АДРЕС»,
# «dns ТИП АДРЕС», «bad …» и rc=0 (сторож всё равно проверит каждую строку). Ошибка — одна строка
# «error КОД текст» и rc=1; КОД: denied (macOS не пускает), missing (нет конфига), unreadable.
vg_provider_extract() {
  local conf="$HOME/$VG_PROVIDER_CONF" out
  if out=$(/usr/bin/jq -r "$VG_KARING_JQ" "$conf" 2>&1); then printf '%s\n' "$out"; return 0; fi
  if [[ $out == *"not permitted"* ]]; then echo "error denied macOS не пускает к настройкам Karing ($conf) — разреши доступ (памятка)"
  elif [ ! -e "$conf" ]; then echo "error missing нет файла настроек Karing: $conf"
  else echo "error unreadable не прочитал настройки Karing: ${out:0:120}"; fi
  return 1
}

# vg_provider_precheck → проверки клиента для precheck.sh через его ok/warn/stop. Ничего не меняет.
# Общее (macOS, интерфейс, серверы через публичный DNS, список российских сетей) precheck проверяет
# сам по выжимке, которую эта функция кладёт в VG_PRECHECK_EXTRACT (пусто — не прочиталась).
vg_provider_precheck() {
  local conf="$HOME/$VG_PROVIDER_CONF" kvpn def out geosite geoip
  VG_PRECHECK_EXTRACT=""
  if [ -d /Applications/Karing.app ]; then ok "Karing установлен"
  else stop "Karing не найден в /Applications"; fi
  kvpn=$(scutil --nc list 2>/dev/null | grep "$VG_PROVIDER_NC_MATCH" | head -1)
  def=$(netstat -rn -f inet 2>/dev/null | awk '$1 == "default" { print $NF; exit }')
  if [[ $kvpn == *"(Connected)"* ]] && vg_is_tunnel "$def"; then ok "Karing подключён, интернет идёт через туннель ($def)"
  elif [ -z "$kvpn" ]; then stop "Karing не работает как системный VPN (режим TUN): VPN Guard рассчитан на туннель"
  else warn "Karing сейчас не подключён: подключи его и запусти проверку снова — так проверка полнее"; fi

  if out=$(vg_provider_extract); then
    ok "настройки Karing читаются"; VG_PRECHECK_EXTRACT=$out
  else
    case $out in
      "error denied"*)  stop "macOS не пускает Терминал к данным Karing. Запусти проверку снова и в окне «…хочет получить доступ к данным других приложений» нажми «Разрешить» (или: Системные настройки → Конфиденциальность и безопасность)" ;;
      "error missing"*) stop "нет $conf: подключи Karing хотя бы раз и запусти проверку снова" ;;
      *)                stop "${out#error unreadable }" ;;
    esac
    return 0
  fi

  # Напрямую мимо туннеля защита пускает только в российские IP (тот же список geoip:ru, что у Karing).
  # Остальные «прямые» правила Karing под защитой не откроются: сайт будет недоступен.
  geosite=$(/usr/bin/jq -r '[.route.rules[]? | select(.outbound == "direct_out") | .rule_set[]? | select(startswith("geosite:"))] | unique | join(" ")' "$conf" 2>/dev/null)
  geoip=$(/usr/bin/jq -r '[.route.rules[]? | select(.outbound == "direct_out") | .rule_set[]? | select(startswith("geoip:") and . != "geoip:ru")] | unique | join(" ")' "$conf" 2>/dev/null)
  if [ -n "$geosite" ]; then
    warn "в Karing включены прямые правила по доменам ($geosite). Выключи «по доменам» (geosite) в «Автоматически добавлять основные правила», по IP (geoip) оставь, и переподключи Karing. Или запусти providers/karing/geosite-off.sh — сделает это сам, с копией настроек"
  else ok "прямых правил по доменам (geosite) в Karing нет"; fi
  [ -z "$geoip" ] || warn "Karing пускает напрямую $geoip — защита пускает напрямую только российские IP, эти сайты не откроются"
}

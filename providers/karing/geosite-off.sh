#!/bin/bash
# Выключить в Karing прямые правила региона по доменам (geosite), правила по IP (geoip) оставить.
# Под VPN Guard по доменам напрямую не открыть: российский сайт на зарубежном хостинге защита не
# пустит мимо туннеля. С выключенным geosite такие сайты идут через VPN.
#   providers/karing/geosite-off.sh           — сделать: копия настроек → Karing закрыть → правка → Karing запустить
#   providers/karing/geosite-off.sh --check   — только показать, что будет сделано; ничего не меняет
# Karing закрывается секунд на пять: на это время связь пропадает. Пароль не нужен.
# Вернуть как было: закрыть Karing, скопировать karing_setting.json из папки копии обратно, запустить Karing.
set -u
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
[ "$(id -u)" != 0 ] || { echo "Запускай без sudo."; exit 1; }
G="${VG_KARING_DIR:-$HOME/Library/Group Containers/group.com.nebula.karing}"   # переменная — для тестов
F="$G/karing_setting.json"
SC="$G/service_core.json"
say() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

[ -r "$F" ] || { say "не прочитал $F (Karing не стоит или macOS не даёт доступ Терминалу)"; exit 1; }
cur=$(/usr/bin/jq -r '.rule_sets.auto_append_region_geosite' "$F" 2>/dev/null)
case $cur in
  false) say "уже выключено: по доменам (geosite) — нет, по IP (geoip) — $(/usr/bin/jq -r '.rule_sets.auto_append_region_geoip' "$F")"; exit 0 ;;
  true)  ;;
  *)     say "в настройках этой версии Karing нет rule_sets.auto_append_region_geosite — выключи вручную"; exit 1 ;;
esac

edit() { # файл → правленая копия; rc 0 — правка ровно одна и только в этом ключе
  sed -E 's/"auto_append_region_geosite"( *): *true/"auto_append_region_geosite"\1: false/' "$1" > "$2" || return 1
  [ "$(diff "$1" "$2" | grep -c '^[<>]')" = 2 ] || return 1
  [ "$(/usr/bin/jq -n --slurpfile a "$1" --slurpfile b "$2" '
    ($b[0].rule_sets.auto_append_region_geosite == false) and
    (($a[0] | del(.rule_sets.auto_append_region_geosite)) == ($b[0] | del(.rule_sets.auto_append_region_geosite)))')" = true ]
}
T=$(mktemp "${TMPDIR:-/tmp}/karing-setting.XXXXXX")
trap 'rm -f "$T"' EXIT
edit "$F" "$T" || { say "правка не прошла проверку — ничего не трогаю"; exit 1; }
VPN=$(scutil --nc list 2>/dev/null | sed -n 's/.*"\([^"]*\)" *\[VPN:com\.nebula\.karing\].*/\1/p' | head -1)
if [ "${1:-}" = --check ]; then
  say "будет: rule_sets.auto_append_region_geosite true → false (geoip остаётся $(/usr/bin/jq -r '.rule_sets.auto_append_region_geoip' "$F"))"
  say "Karing закроется и запустится снова; VPN в системе: ${VPN:-не найден}"
  exit 0
fi

# 1. копия
B="$G/vpnguard-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$B" && cp -p "$G"/*.json "$B/" || { say "копия не удалась — ничего не трогаю"; exit 1; }
for x in "$G"/*.json; do cmp -s "$x" "$B/$(basename "$x")" || { say "копия не совпала: $(basename "$x") — ничего не трогаю"; exit 1; }; done
say "копия настроек: $B"
sc0=$(stat -f %m "$SC" 2>/dev/null || echo 0)

# 2. Karing закрыть штатно: запущенный Karing вернул бы старое значение из памяти
say "закрываю Karing…"
osascript -e 'with timeout of 15 seconds' -e 'tell application "Karing" to quit' -e 'end timeout' >/dev/null 2>&1
for i in $(seq 1 40); do pgrep -x Karing >/dev/null || break; sleep 0.5; done
if pgrep -x Karing >/dev/null; then say "Karing не закрылся за 20 с — ничего не правлю. Закрой его сам и запусти скрипт снова"; exit 1; fi

# 3. туннель вниз — при запуске Karing соберёт конфиг заново
if [ -n "$VPN" ] && ! scutil --nc status "$VPN" 2>/dev/null | head -1 | grep -qx Disconnected; then
  scutil --nc stop "$VPN"
  for i in $(seq 1 30); do scutil --nc status "$VPN" 2>/dev/null | head -1 | grep -qx Disconnected && break; sleep 0.5; done
fi

# 4. правка (заново — Karing мог переписать файл при выходе)
if edit "$F" "$T"; then cat "$T" > "$F"; say "правка внесена: по доменам (geosite) выключено, по IP (geoip) — $(/usr/bin/jq -r '.rule_sets.auto_append_region_geoip' "$F")"
else say "после выхода Karing правка не прошла проверку — файл не трогаю"; fi

# 5. Karing запустить и дождаться подключения
open -a Karing
say "Karing запущен, жду подключения (если он не подключается сам при запуске — подключи его)…"
for i in $(seq 1 90); do
  [ -n "$VPN" ] && scutil --nc status "$VPN" 2>/dev/null | head -1 | grep -qx Connected && [ "$(stat -f %m "$SC" 2>/dev/null || echo 0)" != "$sc0" ] && break
  sleep 1
done
if [ -n "$VPN" ] && scutil --nc status "$VPN" 2>/dev/null | head -1 | grep -qx Connected; then say "Karing подключён"
else say "Karing пока не подключён — подключи его в окне Karing"; fi
left=$(/usr/bin/jq -r '[.route.rules[]? | select(.outbound == "direct_out") | .rule_set[]? | select(startswith("geosite:"))] | join(" ")' "$SC" 2>/dev/null)
if [ -z "$left" ]; then say "в рабочем конфиге Karing прямых правил по доменам больше нет"
else say "в рабочем конфиге Karing ещё есть: $left — переподключи Karing"; fi

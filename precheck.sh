#!/bin/bash
# Проверка до установки: подойдёт ли VPN Guard этому Mac и этому VPN-клиенту. В системе ничего не меняет и
# не ставит, пароль не нужен; в macOS 14 скачивает jq в bin/jq рядом с исходниками (tools/get-jq.sh).
# Запуск из папки с исходниками, VPN-клиент подключён:
#   ./precheck.sh [--provider ИМЯ]   (адаптер из providers/; по умолчанию — установленный, иначе karing)
# Журнал: precheck.log рядом (его можно приложить к issue).
set -u
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
DIR="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" != 0 ] || { echo "Запускай без sudo: ./precheck.sh"; exit 1; }
BASE="/Library/Application Support/VPNGuard"
PROVIDER=""
[ "${1:-}" = --provider ] && PROVIDER=${2:-}
[ -n "$PROVIDER" ] || PROVIDER=$(sed -n 's/^VG_PROVIDER=\([a-z0-9-]*\)$/\1/p' "$BASE/provider.sh" 2>/dev/null | head -1)
PROVIDER=${PROVIDER:-karing}
[[ $PROVIDER =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && [ -f "$DIR/providers/$PROVIDER/provider.sh" ] ||
  { echo "Нет адаптера «${PROVIDER}». Есть: $(ls "$DIR/providers" | paste -sd' ' -)"; exit 1; }
. "$DIR/lib/state.sh"
. "$DIR/providers/$PROVIDER/provider.sh"
exec > >(tee "$DIR/precheck.log") 2>&1

OKN=0; WARNN=0; STOPN=0
ok()   { OKN=$((OKN + 1));     printf 'ок        %s\n' "$*"; }
warn() { WARNN=$((WARNN + 1)); printf 'ВНИМАНИЕ  %s\n' "$*"; }
stop() { STOPN=$((STOPN + 1)); printf 'СТОП      %s\n' "$*"; }

echo "== Mac"
v=$(sw_vers -productVersion)
# jq: встроенный (macOS 15+). В macOS 14 — официальная сборка с sha256 из tools/jq.sha256 для этого
# процессора: bin/jq из исходников, иначе уже стоящая копия VPN Guard. Подходящего нет — скачиваем в bin/jq
# (tools/get-jq.sh). Правила те же, что у установщика: «ок» здесь значит, что установщик этот jq возьмёт
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then JQ_ARCH=jq-macos-arm64; else JQ_ARCH=jq-macos-amd64; fi
jq_fits() { # файл → rc=0: sha256 из списка именно для этого процессора, и он запускается
  local h; h=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
  [ -n "$h" ] && awk -v h="$h" -v a="$JQ_ARCH" '$1 == h && $2 == a { f = 1 } END { exit !f }' "$DIR/tools/jq.sha256" &&
    "$1" --version >/dev/null 2>&1
}
if [ "${v%%.*}" -lt 14 ]; then stop "macOS $v: нужна macOS 14 или новее"
elif [ -x /usr/bin/jq ]; then ok "macOS $v (jq встроенный)"
else
  # качаем, если bin/jq есть, но не подходит (например, сменилась версия в списке), или подходящего нет нигде
  if [ -e "$DIR/bin/jq" ]; then jq_fits "$DIR/bin/jq" || need_jq=1; else jq_fits "$VG_JQ_LOCAL" || need_jq=1; fi
  if [ "${need_jq:-0}" = 1 ]; then
    echo "          встроенного jq нет — скачиваю официальную сборку (tools/get-jq.sh):"
    "$DIR/tools/get-jq.sh" 2>&1 | sed -e '/^дальше:/d' -e 's/^/            /'   # «дальше: ./precheck.sh» здесь лишнее
  fi
  if jq_fits "$DIR/bin/jq"; then
    VG_JQ_LOCAL="$DIR/bin/jq"; ok "macOS $v: встроенного jq нет, установщик поставит bin/jq ($("$DIR/bin/jq" --version), sha256 из tools/jq.sha256)"
  elif jq_fits "$VG_JQ_LOCAL"; then ok "macOS $v: jq — копия VPN Guard ($VG_JQ_LOCAL)"
  else stop "macOS $v: встроенного jq нет, и скачать его не вышло — проверь интернет и запусти ./tools/get-jq.sh"; fi
fi
if xcode-select -p >/dev/null 2>&1; then ok "Xcode Command Line Tools есть (из них собирается значок в строке меню)"
else stop "нет Xcode Command Line Tools: поставь командой xcode-select --install и запусти проверку снова"; fi
PHYS=$(netstat -rn -f inet 2>/dev/null | vg_phys_iface)
if [ -n "$PHYS" ]; then ok "физический интерфейс: $PHYS"
else stop "не нашёл физический интерфейс с маршрутом по умолчанию (Wi-Fi или Ethernet)"; fi

echo "== $VG_PROVIDER_TITLE (адаптер providers/$PROVIDER)"
vg_provider_precheck   # что знает только адаптер; выжимку кладёт в VG_PRECHECK_EXTRACT

if [ -n "${VG_PRECHECK_EXTRACT:-}" ]; then
  parsed=$(printf '%s\n' "$VG_PRECHECK_EXTRACT" | vg_parse_extract)
  servers=$(printf '%s\n' "$parsed" | sed -n 's/^server //p')
  if [ -n "$servers" ]; then ok "VPN-серверы в профиле: $(printf '%s\n' "$servers" | paste -sd' ' - | sed 's/ /, /g')"
  else stop "в настройках $VG_PROVIDER_TITLE не нашёл ни одного VPN-сервера"; fi
  bad=$(printf '%s\n' "$parsed" | sed -n 's/^bad //p' | head -5 | paste -sd' ' -)
  [ -z "$bad" ] || warn "странные адреса в настройках $VG_PROVIDER_TITLE, защита их не возьмёт: $bad"
  # Имена серверов защита узнаёт у публичных DNS (Cloudflare, Google), а не у клиента: имя, которого
  # там нет, она не пропустит, и клиент до такого сервера не достучится.
  for n in $servers; do
    vg_is_ipv4 "$n" || vg_is_ipv6 "$n" && continue
    a=""
    for r in $VG_RESOLVERS; do
      a=$(curl -s --max-time 5 -H 'accept: application/dns-json' "$(vg_doh_url "$r" "$n" A)" 2>/dev/null |
            vg_jq -r "$VG_DOH_JQ" 2>/dev/null | paste -sd' ' -)
      [ -n "$a" ] && break
    done
    if [ -n "$a" ]; then ok "сервер $n по публичному DNS: $a"
    else stop "сервер $n не находится через публичный DNS (1.1.1.1, 8.8.8.8): защита не пропустит $VG_PROVIDER_TITLE к нему"; fi
  done
fi

echo "== Список российских сетей"
want=$(sed -n 's/^# sha256 источника: *\([0-9a-f]*\).*/\1/p' "$DIR/pf/ru.cidr" | head -1)
if [ -z "${VG_PROVIDER_RU_SRC:-}" ]; then ok "у адаптера $VG_PROVIDER_TITLE нет своего списка — pf/ru.cidr берётся как есть ($(vg_ru_count "$DIR/pf/ru.cidr") сетей)"
else
  have=$(shasum -a 256 "$VG_PROVIDER_RU_SRC" 2>/dev/null | awk '{print $1}')
  if [ -n "$have" ] && [ "$want" = "$have" ]; then ok "pf/ru.cidr сделан из того же списка, что у твоего $VG_PROVIDER_TITLE"
  else warn "pf/ru.cidr сделан из другой версии $VG_PROVIDER_TITLE. Пересобери из своего: python3 tools/srs2cidr.py > pf/ru.cidr"; fi
fi

echo "== Что уже стоит"
if [ ! -d "$BASE" ]; then ok "VPN Guard не стоит — первая установка"
elif [ -f "$BASE/ru.cidr" ]; then ok "VPN Guard уже стоит — обновление: vpnguard update"
else warn "стоит старая версия (без списка российских сетей) — обновись: sudo ./install.sh"; fi

echo
echo "== Итог: ок $OKN · внимание $WARNN · стоп $STOPN"
if [ "$STOPN" -gt 0 ]; then echo "ВЫВОД: пока не ставь — исправь пункты СТОП и запусти проверку снова"
elif [ "$WARNN" -gt 0 ]; then echo "ВЫВОД: ставить можно, но сначала разберись с пунктами ВНИМАНИЕ. Установка: sudo ./install.sh"
else echo "ВЫВОД: совместимо — можно ставить: sudo ./install.sh"; fi
echo "журнал: $DIR/precheck.log"
[ "$STOPN" = 0 ]

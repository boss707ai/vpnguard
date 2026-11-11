#!/bin/bash
# Полное удаление vpnguard: vpnguard uninstall  (= sudo -k "/Library/Application Support/VPNGuard/uninstall.sh")
# /etc/pf.conf vpnguard не трогает никогда — восстанавливать нечего.
set -uo pipefail
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
[ "$(id -u)" = 0 ] || { echo "Нужен sudo: sudo $0"; exit 1; }
U="${SUDO_USER:-$(stat -f %Su /dev/console)}"
UIDN=$(id -u "$U" 2>/dev/null || true)
UHOME=$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')
BASE="/Library/Application Support/VPNGuard"
ANCHOR="com.apple/999.vpnguard"
trap 'sudo -u "$U" /usr/bin/sudo -K 2>/dev/null || true' EXIT   # сбросить кэш sudo пользователя

echo "== Иконка и команда"
[ -n "$UIDN" ] && launchctl bootout "gui/$UIDN/local.vpnguard.menubar" 2>/dev/null
rm -f /Library/LaunchAgents/local.vpnguard.menubar.plist
L="$UHOME/.local/bin/vpnguard"
if [ -n "$UHOME" ] && [ -L "$L" ] && [ "$(readlink "$L")" = "$BASE/vpnguard" ]; then sudo -u "$U" rm -f "$L"; fi

echo "== Сторож"
launchctl bootout system/local.vpnguard 2>/dev/null
rm -f /Library/LaunchDaemons/local.vpnguard.plist

echo "== Правила и pf"
pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1
pfctl -a "$ANCHOR" -F Tables >/dev/null 2>&1
if [ -f "$BASE/pf.tokens" ]; then
  while read -r t; do [ -n "$t" ] && pfctl -X "$t" >/dev/null 2>&1; done < "$BASE/pf.tokens"
fi
BEFORE=$(cat "$BASE/pf-before" 2>/dev/null || echo "?")
NOW=$(pfctl -s info 2>/dev/null | awk '/^Status/{print $2}')

rm -rf "$BASE"
rm -f /Library/Logs/VPNGuard.log /Library/Logs/VPNGuard.log.1 /Library/Logs/VPNGuard.err.log

echo "== Проверка"
ok=1
if [ -z "$(pfctl -a "$ANCHOR" -sr 2>/dev/null)" ]; then echo "якорь пуст: да"; else echo "якорь пуст: НЕТ"; ok=0; fi
if [ ! -e /Library/LaunchDaemons/local.vpnguard.plist ] && [ ! -e /Library/LaunchAgents/local.vpnguard.menubar.plist ] && [ ! -e "$BASE" ]; then
  echo "файлы удалены: да"; else echo "файлы удалены: НЕТ"; ok=0; fi
if [ "$BEFORE" = "$NOW" ]; then echo "pf: $NOW (как до установки)"; else echo "pf: сейчас $NOW, до установки было $BEFORE"; ok=0; fi
if [ $ok = 1 ]; then echo "Удалено полностью. Исходники остались в ~/Tools/vpnguard."; else echo "Есть расхождения — см. выше."; exit 1; fi

#!/bin/bash
# Скачать официальную сборку jq для macOS 14. В macOS 15 и новее jq встроенный — скачивать не нужно.
# Без sudo, в системе ничего не меняет: файл ложится в bin/jq рядом с исходниками (bin/ в .gitignore).
# Установщик (sudo ./install.sh) сверит его sha256 со списком tools/jq.sha256 и поставит копию root.
#   ./tools/get-jq.sh
set -u
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(id -u)" != 0 ] || { echo "Запускай без sudo: ./tools/get-jq.sh"; exit 1; }
if [ -x /usr/bin/jq ]; then echo "в этой macOS есть встроенный /usr/bin/jq — скачивать не нужно"; exit 0; fi
# версия — из шапки списка сумм: сменить jq значит поправить один файл, tools/jq.sha256
V=$(sed -n 's|^# Официальные сборки jq [0-9.]*: https://github\.com/jqlang/jq/releases/tag/jq-\([0-9.]*\)$|\1|p' "$DIR/tools/jq.sha256" | head -1)
[ -n "$V" ] || { echo "в tools/jq.sha256 нет строки с версией jq"; exit 1; }
# архитектура процессора, а не терминала: под Rosetta uname -m сказал бы x86_64 и на Apple Silicon
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then NAME=jq-macos-arm64; else NAME=jq-macos-amd64; fi
WANT=$(awk -v n="$NAME" '$2 == n { print $1; exit }' "$DIR/tools/jq.sha256")
[ -n "$WANT" ] || { echo "нет суммы для $NAME в tools/jq.sha256"; exit 1; }
mkdir -p "$DIR/bin"
TMP=$(mktemp "$DIR/bin/jq.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT
echo "скачиваю jq $V ($NAME) с github.com/jqlang/jq"
curl -q -fsSL --max-time 120 --proto '=https' -o "$TMP" "https://github.com/jqlang/jq/releases/download/jq-$V/$NAME" ||
  { echo "не скачал — проверь интернет и запусти снова"; exit 1; }
HAVE=$(shasum -a 256 "$TMP" | awk '{print $1}')
[ "$HAVE" = "$WANT" ] || { echo "sha256 не совпадает с tools/jq.sha256 ($HAVE) — файл не взят"; exit 1; }
chmod 755 "$TMP" && mv -f "$TMP" "$DIR/bin/jq" || exit 1
trap - EXIT
echo "готово: bin/jq — $("$DIR/bin/jq" --version), sha256 сверен с tools/jq.sha256"
echo "дальше: ./precheck.sh, потом sudo ./install.sh"

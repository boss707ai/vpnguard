#!/bin/bash
# Тест проверки текста файлов из install.sh: белый список символов, смесь латиницы и кириллицы, слова из двойников.
# Проверка достаётся прямо из install.sh, чтобы тестировать ровно её. Запуск: bash tests/test_textcheck.sh
set -u
export PATH=/sbin:/usr/sbin:/bin:/usr/bin   # как у установщика: системные BSD-утилиты
DIR="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/vgtext.XXXXXX")
trap 'rm -rf "$T"' EXIT

# программа perl между «/usr/bin/perl -e '» и «' $CHECK_FILES»
awk "/^\\/usr\\/bin\\/perl -e '\$/{f=1; next} /^' \\\$CHECK_FILES/{f=0} f" "$DIR/install.sh" > "$T/check.pl"
[ -s "$T/check.pl" ] || { echo "FAIL не нашёл проверку в install.sh"; exit 1; }

PASSN=0; FAILN=0
case_() { # ожидание(pass|refuse) описание содержимое-printf
  local want=$1 what=$2 got
  printf "$3" > "$T/f"
  if /usr/bin/perl "$T/check.pl" "$T/f" >/dev/null 2>&1; then got=pass; else got=refuse; fi
  if [ "$got" = "$want" ]; then PASSN=$((PASSN + 1)); else FAILN=$((FAILN + 1)); echo "FAIL $what: ждали $want, получили $got"; fi
}

case_ pass   "ASCII и русский текст"           'echo "Защита включена" # Ёж, ёлка\n'
case_ pass   "типографика из белого списка"     'a — «b» · c… → d ↔ e ≈ f ⏸\n'
case_ pass   "табуляция"                        'a\tb\n'
case_ pass   "однобуквенные предлоги"           'с ним, у нас, о том, а также\n'
case_ pass   "дефис между словами"              'pf-правила VPN-клиент\n'
case_ refuse "RLO U+202E"                       'a\xe2\x80\xaeb\n'
case_ refuse "LRI U+2066"                       'a\xe2\x81\xa6b\n'
case_ refuse "ZWSP U+200B"                      'a\xe2\x80\x8bb\n'
case_ refuse "мягкий перенос U+00AD"            'a\xc2\xadb\n'
case_ refuse "филлер хангыля U+3164"            'a\xe3\x85\xa4b\n'
case_ refuse "тег Юникода U+E0041"              'a\xf3\xa0\x81\x81b\n'
case_ refuse "селектор варианта U+FE0F"         'a\xef\xb8\x8fb\n'
case_ refuse "BOM"                              '\xef\xbb\xbfecho\n'
case_ refuse "C1 CSI U+009B"                    'a\xc2\x9bb\n'
case_ refuse "NUL"                              'a\000b\n'
case_ refuse "CR"                               'a\rb\n'
case_ refuse "ESC"                              'a\033[2Kb\n'
case_ refuse "битый UTF-8"                      'a\xc3b\n'
case_ refuse "украинская І (двойник I)"         '\xd0\x86nfo\n'
case_ refuse "палочка Ӏ (двойник l)"            '\xd3\x80ocal\n'
case_ refuse "смесь: VPNGuаrd (кирил. а)"       '/Library/VPNGu\xd0\xb0rd\n'
case_ refuse "смесь: сron (кирил. с)"           '\xd1\x81ron\n'
case_ refuse "двойники в пути: /tmp/сор"         'cp x /tmp/\xd1\x81\xd0\xbe\xd1\x80\n'
case_ refuse 'двойники в пути: $BASE/ТОР'       'rm "$BASE/\xd0\xa2\xd0\x9e\xd0\xa0"\n'
case_ refuse "двойники в имени: сор.sh"          'bash \xd1\x81\xd0\xbe\xd1\x80.sh\n'
case_ refuse "одна буква в пути: /х/"            'ls /\xd1\x85/\n'
case_ pass   "обычные слова: Не, НЕТ, со"        'echo "Не понял: НЕТ, со своей ссылкой"\n'
case_ pass   "сообщение в alert(...)"             'alert("\xd0\x9d\xd0\xb5 получилось", out)\n'
case_ refuse "двойник с цифрой: /tmp/р2"         'cat /tmp/\xd1\x802\n'
case_ refuse "З вместо 3: v3 → vЗ в пути"         'cd /opt/З\n'
case_ refuse "сравнение: = ТОР"                   '[ "$a" = \xd0\xa2\xd0\x9e\xd0\xa0 ]\n'
case_ refuse 'целиком в кавычках: "ТОР"'          'x="\xd0\xa2\xd0\x9e\xd0\xa0"\n'
case_ refuse "одна буква в кавычках: \"у\""       '[ "$ans" = "\xd1\x83" ]\n'
case_ refuse "метка case: ТОР)"                   '  \xd0\xa2\xd0\x9e\xd0\xa0) echo x ;;\n'
case_ refuse "метка case после |: on|ТОР)"        '  on|\xd0\xa2\xd0\x9e\xd0\xa0) echo x ;;\n'
mkdir -p "$T/pf.d/pf"
case_rules() { # ожидание описание строка [raw] — без raw в конец дописывается обязательный финальный отказ
  local got; printf "$3" > "$T/pf.d/pf/vpnguard.rules"
  [ "${4:-}" = raw ] || echo "block return out log quick all" >> "$T/pf.d/pf/vpnguard.rules"
  if /usr/bin/perl "$T/check.pl" "$T/pf.d/pf/vpnguard.rules" >/dev/null 2>&1; then got=pass; else got=refuse; fi
  if [ "$got" = "$1" ]; then PASSN=$((PASSN + 1)); else FAILN=$((FAILN + 1)); echo "FAIL $2: ждали $1, получили $got"; fi
}
case_rules pass   "правила pf: обычная строка"          'pass out quick on lo0 all no state\n'
case_rules refuse "правила pf: include"                 'include "/Users/x/evil.conf"\n'
case_rules refuse "правила pf: load anchor from"        'load anchor "x" from "/Users/x/a"\n'
case_rules refuse "правила pf: table … file"            'table <vg_lan> persist file "/Users/x/lan"\n'
case_rules refuse "правила pf: перенос через \\"         'inc\\\nlude "/Users/x/evil.conf"\n'
case_rules refuse "правила pf: include через макрос"     'f = "/Users/x/evil.conf"\ninclude $f\n'
case_rules refuse "правила pf: комментарий с \\ прячет правило" '# 7. всё остальное \\\nblock return out log quick all\n'
case_rules refuse "правила pf: чужой макрос в правиле"   'pass out quick on $x all no state\n'
case_rules refuse "правила pf: set skip"                 'set skip on en0\n'
case_rules refuse "правила pf: rdr"                      'rdr pass on en0 proto tcp to any port 80 -> 127.0.0.1\n'
case_rules refuse "правила pf: user root (проверка владельца)" 'pass out quick proto { tcp udp } from any to any user root no state\n'
case_rules refuse "правила pf: group"                    'pass out quick to any group wheel no state\n'
case_rules refuse "правила pf: log (user)"               'block return out log (user) quick all\n'
case_rules refuse "правила pf: route-to"                 'pass out quick route-to (en0 192.168.1.1) all no state\n'
case_rules refuse "правила pf: flags больше не нужны"    'pass out quick proto tcp from any to any flags R/R no state\n'
case_rules pass   "правила pf: «user» в комментарии"     '# 3. было: user root — убрано\npass out quick to <vg_servers> no state\n'
case_rules refuse "правила pf: en0 в tun_if"            'tun_if = "{ utun0 en0 }"\n'
case_rules refuse "правила pf: vg_lan подменена"         'table <vg_lan> const { 0.0.0.0/0 }\n'
case_rules refuse "правила pf: лишняя таблица"           'table <vg_x> const { 10.0.0.0/8 }\n'
case_rules refuse "правила pf: pass to any"              'pass out quick to any no state\n'
case_rules refuse "правила pf: pass all без туннеля"     'pass out quick all no state\n'
case_rules refuse "правила pf: pass на порт куда угодно"  'pass out quick proto tcp to any port 443 no state\n'
case_rules pass   "правила pf: DHCP ровно"               'pass out quick proto udp from any port 68 to any port 67 no state\n'
case_rules refuse "правила pf: нет финального отказа"     'pass out quick on lo0 all no state\n' raw
case_rules refuse "правила pf: финальный отказ не последний" 'block return out log quick all\npass out quick on lo0 all no state\n' raw
case_rules pass   "правила pf: наш файл целиком"         "$(sed 's/%/%%/g; s/\\/\\\\/g' "$DIR/pf/vpnguard.rules" | awk '{printf "%s\\n", $0}')"

case_ru() { # ожидание описание дополнительные-строки (к 1000 сетей 10.x.y.0/24) [шапка: nets addrs | none]
  local got head
  head="# Сетей: 1000 · адресов: 256000"
  [ -n "${4:-}" ] && head="# Сетей: ${4% *} · адресов: ${4#* }"
  [ "${4:-}" = none ] && head="# тест"
  { echo "$head"; for i in $(seq 0 999); do echo "10.$((i / 256)).$((i % 256)).0/24"; done; printf "$3"; } > "$T/pf.d/pf/ru.cidr"
  if /usr/bin/perl "$T/check.pl" "$T/pf.d/pf/ru.cidr" >/dev/null 2>&1; then got=pass; else got=refuse; fi
  if [ "$got" = "$1" ]; then PASSN=$((PASSN + 1)); else FAILN=$((FAILN + 1)); echo "FAIL $2: ждали $1, получили $got"; fi
}
case_ru pass   "ru.cidr: обычный список"                 ''
case_ru refuse "ru.cidr: 0.0.0.0/1 — полинтернета"        '0.0.0.0/1\n'
case_ru refuse "ru.cidr: шире /8"                          '4.0.0.0/7\n'
case_ru refuse "ru.cidr: лишние биты после маски"          '10.200.0.1/24\n'
case_ru refuse "ru.cidr: октет > 255"                      '10.300.0.0/24\n'
case_ru refuse "ru.cidr: мусор"                            'pass out all\n'
case_ru refuse "ru.cidr: IPv6"                             '2a00::/16\n'
case_ru refuse "ru.cidr: Anthropic (контрольный адрес)"    '160.79.104.0/23\n'
case_ru refuse "ru.cidr: Google DNS (контрольный адрес)"   '8.8.8.0/24\n'
case_ru refuse "ru.cidr: больше 64 млн адресов"            "$(for i in 20 21 22 23 24; do printf '%s.0.0.0/8\\n' $i; done)" "1005 84142080"
case_ru pass   "ru.cidr: сеть дописана вместе с шапкой"    '10.200.0.0/24\n' "1001 256256"
case_ru refuse "ru.cidr: сеть дописана, шапка прежняя"     '10.200.0.0/24\n'
case_ru refuse "ru.cidr: нет шапки со счётчиками"          '' none
printf '# мало\n10.0.0.0/24\n' > "$T/pf.d/pf/ru.cidr"
if /usr/bin/perl "$T/check.pl" "$T/pf.d/pf/ru.cidr" >/dev/null 2>&1; then FAILN=$((FAILN + 1)); echo "FAIL ru.cidr: меньше 1000 сетей — ждали отказ"; else PASSN=$((PASSN + 1)); fi

echo "--- файлы репозитория (как их увидит установщик):"
FILES=$(sed -n '/^FILES="/,/"$/p' "$DIR/install.sh" | tr -d '"' | sed 's/^FILES=//')
# адаптеры VPN-клиентов установщик добавляет к FILES (FILES+=" $PFILE") — проверяем все
for f in "$DIR"/providers/*/provider.sh; do [ -f "$f" ] && FILES="$FILES ${f#"$DIR"/}"; done
REPO=""; for f in $FILES; do REPO="$REPO $DIR/$f"; done
# shellcheck disable=SC2086
if out=$(/usr/bin/perl "$T/check.pl" $REPO 2>&1); then PASSN=$((PASSN + 1)); echo "все файлы проходят"
else FAILN=$((FAILN + 1)); echo "FAIL файлы репозитория:"; echo "$out"; fi

# Программа выше достана из install.sh текстом, а установщик передаёт её perl через bash в '…'.
# Одинарная кавычка внутри закрыла бы строку раньше, и bash исполнил бы другое: например,
# «'table <vg_lan> …'» стало бы чтением из файла vg_lan, и установщик отказал бы. Поэтому: (1) то, что
# получит perl после разбора bash, совпадает с текстом; (2) сам блок проверки из install.sh
# исполняется bash, как при установке, на копии файлов — в пустом каталоге, без следов в нём.
{ printf "printf '%%s' '\n"; cat "$T/check.pl"; printf "'\n"; } > "$T/as_bash.sh"
if (cd "$T" && bash "$T/as_bash.sh" 2>/dev/null) > "$T/as_bash.pl" && { printf '\n'; cat "$T/check.pl"; } | cmp -s - "$T/as_bash.pl"; then
  PASSN=$((PASSN + 1)); else FAILN=$((FAILN + 1)); echo "FAIL программа perl после разбора bash не совпадает с текстом (одинарная кавычка внутри '…'?)"; fi
awk '/^\[ -x \/usr\/bin\/perl \]/{f=1} f{print} /^echo "текст файлов: ок"$/{exit}' "$DIR/install.sh" > "$T/textcheck.sh"
mkdir -p "$T/stage" "$T/cwd"
for f in $FILES; do mkdir -p "$T/stage/$(dirname "$f")"; cp "$DIR/$f" "$T/stage/$f"; done
out=$(cd "$T/cwd" && S="$T/stage" FILES="$FILES" bash -c 'set -euo pipefail; . "$1"' _ "$T/textcheck.sh" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$out" = "текст файлов: ок" ] && [ -z "$(ls -A "$T/cwd")" ]; then PASSN=$((PASSN + 1))
else FAILN=$((FAILN + 1)); echo "FAIL проверка текста из install.sh, исполненная bash: rc=$rc, следы: $(ls -A "$T/cwd" | tr '\n' ' ')"; echo "$out" | head -5; fi

# ru_diff из install.sh под set -euo pipefail, как в самом установщике: ни один вид обновления
# (новый файл при обновлении старой установки, только добавления, только удаления, только шапка) не должен
# молча обрывать установку до вопроса «Ставлю?»
awk '/^ru_diff\(\) \{/,/^}$/' "$DIR/install.sh" > "$T/ru_diff.fn"
printf '# a\n10.0.0.0/24\n' > "$T/ra"; printf '# b\n10.0.0.0/24\n10.0.1.0/24\n' > "$T/rb"; printf '# c\n10.0.0.0/24\n' > "$T/rc"
for c in "/dev/null $T/rb" "$T/ra $T/rb" "$T/rb $T/ra" "$T/ra $T/rc"; do
  # shellcheck disable=SC2086
  if [ -s "$T/ru_diff.fn" ] && bash -c "set -euo pipefail; . '$T/ru_diff.fn'; ru_diff $c > /dev/null; echo ok" 2>/dev/null | grep -q '^ok$'; then
    PASSN=$((PASSN + 1)); else FAILN=$((FAILN + 1)); echo "FAIL ru_diff обрывается под set -euo pipefail: $c"; fi
done

# $имя сразу перед не-ASCII символом: bash 3.2 в UTF-8 считает байты «»/кириллицы частью имени →
# «unbound variable» и падение под set -u (так падал сторож на «$v»). Только ${имя}.
SH=""; for f in $FILES; do case $f in *.sh|daemon/*|cli/*|lib/*) SH="$SH $DIR/$f" ;; esac; done
# shellcheck disable=SC2086
if hits=$(LC_ALL=C grep -n -E '\$[A-Za-z_][A-Za-z0-9_]*[^ -~	]' $SH | LC_ALL=C grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#'); then
  FAILN=$((FAILN + 1)); echo "FAIL \$имя вплотную к не-ASCII (нужно \${имя}):"; echo "$hits"
else PASSN=$((PASSN + 1)); fi

echo "PASS=$PASSN FAIL=$FAILN"
[ "$FAILN" = 0 ]

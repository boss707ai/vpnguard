#!/bin/bash
# Установка и обновление vpnguard.
#   Первая установка: sudo ~/Tools/vpnguard/install.sh [--provider ИМЯ]   (адаптер VPN-клиента из providers/, по умолчанию karing)
#   Обновление:       vpnguard update   (root-копия этого скрипта: покажет diff всего, что попадёт в root, и спросит;
#                     адаптер остаётся прежним, сменить — sudo ~/Tools/vpnguard/install.sh --provider ИМЯ)
# Каталог-источник может править любой процесс пользователя, поэтому всё из него читается от пользователя
# в закрытый каталог root, проверяется и собирается там; в систему ставятся только эти копии.
set -euo pipefail
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
[ "$(id -u)" = 0 ] || { echo "Нужен sudo: sudo $0"; exit 1; }
U="${SUDO_USER:-$(stat -f %Su /dev/console)}"
[ -n "$U" ] && [ "$U" != root ] || { echo "Не понял, для какого пользователя ставить — запусти через sudo."; exit 1; }
UIDN=$(id -u "$U")
UHOME=$(dscl . -read "/Users/$U" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
PROVIDER=""
if [ "${1:-}" = --provider ]; then
  [ $# -ge 2 ] || { echo "Укажи адаптер: --provider ИМЯ (папка в providers/)"; exit 1; }
  PROVIDER=$2; shift 2
fi
SRC="$(cd "${1:-$(dirname "$0")}" && pwd)"
BASE="/Library/Application Support/VPNGuard"
# адаптер: указан явно → он; иначе тот, что уже стоит; иначе karing
[ -n "$PROVIDER" ] || PROVIDER=$(sed -n 's/^VG_PROVIDER=\([a-z0-9-]*\)$/\1/p' "$BASE/provider.sh" 2>/dev/null | head -1 || true)
PROVIDER=${PROVIDER:-karing}
[[ $PROVIDER =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "Имя адаптера — строчная латиница, цифры и дефис: $PROVIDER"; exit 1; }
PFILE="providers/$PROVIDER/provider.sh"
[ -f "$SRC/$PFILE" ] || { echo "Нет адаптера «${PROVIDER}»: $SRC/$PFILE. Есть: $(ls "$SRC/providers" 2>/dev/null | paste -sd' ' -)"; exit 1; }
APP="$BASE/VPN Guard.app"
DAEMON_PLIST=/Library/LaunchDaemons/local.vpnguard.plist
AGENT_PLIST=/Library/LaunchAgents/local.vpnguard.menubar.plist
FILES="daemon/vpnguardd cli/vpnguard lib/state.sh pf/vpnguard.rules pf/ru.cidr ПАМЯТКА.md install.sh uninstall.sh
launchd/local.vpnguard.plist launchd/local.vpnguard.menubar.plist app/VPNGuard.swift app/Info.plist
tests/acceptance.sh tests/soak.sh tests/nwprobe.swift tests/test_state.sh"
FILES+=" $PFILE"   # адаптер VPN-клиента — тоже код от root: та же проверка и тот же diff

STAGE=$(mktemp -d /private/var/tmp/vpnguard-install.XXXXXX)   # root, 700
cleanup() { rm -rf "$STAGE"; sudo -u "$U" /usr/bin/sudo -K 2>/dev/null || true; }   # и сбросить кэш sudo пользователя
trap cleanup EXIT
S="$STAGE/src"; B="$STAGE/build"

echo "== Источник: $SRC · адаптер: $PROVIDER"
sudo -H -u "$U" git -C "$SRC" log -1 --format='коммит %h · %s · %cr' 2>/dev/null || echo "(не git-репозиторий)"
DIRTY=$(sudo -H -u "$U" git -C "$SRC" status --porcelain 2>/dev/null || true)
if [ -n "$DIRTY" ]; then echo "ВНИМАНИЕ: незакоммиченные изменения:"; printf '%s\n' "$DIRTY" | sed 's/^/  /'; fi
for f in $FILES; do
  mkdir -p "$S/$(dirname "$f")"
  sudo -u "$U" cat "$SRC/$f" > "$S/$f" || { echo "Не прочитал $SRC/$f"; exit 1; }
done

# До подтверждения — только проверки, которые ничего из источника не исполняют.
echo "== Проверки (без исполнения)"
# набор в том виде, в каком его соберёт сторож: таблицы адресов + правила (адреса — пробные)
{ printf 'table <vg_servers> const { 192.0.2.1 }\ntable <vg_dns> const { 192.0.2.2 }\ntable <vg_ru> const file "%s"\n' "$S/pf/ru.cidr"
  cat "$S/pf/vpnguard.rules"; } > "$STAGE/check.rules"
pfctl -a com.apple/999.vpnguard-check -nf "$STAGE/check.rules" >/dev/null 2>&1 || { echo "Правила pf не парсятся"; exit 1; }
for f in daemon/vpnguardd cli/vpnguard lib/state.sh "$PFILE" install.sh uninstall.sh tests/acceptance.sh tests/soak.sh tests/test_state.sh; do
  bash -n "$S/$f" || { echo "Синтаксис: $f"; exit 1; }
done
plutil -lint -s "$S/launchd/local.vpnguard.plist" "$S/launchd/local.vpnguard.menubar.plist" "$S/app/Info.plist"
echo "правила и синтаксис: ок"

# Текст файлов — только белый список: печатные ASCII, табуляция, русский алфавит и несколько типографских
# знаков. Плюс запрет слов, где смешаны латиница и кириллица, и слов целиком из кириллических двойников
# латинских букв. Иначе diff показал бы не то, что исполнится: управляющие и невидимые символы, bidi
# («Trojan Source»), NUL, буквы-двойники в путях. Отказ, а не подсветка. Проверка — внутри этого скрипта,
# а не в файле из источника: при обновлении работает root-копия, источнику она не доверяет.
[ -x /usr/bin/perl ] || { echo "Нет /usr/bin/perl — не могу проверить текст файлов, отказ."; exit 1; }
CHECK_FILES=""; for f in $FILES; do CHECK_FILES="$CHECK_FILES $S/$f"; done
# shellcheck disable=SC2086 — пути без пробелов (каталог mktemp и имена из FILES)
/usr/bin/perl -e '
  use strict; use warnings; use utf8; use Encode qw(decode FB_CROAK);
  binmode STDOUT, ":encoding(UTF-8)";
  my $ok = qr/[\t\x20-\x7e\x{0410}-\x{044F}\x{0401}\x{0451}\x{00AB}\x{00B7}\x{00BB}\x{2014}\x{2026}\x{2192}\x{2194}\x{2248}\x{23F8}]/;
  my $bad = 0;
  my (%ru, %last, %ruhead);
  for my $f (@ARGV) {
    open(my $fh, "<:raw", $f) or die "не открыл $f\n";
    my $raw = do { local $/; <$fh> }; close $fh;
    my $t = eval { decode("UTF-8", $raw, FB_CROAK) };
    unless (defined $t) { print "  $f: не UTF-8\n"; $bad = 1; next; }
    my $n = 0;
    for my $line (split /\n/, $t, -1) {
      $n++;
      for my $ch (split //, $line) {
        next if $ch =~ $ok;
        printf "  %s:%d: недопустимый символ U+%04X\n", $f, $n, ord $ch; $bad = 1; last;
      }
      if ($line =~ /\w*(?:\p{Latin}\w*\p{Cyrillic}|\p{Cyrillic}\w*\p{Latin})/) {
        print "  $f:$n: латиница и кириллица в одном слове\n"; $bad = 1;
      }
      # Кириллица, неотличимая от латиницы или цифр (а е о р с у х, А В Е З К М Н О Р С Т Х). Слово только
      # из таких букв (цифры и _ не в счёт) опасно там, где оно часть кода: вплотную к символу пути или
      # идентификатора (/ . $ = ~ \ -), целиком в кавычках, сразу после =, меткой case. Слова сообщений не трогаем.
      my $look = qr/[\x{0430}\x{0435}\x{043E}\x{0440}\x{0441}\x{0443}\x{0445}\x{0410}\x{0412}\x{0415}\x{0417}\x{041A}\x{041C}\x{041D}\x{041E}\x{0420}\x{0421}\x{0422}\x{0425}]/;
      while ($line =~ /(\w+)/g) {
        my ($w, $s, $e) = ($1, $-[1], $+[1]);
        (my $letters = $w) =~ s/[\d_]//g;
        next unless length $letters && $letters =~ /^$look+$/;
        my $prev = $s > 0 ? substr($line, $s - 1, 1) : "";
        my $next = substr($line, $e, 1);
        my $before = substr($line, 0, $s);
        if ($prev =~ m{[/.\$=~\\\-]} || $next =~ m{[/.\$=~\\\-]}
            || ($prev =~ /["\x27]/ && $next eq $prev)
            || $before =~ /=\s*$/
            || ($next eq ")" && $before =~ /^\s*(?:[^\s|]*\|)*$/)) {
          print "  $f:$n: кириллические двойники латиницы в коде (путь, имя, сравнение)\n"; $bad = 1; last;
        }
      }
      # Правила pf — белый список видов строк. Язык pf умеет include/load/table … file, перенос строки через \
      # и макросы — текстовый запрет слов обходится. Разрешено ровно то, из чего состоят наши правила;
      # новый вид строки — правка этого списка, и она тоже попадёт в diff.
      if ($f =~ m{/pf/vpnguard\.rules$}) {
        # обратная косая в pf — перенос строки, в том числе внутри комментария: «# …\» спрятала бы
        # от pf следующую строку, которую в diff видно как правило
        if (index($line, "\\") >= 0) { print "  $f:$n: обратная косая в правилах pf запрещена\n"; $bad = 1; }
        # Проверка владельца пакета (user, group, log (user)) заставляет pf под своей блокировкой искать
        # сокет, и это может увести ядро macOS во взаимоблокировку. Перенаправления и прочее, что уводит pf в другие части
        # ядра, — тоже нет. Белый список ниже их и так не пропустит; здесь — понятная причина отказа.
        if ($line !~ /^\s*#/ && $line =~ /\b(?:user|group|route-to|reply-to|dup-to|fastroute|divert-to|divert-packet|divert-reply|rdr|nat|binat|synproxy|dnpipe|dnqueue|dummynet)\b/) {
          print "  $f:$n: в правилах pf запрещены проверки владельца и перенаправления — они могут увести ядро macOS во взаимоблокировку\n"; $bad = 1;
        }
        my $rule = qr{^(?:pass|block)(?: return)? out(?: log)? quick(?: on (?:lo0|\$tun_if))?(?: proto (?:tcp|udp|\{ tcp udp \}))?(?: from any(?: port \d+)?)?(?: to (?:any|<[a-z_]+>)(?: port (?:\d+|\{ [\d ]+ \}))?)?(?: all)?(?: no state)?$};
        # строки — в q(…), не в кавычках: вся программа стоит в одинарных кавычках bash (см. test_textcheck.sh)
        my $lan = q(table <vg_lan> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255, fe80::/10, fc00::/7, ff00::/8 });
        my $dhcp = q(pass out quick proto udp from any port 68 to any port 67 no state);
        if ($line =~ /^\s*(?:#.*)?$/) {
        } elsif ($line =~ /^tun_if = "\{ ([a-z0-9 ]+) \}"$/) {
          # в списке туннелей — только туннели: en0 здесь открыл бы Wi-Fi напрямую
          for my $t (split / /, $1) { next if $t =~ /^(?:utun|ipsec|ppp)\d+$/; print "  $f:$n: в tun_if не туннель: $t\n"; $bad = 1; }
        } elsif ($line =~ /^table /) {
          # таблицы адресов дописывает сторож; в файле — только локальная сеть, строка в строку
          unless ($line eq $lan) { print "  $f:$n: в правилах допустима только таблица <vg_lan> ровно в известном виде\n"; $bad = 1; }
        } elsif ($line =~ $rule) {
          # pass — только на туннель/петлю, в таблицу или DHCP: «pass … to any» открыл бы всё
          if ($line =~ /^pass/ && $line !~ / on (?:lo0|\$tun_if) / && $line !~ / to <[a-z_]+>/ && $line ne $dhcp) {
            print "  $f:$n: pass без туннеля, таблицы или DHCP — открыл бы прямой выход\n"; $bad = 1;
          }
          $last{$f} = $line;
        } else {
          print "  $f:$n: строка правил pf вне разрешённого вида\n"; $bad = 1;
        }
      }
      # Список российских сетей: каждая строка — комментарий или сеть IPv4 не шире /8 без лишних бит.
      # Это разрешение ходить напрямую мимо туннеля, поэтому ещё и общий объём, и контрольные адреса ниже.
      if ($f =~ m{/pf/ru\.cidr$} && $line =~ /^# Сетей: (\d+) · адресов: (\d+)$/) { $ruhead{$f} = [$1, $2]; }
      if ($f =~ m{/pf/ru\.cidr$} && $line !~ /^\s*(?:#.*)?$/) {
        if ($line =~ m{^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$} && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255 && $5 >= 8 && $5 <= 32) {
          my $ip = ($1 << 24) | ($2 << 16) | ($3 << 8) | $4;
          my $size = 2 ** (32 - $5);
          if ($ip % $size) { print "  $f:$n: у сети лишние биты после маски\n"; $bad = 1; }
          push @{$ru{$f}}, [$ip, $size];
        } else {
          print "  $f:$n: строка списка российских сетей — не сеть IPv4 от /8 до /32\n"; $bad = 1;
        }
      }
    }
  }
  # последнее правило — всегда финальный отказ: без него всё, что не совпало, проходило бы
  for my $f (grep { m{/pf/vpnguard\.rules$} } @ARGV) {
    unless (($last{$f} // "") eq "block return out log quick all") { print "  $f: последнее правило должно быть «block return out log quick all»\n"; $bad = 1; }
  }
  # Объём и контрольные адреса: в списке не может быть всего интернета (российских IPv4 ≈ 46 млн)
  # и адресов, которые точно не российские (AI-сервисы, публичные DNS, ipinfo из самотеста).
  my @canary = map { my @o = split /\./; ($o[0] << 24) | ($o[1] << 16) | ($o[2] << 8) | $o[3] }
    qw(160.79.104.10 104.18.32.47 162.159.140.245 34.117.59.81 8.8.8.8 1.1.1.1 142.250.74.46);
  for my $f (keys %ru) {
    my ($sum, $nets) = (0, scalar @{$ru{$f}});
    $sum += $_->[1] for @{$ru{$f}};
    if ($nets < 1000 || $nets > 100000) { print "  $f: сетей $nets — ждём от 1000 до 100000\n"; $bad = 1; }
    if ($sum > 67108864) { print "  $f: адресов $sum — больше 64 млн, это не список российских сетей\n"; $bad = 1; }
    # шапку пишет tools/srs2cidr.py; дописанная руками сеть без правки шапки — отказ
    my $h = $ruhead{$f};
    if (!$h) { print "  $f: нет строки «# Сетей: N · адресов: M» — список сделан не tools/srs2cidr.py\n"; $bad = 1; }
    elsif ($h->[0] != $nets || $h->[1] != $sum) { print "  $f: в шапке сетей $h->[0] и адресов $h->[1], а в списке $nets и $sum\n"; $bad = 1; }
    for my $c (@canary) {
      for my $r (@{$ru{$f}}) {
        if ($c >= $r->[0] && $c < $r->[0] + $r->[1]) {
          printf "  %s: контрольный нероссийский адрес %d.%d.%d.%d попал в список\n", $f, $c >> 24, ($c >> 16) & 255, ($c >> 8) & 255, $c & 255; $bad = 1; last;
        }
      }
    }
  }
  exit $bad;
' $CHECK_FILES || { echo "Отказ: в файлах недопустимые символы — в diff было бы видно не то, что исполнится."; exit 1; }
echo "текст файлов: ок"

# Список российских сетей сделан из того же файла, по которому решает VPN-клиент? Шапка ru.cidr хранит
# sha256 источника — сверяем с файлом клиента из адаптера. Адаптер здесь не исполняется (до «y» — только
# чтение): путь и название берём из его текста.
PTITLE=$(sed -n 's/^VG_PROVIDER_TITLE="\(.*\)"$/\1/p' "$S/$PFILE" | head -1 || true); PTITLE=${PTITLE:-$PROVIDER}
RU_SRC=$(sed -n 's/^VG_PROVIDER_RU_SRC="\(.*\)"$/\1/p' "$S/$PFILE" | head -1 || true)
RU_WANT=$(sed -n 's/^# sha256 источника: *\([0-9a-f]*\).*/\1/p' "$S/pf/ru.cidr" | head -1 || true)
if [ -z "$RU_SRC" ]; then echo "у адаптера $PTITLE нет своего списка российских сетей — сверку пропускаю"
else
  # путь — из текста источника: читаем только обычный файл и от пользователя, не от root
  RU_HAVE=""
  if [ -f "$RU_SRC" ]; then RU_HAVE=$(sudo -u "$U" /usr/bin/shasum -a 256 "$RU_SRC" 2>/dev/null | awk '{print $1}' || true); fi   # нет клиента — не повод падать
  if [ -n "$RU_HAVE" ] && [ "$RU_WANT" = "$RU_HAVE" ]; then echo "список российских сетей сверен с $PTITLE: источник тот же (sha256)"
  else echo "ВНИМАНИЕ: список российских сетей сделан не из установленного у тебя $PTITLE (sha256 не совпадает или файл не найден)"; fi
fi

ru_diff() { # старый новый — список российских сетей: данные, а не код; тысячи строк в diff никто не
            # прочтёт, поэтому сводка, шапка целиком и добавленные сети (их проверить важнее всего)
  # под set -euo pipefail: пустой результат grep — это rc=1, и без «|| true» установщик молча
  # завершился бы до вопроса (так было бы при обновлении старой установки, где ru.cidr ещё нет)
  local o n added removed na nr
  o=$(grep -v -e '^#' -e '^$' "$1" | sort || true); n=$(grep -v -e '^#' -e '^$' "$2" | sort || true)
  added=$(comm -13 <(printf '%s\n' "$o") <(printf '%s\n' "$n") | grep -v '^$' || true)
  removed=$(comm -23 <(printf '%s\n' "$o") <(printf '%s\n' "$n") | grep -v '^$' || true)
  na=$(printf '%s' "$added" | grep -c . || true); nr=$(printf '%s' "$removed" | grep -c . || true)
  echo "--- pf/ru.cidr (российские сети — разрешение ходить напрямую): сетей $(printf '%s' "$o" | grep -c . || true) → $(printf '%s' "$n" | grep -c . || true), добавлено $na, убрано $nr"
  diff -a -u <(grep '^#' "$1") <(grep '^#' "$2") | tail -n +3 | LC_ALL=C sed $'s/[\x01-\x08\x0b-\x1f\x7f]/?/g' || true
  printf '%s\n' "$added" | grep -v '^$' | sed 's/^/+ /' || true   # все: добавленная сеть — разрешение ходить напрямую
  printf '%s\n' "$removed" | grep -v '^$' | head -20 | sed 's/^/- /' || true
  [ "$nr" -gt 20 ] && echo "  … и ещё $((nr - 20)) убранных"
  return 0
}

if [ -d "$BASE/src" ]; then
  echo "== Что изменится в root-части по сравнению с установленной (полностью)"
  CHANGED=0
  for f in $FILES; do
    if ! cmp -s "$BASE/src/$f" "$S/$f"; then
      CHANGED=1
      old="$BASE/src/$f"; [ -f "$old" ] || old=/dev/null   # нового файла нет в установленной копии — показать целиком
      if [ "$f" = pf/ru.cidr ]; then ru_diff "$old" "$S/$f"; continue; fi
      echo "--- $f"
      diff -a -u "$old" "$S/$f" | tail -n +3 | LC_ALL=C sed $'s/[\x01-\x08\x0b-\x1f\x7f]/?/g' || true
    fi
  done
  if [ "$CHANGED" = 1 ]; then
    echo
    printf 'Ставлю эти изменения от root? Напиши y и Enter: '
    read -r ans </dev/tty || ans=""
    [ "$ans" = y ] || { echo "Отменено, ничего не изменено."; exit 1; }
  else
    echo "изменений нет — переустанавливаю то же самое"
  fi
fi

# Дальше исполняется код источника — только после подтверждения (или при первой установке,
# которую и так запускают из репозитория).
echo "== Юнит-тесты"
bash "$S/tests/test_state.sh" >/dev/null || { echo "Юнит-тесты не прошли"; exit 1; }
echo "ок"

echo "== Сборка приложения и зонда (от root, из проверенных копий)"
mkdir -p "$B/VPN Guard.app/Contents/MacOS"
cp "$S/app/Info.plist" "$B/VPN Guard.app/Contents/Info.plist"
swiftc -swift-version 5 -O -module-cache-path "$STAGE/mc" -o "$B/VPN Guard.app/Contents/MacOS/VPNGuard" "$S/app/VPNGuard.swift"
codesign --force --sign - "$B/VPN Guard.app" >/dev/null 2>&1
swiftc -O -module-cache-path "$STAGE/mc" -o "$B/nwprobe" "$S/tests/nwprobe.swift"

echo "== Root-часть → $BASE"
install -d -o root -g wheel -m 755 "$BASE" "$BASE/tests"
[ -f "$BASE/pf-before" ] || pfctl -s info 2>/dev/null | awk '/^Status/{print $2}' > "$BASE/pf-before"
install -o root -g wheel -m 755 "$S/daemon/vpnguardd" "$S/cli/vpnguard" "$S/install.sh" "$S/uninstall.sh" "$BASE/"
install -o root -g wheel -m 644 "$S/lib/state.sh" "$S/pf/vpnguard.rules" "$S/pf/ru.cidr" "$S/ПАМЯТКА.md" "$BASE/"
install -o root -g wheel -m 644 "$S/$PFILE" "$BASE/provider.sh"
rm -f "$BASE/karing.map" "$BASE/karing.seen" "$BASE/request/karing"   # файлы версий до адаптеров
install -o root -g wheel -m 755 "$S/tests/acceptance.sh" "$S/tests/soak.sh" "$B/nwprobe" "$BASE/tests/"
install -d -o root -g wheel -m 1777 "$BASE/request"
printf '%s\n' "$U" > "$BASE/user"; chown root:wheel "$BASE/user"; chmod 644 "$BASE/user"   # чьи настройки VPN-клиента брать
rm -rf "$BASE/src"; cp -R "$S" "$BASE/src"; chown -R root:wheel "$BASE/src"; chmod -R go-w "$BASE/src"   # эталон для следующего diff
echo "pf до установки: $(cat "$BASE/pf-before")"

# Адреса VPN-серверов и DNS берём из клиента до запуска сторожа: иначе первые секунды после установки
# клиент не достучался бы до своего сервера. Данные других приложений macOS отдаёт только процессам
# пользователя с разрешением — здесь это терминал, из которого запущена установка.
echo "== Адреса из $PTITLE"
sudo -H -u "$U" "$BASE/vpnguard" sync || echo "не взял адреса из $PTITLE — иконка возьмёт их сама (или: vpnguard sync)"

echo "== Сторож (LaunchDaemon local.vpnguard)"
install -o root -g wheel -m 644 "$S/launchd/local.vpnguard.plist" "$DAEMON_PLIST"
launchctl bootout system/local.vpnguard 2>/dev/null || true
sleep 1
launchctl bootstrap system "$DAEMON_PLIST"

echo "== Иконка в меню (приложение и LaunchAgent принадлежат root)"
launchctl bootout "gui/$UIDN/local.vpnguard.menubar" 2>/dev/null || true
rm -rf "$APP"
cp -R "$B/VPN Guard.app" "$APP"
chown -R root:wheel "$APP"; chmod -R go-w "$APP"
install -o root -g wheel -m 644 "$S/launchd/local.vpnguard.menubar.plist" "$AGENT_PLIST"
sleep 1
launchctl bootstrap "gui/$UIDN" "$AGENT_PLIST" 2>/dev/null || echo "иконка загрузится при следующем входе в систему"

echo "== Команда vpnguard"
sudo -u "$U" mkdir -p "$UHOME/.local/bin"
sudo -u "$U" ln -sfn "$BASE/vpnguard" "$UHOME/.local/bin/vpnguard"

echo "== Жду сторожа"
for i in $(seq 1 20); do [ -f "$BASE/status" ] && break; sleep 0.5; done
sleep 1
"$BASE/vpnguard" status || true
echo
echo "Готово. Памятка: $BASE/ПАМЯТКА.md · журнал: vpnguard log · обновление: vpnguard update"

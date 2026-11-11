# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""srs2cidr — список IPv4-сетей из сборки правил sing-box (.srs) Karing → pf/ru.cidr.

Запуск (из корня репозитория):
    uv run tools/srs2cidr.py [путь к ru.srs] > pf/ru.cidr

По умолчанию берёт geoip/ru.srs из /Applications/Karing.app. Разбирает только то, что бывает
в geoip-сборках (правило по умолчанию с ip_cidr); на всём остальном — отказ, а не догадка.
Формат .srs (sing-box common/srs/binary.go): «SRS», версия, дальше zlib-поток: число правил
(uvarint), у правила — тип (0 — обычное), затем элементы (тип-байт + данные) до 0xFF + invert.
IP-набор: версия 1, число диапазонов (uint64 big-endian), у диапазона from/to — uvarint-длина + байты.
"""
import hashlib
import ipaddress
import sys
import zlib
from datetime import date

DEFAULT = ("/Applications/Karing.app/Contents/Frameworks/App.framework/Versions/A/Resources/"
           "flutter_assets/assets/datas/geoip/ru.srs")
ITEM_SOURCE_IP_CIDR = 5
ITEM_IP_CIDR = 6
ITEM_FINAL = 0xFF


class Reader:
    def __init__(self, data: bytes):
        self.d, self.i = data, 0

    def byte(self) -> int:
        if self.i >= len(self.d):
            raise ValueError("неожиданный конец данных")
        b = self.d[self.i]
        self.i += 1
        return b

    def take(self, n: int) -> bytes:
        if self.i + n > len(self.d):
            raise ValueError("неожиданный конец данных")
        b = self.d[self.i:self.i + n]
        self.i += n
        return b

    def uvarint(self) -> int:
        x = s = 0
        while True:
            b = self.byte()
            x |= (b & 0x7F) << s
            if b < 0x80:
                return x
            s += 7
            if s > 63:
                raise ValueError("uvarint слишком длинный")


def read_ipset(r: Reader):
    if r.byte() != 1:
        raise ValueError("неизвестная версия IP-набора")
    n = int.from_bytes(r.take(8), "big")
    ranges = []
    for _ in range(n):
        a = r.take(r.uvarint())
        b = r.take(r.uvarint())
        if len(a) not in (4, 16) or len(a) != len(b):
            raise ValueError(f"странный диапазон: {a.hex()}–{b.hex()}")
        lo, hi = ipaddress.ip_address(a), ipaddress.ip_address(b)
        if lo > hi:
            raise ValueError(f"диапазон наоборот: {lo}–{hi}")
        ranges.append((lo, hi))
    return ranges


def parse(path: str):
    raw = open(path, "rb").read()
    if raw[:3] != b"SRS":
        raise ValueError("не .srs: нет сигнатуры SRS")
    version = raw[3]
    if version not in (1, 2, 3):
        raise ValueError(f"неизвестная версия .srs: {version}")
    r = Reader(zlib.decompress(raw[4:]))
    ranges = []
    for _ in range(r.uvarint()):
        if r.byte() != 0:
            raise ValueError("логическое правило — в geoip-сборке не ожидается")
        while True:
            t = r.byte()
            if t == ITEM_IP_CIDR:
                ranges += read_ipset(r)
            elif t == ITEM_FINAL:
                if r.byte() != 0:
                    raise ValueError("invert у правила — не ожидается")
                break
            else:
                raise ValueError(f"элемент правила типа {t} — в geoip-сборке не ожидается")
    if r.i != len(r.d):
        raise ValueError(f"после правил остались лишние байты: {len(r.d) - r.i}")
    return version, raw, ranges


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    version, raw, ranges = parse(path)
    nets = []
    for lo, hi in ranges:
        if lo.version == 4:   # Karing резолвит ipv4_only; IPv6 кроме локалки закрыт правилами
            nets += ipaddress.summarize_address_range(lo, hi)
    nets = list(ipaddress.collapse_addresses(nets))
    total = sum(n.num_addresses for n in nets)
    print("# vpnguard — российские IPv4-сети (geoip:ru), тот же список, что у Karing.")
    print(f"# Источник: {path}")
    print(f"# sha256 источника: {hashlib.sha256(raw).hexdigest()}")
    print(f"# Создан: {date.today().isoformat()} · tools/srs2cidr.py · .srs v{version}")
    print(f"# Сетей: {len(nets)} · адресов: {total}")
    for n in nets:
        print(n)


if __name__ == "__main__":
    main()

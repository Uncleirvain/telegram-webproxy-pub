#!/usr/bin/env python3
"""Abort guard activation if the provided admin IP belongs to a blocked subnet."""
import argparse
import ipaddress
import sys
from pathlib import Path


def check(path, admin_ip):
    ip = ipaddress.ip_address(admin_ip)
    if not ip.is_global:
        raise ValueError('Для проверки нужен публичный IP, с которого сервер видит SSH-подключение')
    count = 0
    blocked_by = []
    for lineno, raw in enumerate(Path(path).read_text(encoding='utf-8').splitlines(), 1):
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        try:
            network = ipaddress.ip_network(line, strict=False)
        except ValueError as exc:
            raise ValueError(f'Некорректная строка {lineno}: {exc}') from exc
        count += 1
        if ip in network:
            blocked_by.append(str(network))
    if count == 0:
        raise ValueError('Список блокировок пуст')
    return count, blocked_by


def main():
    p = argparse.ArgumentParser()
    p.add_argument('file')
    p.add_argument('admin_ip')
    args = p.parse_args()
    try:
        count, matches = check(args.file, args.admin_ip)
        if matches:
            print(f'ОТКАЗ: IP администратора {args.admin_ip} попадает в блокировки: {matches}', file=sys.stderr)
            sys.exit(2)
    except ValueError as exc:
        print(f'BLOCKLIST ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
    print(f'BLOCKLIST OK: {count} сетей, IP администратора отсутствует')


if __name__ == '__main__':
    main()

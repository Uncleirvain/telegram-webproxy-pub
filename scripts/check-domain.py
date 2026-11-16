#!/usr/bin/env python3
"""Preflight: validate a public DNS name and compare its A records to server egress IPv4."""
import argparse
import ipaddress
import re
import socket
import sys


def validate_hostname(host):
    if not isinstance(host, str) or len(host) > 253 or host != host.lower():
        raise ValueError('Домен должен быть lowercase ASCII, длиной не более 253 символов')
    if not re.fullmatch(r'[a-z0-9.-]+', host) or '.' not in host:
        raise ValueError('Используй FQDN, например proxy.example.com (IDN — в punycode)')
    if not all(0 < len(label) <= 63 and re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', label) for label in host.split('.')):
        raise ValueError('Недопустимое имя хоста или DNS-метка')
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return host
    raise ValueError('Вместо IP требуется доменное имя')


def check(domain, expected, allow_aaaa=False):
    validate_hostname(domain)
    ip = ipaddress.ip_address(expected)
    if ip.version != 4 or not ip.is_global:
        raise ValueError('Ожидаемый публичный IPv4 некорректен')
    answers = socket.getaddrinfo(domain, None, type=socket.SOCK_STREAM)
    v4 = {row[4][0] for row in answers if row[0] == socket.AF_INET}
    v6 = {row[4][0] for row in answers if row[0] == socket.AF_INET6}
    if not v4:
        raise ValueError('DNS не возвращает A-запись')
    if str(ip) not in v4:
        raise ValueError(f'A-запись указывает на {sorted(v4)}, но IPv4 сервера: {ip}')
    if v6 and not allow_aaaa:
        raise ValueError(f'Найдены AAAA-записи {sorted(v6)}. Удали их или запусти с --allow-aaaa после проверки публичного IPv6.')
    return sorted(v4), sorted(v6)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('domain')
    p.add_argument('expected_ipv4')
    p.add_argument('--allow-aaaa', action='store_true')
    args = p.parse_args()
    try:
        v4, v6 = check(args.domain, args.expected_ipv4, args.allow_aaaa)
    except (OSError, ValueError) as exc:
        print(f'DNS PREFLIGHT ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
    print(f'DNS OK: A={", ".join(v4)}' + (f'; AAAA={", ".join(v6)}' if v6 else ''))


if __name__ == '__main__':
    main()

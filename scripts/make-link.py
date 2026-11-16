#!/usr/bin/env python3
"""Write a private single-user link using active tproxy config, never generate a new secret."""
import argparse
import base64
import json
import os
import re
import tempfile
from pathlib import Path
from urllib.parse import urlencode


def build_link(config, profile):
    domain = config['public_hostname']
    base_path = config.get('base_path', '').strip('/')
    secret = profile['secret'].lower()
    if not re.fullmatch(r'[0-9a-f]{32}', secret):
        raise ValueError('Эта сборка установщика поддерживает 32-символьный hex-secret')
    server = domain + ('/' + base_path if base_path else '')
    public_secret = (
        base64.urlsafe_b64encode(b'\x70' + bytes.fromhex(secret)).decode('ascii').rstrip('=')
        if base_path else secret
    )
    url = 'https://t.me/webproxy?' + urlencode({'server': server, 'secret': public_secret})
    return server, secret, url


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--config', default='/etc/tproxy-server/config.json')
    p.add_argument('--profiles', default='/etc/tproxy-server/profiles.json')
    p.add_argument('--out', default='/root/tproxy-links.txt')
    args = p.parse_args()
    config = json.loads(Path(args.config).read_text())
    profiles = json.loads(Path(args.profiles).read_text())['profiles']
    if len(profiles) != 1:
        raise SystemExit('Ожидается ровно один профиль')
    server, secret, url = build_link(config, profiles[0])
    output = Path(args.out)
    fd, name = tempfile.mkstemp(prefix='.tproxy-links-', dir=str(output.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write('WEB Proxy (поддерживаемый экспериментальный клиент)\n')
            f.write('Прокси-сервер (вручную): ' + server + '\n')
            f.write('Секрет (вручную, hex): ' + secret + '\n')
            f.write('Ссылка для совместимого клиента: ' + url + '\n')
        os.replace(name, output)
    finally:
        if os.path.exists(name):
            os.unlink(name)
    print('Ссылка и данные доступа сохранены:', output)


if __name__ == '__main__':
    main()

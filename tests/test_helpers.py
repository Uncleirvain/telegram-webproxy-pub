import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def module(filename):
    spec = importlib.util.spec_from_file_location(filename.replace('-', '_'), ROOT / 'scripts' / filename)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class HelpersTest(unittest.TestCase):
    def test_domain(self):
        d = module('check-domain.py')
        self.assertEqual(d.validate_hostname('proxy.example.com'), 'proxy.example.com')
        for bad in ['HTTPS://proxy.example.com', 'a..example.com', 'bad_.example.com', '127.0.0.1', 'LOCAL.example.com']:
            with self.assertRaises(ValueError):
                d.validate_hostname(bad)

    def test_link_with_basepath(self):
        l = module('make-link.py')
        host, secret, link = l.build_link({'public_hostname':'proxy.example.com', 'base_path':'abc123'}, {'secret':'8561944064fc730cbfa4473562d8ec59'})
        self.assertEqual(host, 'proxy.example.com/abc123')
        self.assertIn('server=proxy.example.com%2Fabc123', link)
        self.assertIn('secret=cIVhlEBk_HMMv6RHNWLY7Fk', link)

    def test_link_without_basepath(self):
        l = module('make-link.py')
        _, _, link = l.build_link({'public_hostname':'proxy.example.com', 'base_path':''}, {'secret':'0123456789abcdef0123456789abcdef'})
        self.assertIn('secret=0123456789abcdef0123456789abcdef', link)

    def test_blocklist(self):
        b = module('check-blocklist.py')
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'list.txt'
            p.write_text('8.8.8.0/24\n2001:4860:4860::/48\n')
            self.assertEqual(b.check(p, '8.8.8.4')[1], ['8.8.8.0/24'])
            self.assertEqual(b.check(p, '1.1.1.1')[1], [])
            self.assertEqual(b.check(p, '2001:4860:4860::8888')[1], ['2001:4860:4860::/48'])


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Exercise the real Swift coordinator + installed Claude CLI with disposable OAuth credentials.

All child HTTPS requests terminate at this local fixture server. No real tokens are copied,
no trust settings are changed, and the temporary Keychain item is removed on exit.
Run after swift test: python3 tests/check_claude_renewal.py
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit


def main():
    with tempfile.TemporaryDirectory(prefix='ai-usage-renewal-fixture-') as directory:
        root = Path(directory).resolve()
        root.chmod(0o700)
        certificate, key = root / 'cert.pem', root / 'key.pem'
        config = root / 'openssl.cnf'
        config.write_text('''[req]
prompt=no
distinguished_name=dn
x509_extensions=ext
[dn]
CN=AI Usage disposable OAuth fixture
[ext]
subjectAltName=DNS:*.anthropic.com,DNS:anthropic.com,DNS:*.claude.com,DNS:claude.com,DNS:claude.ai,DNS:*.claude.ai
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment
''')
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(certificate), '-days', '1', '-config', str(config)],
                       capture_output=True, check=True)
        key.chmod(0o600)
        now = int(time.time() * 1000)
        scopes = ['user:profile', 'user:inference', 'user:sessions:claude_code']
        credentials = root / '.credentials.json'
        credentials.write_text(json.dumps({'claudeAiOauth': {
            'accessToken': 'fixture-access-old', 'refreshToken': 'fixture-refresh-old',
            'expiresAt': now + 120_000, 'refreshTokenExpiresAt': now + 25 * 86_400_000,
            'scopes': scopes, 'subscriptionType': 'max', 'rateLimitTier': 'default_claude_max_5x',
        }}))
        credentials.chmod(0o600)
        account = {
            'accountUuid': '11111111-1111-4111-8111-111111111111',
            'organizationUuid': '22222222-2222-4222-8222-222222222222',
            'emailAddress': 'fixture@example.invalid', 'organizationType': 'claude_max',
            'billingType': 'stripe_subscription', 'accountCreatedAt': '2025-01-01T00:00:00Z',
            'subscriptionCreatedAt': '2025-01-01T00:00:00Z', 'ccOnboardingFlags': {},
        }
        (root / '.claude.json').write_text(json.dumps({'hasCompletedOnboarding': True, 'oauthAccount': account}))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        requests = []
        refreshes = []

        class App(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                path = urlsplit(self.path).path
                requests.append((self.command, path))
                status = 200
                if path == '/v1/oauth/token':
                    payload = json.loads(body)
                    count = len(refreshes) + 1
                    expected = 'fixture-refresh-old' if count == 1 else f'fixture-refresh-new-{count - 1}'
                    # Reject any unexpected credential without ever logging it.
                    assert payload.get('grant_type') == 'refresh_token'
                    assert payload.get('refresh_token') == expected
                    refreshes.append(count)
                    result = {
                        'access_token': f'fixture-access-new-{count}',
                        'refresh_token': f'fixture-refresh-new-{count}',
                        'expires_in': 300 if count == 1 else 28800,
                        'refresh_token_expires_in': 30 * 86400,
                        'scope': ' '.join(scopes), 'token_type': 'Bearer',
                    }
                elif path == '/api/oauth/profile':
                    result = {
                        'account': {'uuid': account['accountUuid'], 'email': 'fixture@example.invalid'},
                        'organization': {'uuid': account['organizationUuid'], 'organization_type': 'claude_max',
                                         'rate_limit_tier': 'default_claude_max_5x', 'billing_type': 'stripe_subscription'},
                    }
                else:
                    status, result = 403, {'error': {'type': 'permission_error', 'message': 'Blocked by fixture'}}
                data = json.dumps(result).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(data)

        class Proxy(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_CONNECT(self):
                self.send_response(200, 'Connection established')
                self.end_headers()
                with context.wrap_socket(self.connection, server_side=True) as connection:
                    App(connection, self.client_address, self.server)

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True

        service = 'Claude Code-credentials-' + hashlib.sha256(str(root).encode()).hexdigest()[:8]
        server = Server(('127.0.0.1', 0), Proxy)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith(('CLAUDE', 'ANTHROPIC', 'OTEL'))
                       and k.upper() not in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')}
        environment.update({
            'AI_USAGE_CLAUDE_RENEWAL_FIXTURE': str(root), 'NODE_EXTRA_CA_CERTS': str(certificate),
            'HTTP_PROXY': f'http://127.0.0.1:{server.server_port}',
            'HTTPS_PROXY': f'http://127.0.0.1:{server.server_port}', 'NO_PROXY': 'localhost,127.0.0.1',
        })
        try:
            result = subprocess.run(['swift', 'test', '--skip-build', '--filter', 'renewalWithInstalledClaudeFixture'],
                                    cwd=Path(__file__).resolve().parents[1], env=environment,
                                    capture_output=True, text=True, timeout=90)
            assert result.returncode == 0, result.stdout + result.stderr
            assert len(refreshes) == 2, f'Expected two confirmed renewals, observed {len(refreshes)}'
            assert not any('messages' in path or 'completion' in path for _, path in requests), requests
            print('Real CLI integration passed: two renewals, both saved and rescheduled; no model requests.')
        finally:
            server.shutdown()
            subprocess.run(['/usr/bin/security', 'delete-generic-password', '-s', service],
                           capture_output=True, timeout=5)
            check = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', service, '-w'],
                                   capture_output=True, timeout=5)
            assert check.returncode != 0, 'Temporary Keychain item was not removed'


if __name__ == '__main__':
    main()

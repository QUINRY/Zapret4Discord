"""Anonymous TLS, update endpoint and WebSocket checks; never reads account tokens."""
import base64
import json
import os
import socket
import ssl

results = []
for host, path, upgrade, expected in [
    ('discord.com', '/api/v10/gateway', False, 200),
    ('updates.discord.com', '/distributions/app/manifests/latest?channel=stable&platform=win&arch=x64', False, 200),
    ('gateway.discord.gg', '/?v=10&encoding=json', True, 101),
]:
    try:
        with socket.create_connection((host, 443), timeout=6) as raw:
            with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as stream:
                headers = f'GET {path} HTTP/1.1\r\nHost: {host}\r\n'
                if upgrade:
                    key = base64.b64encode(os.urandom(16)).decode()
                    headers += f'Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n'
                else:
                    headers += 'Connection: close\r\n'
                stream.sendall((headers + '\r\n').encode())
                response = stream.recv(4096)
                status = int(response.split(b' ', 2)[1])
                results.append({'host': host, 'tls': stream.version(), 'status': status, 'passed': status == expected})
    except Exception as error:
        results.append({'host': host, 'passed': False, 'error': str(error)})
print(json.dumps(results, indent=2))
raise SystemExit(0 if all(result['passed'] for result in results) else 1)

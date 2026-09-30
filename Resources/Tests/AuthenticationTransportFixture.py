"""Exercise production curl/Mbed TLS against a local HTTPS fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import threading
import ssl
import tempfile
from pathlib import Path

requests = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        requests.append((self.client_address, self.path, body, self.headers))
        index = len(requests)
        payload = b"fixture-success" if index == 3 else b""
        self.send_response({1: 204, 2: 302, 3: 200}.get(index, 500))
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "keep-alive")
        if index == 1:
            self.send_header("Set-Cookie", "synthetic-session=fixture; Path=/; HttpOnly")
            self.send_header("Set-Cookie", "second-session=fixture; Path=/; Expires=Tue, 01 Jan 2030 00:00:00 GMT; Secure")
        if index == 2:
            self.send_header("Location", "/pod")
        self.end_headers()
        self.wfile.write(payload)


temporary = tempfile.TemporaryDirectory()
root = Path(temporary.name)
(root / 'openssl.cnf').write_text('''[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=localhost
[extensions]
basicConstraints=critical,CA:TRUE
subjectAltName=DNS:localhost
''')
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-config', str(root / 'openssl.cnf'), '-keyout', str(root / 'key.pem'),
                '-out', str(root / 'cert.pem')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.set_alpn_protocols(['http/1.1'])
tls.load_cert_chain(root / 'cert.pem', root / 'key.pem')
server.socket = tls.wrap_socket(server.socket, server_side=True)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    subprocess.run([sys.argv[1], f"https://localhost:{server.server_port}",
                    str(root / 'cert.pem'), sys.argv[2]], check=True, timeout=45)
    assert len(requests) == 3, "Automatic redirect or unexpected retry"
    assert len({request[0] for request in requests}) == 3, "Reused a TCP connection"
    assert [request[1] for request in requests] == ["/login", "/login", "/pod"]
    assert all(request[2] == b"synthetic-body" for request in requests)
    assert all(request[3]["X-Apple-ActionSignature"] == "synthetic-signature" for request in requests)
    assert all(request[3].get('Host', '').startswith('localhost:') for request in requests)
    assert all("synthetic-session=fixture" in request[3].get("Cookie", "") for request in requests[1:])
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    temporary.cleanup()

"""Exercise production URLSession transport against a keep-alive loopback fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import threading

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
        if index == 2:
            self.send_header("Location", "/pod")
        self.end_headers()
        self.wfile.write(payload)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}"], check=True, timeout=30)
    assert len(requests) == 3, "Automatic redirect or unexpected retry"
    assert len({request[0] for request in requests}) == 3, "Reused a TCP connection"
    assert [request[1] for request in requests] == ["/login", "/login", "/pod"]
    assert all(request[2] == b"synthetic-body" for request in requests)
    assert all(request[3]["X-Apple-ActionSignature"] == "synthetic-signature" for request in requests)
    assert all("synthetic-session=fixture" in request[3].get("Cookie", "") for request in requests[1:])
finally:
    server.shutdown()
    server.server_close()
    thread.join()

import http.server
import os
import socket
import ssl
import subprocess
import threading
from pathlib import Path

HTTP_PORT = 80
HTTPS_PORT = 443
DNS_PORT = 53
ROOT = Path(__file__).resolve().parent
CERT_FILE = ROOT / "cert.pem"
KEY_FILE = ROOT / "key.pem"

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def log_message(self, format, *args):
        print(f"[{self.client_address[0]}] {format % args}")

    def do_GET(self):
        # Redirect PS5 User's Guide subpath to the root exploit index.html
        if self.path.startswith("/document/"):
            self.send_response(302)
            self.send_header("Location", "/index.html")
            self.end_headers()
            return
        super().do_GET()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        super().end_headers()

def local_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return "127.0.0.1"

def ensure_ssl_certs():
    if not (CERT_FILE.exists() and KEY_FILE.exists()):
        print(f"[*] Generating self-signed SSL certificate for manuals.playstation.net...")
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", str(KEY_FILE),
                "-out", str(CERT_FILE),
                "-days", "365", "-nodes",
                "-subj", "/CN=manuals.playstation.net"
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        print(f"[+] Certificate created ({CERT_FILE.name}, {KEY_FILE.name})")

def extract_domain(data):
    try:
        idx = 12
        parts = []
        while idx < len(data) and data[idx] != 0:
            length = data[idx]
            idx += 1
            parts.append(data[idx:idx + length].decode("utf-8", errors="replace"))
            idx += length
        return ".".join(parts)
    except Exception:
        return "unknown"

def start_dns_server(ip):
    def dns_worker():
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except Exception:
            pass

        bound_addr = None
        # Try binding to specific LAN IP first (bypasses conflict with systemd-resolved on 127.0.0.53)
        for target in [ip, "0.0.0.0"]:
            try:
                sock.bind((target, DNS_PORT))
                bound_addr = target
                break
            except Exception:
                continue

        if not bound_addr:
            print(f"[!] Warning: Could not bind UDP port {DNS_PORT}. DNS responder disabled.")
            print(f"    (Make sure to run with 'sudo python3 serve.py' or check for existing DNS services).")
            return

        ip_bytes = socket.inet_aton(ip)
        print(f"[+] DNS Server active on {bound_addr}:{DNS_PORT} (resolving queries to {ip})")

        while True:
            try:
                data, addr = sock.recvfrom(512)
                if len(data) < 12:
                    continue
                tid = data[:2]
                flags = b"\x81\x80"
                qdcount = data[4:6]
                ancount = b"\x00\x01"
                nscount = b"\x00\x00"
                arcount = b"\x00\x00"

                # Parse question
                idx = 12
                while idx < len(data) and data[idx] != 0:
                    idx += 1 + data[idx]
                idx += 5
                question = data[12:idx]
                answer = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + ip_bytes
                response = tid + flags + qdcount + ancount + nscount + arcount + question + answer
                sock.sendto(response, addr)

                domain = extract_domain(data)
                print(f"[DNS] {addr[0]} queried '{domain}' -> replied {ip}")
            except Exception:
                pass

    t = threading.Thread(target=dns_worker, daemon=True)
    t.start()

def main():
    ip = local_ip()
    ensure_ssl_certs()
    start_dns_server(ip)

    # HTTP Server
    try:
        http_server = http.server.ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
        t_http = threading.Thread(target=http_server.serve_forever, daemon=True)
        t_http.start()
        print(f"[+] HTTP Server:  http://{ip}:{HTTP_PORT}/")
    except Exception as e:
        print(f"[!] HTTP Server failed on port {HTTP_PORT}: {e}")

    # HTTPS Server
    try:
        https_server = http.server.ThreadingHTTPServer(("0.0.0.0", HTTPS_PORT), Handler)
        ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_ctx.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        https_server.socket = ssl_ctx.wrap_socket(https_server.socket, server_side=True)
        t_https = threading.Thread(target=https_server.serve_forever, daemon=True)
        t_https.start()
        print(f"[+] HTTPS Server: https://{ip}:{HTTPS_PORT}/")
    except Exception as e:
        print(f"[!] HTTPS Server failed on port {HTTPS_PORT}: {e}")

    print("\n--- PS5 Connection Guide ---")
    print(f"Option 1 (User's Guide Method):")
    print(f"  1. Go to PS5 Settings -> Network -> Settings -> Set Up Internet Connection.")
    print(f"  2. In your connection's Advanced Settings, set Primary DNS to: {ip}")
    print(f"  3. Open Settings -> User's Guide, Health & Safety, and Other Information -> User's Guide.")
    print(f"  4. When prompted with the SSL certificate warning, select 'Yes' to accept.")
    print(f"\nOption 2 (Direct Browser / Messages Method - No SSL Warning):")
    print(f"  1. Send a message to any PSN account with: http://{ip}/")
    print(f"  2. Click the link on your PS5 to open it directly in the web browser.")
    print("----------------------------\n")
    print("Server running. Press Ctrl+C to stop.")

    try:
        while True:
            threading.Event().wait(100)
    except KeyboardInterrupt:
        print("\nShutting down servers...")

if __name__ == "__main__":
    main()
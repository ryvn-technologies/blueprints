import argparse
import http.client
import socket
import ssl
import time


parser = argparse.ArgumentParser()
parser.add_argument("origin_ip")
parser.add_argument("--pause", type=int, default=25)
args = parser.parse_args()

context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
with socket.create_connection((args.origin_ip, 443), timeout=10) as plain:
    with context.wrap_socket(plain, server_hostname="example.com") as connection:
        connection.settimeout(10)
        print(f"connection={connection.getsockname()}->{connection.getpeername()}", flush=True)
        for phase in ("before", "during", "repaired"):
            nonce = time.time_ns()
            print(f"phase={phase} nonce={nonce} time={time.time()}", flush=True)
            connection.sendall(
                f"GET /?egfw={phase}-{nonce} HTTP/1.1\r\n"
                "Host: example.com\r\nConnection: keep-alive\r\n\r\n".encode()
            )
            response = http.client.HTTPResponse(connection)
            response.begin()
            print(f"status={response.status} body={response.read().decode().strip()}", flush=True)
            if phase != "repaired":
                time.sleep(args.pause)

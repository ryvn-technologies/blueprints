import argparse
import socket
import ssl
import time


def tcp_probe(host, port, payload, target_ip=None):
    address = target_ip or socket.gethostbyname(host)
    print(f"destination={address}:{port}")
    with socket.create_connection((address, port), timeout=8) as connection:
        print(f"source={connection.getsockname()}")
        connection.settimeout(8)
        connection.sendall(payload)
        try:
            print(f"response={connection.recv(256)!r}")
        except socket.timeout:
            print("response=timeout")


def segmented_http():
    address = socket.gethostbyname("example.net")
    print(f"destination={address}:80")
    with socket.create_connection((address, 80), timeout=8) as connection:
        connection.settimeout(8)
        connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        connection.sendall(b"GET / HTTP/1.1\r\nHost: exam")
        time.sleep(0.5)
        connection.sendall(b"ple.net\r\nConnection: close\r\n\r\n")
        print(f"response={connection.recv(256)!r}")


def segmented_tls():
    address = socket.gethostbyname("example.com")
    print(f"destination={address}:443")
    inbound = ssl.MemoryBIO()
    outbound = ssl.MemoryBIO()
    client = ssl.create_default_context().wrap_bio(inbound, outbound, server_hostname="example.com")
    with socket.create_connection((address, 443), timeout=8) as connection:
        connection.settimeout(8)
        connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        first_record = True
        while True:
            try:
                client.do_handshake()
                break
            except ssl.SSLWantReadError:
                pass
            pending = outbound.read()
            if pending:
                if first_record:
                    connection.sendall(pending[:9])
                    time.sleep(0.5)
                    connection.sendall(pending[9:])
                    first_record = False
                else:
                    connection.sendall(pending)
            inbound.write(connection.recv(16384))
        client.write(b"GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
        connection.sendall(outbound.read())
        inbound.write(connection.recv(16384))
        print(f"response={client.read(256)!r}")


def udp_probe():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.settimeout(5)
        connection.sendto(b"egfw-udp443-canary", ("1.1.1.1", 443))
        print("destination=1.1.1.1:443/udp sent")
        try:
            print(f"response={connection.recv(256)!r}")
        except socket.timeout:
            print("response=timeout; check native firewall ALERT for verdict")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=["http443", "malformed80", "nonweb443", "segmented_http", "segmented_tls", "udp443"])
    parser.add_argument("--target-ip", help="controlled origin IPv4 address")
    args = parser.parse_args()
    case = args.case
    print(f"case={case} timestamp={time.time()}")
    if case == "http443":
        tcp_probe("example.com", 443, b"GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", args.target_ip)
    elif case == "malformed80":
        tcp_probe("example.net", 80, b"BOGUS / HTTP/1.1\r\nMalformed: yes\r\n\r\n")
    elif case == "nonweb443":
        tcp_probe("example.com", 443, b"egfw-non-tls-canary\x00\r\n", args.target_ip)
    elif case == "segmented_http":
        segmented_http()
    elif case == "segmented_tls":
        segmented_tls()
    else:
        udp_probe()

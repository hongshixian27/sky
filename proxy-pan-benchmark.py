import concurrent.futures
import json
import socket
import ssl
import time


IPS = [
    "220.181.7.1",
    "220.181.33.174",
    "220.181.111.189",
    "183.240.98.84",
    "14.215.182.75",
    "163.177.17.6",
    "163.177.17.189",
    "36.155.169.188",
    "180.101.50.208",
    "180.101.50.249",
    "153.3.237.117",
    "157.0.146.158",
    "110.242.70.68",
    "110.242.70.69",
]

AUTH = "1951164069"
TARGET_HOST = "pub-1b3cd0ceef4949aba92604ef86a1dd04.r2.dev"
TARGET_PATH = "/sky.apk"
RANGE_END = 2 * 1024 * 1024 - 1


def recv_headers(sock):
    data = bytearray()
    while b"\r\n\r\n" not in data and len(data) < 32768:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data.extend(chunk)
    head, sep, body = bytes(data).partition(b"\r\n\r\n")
    return head, body if sep else b""


def benchmark(ip):
    result = {"ip": ip}
    started = time.perf_counter()
    try:
        raw = socket.create_connection((ip, 443), timeout=5)
        result["tcp_ms"] = round((time.perf_counter() - started) * 1000, 1)
        raw.settimeout(12)
        request = (
            f"CONNECT {TARGET_HOST}:443 HTTP/1.1\r\n"
            "Host: pan.wo.cn\r\n"
            "User-Agent: baiduboxapp\r\n"
            "Connection: Keep-Alive\r\n"
            f"X-T5-Auth: {AUTH}\r\n\r\n"
        ).encode("ascii")
        raw.sendall(request)
        response_head, _ = recv_headers(raw)
        status_line = response_head.split(b"\r\n", 1)[0].decode("latin1", "replace")
        result["connect_status"] = status_line
        if " 200 " not in status_line:
            raw.close()
            return result

        context = ssl.create_default_context()
        tls = context.wrap_socket(raw, server_hostname=TARGET_HOST)
        get_request = (
            f"GET {TARGET_PATH} HTTP/1.1\r\n"
            f"Host: {TARGET_HOST}\r\n"
            "User-Agent: proxy-benchmark/1.0\r\n"
            f"Range: bytes=0-{RANGE_END}\r\n"
            "Connection: close\r\n\r\n"
        ).encode("ascii")
        download_started = time.perf_counter()
        tls.sendall(get_request)
        response_head, initial_body = recv_headers(tls)
        download_status = response_head.split(b"\r\n", 1)[0].decode("latin1", "replace")
        total = len(initial_body)
        while total <= RANGE_END:
            chunk = tls.recv(min(65536, RANGE_END + 1 - total))
            if not chunk:
                break
            total += len(chunk)
        elapsed = time.perf_counter() - download_started
        result["download_status"] = download_status
        result["bytes"] = total
        result["mbps"] = round(total * 8 / max(elapsed, 0.001) / 1_000_000, 2)
        tls.close()
    except Exception as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
    return result


def main():
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(IPS)) as pool:
        results = list(pool.map(benchmark, IPS))
    results.sort(key=lambda item: item.get("mbps", -1), reverse=True)
    print(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

"""Loopback-only CONNECT adapter: CN upstream first, direct on setup failure.

Never replays application data after a tunnel has been established.
The upstream authentication header is supplied only through the environment.
"""
import asyncio
import contextlib
import ipaddress
import os
import socket
import time
from collections import OrderedDict


class Proxy:
    def __init__(self, upstream='220.181.7.1', port=443, auth='', timeout=4):
        if any(c in auth for c in '\r\n'):
            raise ValueError('Invalid upstream authentication header')
        self.upstream, self.port, self.auth = upstream, port, auth
        self.timeout = timeout
        self.cooldown = OrderedDict()
        self.active = 0

    @staticmethod
    def target(authority):
        if not authority.isascii() or any(c.isspace() for c in authority):
            raise ValueError('Invalid destination')
        host, port = authority.rsplit(':', 1)
        host = host.strip('[]')
        port = int(port)
        if not host or not 1 <= port <= 65535 or any(c in host for c in '/\\@?#'):
            raise ValueError('Invalid destination')
        return host, port

    async def upstream_connect(self, authority):
        writer = None
        try:
            reader, writer = await asyncio.open_connection(self.upstream, self.port, limit=32768)
            request = (f'CONNECT {authority} HTTP/1.1\r\nHost: ascdn.baidu.com\r\n'
                       f'User-Agent: baiduboxapp\r\nConnection: Keep-Aliv\r\n'
                       f'X-T5-Auth: {self.auth}\r\n\r\n')
            writer.write(request.encode('ascii'))
            await writer.drain()
            header = await reader.readuntil(b'\r\n\r\n')
            if header.split(b'\r\n', 1)[0].split()[1] != b'200':
                raise ConnectionError('Upstream CONNECT refused')
            return reader, writer
        except BaseException:
            if writer:
                writer.close()
            raise

    async def connect(self, authority):
        host, port = self.target(authority)
        try:
            local = not ipaddress.ip_address(host).is_global
        except ValueError:
            local = '.' not in host or host.lower().endswith(('.local', '.lan', '.ts.net'))
        if not local and self.auth and self.cooldown.get(authority, 0) <= time.monotonic():
            try:
                return await asyncio.wait_for(self.upstream_connect(authority), self.timeout)
            except (OSError, ValueError, IndexError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
                self.cooldown[authority] = time.monotonic() + 15
                self.cooldown.move_to_end(authority)
                while len(self.cooldown) > 1024:
                    self.cooldown.popitem(last=False)
        return await asyncio.wait_for(asyncio.open_connection(host, port), 8)

    async def handle(self, reader, writer):
        upstream = None
        established = False
        tasks = []
        if self.active >= 128:
            writer.write(b'HTTP/1.1 503 Busy\r\nContent-Length: 0\r\n\r\n')
            writer.close()
            return
        self.active += 1
        try:
            header = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
            method, authority, version = header.split(b'\r\n', 1)[0].decode('ascii').split()
            if method != 'CONNECT' or version not in ('HTTP/1.1', 'HTTP/1.0'):
                raise ValueError('Only CONNECT is supported')
            remote, upstream = await self.connect(authority)
            for w in (writer, upstream):
                sock = w.get_extra_info('socket')
                if sock:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            writer.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            await writer.drain()
            established = True

            async def copy(src, dst):
                while True:
                    data = await asyncio.wait_for(src.read(65536), 300)
                    if not data:
                        if dst.can_write_eof():
                            dst.write_eof()
                        return
                    dst.write(data)
                    await asyncio.wait_for(dst.drain(), 30)

            tasks = [asyncio.create_task(copy(reader, upstream)), asyncio.create_task(copy(remote, writer))]
            await asyncio.gather(*tasks)
        except (OSError, ValueError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            if not established:
                with contextlib.suppress(Exception):
                    writer.write(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n')
                    await writer.drain()
        finally:
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            if upstream:
                upstream.close()
            writer.close()
            self.active -= 1


async def main():
    proxy = Proxy(auth=os.environ.get('CN_PROXY_AUTH', ''))
    server = await asyncio.start_server(proxy.handle, '127.0.0.1', 18082, limit=32768)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())

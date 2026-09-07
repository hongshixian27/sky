import asyncio
import importlib.util
import pathlib
import sys
import unittest

spec = importlib.util.spec_from_file_location('fallback', pathlib.Path(__file__).with_name('cn-fallback.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Tests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.servers = []

    async def asyncTearDown(self):
        for server in self.servers:
            server.close()
            await server.wait_closed()

    async def serve(self, handler):
        server = await asyncio.start_server(handler, '127.0.0.1', 0)
        self.servers.append(server)
        return server.sockets[0].getsockname()[1]

    async def test_upstream_success_preserves_buffered_bytes(self):
        async def fake(reader, writer):
            header = await reader.readuntil(b'\r\n\r\n')
            self.assertIn(b'Host: ascdn.baidu.com', header)
            self.assertIn(b'X-T5-Auth: test-only', header)
            writer.write(b'HTTP/1.1 200 OK\r\n\r\nhello')
            await writer.drain()
            writer.close()
        port = await self.serve(fake)
        proxy = module.Proxy('127.0.0.1', port, 'test-only')
        reader, writer = await proxy.connect('example.com:443')
        self.assertEqual(await reader.read(), b'hello')
        writer.close()

    async def test_refusal_and_timeout_fall_back(self):
        for failure in ('refuse', 'timeout'):
            async def fake(reader, writer):
                await reader.readuntil(b'\r\n\r\n')
                if failure == 'refuse':
                    writer.write(b'HTTP/1.1 503 Failed\r\n\r\n')
                    await writer.drain()
                else:
                    await reader.read()
                writer.close()
            port = await self.serve(fake)
            proxy = module.Proxy('127.0.0.1', port, 'test-only', timeout=.05)
            real_open = asyncio.open_connection
            direct_calls = []
            async def open_test(host, p, **kwargs):
                if host == 'example.com':
                    direct_calls.append((host, p))
                    return 'direct-reader', 'direct-writer'
                return await real_open(host, p, **kwargs)
            module.asyncio.open_connection = open_test
            try:
                self.assertEqual(await proxy.connect('example.com:443'), ('direct-reader', 'direct-writer'))
                self.assertEqual(await proxy.connect('example.com:443'), ('direct-reader', 'direct-writer'))
                self.assertEqual(len(direct_calls), 2)
                self.assertEqual(len(proxy.cooldown), 1)
            finally:
                module.asyncio.open_connection = real_open

    async def test_loopback_bypasses_upstream(self):
        async def echo(reader, writer):
            writer.write(b'direct');await writer.drain();writer.close()
        port = await self.serve(echo)
        proxy = module.Proxy('127.0.0.1', 1, 'test-only')
        reader, writer = await proxy.connect('127.0.0.1:'+str(port))
        self.assertEqual(await reader.read(), b'direct')
        self.assertEqual(len(proxy.cooldown), 0)
        writer.close()

    async def test_connect_tunnel(self):
        async def echo(reader, writer):
            data=await reader.read(100);writer.write(data);await writer.drain();writer.close()
        target = await self.serve(echo)
        proxy = module.Proxy()
        port = await self.serve(proxy.handle)
        reader, writer = await asyncio.open_connection('127.0.0.1', port)
        writer.write(f'CONNECT 127.0.0.1:{target} HTTP/1.1\r\n\r\npayload'.encode())
        await writer.drain()
        self.assertIn(b'200', await reader.readuntil(b'\r\n\r\n'))
        self.assertEqual(await reader.readexactly(7), b'payload')
        writer.close()
        await writer.wait_closed()

    def test_reject_header_injection(self):
        with self.assertRaises(ValueError): module.Proxy(auth='bad\r\nheader')
        with self.assertRaises(ValueError): module.Proxy.target('host\r\n:443')


if __name__ == '__main__':
    if sys.platform == 'win32':
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    unittest.main()

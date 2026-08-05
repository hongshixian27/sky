FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install the official Cloudflare WARP client and process supervisor.
RUN apt-get update && apt-get install -y --no-install-recommends       ca-certificates curl gnupg supervisor     && curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg       | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg     && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main"       > /etc/apt/sources.list.d/cloudflare-client.list     && apt-get update     && apt-get install -y --no-install-recommends cloudflare-warp     && rm -rf /var/lib/apt/lists/*

# Install sing-box. WARP runs as a local SOCKS5 egress for sing-box.
RUN curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz       | tar -xz -C /tmp     && install -m 0755 /tmp/sing-box-1.11.0-linux-amd64/sing-box /usr/local/bin/sing-box     && rm -rf /tmp/sing-box-1.11.0-linux-amd64

RUN mkdir -p /app /etc/supervisor/conf.d /var/log /run/cloudflare-warp

COPY config.json /app/config.json
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
COPY warp-init.sh /usr/local/bin/warp-init.sh
RUN chmod 0755 /entrypoint.sh /usr/local/bin/warp-init.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

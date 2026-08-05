FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends       ca-certificates curl gnupg gzip nginx supervisor     && curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg       | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg     && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main"       > /etc/apt/sources.list.d/cloudflare-client.list     && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg       > /usr/share/keyrings/tailscale-archive-keyring.gpg     && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list       > /etc/apt/sources.list.d/tailscale.list     && apt-get update     && apt-get install -y --no-install-recommends cloudflare-warp tailscale     && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz       | tar -xz -C /tmp     && install -m 0755 /tmp/sing-box-1.11.0-linux-amd64/sing-box /usr/local/bin/sing-box     && rm -rf /tmp/sing-box-1.11.0-linux-amd64

RUN mkdir -p /opt/alist /data     && curl -fsSL https://github.com/AlistGo/alist/releases/latest/download/alist-linux-amd64.tar.gz       | tar -xz -C /opt/alist     && chmod 0755 /opt/alist/alist     && ln -s /data /opt/alist/data

RUN mkdir -p /app /etc/supervisor/conf.d /var/log       /var/lib/tailscale /var/run/tailscale /run/cloudflare-warp

COPY config.json /app/config.json
COPY nginx.conf /etc/nginx/nginx.conf
RUN nginx -t
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
COPY warp-init.sh /usr/local/bin/warp-init.sh
COPY tailscale-init.sh /usr/local/bin/tailscale-init.sh
COPY alist-init.sh /usr/local/bin/alist-init.sh

RUN chmod 0755 /entrypoint.sh       /usr/local/bin/warp-init.sh       /usr/local/bin/tailscale-init.sh       /usr/local/bin/alist-init.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

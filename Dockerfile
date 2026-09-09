FROM golang:1.25-bookworm AS bootstrap-builder

WORKDIR /src
COPY alist-bootstrap.go .
COPY huawei-proxy.go .
COPY header-cache.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /alist-bootstrap ./alist-bootstrap.go \
    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /huawei-proxy ./huawei-proxy.go \
    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /header-cache ./header-cache.go

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gzip nginx supervisor python3 iproute2 iptables \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
      > /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
      > /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v1.11.0/sing-box-1.11.0-linux-amd64.tar.gz \
      | tar -xz -C /tmp \
    && install -m 0755 /tmp/sing-box-1.11.0-linux-amd64/sing-box /usr/local/bin/sing-box \
    && rm -rf /tmp/sing-box-1.11.0-linux-amd64

RUN mkdir -p /opt/alist /data \
    && curl -fsSL https://github.com/AlistGo/alist/releases/latest/download/alist-linux-amd64.tar.gz \
      | tar -xz -C /opt/alist \
    && chmod 0755 /opt/alist/alist \
    && ln -s /data /opt/alist/data

RUN mkdir -p /app /etc/supervisor/conf.d /var/log \
      /var/lib/tailscale /var/run/tailscale

COPY config.json /app/config.json
COPY cn-fallback.py /app/cn-fallback.py
COPY cn-fallback-test.py /app/cn-fallback-test.py
COPY proxy-pan-benchmark.py /app/proxy-pan-benchmark.py
RUN python3 /app/cn-fallback-test.py
RUN curl -fSL --retry 3 --connect-timeout 15 --max-time 90 \
      https://raw.githubusercontent.com/SagerNet/sing-geosite/5a5a9abc760d2653948c9549c4cb56cc3279e1aa/geosite-cn.srs -o /app/geosite-cn.srs \
    && curl -fSL --retry 3 --connect-timeout 15 --max-time 90 \
      https://raw.githubusercontent.com/SagerNet/sing-geosite/5a5a9abc760d2653948c9549c4cb56cc3279e1aa/geosite-category-ai-!cn.srs -o /app/geosite-category-ai-non-cn.srs \
    && curl -fSL --retry 3 --connect-timeout 15 --max-time 90 \
      https://raw.githubusercontent.com/SagerNet/sing-geoip/b9c5e675b4d5359d4b47f4434fa7ae77e9991306/geoip-cn.srs -o /app/geoip-cn.srs \
    && /usr/local/bin/sing-box check -c /app/config.json
COPY alist-backup.enc /app/alist-backup.enc
COPY --from=bootstrap-builder /alist-bootstrap /usr/local/bin/alist-bootstrap
COPY --from=bootstrap-builder /huawei-proxy /usr/local/bin/huawei-proxy
COPY --from=bootstrap-builder /header-cache /usr/local/bin/header-cache
COPY nginx.conf /etc/nginx/nginx.conf.template
RUN sed -e 's/__UPSTREAM_ADDR__/127.0.0.1/g' \
        -e 's/__LIVE_UPSTREAM_ADDR__/127.0.0.1/g' \
        /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf \
    && nginx -t
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
COPY tailscale-init.sh /usr/local/bin/tailscale-init.sh
COPY alist-init.sh /usr/local/bin/alist-init.sh

RUN chmod 0755 /entrypoint.sh \
      /usr/local/bin/tailscale-init.sh \
      /usr/local/bin/alist-init.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

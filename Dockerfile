FROM golang:1.25-bookworm AS bootstrap-builder

WORKDIR /src
COPY alist-bootstrap.go .
COPY huawei-proxy.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /alist-bootstrap ./alist-bootstrap.go \
    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /huawei-proxy ./huawei-proxy.go

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg gzip nginx supervisor \
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
COPY alist-backup.enc /app/alist-backup.enc
COPY --from=bootstrap-builder /alist-bootstrap /usr/local/bin/alist-bootstrap
COPY --from=bootstrap-builder /huawei-proxy /usr/local/bin/huawei-proxy
COPY nginx.conf /etc/nginx/nginx.conf
RUN nginx -t
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
COPY tailscale-init.sh /usr/local/bin/tailscale-init.sh
COPY alist-init.sh /usr/local/bin/alist-init.sh

RUN chmod 0755 /entrypoint.sh \
      /usr/local/bin/tailscale-init.sh \
      /usr/local/bin/alist-init.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

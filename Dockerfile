FROM debian:bookworm-slim

RUN <<EOF

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    inotify-tools \
    jq \
    redis-tools \
    xxd
EOF

RUN curl -fsSL https://github.com/ipfs/kubo/releases/download/v0.23.0/kubo_v0.23.0_linux-amd64.tar.gz | tar -xzf - -C /usr/local/bin --strip-components=1 kubo/ipfs

RUN curl -fsSL https://github.com/ipld/go-car/releases/download/v2.13.1/go-car_2.13.1_linux_amd64.tar.gz | tar -xzf - -C /usr/local/bin car

COPY snapshoter.sh /opt/cartesi/bin/snapshoter.sh

RUN <<EOF
addgroup --system --gid 102 cartesi
adduser --system --uid 102 --ingroup cartesi --disabled-login --no-create-home --home /nonexistent --gecos "cartesi user" --shell /bin/false cartesi
EOF

WORKDIR /opt/cartesi

#USER cartesi
USER root

CMD [ "/opt/cartesi/bin/snapshoter.sh" ]
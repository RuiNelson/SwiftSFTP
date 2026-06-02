FROM debian:testing

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    openssh-server \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /run/sshd

COPY motd /etc/motd
COPY sshd_config /etc/ssh/sshd_config
COPY setup-test-server.sh /usr/local/bin/setup-test-server.sh
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY KeyPairs /tmp/KeyPairs
COPY Fixtures /tmp/Fixtures

RUN chmod +x /usr/local/bin/setup-test-server.sh /usr/local/bin/docker-entrypoint.sh \
  && /usr/local/bin/setup-test-server.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

#!/usr/bin/env bash
set -euo pipefail

ssh-keygen -A >/dev/null
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config

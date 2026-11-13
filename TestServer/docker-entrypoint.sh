#!/usr/bin/env bash
set -euo pipefail

ssh-keygen -A >/dev/null

# Extended attribute for the shell agent `stat` tests. Set at start, since image layers do not keep it.
setfattr -n user.swiftsftp -v hello /home/bulbasaur/Fixtures/TINY.bin \
  || echo "setfattr failed: the extended attribute test will not find it" >&2
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config

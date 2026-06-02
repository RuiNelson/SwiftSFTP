#!/usr/bin/env bash
set -euo pipefail

USER_PASSWORD="pass123"
KEYPAIRS_SRC="/tmp/KeyPairs"
FIXTURES_SRC="/tmp/Fixtures"

create_user() {
  local username="$1"
  useradd -m -s /bin/bash "$username"
  echo "${username}:${USER_PASSWORD}" | chpasswd
  install -d -m 700 -o "$username" -g "$username" "/home/${username}/.ssh"
}

install_authorized_key() {
  local username="$1"
  local public_key_file="$2"

  install -m 600 -o "$username" -g "$username" \
    "$public_key_file" "/home/${username}/.ssh/authorized_keys"
}

create_user bulbasaur
create_user charmander
create_user squirtle
create_user caterpie
create_user weedle
create_user pidgey

install_authorized_key charmander "$KEYPAIRS_SRC/rsa-public-openssh-clear"
install_authorized_key squirtle "$KEYPAIRS_SRC/p256-public-openssh-clear"
install_authorized_key caterpie "$KEYPAIRS_SRC/p384-public-openssh-clear"
install_authorized_key weedle "$KEYPAIRS_SRC/p521-public-openssh-clear"
install_authorized_key pidgey "$KEYPAIRS_SRC/ed25519-public-openssh-clear"

cp -a "$KEYPAIRS_SRC" /home/bulbasaur/KeyPairs
cp -a "$FIXTURES_SRC" /home/bulbasaur/Fixtures
chown -R bulbasaur:bulbasaur /home/bulbasaur/KeyPairs /home/bulbasaur/Fixtures

charmander_home="/home/charmander"
install -d -m 755 -o charmander -g charmander "$charmander_home/documents"
install -d -m 755 -o charmander -g charmander "$charmander_home/archives/2024"
printf 'Sample report for SFTP listing tests.\n' >"$charmander_home/documents/report.txt"
printf 'Archived log entry.\n' >"$charmander_home/archives/2024/log.txt"
chown -R charmander:charmander "$charmander_home/documents" "$charmander_home/archives"
ln -s documents "$charmander_home/current"
ln -s documents/report.txt "$charmander_home/latest-report"
chown -h charmander:charmander "$charmander_home/current" "$charmander_home/latest-report"

squirtle_home="/home/squirtle"
install -m 644 -o squirtle -g squirtle /dev/null "$squirtle_home/readable.txt"
install -m 644 -o squirtle -g squirtle /dev/null "$squirtle_home/writable.txt"
install -m 444 -o squirtle -g squirtle /dev/null "$squirtle_home/readonly.txt"
install -m 000 -o squirtle -g squirtle /dev/null "$squirtle_home/noaccess.txt"
install -m 755 -o squirtle -g squirtle /dev/null "$squirtle_home/executable.sh"
printf 'readable\n' >"$squirtle_home/readable.txt"
printf 'writable\n' >"$squirtle_home/writable.txt"
printf 'readonly\n' >"$squirtle_home/readonly.txt"
printf 'hidden\n' >"$squirtle_home/noaccess.txt"
printf '#!/bin/sh\necho executable\n' >"$squirtle_home/executable.sh"
printf 'owned by root\n' >/root-owned.txt
install -m 644 -o root -g root /root-owned.txt "$squirtle_home/root-owned.txt"
rm -f /root-owned.txt

rm -rf "$KEYPAIRS_SRC" "$FIXTURES_SRC"

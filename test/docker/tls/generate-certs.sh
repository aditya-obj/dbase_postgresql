#!/bin/sh
# Generates a throwaway CA and server certificate for the pg18-tls test
# server, then idles so the service stays healthy for `up --wait`.
# Test-only: the keys live in a Docker volume and are recreated by
# `docker compose down -v`. Never use these for anything real.
set -eu

if [ -f /certs/server.crt ] && [ -f /certs/server.key ]; then
  echo "certificates already present"
else
  cd /certs
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=dabase test CA" -keyout ca.key -out ca.crt
  openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
    -keyout server.key -out server.csr
  printf 'subjectAltName=DNS:localhost,DNS:pg18-tls,IP:127.0.0.1\n' > san.ext
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -days 30 -extfile san.ext -out server.crt
  rm -f server.csr san.ext ca.key ca.srl
  # The postgres user in the Debian-based image is uid/gid 999; the
  # server refuses a key readable by others.
  chown 999:999 server.key server.crt
  chmod 600 server.key
  chmod 644 server.crt ca.crt
fi
cp /certs/ca.crt /export/ca.crt
chmod 644 /export/ca.crt
touch /certs/ready
echo 'certificates ready'
exec sleep 2147483647

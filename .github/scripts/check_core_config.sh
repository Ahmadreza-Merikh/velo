#!/bin/sh
set -e

WORK=$(mktemp -d)
CORE="$(pwd)/core/xray"

cat > "$WORK/tunnel.json" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "dns": {"servers": ["1.1.1.1", "8.8.8.8"], "queryStrategy": "UseIPv4"},
  "inbounds": [
    {"tag": "tun-in", "port": 0, "protocol": "tun",
     "settings": {"MTU": 1500, "mtu": 1500, "userLevel": 0, "name": "velotest0"},
     "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}},
    {"tag": "socks-in", "listen": "127.0.0.1", "port": 21080, "protocol": "socks",
     "settings": {"auth": "noauth", "udp": true}}
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {"domainStrategy": "AsIs", "rules": []}
}
JSON

cat > "$WORK/bogus.json" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag": "tun-in", "port": 0, "protocol": "notaprotocol", "settings": {}}
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
JSON

echo "--- an unknown inbound must fail at config load ---"
set +e
BOGUS=$("$CORE" run -c "$WORK/bogus.json" 2>&1)
set -e
echo "$BOGUS" | tail -2
if ! echo "$BOGUS" | grep -q "unknown config id"; then
  echo "FAIL: an unknown protocol did not fail the way we expect" >&2
  exit 1
fi

echo "--- the tun inbound must get past config load ---"
set +e
REAL=$(timeout 20 "$CORE" run -c "$WORK/tunnel.json" 2>&1)
STATUS=$?
set -e
echo "$REAL" | tail -3

if echo "$REAL" | grep -q "unknown config id"; then
  echo "FAIL: this core has no tun inbound, the desktop tunnel cannot work" >&2
  exit 1
fi
if echo "$REAL" | grep -qi "failed to load config"; then
  echo "FAIL: the generated tunnel config is not valid for this core" >&2
  exit 1
fi

echo "config loaded, tun inbound recognised (exit $STATUS)"
echo "ALL CORE CONFIG CHECKS PASSED"

#!/bin/sh
set -e

ROOT=$(pwd)
WORK=$(mktemp -d)
HELPER="$WORK/velo-helper"

python3 .github/scripts/extract_script.py \
  app/lib/core/privileged_helper.dart _helperScript > "$HELPER.raw"

sed \
  -e "s#/var/run/velo-pins.state#$WORK/pins.state#g" \
  -e "s#/var/run/velo-ipv6.state#$WORK/ipv6.state#g" \
  -e "s#/var/run/velo-tunnel.state#$WORK/tunnel.state#g" \
  -e "s#/var/run/velo-tunnel.pid#$WORK/tunnel.pid#g" \
  "$HELPER.raw" > "$HELPER"
chmod +x "$HELPER"

sh -n "$HELPER"
echo "syntax ok"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "--- contract ---"
CONTRACT=$(sh "$HELPER" ping)
echo "$CONTRACT"
case "$CONTRACT" in
  "velo-helper "*) ;;
  *) fail "ping did not report a contract" ;;
esac

echo "--- gateway on a real route table ---"
sh "$HELPER" gateway
GW=$(sh "$HELPER" gateway | awk -F= '/^gateway=/ {print $2}')
IFACE=$(sh "$HELPER" gateway | awk -F= '/^interface=/ {print $2}')
[ -n "$GW" ] || fail "no physical gateway found on the runner"
[ -n "$IFACE" ] || fail "no physical interface found on the runner"
echo "gateway=$GW interface=$IFACE"

TARGET_A=192.0.2.10
TARGET_B=192.0.2.11
UPLINK=192.0.2.99

echo "--- pin adds real routes ---"
sudo sh "$HELPER" pin "$TARGET_A,$TARGET_B"
netstat -rn -f inet | grep -q "$TARGET_A" || fail "$TARGET_A was not added to the route table"
netstat -rn -f inet | grep -q "$TARGET_B" || fail "$TARGET_B was not added to the route table"
sudo grep -q "host $TARGET_A" "$WORK/pins.state" || fail "$TARGET_A was not recorded"
echo "both routes present and recorded"

echo "--- unpin removes exactly those routes ---"
sudo sh "$HELPER" unpin
if netstat -rn -f inet | grep -q "$TARGET_A"; then fail "$TARGET_A survived unpin"; fi
if netstat -rn -f inet | grep -q "$TARGET_B"; then fail "$TARGET_B survived unpin"; fi
if [ -f "$WORK/pins.state" ]; then fail "pin state file survived unpin"; fi
echo "routes gone and state cleared"

echo "--- pin refuses rubbish and protects tunnel routes ---"
printf 'host %s\n' "$UPLINK" > "$WORK/tunnel.state"
sudo route -n add -host "$UPLINK" "$GW" >/dev/null 2>&1 || true
sudo sh "$HELPER" pin "bogus,,$UPLINK,$TARGET_A"
if sudo grep -q "$UPLINK" "$WORK/pins.state"; then fail "a tunnel-held address was pinned"; fi
if sudo grep -q "bogus" "$WORK/pins.state"; then fail "a malformed address was pinned"; fi
sudo grep -q "host $TARGET_A" "$WORK/pins.state" || fail "the good address was not pinned"
echo "rubbish rejected, tunnel route protected"

echo "--- repin moves the tunnel route and drops test pins ---"
sudo sh "$HELPER" repin
if [ -f "$WORK/pins.state" ]; then fail "test pins survived repin"; fi
netstat -rn -f inet | grep -q "$UPLINK" || fail "the tunnel route is gone after repin"
sudo grep -q "host $UPLINK" "$WORK/tunnel.state" || fail "the tunnel route was not recorded after repin"
echo "tunnel route re-pinned, test pins dropped"

sudo route -n delete -host "$UPLINK" >/dev/null 2>&1 || true
sudo rm -f "$WORK/tunnel.state"

echo "--- ipv6 is really turned off and really restored ---"
BEFORE=$(networksetup -getinfo Wi-Fi 2>/dev/null | awk -F': ' '/^IPv6:/ {print $2}')
if [ -z "$BEFORE" ]; then
  SERVICE=$(networksetup -listallnetworkservices | tail -n +2 | head -1)
  BEFORE=$(networksetup -getinfo "$SERVICE" 2>/dev/null | awk -F': ' '/^IPv6:/ {print $2}')
else
  SERVICE=Wi-Fi
fi
echo "service=$SERVICE before=$BEFORE"

DURING_FILE="$WORK/ipv6.state"

awk '/^case "\$1" in/ {exit} {print}' "$HELPER" > "$WORK/funcs.sh"
sh -n "$WORK/funcs.sh" || fail "extracted functions do not parse"

sudo sh -c ". '$WORK/funcs.sh'; disable_ipv6" || fail "disable_ipv6 failed"

[ -f "$DURING_FILE" ] || fail "the previous ipv6 state was not saved"
DURING=$(networksetup -getinfo "$SERVICE" 2>/dev/null | awk -F': ' '/^IPv6:/ {print $2}')
echo "during=$DURING"
if [ "$BEFORE" != "Off" ] && [ "$BEFORE" != "Manual" ]; then
  [ "$DURING" = "Off" ] || fail "ipv6 was not actually turned off (still $DURING)"
fi

sudo sh -c ". '$WORK/funcs.sh'; restore_ipv6" || fail "restore_ipv6 failed"

AFTER=$(networksetup -getinfo "$SERVICE" 2>/dev/null | awk -F': ' '/^IPv6:/ {print $2}')
echo "after=$AFTER"
[ "$AFTER" = "$BEFORE" ] || fail "ipv6 was not restored (was $BEFORE, now $AFTER)"
if [ -f "$DURING_FILE" ]; then fail "the ipv6 state file survived restore"; fi

sudo sh "$HELPER" unpin >/dev/null 2>&1 || true
echo "ipv6 turned off and restored for real"
echo "ALL MAC HELPER CHECKS PASSED"

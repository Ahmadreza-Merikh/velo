import 'dart:convert';
import 'dart:io';

class HelperResult {
  HelperResult({required this.ok, this.message = '', this.foreignTunnel = false});

  final bool ok;
  final String message;
  final bool foreignTunnel;
}

class GatewayInfo {
  const GatewayInfo({
    this.gateway = '',
    this.interfaceName = '',
    this.foreignInterface = '',
  });

  final String gateway;
  final String interfaceName;
  final String foreignInterface;

  bool get found => gateway.isNotEmpty;

  bool get blocked => foreignInterface.isNotEmpty;
}

abstract class PrivilegedHelper {
  static const int contract = 4;

  static PrivilegedHelper? forPlatform(Directory workDir) {
    if (Platform.isMacOS) {
      return MacHelper(workDir);
    }
    if (Platform.isWindows) {
      return WindowsHelper(workDir);
    }
    return null;
  }

  Future<bool> isInstalled();

  Future<bool> isPresent();

  Future<HelperResult> install({
    required File xray,
    required File config,
    required Directory workDir,
  });

  Future<HelperResult> start({
    required File config,
    required String tunName,
    required List<String> serverAddresses,
  });

  Future<HelperResult> stop();

  Future<HelperResult> pin(List<String> addresses);

  Future<HelperResult> unpin();

  Future<HelperResult> cleanup();

  Future<HelperResult> repin();

  Future<GatewayInfo> gateway();

  Future<HelperResult> uninstall();
}

class MacHelper implements PrivilegedHelper {
  MacHelper(this.workDir);

  static const String installDir = '/usr/local/libexec/velo';
  static const String helperPath = '$installDir/velo-helper';
  static const String corePath = '$installDir/xray';
  static const String sudoersPath = '/etc/sudoers.d/velo';

  final Directory workDir;

  @override
  Future<bool> isPresent() async =>
      File(helperPath).existsSync() && File(corePath).existsSync();

  @override
  Future<bool> isInstalled() async {
    if (!File(helperPath).existsSync() || !File(corePath).existsSync()) {
      return false;
    }
    final ProcessResult probe = await Process.run(
      'sudo',
      <String>['-n', helperPath, 'ping'],
    );
    if (probe.exitCode != 0) {
      return false;
    }
    return (probe.stdout as String).trim() ==
        'velo-helper ${PrivilegedHelper.contract}';
  }

  @override
  Future<HelperResult> install({
    required File xray,
    required File config,
    required Directory workDir,
  }) async {
    final File script = File('${workDir.path}/velo-helper');
    await script.writeAsString(_helperScript);

    final File installer = File('${workDir.path}/velo-install.sh');
    await installer.writeAsString(
      _installerScript(stagedHelper: script.path, stagedCore: xray.path),
    );

    final ProcessResult result = await Process.run('osascript', <String>[
      '-e',
      'do shell script "/bin/sh ${_quote(installer.path)}" '
          'with administrator privileges',
    ]);

    if (result.exitCode != 0) {
      final String error = (result.stderr as String).trim();
      if (error.contains('-128') || error.toLowerCase().contains('cancel')) {
        return HelperResult(ok: false, message: 'admin prompt was cancelled');
      }
      return HelperResult(
        ok: false,
        message: error.isEmpty ? 'helper install failed' : error,
      );
    }
    return HelperResult(ok: true);
  }

  @override
  Future<HelperResult> start({
    required File config,
    required String tunName,
    required List<String> serverAddresses,
  }) async {
    final ProcessResult result = await Process.run('sudo', <String>[
      '-n',
      helperPath,
      'start',
      config.path,
      tunName,
      serverAddresses.join(','),
    ]);
    if (result.exitCode != 0) {
      final String error = (result.stderr as String).trim();
      return HelperResult(
        ok: false,
        message: error.isEmpty ? 'tunnel did not start' : error,
        foreignTunnel: result.exitCode == 4,
      );
    }
    return HelperResult(ok: true);
  }

  @override
  Future<HelperResult> stop() async {
    final ProcessResult result = await Process.run(
      'sudo',
      <String>['-n', helperPath, 'stop'],
    );
    return HelperResult(ok: result.exitCode == 0);
  }

  @override
  Future<HelperResult> pin(List<String> addresses) async {
    if (addresses.isEmpty) {
      return HelperResult(ok: true);
    }
    final ProcessResult result = await Process.run('sudo', <String>[
      '-n',
      helperPath,
      'pin',
      addresses.join(','),
    ]);
    if (result.exitCode != 0) {
      final String error = (result.stderr as String).trim();
      return HelperResult(
        ok: false,
        message: error.isEmpty ? 'could not pin the test routes' : error,
        foreignTunnel: result.exitCode == 4,
      );
    }
    return HelperResult(ok: true);
  }

  @override
  Future<HelperResult> unpin() async {
    final ProcessResult result = await Process.run(
      'sudo',
      <String>['-n', helperPath, 'unpin'],
    );
    return HelperResult(ok: result.exitCode == 0);
  }

  @override
  Future<HelperResult> cleanup() async {
    final ProcessResult result = await Process.run(
      'sudo',
      <String>['-n', helperPath, 'cleanup'],
    );
    return HelperResult(ok: result.exitCode == 0);
  }

  @override
  Future<HelperResult> repin() async {
    final ProcessResult result = await Process.run(
      'sudo',
      <String>['-n', helperPath, 'repin'],
    );
    return HelperResult(
      ok: result.exitCode == 0,
      foreignTunnel: result.exitCode == 4,
    );
  }

  @override
  Future<GatewayInfo> gateway() async {
    final ProcessResult result = await Process.run(
      'sudo',
      <String>['-n', helperPath, 'gateway'],
    );
    if (result.exitCode != 0) {
      return const GatewayInfo();
    }
    String gateway = '';
    String interfaceName = '';
    String foreign = '';
    for (final String line in (result.stdout as String).split('\n')) {
      final int split = line.indexOf('=');
      if (split < 0) {
        continue;
      }
      final String key = line.substring(0, split).trim();
      final String value = line.substring(split + 1).trim();
      if (key == 'gateway') {
        gateway = value;
      } else if (key == 'interface') {
        interfaceName = value;
      } else if (key == 'foreign') {
        foreign = value;
      }
    }
    return GatewayInfo(
      gateway: gateway,
      interfaceName: interfaceName,
      foreignInterface: foreign,
    );
  }

  @override
  Future<HelperResult> uninstall() async {
    final ProcessResult result = await Process.run('osascript', <String>[
      '-e',
      'do shell script "rm -f $sudoersPath; rm -rf $installDir" '
          'with administrator privileges',
    ]);
    return HelperResult(ok: result.exitCode == 0);
  }

  static String _quote(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  String _installerScript({
    required String stagedHelper,
    required String stagedCore,
  }) {
    return '''#!/bin/sh
set -e
mkdir -p '$installDir'
cp '$stagedHelper' '$helperPath'
cp '$stagedCore' '$corePath'
chown root:wheel '$helperPath' '$corePath'
chmod 755 '$helperPath' '$corePath'
xattr -d com.apple.quarantine '$corePath' 2>/dev/null || true
printf '%s\\n' '%admin ALL=(root) NOPASSWD: $helperPath' > '$sudoersPath'
chown root:wheel '$sudoersPath'
chmod 440 '$sudoersPath'
''';
  }

  static const String _helperScript = r'''#!/bin/sh

CONTRACT=4
CORE="/usr/local/libexec/velo/xray"
PID_FILE="/var/run/velo-tunnel.pid"
STATE_FILE="/var/run/velo-tunnel.state"
PIN_FILE="/var/run/velo-pins.state"
V6_FILE="/var/run/velo-ipv6.state"
LOG_FILE="/var/log/velo-tunnel.log"
PIN_LIMIT=1024

kill_core() {
  if [ -f "$PID_FILE" ]; then
    OLD=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
      kill "$OLD" 2>/dev/null
      sleep 1
      kill -9 "$OLD" 2>/dev/null
    fi
    rm -f "$PID_FILE"
  fi
}

drop_routes() {
  if [ ! -f "$STATE_FILE" ]; then
    return 0
  fi
  while IFS=' ' read -r kind value; do
    case "$kind" in
      split) route -n delete -net "$value" >/dev/null 2>&1 ;;
      host) route -n delete -host "$value" >/dev/null 2>&1 ;;
    esac
  done < "$STATE_FILE"
  rm -f "$STATE_FILE"
}

drop_pins() {
  if [ ! -f "$PIN_FILE" ]; then
    return 0
  fi
  while IFS=' ' read -r kind value; do
    case "$kind" in
      host) route -n delete -host "$value" >/dev/null 2>&1 ;;
      host6) route -n delete -inet6 -host "$value" >/dev/null 2>&1 ;;
    esac
  done < "$PIN_FILE"
  rm -f "$PIN_FILE"
}

teardown() {
  kill_core
  drop_routes
  drop_pins
  restore_ipv6
}

valid_address() {
  case "$1" in
    *[!0-9A-Fa-f.:]*) return 1 ;;
    *[.:]*) return 0 ;;
    *) return 1 ;;
  esac
}

held_by_tunnel() {
  if [ ! -f "$STATE_FILE" ]; then
    return 1
  fi
  while IFS=' ' read -r kind value; do
    if [ "$value" = "$1" ]; then
      case "$kind" in
        host|host6) return 0 ;;
      esac
    fi
  done < "$STATE_FILE"
  return 1
}

physical_default() {
  netstat -rn -f inet 2>/dev/null | awk '
    $1 == "default" && $4 !~ /^(utun|ipsec|ppp|tap|tun)/ { print $2, $4; exit }'
}

default_gateway() {
  set -- $(physical_default)
  case "$1" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) echo "$1"; return 0 ;;
  esac
  if [ -n "$2" ]; then
    ipconfig getoption "$2" router 2>/dev/null |
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  fi
}

default_interface() {
  netstat -rn -f inet 2>/dev/null | awk '
    $1 == "default" && $4 !~ /^(utun|ipsec|ppp|tap|tun)/ { print $4; exit }'
}

winning_interface() {
  netstat -rn -f inet 2>/dev/null | awk '$1 == "default" { print $4; exit }'
}

foreign_tunnel() {
  winning_interface | grep -qE '^(utun|ipsec|ppp|tap|tun)'
}

default_gateway6() {
  netstat -rn -f inet6 2>/dev/null | awk '
    $1 == "default" && $4 !~ /^(utun|ipsec|ppp|tap|tun)/ &&
    $2 !~ /^link#/ { print $2; exit }'
}

no_gateway() {
  if foreign_tunnel; then
    echo "another vpn is holding the default route on $(winning_interface), disconnect it and try again" >&2
    exit 4
  fi
  echo "could not find your physical network gateway" >&2
  exit 3
}

save_ipv6() {
  if [ -f "$V6_FILE" ]; then
    return 0
  fi
  TMP="$V6_FILE.new"
  : > "$TMP"
  chmod 600 "$TMP"
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 |
    while IFS= read -r SERVICE; do
      SERVICE=${SERVICE#\*}
      if [ -z "$SERVICE" ]; then
        continue
      fi
      STATE=$(networksetup -getinfo "$SERVICE" 2>/dev/null |
        awk -F': ' '/^IPv6:/ {print $2; exit}')
      if [ -n "$STATE" ]; then
        printf '%s\t%s\n' "$STATE" "$SERVICE" >> "$TMP"
      fi
    done
  mv "$TMP" "$V6_FILE"
}

disable_ipv6() {
  save_ipv6
  SKIPPED=0
  TAB=$(printf '\t')
  while IFS="$TAB" read -r STATE SERVICE; do
    if [ -z "$SERVICE" ]; then
      continue
    fi
    case "$STATE" in
      Off) ;;
      Manual) SKIPPED=$((SKIPPED + 1)) ;;
      *) networksetup -setv6off "$SERVICE" >/dev/null 2>&1 ;;
    esac
  done < "$V6_FILE"
  if [ "$SKIPPED" -gt 0 ]; then
    echo "left ipv6 alone on $SKIPPED service(s) with a manual address" >&2
  fi
}

restore_ipv6() {
  if [ ! -f "$V6_FILE" ]; then
    return 0
  fi
  TAB=$(printf '\t')
  while IFS="$TAB" read -r STATE SERVICE; do
    if [ -z "$SERVICE" ]; then
      continue
    fi
    case "$STATE" in
      Off) networksetup -setv6off "$SERVICE" >/dev/null 2>&1 ;;
      Manual) ;;
      "Link-local only") networksetup -setv6LinkLocal "$SERVICE" >/dev/null 2>&1 ;;
      *) networksetup -setv6automatic "$SERVICE" >/dev/null 2>&1 ;;
    esac
  done < "$V6_FILE"
  rm -f "$V6_FILE"
}

case "$1" in
  ping)
    echo "velo-helper $CONTRACT"
    exit 0
    ;;
  start)
    CONFIG="$2"
    TUN="$3"
    SERVERS="$4"

    case "$CONFIG" in
      /*) ;;
      *) echo "config path must be absolute" >&2; exit 2 ;;
    esac
    case "$TUN" in
      utun[0-9]*) ;;
      *) echo "interface name must look like utunN" >&2; exit 2 ;;
    esac
    if [ ! -f "$CONFIG" ]; then
      echo "config not found" >&2
      exit 2
    fi
    if [ ! -x "$CORE" ]; then
      echo "core is missing, reinstall the helper" >&2
      exit 2
    fi

    teardown

    GATEWAY=$(default_gateway)
    if [ -z "$GATEWAY" ]; then
      no_gateway
    fi

    : > "$STATE_FILE"
    chmod 600 "$STATE_FILE"

    OLD_IFS=$IFS
    IFS=,
    for ADDRESS in $SERVERS; do
      IFS=$OLD_IFS
      if [ -n "$ADDRESS" ]; then
        if route -n add -host "$ADDRESS" "$GATEWAY" >/dev/null 2>&1; then
          echo "host $ADDRESS" >> "$STATE_FILE"
        fi
      fi
      IFS=,
    done
    IFS=$OLD_IFS

    "$CORE" run -c "$CONFIG" >"$LOG_FILE" 2>&1 &
    CORE_PID=$!
    echo $CORE_PID > "$PID_FILE"

    WAITED=0
    while [ $WAITED -lt 60 ]; do
      if ! kill -0 "$CORE_PID" 2>/dev/null; then
        echo "core exited, see $LOG_FILE" >&2
        teardown
        exit 3
      fi
      if ifconfig "$TUN" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
      WAITED=$((WAITED + 1))
    done

    if ! ifconfig "$TUN" >/dev/null 2>&1; then
      echo "interface $TUN never appeared" >&2
      teardown
      exit 3
    fi

    for NET in 0.0.0.0/1 128.0.0.0/1; do
      if route -n add -net "$NET" -interface "$TUN" >/dev/null 2>&1; then
        echo "split $NET" >> "$STATE_FILE"
      else
        echo "could not route $NET through $TUN" >&2
        teardown
        exit 3
      fi
    done

    disable_ipv6

    exit 0
    ;;
  pin)
    LIST="$2"
    if [ -z "$LIST" ]; then
      exit 0
    fi

    GATEWAY=$(default_gateway)
    GATEWAY6=$(default_gateway6)
    if [ -z "$GATEWAY" ] && [ -z "$GATEWAY6" ]; then
      no_gateway
    fi

    if [ ! -f "$PIN_FILE" ]; then
      : > "$PIN_FILE"
      chmod 600 "$PIN_FILE"
    fi
    COUNT=$(wc -l < "$PIN_FILE" | tr -d ' ')

    OLD_IFS=$IFS
    IFS=,
    for ADDRESS in $LIST; do
      IFS=$OLD_IFS
      if [ -n "$ADDRESS" ] && [ "$COUNT" -lt "$PIN_LIMIT" ] &&
        valid_address "$ADDRESS" && ! held_by_tunnel "$ADDRESS"; then
        case "$ADDRESS" in
          *:*)
            if [ -n "$GATEWAY6" ] &&
              route -n add -inet6 -host "$ADDRESS" "$GATEWAY6" \
                >/dev/null 2>&1; then
              echo "host6 $ADDRESS" >> "$PIN_FILE"
              COUNT=$((COUNT + 1))
            fi
            ;;
          *)
            if [ -n "$GATEWAY" ] &&
              route -n add -host "$ADDRESS" "$GATEWAY" >/dev/null 2>&1; then
              echo "host $ADDRESS" >> "$PIN_FILE"
              COUNT=$((COUNT + 1))
            fi
            ;;
        esac
      fi
      IFS=,
    done
    IFS=$OLD_IFS
    exit 0
    ;;
  unpin)
    drop_pins
    exit 0
    ;;
  repin)
    GATEWAY=$(default_gateway)
    if [ -z "$GATEWAY" ]; then
      no_gateway
    fi
    drop_pins
    if [ ! -f "$STATE_FILE" ]; then
      exit 0
    fi
    TMP="$STATE_FILE.new"
    : > "$TMP"
    chmod 600 "$TMP"
    while IFS=' ' read -r kind value; do
      case "$kind" in
        host)
          route -n delete -host "$value" >/dev/null 2>&1
          if route -n add -host "$value" "$GATEWAY" >/dev/null 2>&1; then
            echo "host $value" >> "$TMP"
          fi
          ;;
        *)
          if [ -n "$kind" ]; then
            echo "$kind $value" >> "$TMP"
          fi
          ;;
      esac
    done < "$STATE_FILE"
    mv "$TMP" "$STATE_FILE"
    exit 0
    ;;
  cleanup)
    drop_pins
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
      echo "tunnel is still running, leaving ipv6 alone" >&2
    else
      restore_ipv6
    fi
    exit 0
    ;;
  gateway)
    echo "gateway=$(default_gateway)"
    echo "interface=$(default_interface)"
    if foreign_tunnel; then
      echo "foreign=$(winning_interface)"
    else
      echo "foreign="
    fi
    exit 0
    ;;
  stop)
    teardown
    exit 0
    ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo running
    else
      echo stopped
    fi
    exit 0
    ;;
  *)
    echo "usage: velo-helper ping|start|stop|pin|unpin|repin|cleanup|gateway|status" >&2
    exit 64
    ;;
esac
''';
}

class WindowsHelper implements PrivilegedHelper {
  WindowsHelper(this.workDir);

  static const String startTask = 'Velo\\VeloTunnel';
  static const String stopTask = 'Velo\\VeloTunnelStop';
  static const String routeTask = 'Velo\\VeloRoute';
  static const String adapterName = 'Velo';

  final Directory workDir;

  Directory get dataDir => Directory(
        '${Platform.environment['ProgramData'] ?? 'C:\\ProgramData'}\\Velo',
      );

  String get corePath => '${dataDir.path}\\xray.exe';

  String get requestPath => '${workDir.path}\\route-request.json';

  String get resultPath => '$requestPath.done';

  @override
  Future<bool> isPresent() async => File(corePath).existsSync();

  @override
  Future<bool> isInstalled() async {
    if (!File(corePath).existsSync()) {
      return false;
    }
    for (final String task in <String>[startTask, stopTask, routeTask]) {
      final ProcessResult result = await Process.run(
        'schtasks',
        <String>['/query', '/tn', task],
      );
      if (result.exitCode != 0) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<HelperResult> install({
    required File xray,
    required File config,
    required Directory workDir,
  }) async {
    final File wintun = File('${xray.parent.path}\\wintun.dll');
    final File startScript = File('${workDir.path}\\velo-tunnel.ps1');
    final File stopScript = File('${workDir.path}\\velo-stop.ps1');
    final File routeScript = File('${workDir.path}\\velo-route.ps1');
    final File installer = File('${workDir.path}\\velo-install.ps1');

    await startScript.writeAsString(_startScript);
    await stopScript.writeAsString(_stopScript);
    await routeScript.writeAsString(_routeScript);
    await installer.writeAsString(
      _installerScript(
        stagedCore: xray.path,
        stagedWintun: wintun.existsSync() ? wintun.path : '',
        stagedStart: startScript.path,
        stagedStop: stopScript.path,
        stagedRoute: routeScript.path,
        configPath: config.path,
      ),
    );

    final ProcessResult result = await Process.run('powershell', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      'Start-Process -FilePath powershell -Verb RunAs -Wait -ArgumentList '
          "'-NoProfile','-ExecutionPolicy','Bypass','-File','${installer.path}'",
    ]);

    if (result.exitCode != 0) {
      return HelperResult(
        ok: false,
        message: 'the administrator prompt was declined',
      );
    }
    if (!await isInstalled()) {
      return HelperResult(ok: false, message: 'helper tasks were not created');
    }
    return HelperResult(ok: true);
  }

  @override
  Future<HelperResult> start({
    required File config,
    required String tunName,
    required List<String> serverAddresses,
  }) async {
    final ProcessResult result = await Process.run(
      'schtasks',
      <String>['/run', '/tn', startTask],
    );
    if (result.exitCode != 0) {
      return HelperResult(ok: false, message: 'tunnel task did not start');
    }
    return HelperResult(ok: true);
  }

  @override
  Future<HelperResult> stop() async {
    await Process.run('schtasks', <String>['/run', '/tn', stopTask]);
    await Process.run('schtasks', <String>['/end', '/tn', startTask]);
    return HelperResult(ok: true);
  }

  @override
  Future<HelperResult> pin(List<String> addresses) async {
    if (addresses.isEmpty) {
      return HelperResult(ok: true);
    }
    return _route('pin', addresses);
  }

  @override
  Future<HelperResult> unpin() => _route('unpin', const <String>[]);

  @override
  Future<HelperResult> cleanup() => _route('cleanup', const <String>[]);

  @override
  Future<HelperResult> repin() => _route('repin', const <String>[]);

  @override
  Future<GatewayInfo> gateway() async {
    final ProcessResult result = await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      _gatewayQuery,
    ]);
    if (result.exitCode != 0) {
      return const GatewayInfo();
    }
    String gateway = '';
    String interfaceName = '';
    String foreign = '';
    for (final String line in (result.stdout as String).split('\n')) {
      final int split = line.indexOf('=');
      if (split < 0) {
        continue;
      }
      final String key = line.substring(0, split).trim();
      final String value = line.substring(split + 1).trim();
      if (key == 'gateway') {
        gateway = value;
      } else if (key == 'interface') {
        interfaceName = value;
      } else if (key == 'foreign') {
        foreign = value;
      }
    }
    return GatewayInfo(
      gateway: gateway,
      interfaceName: interfaceName,
      foreignInterface: foreign,
    );
  }

  static const String _gatewayQuery = r'''
''' + _gatewayFunctions + r'''
$info = Resolve-GatewayState
if ($info.state -eq 'found') {
  Write-Output "gateway=$($info.nextHop)"
  Write-Output "interface=$($info.interface)"
} else {
  Write-Output 'gateway='
  Write-Output 'interface='
}
Write-Output "foreign=$($info.foreign)"
''';

  Future<HelperResult> _route(String action, List<String> addresses) async {
    final File request = File(requestPath);
    final File result = File(resultPath);
    final int seq = DateTime.now().microsecondsSinceEpoch;

    try {
      if (result.existsSync()) {
        result.deleteSync();
      }
      await request.writeAsString(
        jsonEncode(<String, dynamic>{
          'seq': seq,
          'action': action,
          'addresses': addresses,
        }),
        flush: true,
      );
    } catch (_) {
      return HelperResult(
        ok: false,
        message: 'could not write the route request',
      );
    }

    final ProcessResult started = await Process.run(
      'schtasks',
      <String>['/run', '/tn', routeTask],
    );
    if (started.exitCode != 0) {
      return HelperResult(ok: false, message: 'the route task did not start');
    }

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      if (result.existsSync()) {
        try {
          final Object? decoded = jsonDecode(await result.readAsString());
          if (decoded is Map && (decoded['seq'] as num?)?.toInt() == seq) {
            final String status = (decoded['status'] as String?) ?? '';
            if (status == 'ok') {
              return HelperResult(ok: true);
            }
            if (status == 'foreigntunnel') {
              return HelperResult(
                ok: false,
                message: 'another vpn is holding the default route',
                foreignTunnel: true,
              );
            }
            if (status == 'nogateway') {
              return HelperResult(
                ok: false,
                message: 'could not find your physical network gateway',
              );
            }
            return HelperResult(
              ok: false,
              message: 'the route task reported $status',
            );
          }
        } catch (_) {
          _ignore();
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return HelperResult(ok: false, message: 'the route task did not answer');
  }

  static void _ignore() {}

  @override
  Future<HelperResult> uninstall() async {
    final ProcessResult result = await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      'Start-Process -FilePath powershell -Verb RunAs -Wait -ArgumentList '
          "'-NoProfile','-Command','schtasks /delete /tn \"$startTask\" /f; "
          "schtasks /delete /tn \"$stopTask\" /f; "
          "schtasks /delete /tn \"$routeTask\" /f'",
    ]);
    return HelperResult(ok: result.exitCode == 0);
  }

  String _installerScript({
    required String stagedCore,
    required String stagedWintun,
    required String stagedStart,
    required String stagedStop,
    required String stagedRoute,
    required String configPath,
  }) {
    final String root = dataDir.path;
    final StringBuffer buffer = StringBuffer();
    buffer.writeln("\$ErrorActionPreference = 'Stop'");
    buffer.writeln("New-Item -ItemType Directory -Force -Path '$root' | Out-Null");
    buffer.writeln(
      "Copy-Item -LiteralPath '$stagedCore' -Destination '$root\\xray.exe' -Force",
    );
    if (stagedWintun.isNotEmpty) {
      buffer.writeln(
        "Copy-Item -LiteralPath '$stagedWintun' "
        "-Destination '$root\\wintun.dll' -Force",
      );
    }
    buffer.writeln(
      "Copy-Item -LiteralPath '$stagedStart' "
      "-Destination '$root\\velo-tunnel.ps1' -Force",
    );
    buffer.writeln(
      "Copy-Item -LiteralPath '$stagedStop' "
      "-Destination '$root\\velo-stop.ps1' -Force",
    );
    buffer.writeln(
      "Copy-Item -LiteralPath '$stagedRoute' "
      "-Destination '$root\\velo-route.ps1' -Force",
    );
    buffer.writeln(
      "\$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest",
    );
    buffer.writeln(
      "\$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries "
      "-DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)",
    );
    buffer.writeln(
      "\$startAction = New-ScheduledTaskAction -Execute 'powershell.exe' "
      "-Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
      "-File \"$root\\velo-tunnel.ps1\" -Config \"$configPath\" "
      "-Adapter \"$adapterName\"' -WorkingDirectory '$root'",
    );
    buffer.writeln(
      "Register-ScheduledTask -TaskName '$startTask' -Action \$startAction "
      "-Principal \$principal -Settings \$settings -Force | Out-Null",
    );
    buffer.writeln(
      "\$stopAction = New-ScheduledTaskAction -Execute 'powershell.exe' "
      "-Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
      "-File \"$root\\velo-stop.ps1\"' -WorkingDirectory '$root'",
    );
    buffer.writeln(
      "Register-ScheduledTask -TaskName '$stopTask' -Action \$stopAction "
      "-Principal \$principal -Settings \$settings -Force | Out-Null",
    );
    buffer.writeln(
      "\$routeAction = New-ScheduledTaskAction -Execute 'powershell.exe' "
      "-Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
      "-File \"$root\\velo-route.ps1\" -Requests \"$requestPath\"' "
      "-WorkingDirectory '$root'",
    );
    buffer.writeln(
      "Register-ScheduledTask -TaskName '$routeTask' -Action \$routeAction "
      "-Principal \$principal -Settings \$settings -Force | Out-Null",
    );
    return buffer.toString();
  }

  static const String _gatewayFunctions = r'''
function Resolve-GatewayState {
  $candidates = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' })
  $physical = @()
  foreach ($adapter in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
    if ($adapter.HardwareInterface -eq $true -and $adapter.Name -ne 'Velo') {
      $physical += $adapter.ifIndex
    }
  }
  $onPhysical = @($candidates | Where-Object { $physical -contains $_.ifIndex })
  if ($onPhysical.Count -gt 0) {
    $route = $onPhysical | Sort-Object RouteMetric | Select-Object -First 1
    $name = ''
    $picked = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
    if ($picked) { $name = $picked.Name }
    return @{
      state = 'found'
      nextHop = $route.NextHop
      ifIndex = $route.ifIndex
      interface = $name
      foreign = ''
    }
  }
  $winner = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric | Select-Object -First 1
  if ($winner) {
    $adapter = Get-NetAdapter -InterfaceIndex $winner.ifIndex -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Name -ne 'Velo' -and $adapter.HardwareInterface -ne $true) {
      return @{
        state = 'foreign'
        nextHop = ''
        ifIndex = 0
        interface = ''
        foreign = $adapter.Name
      }
    }
  }
  return @{ state = 'none'; nextHop = ''; ifIndex = 0; interface = ''; foreign = '' }
}
''';

  static const String _startScript = r'''
param([string]$Config, [string]$Adapter = 'Velo')

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$core = Join-Path $root 'xray.exe'
$statePath = Join-Path $root 'state.json'

& (Join-Path $root 'velo-stop.ps1')

$config = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json

$hosts = @()
foreach ($outbound in $config.outbounds) {
  if ($outbound.settings.vnext) {
    foreach ($entry in $outbound.settings.vnext) { $hosts += $entry.address }
  }
  if ($outbound.settings.servers) {
    foreach ($entry in $outbound.settings.servers) { $hosts += $entry.address }
  }
}

$addresses = @()
foreach ($item in $hosts) {
  if (-not $item) { continue }
  if ($item -as [ipaddress]) {
    $addresses += $item
  } else {
    try {
      $addresses += [System.Net.Dns]::GetHostAddresses($item) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.IPAddressToString }
    } catch { }
  }
}
$addresses = $addresses | Select-Object -Unique

''' + _gatewayFunctions + r'''
$info = Resolve-GatewayState
if ($info.state -eq 'foreign') {
  Write-Error "another vpn is holding the default route on $($info.foreign), disconnect it and try again"
  exit 4
}
if ($info.state -ne 'found') {
  Write-Error 'could not find your physical network gateway'
  exit 3
}

$added = @()
foreach ($address in $addresses) {
  try {
    New-NetRoute -DestinationPrefix "$address/32" -NextHop $info.nextHop `
      -InterfaceIndex $info.ifIndex -PolicyStore ActiveStore | Out-Null
    $added += "$address/32"
  } catch { }
}

$process = Start-Process -FilePath $core -ArgumentList @('run', '-c', $Config) `
  -WorkingDirectory $root -PassThru -WindowStyle Hidden

$index = $null
for ($attempt = 0; $attempt -lt 120; $attempt++) {
  $adapter = Get-NetAdapter -Name $Adapter -ErrorAction SilentlyContinue
  if ($adapter) { $index = $adapter.ifIndex; break }
  if ($process.HasExited) { break }
  Start-Sleep -Milliseconds 100
}

if (-not $index) {
  if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
  @{ pid = 0; routes = $added } | ConvertTo-Json |
    Set-Content -LiteralPath $statePath -Encoding ASCII
  & (Join-Path $root 'velo-stop.ps1')
  exit 3
}

try {
  New-NetIPAddress -InterfaceIndex $index -IPAddress '169.254.10.2' `
    -PrefixLength 30 -ErrorAction SilentlyContinue | Out-Null
} catch { }

foreach ($prefix in @('0.0.0.0/1', '128.0.0.0/1')) {
  try {
    New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $index `
      -NextHop '0.0.0.0' -PolicyStore ActiveStore | Out-Null
    $added += $prefix
  } catch { }
}

$v6Path = Join-Path $root 'ipv6.json'
if (-not (Test-Path -LiteralPath $v6Path)) {
  $saved = @()
  foreach ($binding in (Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue)) {
    $saved += @{ name = $binding.Name; enabled = [bool]$binding.Enabled }
  }
  @{ bindings = $saved } | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $v6Path -Encoding ASCII
}
foreach ($entry in (Get-Content -LiteralPath $v6Path -Raw | ConvertFrom-Json).bindings) {
  if ($entry.enabled) {
    Disable-NetAdapterBinding -Name $entry.name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
  }
}

@{ pid = $process.Id; routes = $added } | ConvertTo-Json |
  Set-Content -LiteralPath $statePath -Encoding ASCII
exit 0
''';

  static const String _routeScript = r'''
param([string]$Requests)

$root = $PSScriptRoot
$pinPath = Join-Path $root 'pins.json'
$tunnelPath = Join-Path $root 'state.json'
$limit = 1024

''' + _gatewayFunctions + r'''
if (-not $Requests -or -not (Test-Path -LiteralPath $Requests)) { exit 2 }

$request = Get-Content -LiteralPath $Requests -Raw | ConvertFrom-Json
if (-not $request) { exit 2 }
$resultPath = "$Requests.done"

function Save-Result([object]$seq, [string]$status, [int]$count) {
  @{ seq = $seq; status = $status; count = $count } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $resultPath -Encoding ASCII
}

$pinned = @()
if (Test-Path -LiteralPath $pinPath) {
  $pinned = @((Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json).routes)
  $pinned = @($pinned | Where-Object { $_ })
}

if ($request.action -eq 'repin') {
  foreach ($prefix in $pinned) {
    Remove-NetRoute -DestinationPrefix $prefix -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $pinPath -Force -ErrorAction SilentlyContinue
  $info = Resolve-GatewayState
  if ($info.state -eq 'foreign') {
    Save-Result $request.seq 'foreigntunnel' 0
    exit 4
  }
  if ($info.state -ne 'found') {
    Save-Result $request.seq 'nogateway' 0
    exit 3
  }
  $kept = @()
  if (Test-Path -LiteralPath $tunnelPath) {
    $state = Get-Content -LiteralPath $tunnelPath -Raw | ConvertFrom-Json
    foreach ($prefix in @($state.routes)) {
      if (-not $prefix) { continue }
      if ($prefix -like '*/32' -and $prefix -notlike '0.0.0.0/*' -and
        $prefix -notlike '128.0.0.0/*') {
        Remove-NetRoute -DestinationPrefix $prefix -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
        try {
          New-NetRoute -DestinationPrefix $prefix -NextHop $info.nextHop `
            -InterfaceIndex $info.ifIndex -PolicyStore ActiveStore `
            -ErrorAction Stop | Out-Null
          $kept += $prefix
        } catch { }
      } else {
        $kept += $prefix
      }
    }
    @{ pid = $state.pid; routes = @($kept) } | ConvertTo-Json |
      Set-Content -LiteralPath $tunnelPath -Encoding ASCII
  }
  Save-Result $request.seq 'ok' $kept.Count
  exit 0
}

if ($request.action -eq 'unpin' -or $request.action -eq 'cleanup') {
  foreach ($prefix in $pinned) {
    Remove-NetRoute -DestinationPrefix $prefix -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $pinPath -Force -ErrorAction SilentlyContinue
  if ($request.action -eq 'cleanup') {
    $live = $false
    if (Test-Path -LiteralPath $tunnelPath) {
      $state = Get-Content -LiteralPath $tunnelPath -Raw | ConvertFrom-Json
      if ($state.pid -and $state.pid -gt 0 -and
        (Get-Process -Id $state.pid -ErrorAction SilentlyContinue)) {
        $live = $true
      }
    }
    $v6Path = Join-Path $root 'ipv6.json'
    if (-not $live -and (Test-Path -LiteralPath $v6Path)) {
      foreach ($entry in (Get-Content -LiteralPath $v6Path -Raw | ConvertFrom-Json).bindings) {
        if ($entry.enabled) {
          Enable-NetAdapterBinding -Name $entry.name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        }
      }
      Remove-Item -LiteralPath $v6Path -Force
    }
  }
  Save-Result $request.seq 'ok' 0
  exit 0
}

$tunnel = @()
if (Test-Path -LiteralPath $tunnelPath) {
  $tunnel = @((Get-Content -LiteralPath $tunnelPath -Raw | ConvertFrom-Json).routes)
  $tunnel = @($tunnel | Where-Object { $_ })
}

$info = Resolve-GatewayState
if ($info.state -eq 'foreign') {
  Save-Result $request.seq 'foreigntunnel' 0
  exit 4
}
if ($info.state -ne 'found') {
  Save-Result $request.seq 'nogateway' 0
  exit 3
}

$added = 0
foreach ($address in @($request.addresses)) {
  if (-not $address) { continue }
  if ($pinned.Count -ge $limit) { break }
  $prefix = "$address/32"
  if ($address -like '*:*') { $prefix = "$address/128" }
  if ($tunnel -contains $prefix) { continue }
  if ($pinned -contains $prefix) { continue }
  try {
    New-NetRoute -DestinationPrefix $prefix -NextHop $info.nextHop `
      -InterfaceIndex $info.ifIndex -PolicyStore ActiveStore `
      -ErrorAction Stop | Out-Null
    $pinned += $prefix
    $added += 1
  } catch { }
}

@{ routes = @($pinned) } | ConvertTo-Json -Compress |
  Set-Content -LiteralPath $pinPath -Encoding ASCII
Save-Result $request.seq 'ok' $added
exit 0
''';

  static const String _stopScript = r'''
$statePath = Join-Path $PSScriptRoot 'state.json'
$pinPath = Join-Path $PSScriptRoot 'pins.json'
$v6Path = Join-Path $PSScriptRoot 'ipv6.json'

if (Test-Path -LiteralPath $v6Path) {
  foreach ($entry in (Get-Content -LiteralPath $v6Path -Raw | ConvertFrom-Json).bindings) {
    if ($entry.enabled) {
      Enable-NetAdapterBinding -Name $entry.name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    }
  }
  Remove-Item -LiteralPath $v6Path -Force
}

if (Test-Path -LiteralPath $pinPath) {
  $pins = @((Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json).routes)
  foreach ($prefix in $pins) {
    if ($prefix) {
      Remove-NetRoute -DestinationPrefix $prefix -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
    }
  }
  Remove-Item -LiteralPath $pinPath -Force
}

if (Test-Path -LiteralPath $statePath) {
  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  if ($state.pid -and $state.pid -gt 0) {
    Stop-Process -Id $state.pid -Force -ErrorAction SilentlyContinue
  }
  foreach ($prefix in $state.routes) {
    Remove-NetRoute -DestinationPrefix $prefix -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $statePath -Force
} else {
  Get-Process -Name xray -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
}
exit 0
''';
}

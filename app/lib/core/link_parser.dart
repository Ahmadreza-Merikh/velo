import 'dart:convert';
import 'dart:io';

import 'models.dart';

class ParsedLink {
  ParsedLink({
    required this.node,
    required this.outbound,
    this.error = '',
  });

  final Node? node;
  final Map<String, dynamic>? outbound;
  final String error;

  bool get ok => node != null && outbound != null;

  static ParsedLink failed(String reason) => ParsedLink(
        node: null,
        outbound: null,
        error: reason,
      );
}

List<int> _decodeBase64(String data) {
  String cleaned = data.replaceAll(RegExp(r'\s'), '');
  final int pad = cleaned.length % 4;
  if (pad != 0) {
    cleaned = cleaned + '=' * (4 - pad);
  }
  try {
    return base64Url.decode(cleaned);
  } catch (_) {
    return base64.decode(cleaned);
  }
}

String _decodeBase64String(String data) {
  return utf8.decode(_decodeBase64(data), allowMalformed: true);
}

String _safeDecode(String value) {
  if (!value.contains('%') && !value.contains('+')) {
    return value;
  }
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    return value;
  }
}

String _firstParam(Map<String, List<String>> query, String key) {
  final List<String>? exact = query[key];
  if (exact != null && exact.isNotEmpty) {
    return exact.first;
  }
  final List<String>? lower = query[key.toLowerCase()];
  if (lower != null && lower.isNotEmpty) {
    return lower.first;
  }
  return '';
}

String _param(
  Map<String, List<String>> query,
  String key, [
  String fallback = '',
]) {
  final String value = _firstParam(query, key);
  return value.isEmpty ? fallback : value;
}

String _fragmentName(String uri, String fallback) {
  final int hash = uri.indexOf('#');
  if (hash < 0 || hash + 1 >= uri.length) {
    return fallback;
  }
  final String raw = uri.substring(hash + 1);
  final String decoded = _safeDecode(raw);
  return decoded.isEmpty ? fallback : decoded;
}

Map<String, List<String>> _queryOf(Uri uri) {
  final Map<String, List<String>> out = <String, List<String>>{};
  uri.queryParametersAll.forEach((String key, List<String> value) {
    out[key] = value;
    out[key.toLowerCase()] = value;
  });
  return out;
}

Map<String, dynamic> _streamSettings(
  Map<String, List<String>> query, {
  String securityDefault = 'none',
}) {
  String network = _param(query, 'type', _param(query, 'net', 'tcp')).toLowerCase();
  String security = _param(
    query,
    'security',
    _param(query, 'tls', securityDefault),
  ).toLowerCase();

  if (security == '1' || security == 'true' || security == 'tls') {
    security = 'tls';
  }
  if (security == '0' || security == 'false' || security.isEmpty) {
    security = 'none';
  }
  if (network.isEmpty) {
    network = 'tcp';
  }

  final Map<String, dynamic> stream = <String, dynamic>{
    'network': network,
    'security': security,
  };

  if (network == 'ws' || network == 'websocket') {
    stream['network'] = 'ws';
    final Map<String, dynamic> ws = <String, dynamic>{
      'path': _safeDecode(_param(query, 'path', '/')),
    };
    final String host = _param(query, 'host');
    if (host.isNotEmpty) {
      ws['headers'] = <String, dynamic>{'Host': host};
    }
    stream['wsSettings'] = ws;
  } else if (network == 'grpc' || network == 'gun') {
    stream['network'] = 'grpc';
    stream['grpcSettings'] = <String, dynamic>{
      'serviceName': _param(query, 'serviceName', _param(query, 'path')),
      'multiMode': _param(query, 'mode').toLowerCase() == 'multi',
    };
  } else if (network == 'h2' || network == 'http') {
    stream['network'] = 'h2';
    final String host = _param(query, 'host');
    stream['httpSettings'] = <String, dynamic>{
      'path': _safeDecode(_param(query, 'path', '/')),
      'host': host.isEmpty
          ? <String>[]
          : host
              .split(',')
              .map((String h) => h.trim())
              .where((String h) => h.isNotEmpty)
              .toList(),
    };
  } else if (network == 'httpupgrade' || network == 'http_upgrade') {
    stream['network'] = 'httpupgrade';
    final Map<String, dynamic> settings = <String, dynamic>{
      'path': _safeDecode(_param(query, 'path', '/')),
    };
    final String host = _param(query, 'host');
    if (host.isNotEmpty) {
      settings['host'] = host;
    }
    stream['httpupgradeSettings'] = settings;
  } else if (network == 'splithttp' || network == 'xhttp') {
    stream['network'] = 'xhttp';
    final Map<String, dynamic> settings = <String, dynamic>{
      'path': _safeDecode(_param(query, 'path', '/')),
    };
    final String host = _param(query, 'host');
    if (host.isNotEmpty) {
      settings['host'] = host;
    }
    final String mode = _param(query, 'mode');
    if (mode.isNotEmpty) {
      settings['mode'] = mode;
    }
    stream['xhttpSettings'] = settings;
  } else if (network == 'kcp' || network == 'mkcp') {
    stream['network'] = 'kcp';
    final Map<String, dynamic> kcp = <String, dynamic>{
      'mtu': 1350,
      'tti': 50,
      'uplinkCapacity': 12,
      'downlinkCapacity': 100,
      'congestion': false,
      'header': <String, dynamic>{
        'type': _param(query, 'headerType', _param(query, 'type', 'none')),
      },
    };
    final String seed = _param(query, 'seed', _param(query, 'path'));
    if (seed.isNotEmpty) {
      kcp['seed'] = seed;
    }
    stream['kcpSettings'] = kcp;
  } else {
    stream['network'] = 'tcp';
    final String headerType =
        _param(query, 'headerType', _param(query, 'header', 'none'));
    if (headerType.isNotEmpty && headerType != 'none') {
      final Map<String, dynamic> header = <String, dynamic>{
        'type': headerType,
      };
      if (headerType == 'http') {
        final String host = _param(query, 'host');
        header['request'] = <String, dynamic>{
          'path': <String>[_safeDecode(_param(query, 'path', '/'))],
          'headers': <String, dynamic>{
            'Host': host.isEmpty ? <String>[] : <String>[host],
          },
        };
      }
      stream['tcpSettings'] = <String, dynamic>{'header': header};
    }
  }

  if (security == 'tls') {
    final String insecure = _param(query, 'allowInsecure', '0');
    final Map<String, dynamic> tls = <String, dynamic>{
      'allowInsecure':
          insecure == '1' || insecure.toLowerCase() == 'true',
      'serverName': _param(
        query,
        'sni',
        _param(query, 'peer', _param(query, 'host')),
      ),
    };
    final String fingerprint =
        _param(query, 'fp', _param(query, 'fingerprint'));
    if (fingerprint.isNotEmpty) {
      tls['fingerprint'] = fingerprint;
    }
    final String alpn = _param(query, 'alpn');
    if (alpn.isNotEmpty) {
      tls['alpn'] = _safeDecode(alpn)
          .split(',')
          .map((String a) => a.trim())
          .where((String a) => a.isNotEmpty)
          .toList();
    }
    stream['tlsSettings'] = tls;
  } else if (security == 'reality') {
    final String spider = _param(query, 'spx', _param(query, 'spiderX'));
    stream['realitySettings'] = <String, dynamic>{
      'show': false,
      'fingerprint': _param(query, 'fp', _param(query, 'fingerprint', 'chrome')),
      'serverName': _param(
        query,
        'sni',
        _param(query, 'serverName', _param(query, 'host')),
      ),
      'publicKey': _param(query, 'pbk', _param(query, 'publicKey')),
      'shortId': _param(query, 'sid', _param(query, 'shortId')),
      'spiderX': spider.isEmpty ? '/' : _safeDecode(spider),
    };
  }

  return stream;
}

ParsedLink _parseVmess(String uri) {
  String payload = uri.substring('vmess://'.length);
  final int hash = payload.indexOf('#');
  if (hash >= 0) {
    payload = payload.substring(0, hash);
  }

  Map<String, dynamic> data;
  try {
    final Object? decoded = jsonDecode(_decodeBase64String(payload));
    if (decoded is! Map) {
      return ParsedLink.failed('vmess payload is not an object');
    }
    data = decoded.cast<String, dynamic>();
  } catch (error) {
    return ParsedLink.failed('vmess decode failed');
  }

  String textOf(String key) {
    final Object? value = data[key];
    if (value == null) {
      return '';
    }
    return value.toString();
  }

  final String server = textOf('add').isNotEmpty ? textOf('add') : textOf('host');
  final int port = int.tryParse(textOf('port')) ?? 0;
  final String network = (textOf('net').isEmpty ? 'tcp' : textOf('net')).toLowerCase();
  final String tlsFlag = textOf('tls').toLowerCase();
  final String hostHeader = textOf('host');
  final String path = textOf('path').isEmpty ? '/' : textOf('path');
  final String name = textOf('ps').isEmpty
      ? _fragmentName(uri, 'vmess')
      : textOf('ps');

  final Map<String, List<String>> query = <String, List<String>>{
    'type': <String>[network],
    'security': <String>[
      tlsFlag == 'tls' || tlsFlag == '1' || tlsFlag == 'true' ? 'tls' : 'none',
    ],
    'sni': <String>[textOf('sni').isEmpty ? hostHeader : textOf('sni')],
    'path': <String>[path],
    'host': <String>[hostHeader],
    'headerType': <String>[textOf('type').isEmpty ? 'none' : textOf('type')],
    'alpn': <String>[textOf('alpn')],
    'fp': <String>[
      textOf('fp').isEmpty ? textOf('fingerprint') : textOf('fp'),
    ],
    'serviceName': <String>[network == 'grpc' ? path : ''],
  };

  final Map<String, dynamic> outbound = <String, dynamic>{
    'protocol': 'vmess',
    'tag': 'proxy',
    'settings': <String, dynamic>{
      'vnext': <dynamic>[
        <String, dynamic>{
          'address': server,
          'port': port,
          'users': <dynamic>[
            <String, dynamic>{
              'id': textOf('id'),
              'alterId': int.tryParse(textOf('aid')) ??
                  int.tryParse(textOf('alterId')) ??
                  0,
              'security': textOf('scy').isEmpty ? 'auto' : textOf('scy'),
              'level': 0,
            },
          ],
        },
      ],
    },
    'streamSettings': _streamSettings(query),
  };

  return ParsedLink(
    node: Node(
      uri: uri,
      name: name,
      protocol: 'vmess',
      server: server,
      port: port,
    ),
    outbound: outbound,
  );
}

ParsedLink _parseVless(String uri) {
  final Uri? parsed = Uri.tryParse(uri.split('#').first);
  if (parsed == null || (parsed.host.isEmpty)) {
    return ParsedLink.failed('vless parse failed');
  }

  final Map<String, List<String>> query = _queryOf(parsed);
  final int port = parsed.hasPort ? parsed.port : 443;
  final Map<String, dynamic> user = <String, dynamic>{
    'id': _safeDecode(parsed.userInfo),
    'encryption': _param(query, 'encryption', 'none'),
    'level': 0,
  };
  final String flow = _param(query, 'flow');
  if (flow.isNotEmpty) {
    user['flow'] = flow;
  }

  final Map<String, dynamic> outbound = <String, dynamic>{
    'protocol': 'vless',
    'tag': 'proxy',
    'settings': <String, dynamic>{
      'vnext': <dynamic>[
        <String, dynamic>{
          'address': parsed.host,
          'port': port,
          'users': <dynamic>[user],
        },
      ],
    },
    'streamSettings': _streamSettings(query),
  };

  return ParsedLink(
    node: Node(
      uri: uri,
      name: _fragmentName(uri, 'vless'),
      protocol: 'vless',
      server: parsed.host,
      port: port,
    ),
    outbound: outbound,
  );
}

ParsedLink _parseTrojan(String uri) {
  final Uri? parsed = Uri.tryParse(uri.split('#').first);
  if (parsed == null || parsed.host.isEmpty) {
    return ParsedLink.failed('trojan parse failed');
  }

  final Map<String, List<String>> query = _queryOf(parsed);
  if (_param(query, 'security').isEmpty) {
    query['security'] = <String>['tls'];
  }
  final int port = parsed.hasPort ? parsed.port : 443;

  final Map<String, dynamic> outbound = <String, dynamic>{
    'protocol': 'trojan',
    'tag': 'proxy',
    'settings': <String, dynamic>{
      'servers': <dynamic>[
        <String, dynamic>{
          'address': parsed.host,
          'port': port,
          'password': _safeDecode(parsed.userInfo),
          'level': 0,
        },
      ],
    },
    'streamSettings': _streamSettings(query, securityDefault: 'tls'),
  };

  return ParsedLink(
    node: Node(
      uri: uri,
      name: _fragmentName(uri, 'trojan'),
      protocol: 'trojan',
      server: parsed.host,
      port: port,
    ),
    outbound: outbound,
  );
}

ParsedLink _parseShadowsocks(String uri) {
  String body = uri.substring('ss://'.length);
  final int hash = body.indexOf('#');
  if (hash >= 0) {
    body = body.substring(0, hash);
  }

  String method = '';
  String password = '';
  String host = '';
  int port = 0;

  try {
    final int at = body.lastIndexOf('@');
    if (at >= 0) {
      final String userInfo = body.substring(0, at);
      String hostInfo = body.substring(at + 1);

      final int mark = userInfo.indexOf(':');
      final String head = mark < 0 ? userInfo : userInfo.substring(0, mark);
      final bool looksPlain =
          mark > 0 && RegExp(r'^[a-z0-9\-]+$', caseSensitive: false).hasMatch(head);
      if (looksPlain) {
        method = userInfo.substring(0, mark);
        password = userInfo.substring(mark + 1);
      } else {
        final String decoded = _decodeBase64String(userInfo);
        final int split = decoded.indexOf(':');
        if (split >= 0) {
          method = decoded.substring(0, split);
          password = decoded.substring(split + 1);
        } else {
          method = decoded;
        }
      }

      final int question = hostInfo.indexOf('?');
      if (question >= 0) {
        hostInfo = hostInfo.substring(0, question);
      }

      if (hostInfo.startsWith('[')) {
        final RegExpMatch? match =
            RegExp(r'^\[([^\]]+)\]:(\d+)$').firstMatch(hostInfo);
        if (match != null) {
          host = match.group(1) ?? '';
          port = int.tryParse(match.group(2) ?? '') ?? 0;
        } else {
          host = hostInfo;
        }
      } else {
        final int colon = hostInfo.lastIndexOf(':');
        if (colon >= 0) {
          host = hostInfo.substring(0, colon);
          port = int.tryParse(hostInfo.substring(colon + 1)) ?? 0;
        } else {
          host = hostInfo;
        }
      }
    } else {
      final String decoded = _decodeBase64String(body);
      final int at2 = decoded.lastIndexOf('@');
      if (at2 < 0) {
        return ParsedLink.failed('ss parse failed');
      }
      final String userInfo = decoded.substring(0, at2);
      final String hostInfo = decoded.substring(at2 + 1);
      final int mark = userInfo.indexOf(':');
      if (mark < 0) {
        return ParsedLink.failed('ss parse failed');
      }
      method = userInfo.substring(0, mark);
      password = userInfo.substring(mark + 1);
      final int colon = hostInfo.lastIndexOf(':');
      if (colon >= 0) {
        host = hostInfo.substring(0, colon);
        port = int.tryParse(hostInfo.substring(colon + 1)) ?? 0;
      } else {
        host = hostInfo;
      }
    }
  } catch (error) {
    return ParsedLink.failed('ss parse failed');
  }

  if (host.isEmpty || port <= 0) {
    return ParsedLink.failed('ss missing host or port');
  }

  final Map<String, dynamic> outbound = <String, dynamic>{
    'protocol': 'shadowsocks',
    'tag': 'proxy',
    'settings': <String, dynamic>{
      'servers': <dynamic>[
        <String, dynamic>{
          'address': host,
          'port': port,
          'method': _safeDecode(method),
          'password': _safeDecode(password),
          'level': 0,
        },
      ],
    },
  };

  return ParsedLink(
    node: Node(
      uri: uri,
      name: _fragmentName(uri, 'ss'),
      protocol: 'ss',
      server: host,
      port: port,
    ),
    outbound: outbound,
  );
}

ParsedLink parseLink(String rawUri) {
  final String uri = rawUri.trim();
  final String lower = uri.toLowerCase();

  try {
    if (lower.startsWith('vmess://')) {
      return _parseVmess(uri);
    }
    if (lower.startsWith('vless://')) {
      return _parseVless(uri);
    }
    if (lower.startsWith('trojan://')) {
      return _parseTrojan(uri);
    }
    if (lower.startsWith('ss://')) {
      return _parseShadowsocks(uri);
    }
  } catch (error) {
    return ParsedLink.failed('parse error');
  }

  final int scheme = lower.indexOf('://');
  final String name = scheme > 0 ? lower.substring(0, scheme) : 'unknown';
  return ParsedLink.failed('unsupported protocol: $name');
}

List<Node> parseLinks(List<String> uris) {
  final List<Node> nodes = <Node>[];
  final Set<String> seen = <String>{};
  for (final String uri in uris) {
    final ParsedLink parsed = parseLink(uri);
    final Node? node = parsed.node;
    if (node == null) {
      continue;
    }
    final String key = '${node.protocol}|${node.server}|${node.port}|${node.uri}';
    if (seen.add(key)) {
      nodes.add(node);
    }
  }
  return nodes;
}

const List<String> tunnelDnsServers = <String>['1.1.1.1', '8.8.8.8'];

Map<String, dynamic> withDialAddress(
  Map<String, dynamic> outbound,
  String address,
) {
  final Object? clone = jsonDecode(jsonEncode(outbound));
  if (clone is! Map) {
    return outbound;
  }
  final Map<String, dynamic> copy = clone.cast<String, dynamic>();
  final Object? settings = copy['settings'];
  if (settings is! Map) {
    return outbound;
  }

  String original = '';
  for (final String key in <String>['vnext', 'servers']) {
    final Object? list = settings[key];
    if (list is! List) {
      continue;
    }
    for (final Object? entry in list) {
      if (entry is! Map) {
        continue;
      }
      final Object? host = entry['address'];
      if (host is String && host.isNotEmpty) {
        if (original.isEmpty && InternetAddress.tryParse(host) == null) {
          original = host;
        }
        entry['address'] = address;
      }
    }
  }

  if (original.isEmpty) {
    return copy;
  }

  final Object? stream = copy['streamSettings'];
  if (stream is! Map) {
    return copy;
  }

  for (final String key in <String>['tlsSettings', 'realitySettings']) {
    final Object? security = stream[key];
    if (security is Map) {
      final Object? name = security['serverName'];
      if (name is! String || name.isEmpty) {
        security['serverName'] = original;
      }
    }
  }

  final Object? ws = stream['wsSettings'];
  if (ws is Map) {
    final Object? headers = ws['headers'];
    if (headers is Map) {
      final Object? value = headers['Host'];
      if (value is! String || value.isEmpty) {
        headers['Host'] = original;
      }
    } else {
      ws['headers'] = <String, dynamic>{'Host': original};
    }
  }

  for (final String key in <String>['httpupgradeSettings', 'xhttpSettings']) {
    final Object? value = stream[key];
    if (value is Map) {
      final Object? host = value['host'];
      if (host is! String || host.isEmpty) {
        value['host'] = original;
      }
    }
  }

  final Object? http = stream['httpSettings'];
  if (http is Map) {
    final Object? hosts = http['host'];
    if (hosts is! List || hosts.isEmpty) {
      http['host'] = <String>[original];
    }
  }

  return copy;
}

Map<String, dynamic> probeConfig(Map<String, dynamic> outbound, int httpPort) {
  return <String, dynamic>{
    'log': <String, dynamic>{'loglevel': 'none'},
    'inbounds': <dynamic>[
      <String, dynamic>{
        'tag': 'probe-in',
        'listen': '127.0.0.1',
        'port': httpPort,
        'protocol': 'http',
        'settings': <String, dynamic>{'allowTransparent': false},
      },
    ],
    'outbounds': <dynamic>[
      outbound,
      <String, dynamic>{'protocol': 'freedom', 'tag': 'direct'},
    ],
    'routing': <String, dynamic>{
      'domainStrategy': 'AsIs',
      'rules': <dynamic>[
        <String, dynamic>{
          'type': 'field',
          'outboundTag': 'proxy',
          'network': 'tcp,udp',
        },
      ],
    },
  };
}

Map<String, dynamic> tunnelConfig(
  Map<String, dynamic> outbound, {
  required bool tun,
  required int socksPort,
  required int httpPort,
  String tunName = '',
  int mtu = 1500,
  List<String> dns = tunnelDnsServers,
}) {
  final List<dynamic> inbounds = <dynamic>[
    <String, dynamic>{
      'tag': 'socks-in',
      'listen': '127.0.0.1',
      'port': socksPort,
      'protocol': 'socks',
      'settings': <String, dynamic>{'auth': 'noauth', 'udp': true},
      'sniffing': <String, dynamic>{
        'enabled': true,
        'destOverride': <String>['http', 'tls'],
      },
    },
    <String, dynamic>{
      'tag': 'http-in',
      'listen': '127.0.0.1',
      'port': httpPort,
      'protocol': 'http',
      'settings': <String, dynamic>{'allowTransparent': false},
    },
  ];

  if (tun) {
    final Map<String, dynamic> settings = <String, dynamic>{
      'MTU': mtu,
      'mtu': mtu,
      'userLevel': 0,
    };
    if (tunName.isNotEmpty) {
      settings['name'] = tunName;
    }
    inbounds.insert(0, <String, dynamic>{
      'tag': 'tun-in',
      'port': 0,
      'protocol': 'tun',
      'settings': settings,
      'sniffing': <String, dynamic>{
        'enabled': true,
        'destOverride': <String>['http', 'tls'],
      },
    });
  }

  return <String, dynamic>{
    'log': <String, dynamic>{'loglevel': 'warning'},
    'dns': <String, dynamic>{
      'servers': <dynamic>[...dns],
      'queryStrategy': 'UseIPv4',
    },
    'inbounds': inbounds,
    'outbounds': <dynamic>[
      outbound,
      <String, dynamic>{'protocol': 'freedom', 'tag': 'direct'},
      <String, dynamic>{'protocol': 'blackhole', 'tag': 'block'},
    ],
    'routing': <String, dynamic>{
      'domainStrategy': 'AsIs',
      'rules': <dynamic>[
        <String, dynamic>{
          'type': 'field',
          'outboundTag': 'proxy',
          'network': 'tcp,udp',
        },
      ],
    },
  };
}

Map<String, dynamic> androidTunnelConfig(
  Map<String, dynamic> outbound, {
  required int socksPort,
  List<String> dns = tunnelDnsServers,
}) {
  return <String, dynamic>{
    'log': <String, dynamic>{'loglevel': 'warning'},
    'dns': <String, dynamic>{
      'servers': <dynamic>[...dns],
      'queryStrategy': 'UseIPv4',
    },
    'inbounds': <dynamic>[
      <String, dynamic>{
        'tag': 'tun-in',
        'port': 0,
        'protocol': 'tun',
        'settings': <String, dynamic>{
          'MTU': 1500,
          'mtu': 1500,
          'userLevel': 0,
        },
        'sniffing': <String, dynamic>{
          'enabled': true,
          'destOverride': <String>['http', 'tls'],
        },
      },
      <String, dynamic>{
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'port': socksPort,
        'protocol': 'socks',
        'settings': <String, dynamic>{'auth': 'noauth', 'udp': true},
      },
    ],
    'outbounds': <dynamic>[
      outbound,
      <String, dynamic>{'protocol': 'freedom', 'tag': 'direct'},
      <String, dynamic>{'protocol': 'blackhole', 'tag': 'block'},
    ],
    'routing': <String, dynamic>{
      'domainStrategy': 'AsIs',
      'rules': <dynamic>[
        <String, dynamic>{
          'type': 'field',
          'outboundTag': 'proxy',
          'network': 'tcp,udp',
        },
      ],
    },
  };
}

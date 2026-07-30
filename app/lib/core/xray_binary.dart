import 'dart:convert';
import 'dart:io';

class XrayBinary {
  XrayBinary(this.file);

  final File file;

  static const String _releaseApi =
      'https://api.github.com/repos/XTLS/Xray-core/releases/latest';
  static const String _fallbackTag = 'v26.3.27';

  static String get binaryName => Platform.isWindows ? 'xray.exe' : 'xray';

  static List<String> _candidatePaths(Directory support) {
    final String sep = Platform.pathSeparator;
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final List<String> paths = <String>[
      '$exeDir$sep$binaryName',
      '$exeDir$sep..${sep}Resources$sep$binaryName',
      '$exeDir${sep}data${sep}flutter_assets${sep}bin$sep$binaryName',
      '${support.path}$sep$binaryName',
    ];
    return paths;
  }

  static File? locate(Directory support) {
    for (final String path in _candidatePaths(support)) {
      final File candidate = File(path);
      if (candidate.existsSync()) {
        return File(candidate.absolute.path);
      }
    }
    final String? onPath = _which(binaryName);
    if (onPath != null) {
      return File(onPath);
    }
    return null;
  }

  static String? _which(String name) {
    try {
      final ProcessResult result = Platform.isWindows
          ? Process.runSync('where', <String>[name])
          : Process.runSync('which', <String>[name]);
      if (result.exitCode != 0) {
        return null;
      }
      final String out = (result.stdout as String).trim();
      if (out.isEmpty) {
        return null;
      }
      return out.split('\n').first.trim();
    } catch (_) {
      return null;
    }
  }

  static String _assetName() {
    final String arch = _arch();
    if (Platform.isMacOS) {
      return 'Xray-macos-$arch.zip';
    }
    if (Platform.isWindows) {
      return arch == 'arm64-v8a' ? 'Xray-windows-arm64-v8a.zip' : 'Xray-windows-64.zip';
    }
    return 'Xray-linux-$arch.zip';
  }

  static String _arch() {
    final String version = Platform.version.toLowerCase();
    if (version.contains('arm64') || version.contains('aarch64')) {
      return 'arm64-v8a';
    }
    return '64';
  }

  static Future<File> ensure(
    Directory support, {
    void Function(String message)? onStatus,
  }) async {
    final File? existing = locate(support);
    if (existing != null) {
      return existing;
    }

    onStatus?.call('downloading proxy core');
    final String asset = _assetName();
    final Uri url = await _resolveDownloadUrl(asset);
    final Directory temp = Directory(
      '${support.path}${Platform.pathSeparator}download',
    );
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
    temp.createSync(recursive: true);

    final File archive = File('${temp.path}${Platform.pathSeparator}$asset');
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(url);
      request.followRedirects = true;
      request.maxRedirects = 8;
      final HttpClientResponse response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('core download failed with http ${response.statusCode}');
      }
      final IOSink sink = archive.openWrite();
      await response.pipe(sink);
    } finally {
      client.close(force: true);
    }

    onStatus?.call('unpacking proxy core');
    await _extract(archive, temp);

    final File? found = _findInDirectory(temp, binaryName);
    if (found == null) {
      throw Exception('proxy core missing from archive');
    }

    final File target = File('${support.path}${Platform.pathSeparator}$binaryName');
    if (target.existsSync()) {
      target.deleteSync();
    }
    await found.copy(target.path);
    temp.deleteSync(recursive: true);

    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['+x', target.path]);
      if (Platform.isMacOS) {
        await Process.run(
          'xattr',
          <String>['-d', 'com.apple.quarantine', target.path],
        );
      }
    }

    return target;
  }

  static Future<Uri> _resolveDownloadUrl(String asset) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(Uri.parse(_releaseApi));
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('User-Agent', 'velo');
      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        final Object? assets = decoded['assets'];
        if (assets is List) {
          for (final Object? item in assets) {
            if (item is Map &&
                (item['name'] as String?)?.toLowerCase() == asset.toLowerCase()) {
              final Object? link = item['browser_download_url'];
              if (link is String) {
                return Uri.parse(link);
              }
            }
          }
        }
        final Object? tag = decoded['tag_name'];
        if (tag is String) {
          return Uri.parse(
            'https://github.com/XTLS/Xray-core/releases/download/$tag/$asset',
          );
        }
      }
    } catch (_) {
      return Uri.parse(
        'https://github.com/XTLS/Xray-core/releases/download/$_fallbackTag/$asset',
      );
    } finally {
      client.close(force: true);
    }
    return Uri.parse(
      'https://github.com/XTLS/Xray-core/releases/download/$_fallbackTag/$asset',
    );
  }

  static Future<void> _extract(File archive, Directory target) async {
    if (Platform.isWindows) {
      final ProcessResult result = await Process.run('powershell', <String>[
        '-NoProfile',
        '-Command',
        'Expand-Archive -LiteralPath "${archive.path}" '
            '-DestinationPath "${target.path}" -Force',
      ]);
      if (result.exitCode != 0) {
        throw Exception('unpacking failed: ${result.stderr}');
      }
      return;
    }
    final ProcessResult result = await Process.run(
      'unzip',
      <String>['-o', archive.path, '-d', target.path],
    );
    if (result.exitCode != 0) {
      throw Exception('unpacking failed: ${result.stderr}');
    }
  }

  static File? _findInDirectory(Directory dir, String name) {
    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is File && entity.uri.pathSegments.last == name) {
        return entity;
      }
    }
    return null;
  }
}

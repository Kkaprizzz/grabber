import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/native.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Releases are public on GitHub; CI attaches the signed APK to each vX.Y.Z tag.
const _latest = 'https://api.github.com/repos/Kkaprizzz/grabber/releases/latest';

class Release {
  Release({required this.version, required this.build, required this.url, required this.size, required this.sha256, required this.notes});
  final String version;
  final int build;
  final String url;
  final int size;
  final String sha256;
  final String notes;
}

Future<T> _withClient<T>(Future<T> Function(HttpClient) f) async {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'grabber-updater';
  try {
    return await f(c);
  } finally {
    c.close(force: true);
  }
}

Future<String> _getText(HttpClient c, String url) async {
  final req = await c.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
  final res = await req.close();
  if (res.statusCode == 404) throw const HttpException('404');
  if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
  return res.transform(utf8.decoder).join();
}

/// The latest release if it's newer than what's installed, else null.
Future<Release?> checkForUpdate() async {
  final current = await Native.version();
  return _withClient((c) async {
    final String body;
    try {
      body = await _getText(c, _latest);
    } on HttpException catch (e) {
      if (e.message == '404') return null; // nothing released yet
      throw GrabError('GitHub не ответил: ${e.message}');
    } on SocketException {
      throw GrabError('Нет связи с GitHub');
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    final m = RegExp(r'^v(\d+)\.(\d+)\.(\d+)$').firstMatch(j['tag_name'] as String? ?? '');
    if (m == null) return null;
    final build = int.parse(m[1]!) * 10000 + int.parse(m[2]!) * 100 + int.parse(m[3]!);
    if (build <= current.code) return null;
    final version = '${m[1]}.${m[2]}.${m[3]}';
    final assets = (j['assets'] as List).cast<Map<String, dynamic>>();
    final apk = assets.where((a) => a['name'] == 'grabber-$version.apk').firstOrNull;
    if (apk == null) return null;
    // GitHub reports each asset's SHA-256; older API answers lack it, so CI
    // also uploads a .sha256 next to the APK.
    var sha = (apk['digest'] as String?)?.replaceFirst('sha256:', '');
    if (sha == null) {
      final side = assets.where((a) => a['name'] == 'grabber-$version.apk.sha256').firstOrNull;
      if (side == null) return null;
      sha = (await _getText(c, side['browser_download_url'] as String)).trim().split(RegExp(r'\s+')).first;
    }
    return Release(
      version: version,
      build: build,
      url: apk['browser_download_url'] as String,
      size: (apk['size'] as num).toInt(),
      sha256: sha.toLowerCase(),
      notes: (j['body'] as String? ?? '').trim(),
    );
  });
}

/// Asks, downloads, verifies the SHA-256, then opens Android's installer
/// (which also checks the APK is signed with the same key).
Future<void> offerUpdate(BuildContext context, Release rel) async {
  final t = Theme.of(context).textTheme;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Версия ${rel.version}'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (rel.notes.isNotEmpty) ...[Text(rel.notes), const SizedBox(height: 12)],
            Text('${fmtBytes(rel.size)} · после скачивания откроется установщик Android', style: t.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Позже')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Обновить')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  final progress = ValueNotifier<double?>(null);
  final cancelled = ValueNotifier(false);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('Скачиваю ${rel.version}'),
        content: ValueListenableBuilder(
          valueListenable: progress,
          builder: (_, v, _) => LinearProgressIndicator(value: v),
        ),
        actions: [TextButton(onPressed: () => cancelled.value = true, child: const Text('Отмена'))],
      ),
    ),
  );
  void close() {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  try {
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    await dir.create(recursive: true);
    final file = File('${dir.path}/grabber-${rel.version}.apk');
    await _withClient((c) async {
      final res = await (await c.getUrl(Uri.parse(rel.url))).close();
      if (res.statusCode != 200) throw GrabError('GitHub не отдал файл (${res.statusCode})');
      final sink = file.openWrite();
      var got = 0;
      try {
        await for (final chunk in res) {
          if (cancelled.value) throw GrabError('Отменено');
          sink.add(chunk);
          got += chunk.length;
          progress.value = rel.size == 0 ? null : got / rel.size;
        }
      } finally {
        await sink.close();
      }
    });
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != rel.sha256) {
      await file.delete();
      throw GrabError('Файл обновления повреждён при скачивании, попробуй ещё раз');
    }
    close();
    final r = await Native.install(file.path);
    if (r == 'needs_permission' && context.mounted) {
      showInfo(context, 'Разреши Грабберу устанавливать приложения и нажми «Обновить» ещё раз');
    }
  } on Object catch (e) {
    close();
    if (context.mounted && !(e is GrabError && e.message == 'Отменено')) showError(context, e);
  }
}

/// One-line reminder shown on launch when a newer release exists.
void showUpdateSnack(BuildContext context, Release rel) {
  final p = Palette.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('Доступна версия ${rel.version}'),
      action: SnackBarAction(label: 'Обновить', textColor: p.accent, onPressed: () => offerUpdate(context, rel)),
    ),
  );
}

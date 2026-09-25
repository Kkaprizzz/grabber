import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Bridge to MainActivity.kt: yt-dlp (Engine.kt), the download queue
/// (DownloadService.kt) and the history (Store.kt) all live on the native
/// side, so downloads survive the app being closed.
const _native = MethodChannel('grabber/native');
const _events = EventChannel('grabber/events');

/// A failure the user should read: yt-dlp's message, translated where we
/// recognise it (see [humanize]).
class GrabError implements Exception {
  GrabError(this.message, {this.raw, this.updateMayHelp = false});
  final String message;
  final String? raw;

  /// Whether «Обновить yt-dlp и повторить» is worth offering.
  final bool updateMayHelp;

  @override
  String toString() => message;
}

/// yt-dlp speaks English and in detail; the user needs to know what happened
/// and whether anything they can do helps.
GrabError humanize(String raw) {
  final s = raw.toLowerCase();
  bool has(String x) => s.contains(x.toLowerCase());
  String msg;
  var update = false;
  if (has('unsupported url')) {
    msg = 'Эта ссылка не поддерживается';
  } else if (has('sign in to confirm') && has('bot')) {
    msg = 'YouTube просит подтвердить, что это не бот. Обычно помогает сменить сеть '
        '(Wi-Fi ↔ мобильный интернет) или подождать.';
  } else if (has('sign in to confirm your age') || has('age-restricted') || has('inappropriate for some users')) {
    msg = 'Видео 18+: YouTube не отдаёт его без входа';
  } else if (has('private video') || has('private post') || has('private account') || has('this account is private')) {
    msg = 'Это приватное видео';
  } else if (has('rate-limit') || has('login required') || has('requested content is not available')) {
    msg = 'Instagram не отдал пост без входа. Так бывает с закрытыми аккаунтами и при частых запросах — '
        'попробуй позже.';
  } else if (has('ip address is blocked') || has('video unavailable') || has('this video is not available') ||
      has('post is unavailable') || has('has been removed')) {
    msg = 'Недоступно: удалено, скрыто или закрыто в этой стране';
  } else if (has('live event will begin') || has('is live')) {
    msg = 'Это прямая трансляция — её можно скачать, когда она закончится';
  } else if (has('unable to download webpage') || has('timed out') || has('failed to resolve') ||
      has('network is unreachable') || has('connection reset') || has('no address associated')) {
    msg = 'Нет связи с сайтом. Проверь интернет.';
  } else if (has('http error 403') || has('forbidden')) {
    msg = 'Сайт не отдал файл (403)';
    update = true;
  } else if (has('ничего не скачалось')) {
    msg = 'Ничего не скачалось';
    update = true;
  } else {
    msg = 'Не получилось: ${raw.split('\n').first}';
    update = true;
  }
  return GrabError(msg, raw: raw, updateMayHelp: update);
}

Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
  try {
    return await _native.invokeMethod<T>(method, args);
  } on PlatformException catch (e) {
    throw humanize(e.message ?? e.code);
  }
}

class SavedFile {
  SavedFile.fromJson(Map<String, dynamic> j)
      : uri = j['uri'] as String,
        name = j['name'] as String? ?? '',
        mime = j['mime'] as String? ?? '',
        size = (j['size'] as num?)?.toInt() ?? 0,
        collection = j['collection'] as String? ?? 'video';

  final String uri, name, mime, collection;
  final int size;

  Map<String, String> toShare() => {'uri': uri, 'mime': mime};
}

/// A queued, running, waiting or failed download (Job in Store.kt).
class QueuedJob {
  QueuedJob.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        url = j['url'] as String? ?? '',
        title = j['title'] as String? ?? '',
        platform = j['platform'] as String? ?? '',
        thumb = j['thumb'] as String?,
        state = j['state'] as String? ?? 'queued',
        progress = (j['progress'] as num?)?.toDouble() ?? 0,
        phase = j['phase'] as String? ?? '',
        error = j['error'] as String?;

  final String id, url, title, platform, state, phase;
  final String? thumb, error;

  /// 0..1, or negative while nothing is measurable (merging, converting).
  final double progress;

  bool get running => state == 'running' || state == 'network';
  bool get failed => state == 'failed';
}

/// A finished download (Entry in Store.kt). [thumb] is a local file.
class HistoryEntry {
  HistoryEntry.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        url = j['url'] as String? ?? '',
        title = j['title'] as String? ?? '',
        platform = j['platform'] as String? ?? '',
        thumb = j['thumb'] as String?,
        files = ((j['files'] as List?) ?? const []).map((f) => SavedFile.fromJson(f as Map<String, dynamic>)).toList(),
        at = DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0);

  final String id, url, title, platform;
  final String? thumb;
  final List<SavedFile> files;
  final DateTime at;

  int get size => files.fold(0, (a, f) => a + f.size);
}

List<T> _list<T>(String? json, T Function(Map<String, dynamic>) f) =>
    json == null ? [] : (jsonDecode(json) as List).map((e) => f(e as Map<String, dynamic>)).toList();

class Native {
  /// "queue" / "history" changes and links shared into the app.
  static Stream<Map<Object?, Object?>> events() =>
      _events.receiveBroadcastStream().map((e) => e as Map<Object?, Object?>);

  static List<QueuedJob> parseQueue(String? json) => _list(json, QueuedJob.fromJson);
  static List<HistoryEntry> parseHistory(String? json) => _list(json, HistoryEntry.fromJson);

  /// Text shared into the app that launched it, if any (read once).
  static Future<String?> sharedText() => _call<String>('sharedText');

  /// Unpacks Python and ffmpeg on first run (seconds); returns yt-dlp's version.
  static Future<String?> engine() => _call<String>('engine');

  /// yt-dlp's JSON for [url]; kept native-side under [id] for the download.
  static Future<String> probe(String url, String id, List<String> args) async =>
      (await _call<String>('probe', {'url': url, 'id': id, 'args': args}))!;

  static Future<void> cancelProbe(String id) => _call('cancelProbe', {'id': id});

  /// Returns (status: done | up_to_date, version).
  static Future<({String status, String? version})> updateYtDlp() async {
    final m = (await _call<Map<Object?, Object?>>('updateYtDlp'))!;
    return (status: m['status'] as String, version: m['version'] as String?);
  }

  static Future<List<QueuedJob>> queue() async => parseQueue(await _call<String>('queue'));
  static Future<List<HistoryEntry>> history() async => parseHistory(await _call<String>('history'));

  static Future<void> enqueue(Map<String, Object?> job) => _call('enqueue', {'job': jsonEncode(job)});
  static Future<void> resume() => _call('resume');
  static Future<void> cancel(String id) => _call('cancel', {'id': id});

  /// Retries one failed job, or all of them when [id] is null.
  static Future<void> retry([String? id]) => _call('retry', {'id': id});

  static Future<List<bool>> exists(List<String> uris) async =>
      ((await _call<List<Object?>>('exists', {'uris': uris})) ?? const []).cast<bool>();

  /// False when no app on the phone can open it.
  static Future<bool> open(SavedFile f) async => await _call<bool>('open', {'uri': f.uri, 'mime': f.mime}) ?? false;

  static Future<void> share(List<SavedFile> files) =>
      _call('share', {'files': files.map((f) => f.toShare()).toList()});

  /// "done", or "kept" when some files couldn't be deleted.
  static Future<String> deleteEntry(String id, {required bool files}) async =>
      await _call<String>('deleteEntry', {'id': id, 'files': files}) ?? 'done';

  static Future<void> clearHistory() => _call('clearHistory');

  /// Storage (Android 8–9) and notifications (13+). False: saving won't work.
  static Future<bool> permissions() async => await _call<bool>('permissions') ?? false;

  static Future<({String name, int code})> version() async {
    final m = (await _call<Map<Object?, Object?>>('version'))!;
    return (name: m['name'] as String? ?? '?', code: (m['code'] as num?)?.toInt() ?? 0);
  }

  /// "started", or "needs_permission" when the user must allow installs first.
  static Future<String?> install(String path) => _call<String>('install', {'path': path});
}

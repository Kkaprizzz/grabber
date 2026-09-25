import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine/native.dart';

/// Everything the screens show: the native queue and history, the engine's
/// state, settings. One instance for the app, reached through [AppScope].
class AppState extends ChangeNotifier {
  AppState(this._prefs)
      : theme = ValueNotifier(ThemeMode.values.byName(_prefs.getString('theme') ?? ThemeMode.system.name)),
        ytdlpCheckedAt = _prefs.getInt('ytdlpCheckedAt')?.let(DateTime.fromMillisecondsSinceEpoch);

  static Future<AppState> load() async => AppState(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  List<QueuedJob> queue = const [];
  List<HistoryEntry> history = const [];

  /// History entries whose files are gone (deleted in the Gallery).
  Set<String> missing = const {};

  /// Separate from the rest so progress ticks don't rebuild MaterialApp.
  final ValueNotifier<ThemeMode> theme;

  /// yt-dlp's version once the engine is up; null while it unpacks.
  String? ytdlp;
  bool engineReady = false;
  GrabError? engineError;
  bool updatingYtDlp = false;
  DateTime? ytdlpCheckedAt;

  Future<void>? _warm;
  Future<({String status, String? version})>? _update;
  StreamSubscription<Object?>? _events;

  /// Links shared into the app while it runs (and the one it was opened with).
  final _links = StreamController<String>.broadcast();
  Stream<String> get links => _links.stream;
  String? _pendingLink;

  final _started = Completer<void>();

  /// Queue, history and the launch link are loaded.
  Future<void> get started => _started.future;

  /// The link the app was opened with, taken once by the home screen.
  String? takePendingLink() {
    final l = _pendingLink;
    _pendingLink = null;
    return l;
  }

  Future<void> start() async {
    _events = Native.events().listen((e) {
      switch (e['type']) {
        case 'queue':
          queue = Native.parseQueue(e['data'] as String?);
          notifyListeners();
        case 'history':
          history = Native.parseHistory(e['data'] as String?);
          notifyListeners();
          checkFiles();
        case 'share':
          _links.add(e['data'] as String);
      }
    });
    queue = await Native.queue();
    history = await Native.history();
    notifyListeners();
    _pendingLink = await Native.sharedText();
    _started.complete();
    unawaited(Native.resume());
    unawaited(checkFiles());
    _warm = _warmUp();
  }

  Future<void> _warmUp() async {
    try {
      ytdlp = await Native.engine();
      engineReady = true;
      engineError = null;
      notifyListeners();
    } on GrabError catch (e) {
      engineError = e;
      notifyListeners();
      return;
    }
    // The yt-dlp inside the APK is older than the sites it talks to; the
    // first launch updates right away, then once a day.
    final checked = ytdlpCheckedAt;
    if (checked == null || DateTime.now().difference(checked) > const Duration(hours: 24)) {
      try {
        await updateYtDlp();
      } on GrabError {
        // No network now; the next launch tries again.
      }
    }
  }

  /// Waits until probing can start: engine unpacked, no yt-dlp swap running.
  Future<void> ready() async {
    await _warm;
    if (engineError != null) {
      _warm = _warmUp();
      await _warm;
      if (engineError case final e?) throw e;
    }
    await _update;
  }

  Future<({String status, String? version})> updateYtDlp() {
    return _update ??= () async {
      updatingYtDlp = true;
      notifyListeners();
      try {
        final r = await Native.updateYtDlp();
        ytdlp = r.version ?? ytdlp;
        ytdlpCheckedAt = DateTime.now();
        await _prefs.setInt('ytdlpCheckedAt', ytdlpCheckedAt!.millisecondsSinceEpoch);
        return r;
      } finally {
        updatingYtDlp = false;
        _update = null;
        notifyListeners();
      }
    }();
  }

  Future<void> checkFiles() async {
    final uris = [for (final e in history) ...e.files.map((f) => f.uri)];
    if (uris.isEmpty) {
      missing = const {};
      return;
    }
    final exists = await Native.exists(uris);
    final gone = <String>{};
    var i = 0;
    for (final e in history) {
      var any = false;
      for (final _ in e.files) {
        if (i < exists.length && exists[i]) any = true;
        i++;
      }
      if (!any) gone.add(e.id);
    }
    missing = gone;
    notifyListeners();
  }

  Future<void> setTheme(ThemeMode m) async {
    theme.value = m;
    await _prefs.setString('theme', m.name);
  }

  /// Links the user already dismissed from the clipboard banner.
  String? get dismissedClip => _prefs.getString('dismissedClip');
  Future<void> dismissClip(String url) => _prefs.setString('dismissedClip', url);

  DateTime? get appCheckedAt => _prefs.getInt('appCheckedAt')?.let(DateTime.fromMillisecondsSinceEpoch);
  Future<void> markAppChecked() => _prefs.setInt('appCheckedAt', DateTime.now().millisecondsSinceEpoch);

  @override
  void dispose() {
    _events?.cancel();
    _links.close();
    super.dispose();
  }
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// For callbacks: no rebuild dependency.
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

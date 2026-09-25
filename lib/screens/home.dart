import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/links.dart';
import '../engine/native.dart';
import '../state.dart';
import '../theme.dart';
import '../update/updater.dart';
import '../widgets/common.dart';
import 'pick.dart';
import 'settings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _field = TextEditingController();
  StreamSubscription<String>? _links;

  /// A supported link found in the clipboard, offered as a banner.
  String? _clip;

  /// The last link opened, so the clipboard banner doesn't offer it again.
  String? _lastPicked;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _field.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final app = AppScope.read(context);
      _links = app.links.listen(_openShared);
      await app.started;
      if (!mounted) return;
      if (app.takePendingLink() case final l?) _openShared(l);
      await _checkClipboard();
      await _checkAppUpdate();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _links?.cancel();
    _field.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      AppScope.read(context).checkFiles();
      // Android 10+ only lets the focused app read the clipboard; give the
      // window a moment to get focus after resuming.
      Future<void>.delayed(const Duration(milliseconds: 300), _checkClipboard);
    }
  }

  Future<void> _checkClipboard() async {
    if (!mounted) return;
    final app = AppScope.read(context);
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final url = text == null ? null : extractUrl(text);
    String? offer;
    if (url != null && siteOf(url) != Site.other && url != app.dismissedClip && url != _lastPicked) {
      final key = linkKey(url);
      final known = app.history.any((e) => linkKey(e.url) == key) || app.queue.any((j) => linkKey(j.url) == key);
      if (!known) offer = url;
    }
    if (mounted && offer != _clip) setState(() => _clip = offer);
  }

  Future<void> _checkAppUpdate() async {
    final app = AppScope.read(context);
    final last = app.appCheckedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 24)) return;
    try {
      final rel = await checkForUpdate();
      await app.markAppChecked();
      if (rel != null && mounted) showUpdateSnack(context, rel);
    } on Object {
      // Offline or GitHub hiccup: tomorrow.
    }
  }

  void _openShared(String text) {
    final url = extractUrl(text);
    if (url == null) {
      showInfo(context, 'В том, чем поделились, нет ссылки');
      return;
    }
    _pick(url);
  }

  void _submit() {
    final url = extractUrl(_field.text);
    if (url == null) {
      showInfo(context, 'Не вижу ссылки');
      return;
    }
    _field.clear();
    FocusScope.of(context).unfocus();
    _pick(url);
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) {
      if (mounted) showInfo(context, 'Буфер обмена пуст');
      return;
    }
    _field.text = text.trim();
    _submit();
  }

  void _pick(String url) {
    _lastPicked = url;
    if (_clip == url) setState(() => _clip = null);
    // Only one pick screen at a time: a new share replaces the open one.
    Navigator.of(context).popUntil((r) => r.isFirst);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PickScreen(url: url)));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = Palette.of(context);
    final t = Theme.of(context).textTheme;
    final active = app.queue.where((j) => j.running).firstOrNull;
    final waiting = app.queue.where((j) => j.state == 'queued').toList();
    final failed = app.queue.where((j) => j.failed).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Граббер'),
        actions: [
          IconButton(
            tooltip: 'Настройки',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _field,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Ссылка на видео или пост',
                suffixIcon: _field.text.isEmpty
                    ? IconButton(tooltip: 'Вставить', icon: const Icon(Icons.content_paste_rounded), onPressed: _paste)
                    : IconButton(tooltip: 'Дальше', icon: const Icon(Icons.arrow_forward_rounded), onPressed: _submit),
              ),
            ),
          ),
          if (_clip != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _ClipBanner(
                url: _clip!,
                onOpen: () => _pick(_clip!),
                onDismiss: () {
                  app.dismissClip(_clip!);
                  setState(() => _clip = null);
                },
              ),
            ),
          if (app.engineError case final e?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Note('Движок не запустился: ${e.message}', fill: p.errFill, ink: p.errInk),
            ),
          if (active != null) ...[
            const SectionLabel('Сейчас'),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _ActiveJob(job: active)),
          ],
          if (waiting.isNotEmpty || failed.isNotEmpty) ...[
            SectionLabel(
              'В очереди',
              trailing: failed.length > 1
                  ? TextButton(onPressed: () => Native.retry(), child: const Text('Повторить все'))
                  : null,
            ),
            for (final j in failed) _FailedJob(job: j),
            for (final j in waiting) _WaitingJob(job: j),
          ],
          if (app.history.isNotEmpty) ...[
            const SectionLabel('Скачано'),
            for (final e in app.history) _HistoryRow(entry: e, missing: app.missing.contains(e.id), onAgain: () => _pick(e.url)),
          ],
          if (app.history.isEmpty && app.queue.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Text(
                'Поделись ссылкой из TikTok, YouTube или Instagram — «Поделиться» → Граббер. '
                'Или вставь её в поле сверху.',
                style: t.bodyMedium?.copyWith(color: p.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class _ClipBanner extends StatelessWidget {
  const _ClipBanner({required this.url, required this.onOpen, required this.onDismiss});
  final String url;
  final VoidCallback onOpen, onDismiss;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = Theme.of(context).textTheme;
    final site = siteOf(url);
    final short = url.replaceFirst(RegExp(r'^https?://(www\.)?'), '');
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: p.outline)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('В буфере ссылка на ${site.label}', style: t.labelLarge),
                    const SizedBox(height: 2),
                    Text(short, style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              TextButton(onPressed: onOpen, child: const Text('Скачать')),
              IconButton(tooltip: 'Не надо', icon: const Icon(Icons.close_rounded, size: 20), onPressed: onDismiss),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActiveJob extends StatelessWidget {
  const _ActiveJob({required this.job});
  final QueuedJob job;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = Theme.of(context).textTheme;
    final pct = job.progress >= 0 ? ' · ${(job.progress * 100).round()}%' : '';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Cover(url: job.thumb, width: rowThumbWidth(job.platform, 72), height: 72),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(job.title, style: t.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text('${job.phase.isEmpty ? 'Готовлюсь' : job.phase}$pct', style: mono(context, size: 13, color: p.textMuted)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Отменить',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Native.cancel(job.id),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: job.progress < 0
                ? const LinearProgressIndicator()
                : TweenAnimationBuilder<double>(
                    tween: Tween(end: job.progress.clamp(0, 1)),
                    duration: motion(context, kFast),
                    curve: kEase,
                    builder: (_, v, _) => LinearProgressIndicator(value: v),
                  ),
          ),
        ],
      ),
    );
  }
}

class _WaitingJob extends StatelessWidget {
  const _WaitingJob({required this.job});
  final QueuedJob job;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        title: Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${job.platform} · ждёт очереди'),
        trailing: IconButton(
          tooltip: 'Убрать',
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => Native.cancel(job.id),
        ),
      );
}

class _FailedJob extends StatelessWidget {
  const _FailedJob({required this.job});
  final QueuedJob job;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = Theme.of(context).textTheme;
    final err = humanize(job.error ?? '');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 4),
        decoration: BoxDecoration(color: p.errFill, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(job.title, style: t.titleSmall?.copyWith(color: p.errInk), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(err.message, style: TextStyle(color: p.errInk, fontSize: 13, height: 18 / 13)),
            Row(
              children: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: p.errInk),
                  onPressed: () => Native.retry(job.id),
                  child: const Text('Повторить'),
                ),
                if (err.updateMayHelp)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: p.errInk),
                    onPressed: () async {
                      try {
                        await AppScope.read(context).updateYtDlp();
                        await Native.retry(job.id);
                      } on GrabError catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    child: const Text('Обновить yt-dlp'),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: 'Убрать',
                  color: p.errInk,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => Native.cancel(job.id),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _EntryAction { share, again, forget, delete }

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.missing, required this.onAgain});
  final HistoryEntry entry;
  final bool missing;
  final VoidCallback onAgain;

  String _what() {
    final photos = entry.files.where((f) => f.collection == 'image').length;
    final audio = entry.files.where((f) => f.collection == 'audio').length;
    final video = entry.files.length - photos - audio;
    if (entry.files.length == 1) return video == 1 ? 'видео' : audio == 1 ? 'звук' : 'фото';
    return [
      if (video > 0) plural(video, 'видео', 'видео', 'видео'),
      if (photos > 0) plural(photos, 'фото', 'фото', 'фото'),
      if (audio > 0) plural(audio, 'трек', 'трека', 'треков'),
    ].join(' + ');
  }

  Future<void> _open(BuildContext context) async {
    if (missing) {
      showInfo(context, 'Файл удалён из Галереи. Можно скачать снова.');
      return;
    }
    if (!await Native.open(entry.files.first) && context.mounted) {
      showInfo(context, 'Нет приложения, которое откроет этот файл');
    }
  }

  Future<void> _act(BuildContext context, _EntryAction a) async {
    switch (a) {
      case _EntryAction.share:
        await Native.share(entry.files);
      case _EntryAction.again:
        onAgain();
      case _EntryAction.forget:
        await Native.deleteEntry(entry.id, files: false);
      case _EntryAction.delete:
        final ok = await confirm(
          context,
          title: 'Удалить с телефона?',
          body: '${entry.title}\n\nФайлы пропадут из Галереи и Музыки.',
          action: 'Удалить',
          destructive: true,
        );
        if (!ok) return;
        final r = await Native.deleteEntry(entry.id, files: true);
        if (r == 'kept' && context.mounted) showInfo(context, 'Часть файлов удалить не вышло — их можно удалить в Галерее');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = Theme.of(context).textTheme;
    final meta = [
      entry.platform,
      _what(),
      if (!missing) fmtBytes(entry.size),
      fmtDate(entry.at),
    ].join(' · ');
    return InkWell(
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Opacity(
              opacity: missing ? 0.4 : 1,
              child: Cover(file: entry.thumb, width: rowThumbWidth(entry.platform, 56), height: 56),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title, style: t.bodyMedium?.copyWith(color: missing ? p.textMuted : null),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(missing ? '$meta · файл удалён' : meta, style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            PopupMenuButton<_EntryAction>(
              tooltip: 'Действия',
              icon: Icon(Icons.more_vert_rounded, color: p.textMuted),
              onSelected: (a) => _act(context, a),
              itemBuilder: (_) => [
                if (!missing) const PopupMenuItem(value: _EntryAction.share, child: Text('Поделиться')),
                const PopupMenuItem(value: _EntryAction.again, child: Text('Скачать снова')),
                const PopupMenuItem(value: _EntryAction.forget, child: Text('Убрать из истории')),
                if (!missing) const PopupMenuItem(value: _EntryAction.delete, child: Text('Удалить с телефона')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

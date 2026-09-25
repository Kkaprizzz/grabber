import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/links.dart';
import '../engine/media.dart';
import '../engine/native.dart';
import '../engine/tiktok_photos.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';

/// What yt-dlp found at a link, and the choice of what to download.
class PickScreen extends StatefulWidget {
  const PickScreen({super.key, required this.url});
  final String url;

  @override
  State<PickScreen> createState() => _PickScreenState();
}

enum _Mode { video, audio }

class _PickScreenState extends State<PickScreen> {
  Media? _media;
  GrabError? _error;
  String? _photosError;
  String? _probeId;
  bool _slow = false;
  Timer? _slowTimer;

  _Mode _mode = _Mode.video;
  VideoOption? _video;
  AudioFormat _audio = AudioFormat.m4a;
  final Set<int> _picked = {};
  bool _music = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    if (_media == null && _error == null && _probeId != null) Native.cancelProbe(_probeId!);
    super.dispose();
  }

  Future<void> _probe({bool update = false}) async {
    final app = AppScope.read(context);
    setState(() {
      _media = null;
      _error = null;
      _photosError = null;
      _slow = false;
    });
    _slowTimer?.cancel();
    _slowTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _slow = true);
    });
    try {
      if (update) await app.updateYtDlp();
      await app.ready();
      var url = widget.url;
      if (siteOf(url) == Site.tiktok) url = await resolveTikTok(url);
      final photo = isTikTokPhoto(url);
      final id = newId();
      _probeId = id;
      final json = await Native.probe(
        photo ? tiktokAsVideo(url) : url,
        id,
        // An Instagram carousel's photos have no formats; keep them instead
        // of failing the whole post. Elsewhere "no formats" is a real error.
        siteOf(url) == Site.instagram ? ['--ignore-no-formats-error'] : const [],
      );
      var m = Media.parse(json, id, fallbackUrl: url);
      if (m.site == Site.tiktok && m.videos.isEmpty) {
        try {
          m = m.withItems(await tiktokPhotos(photo ? url : m.url.replaceFirst('/video/', '/photo/')), slideshow: true);
        } on GrabError catch (e) {
          _photosError = e.message;
          m = m.withItems(const [], slideshow: true);
        }
      }
      if (!mounted) return;
      if (m.videos.isEmpty && !m.hasAudio && m.items.isEmpty) {
        throw GrabError('По ссылке нечего скачать', updateMayHelp: true);
      }
      setState(() {
        _media = m;
        _video = m.videos.firstOrNull;
        _mode = m.videos.isEmpty ? _Mode.audio : _Mode.video;
        _picked
          ..clear()
          ..addAll(List.generate(m.items.length, (i) => i));
      });
    } on GrabError catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      _slowTimer?.cancel();
    }
  }

  bool get _isAudioOnlySlideshow => _media!.slideshow && _media!.items.isEmpty;

  /// Bytes the chosen download will take, and whether that's an estimate.
  (int?, bool) get _size {
    final m = _media!;
    if (m.isCarousel) return (null, false);
    if (_mode == _Mode.audio || _isAudioOnlySlideshow) {
      return _audio == AudioFormat.m4a ? (m.audioSize, false) : (mp3Size(m.duration), true);
    }
    return (_video?.size, _video?.approx ?? false);
  }

  bool get _canStart {
    final m = _media;
    if (m == null || _starting) return false;
    if (m.isCarousel) return _picked.isNotEmpty || (m.slideshow && _music && m.hasAudio);
    return _mode == _Mode.audio || _isAudioOnlySlideshow || _video != null;
  }

  Future<void> _start() async {
    final m = _media!;
    setState(() => _starting = true);
    try {
      if (!await Native.permissions()) {
        if (mounted) showInfo(context, 'Без доступа к памяти Граббер не сможет сохранить файл');
        return;
      }
      final Map<String, Object?> job;
      if (m.isCarousel) {
        final picked = [for (var i = 0; i < m.items.length; i++) if (_picked.contains(i)) m.items[i]];
        job = itemsJob(m, picked, music: m.slideshow && _music && m.hasAudio, audio: _audio);
      } else if (_mode == _Mode.audio || _isAudioOnlySlideshow) {
        job = audioJob(m, _audio);
      } else {
        job = videoJob(m, _video!);
      }
      await Native.enqueue(job);
      if (mounted) Navigator.pop(context);
    } on GrabError catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _media;
    return Scaffold(
      appBar: AppBar(title: Text(m?.site.label ?? siteOf(widget.url).label)),
      body: AnimatedSwitcher(
        duration: motion(context, kFast),
        switchInCurve: kEase,
        child: _error != null
            ? _ErrorView(key: const ValueKey('e'), error: _error!, onRetry: _probe)
            : m == null
                ? _LoadingView(key: const ValueKey('l'), slow: _slow, url: widget.url)
                : _body(context, m),
      ),
      bottomNavigationBar: m == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  onPressed: _canStart ? _start : null,
                  child: Text(_buttonText()),
                ),
              ),
            ),
    );
  }

  String _buttonText() {
    final (size, approx) = _size;
    final s = fmtSize(size, approx: approx);
    return s.isEmpty ? 'Скачать' : 'Скачать · $s';
  }

  Widget _body(BuildContext context, Media m) {
    final p = Palette.of(context);
    final t = Theme.of(context).textTheme;
    final app = AppScope.of(context);
    final key = linkKey(m.url);
    final before = app.history.where((e) => linkKey(e.url) == key).firstOrNull;
    final meta = [m.site.label, ?m.uploader, if (m.duration case final d? when d > 0) fmtDuration(d)].join(' · ');

    return ListView(
      key: const ValueKey('b'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _Preview(url: m.thumb, aspect: m.aspect),
        const SizedBox(height: 16),
        Text(m.title, style: t.titleMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        Text(meta, style: t.bodySmall),
        if (before != null) ...[
          const SizedBox(height: 12),
          Note('Уже скачано ${fmtDate(before.at)} — можно ещё раз', fill: p.warnFill, ink: p.warnInk),
        ],
        if (_photosError != null) ...[
          const SizedBox(height: 12),
          Note('$_photosError. Можно скачать только музыку.', fill: p.errFill, ink: p.errInk),
        ],
        const SizedBox(height: 20),
        if (m.isCarousel)
          ..._carousel(context, m)
        else ...[
          if (m.videos.isNotEmpty && m.hasAudio) ...[
            SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(value: _Mode.video, label: Text('Видео')),
                ButtonSegment(value: _Mode.audio, label: Text('Только звук')),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 12),
          ],
          if (_mode == _Mode.video && m.videos.isNotEmpty)
            for (final o in m.videos) _OptionRow(option: o, selected: o == _video, onTap: () => setState(() => _video = o))
          else
            _audioChoice(context, m),
        ],
      ],
    );
  }

  Widget _audioChoice(BuildContext context, Media m) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<AudioFormat>(
          segments: const [
            ButtonSegment(value: AudioFormat.m4a, label: Text('m4a')),
            ButtonSegment(value: AudioFormat.mp3, label: Text('mp3')),
          ],
          selected: {_audio},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _audio = s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _audio == AudioFormat.m4a
              ? 'Как на сайте, без перекодирования — быстро и без потери качества.'
              : 'Играет где угодно. Перекодирование займёт время.',
          style: t.bodySmall,
        ),
      ],
    );
  }

  List<Widget> _carousel(BuildContext context, Media m) {
    final t = Theme.of(context).textTheme;
    final all = _picked.length == m.items.length;
    return [
      if (m.items.isNotEmpty)
        Row(
          children: [
            Expanded(child: Text('Выбрано ${_picked.length} из ${m.items.length}', style: t.labelMedium)),
            TextButton(
              onPressed: () => setState(() {
                if (all) {
                  _picked.clear();
                } else {
                  _picked.addAll(List.generate(m.items.length, (i) => i));
                }
              }),
              child: Text(all ? 'Снять все' : 'Выбрать все'),
            ),
          ],
        ),
      if (m.items.isNotEmpty)
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 3 / 4,
          children: [
            for (var i = 0; i < m.items.length; i++)
              _ItemTile(
                item: m.items[i],
                selected: _picked.contains(i),
                onTap: () => setState(() => _picked.contains(i) ? _picked.remove(i) : _picked.add(i)),
              ),
          ],
        ),
      if (m.slideshow && m.hasAudio) ...[
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _music,
          onChanged: (v) => setState(() => _music = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Музыка отдельным файлом'),
          subtitle: Text(_audio == AudioFormat.m4a ? 'm4a, в Музыку' : 'mp3, в Музыку'),
        ),
        if (_music) _audioChoice(context, m),
      ],
    ];
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.url, required this.aspect});
  final String? url;
  final double aspect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        // Landscape fills the width; portrait keeps its shape at a fixed height.
        const maxH = 260.0;
        var w = c.maxWidth, h = w / aspect;
        if (h > maxH) {
          h = maxH;
          w = h * aspect;
        }
        return Center(child: Cover(url: url, width: w, height: h, radius: 12));
      });
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.option, required this.selected, required this.onTap});
  final VideoOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? p.surfaceMuted : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 20, color: selected ? p.accentInk : p.textMuted),
                const SizedBox(width: 12),
                Text(option.label, style: mono(context, size: 15, weight: FontWeight.w500)),
                const SizedBox(width: 8),
                Text(option.codec, style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                Text(fmtSize(option.size, approx: option.approx), style: mono(context, size: 13, color: p.textMuted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.selected, required this.onTap});
  final Item item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, c) => Stack(
          fit: StackFit.expand,
          children: [
            AnimatedOpacity(
              opacity: selected ? 1 : 0.45,
              duration: motion(context, kFast),
              curve: kEase,
              child: Cover(url: item.thumb, width: c.maxWidth, height: c.maxHeight),
            ),
            if (item.video)
              Positioned(left: 6, bottom: 6, child: Icon(Icons.play_arrow_rounded, color: p.surface, size: 22)),
            Positioned(
              right: 6,
              top: 6,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: selected ? p.accentInk : p.surface.withValues(alpha: 0.8),
                  shape: BoxShape.circle,
                  border: Border.all(color: selected ? p.accentInk : p.outline, width: 1.5),
                ),
                child: selected ? Icon(Icons.check, size: 14, color: p.surface) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView({super.key, required this.slow, required this.url});
  final bool slow;
  final String url;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final status = !app.engineReady
        ? 'Запускаю движок — первый раз это до полуминуты'
        : app.updatingYtDlp
            ? 'Обновляю yt-dlp'
            : 'Разбираю ссылку';
    final portrait = siteOf(url) != Site.youtube;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Skeleton(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, c) => Center(
                  child: portrait
                      ? const Bone(width: 146, height: 260, radius: 12)
                      : Bone(width: c.maxWidth, height: c.maxWidth * 9 / 16, radius: 12),
                ),
              ),
              const SizedBox(height: 16),
              const Bone(width: 260, height: 16),
              const SizedBox(height: 8),
              const Bone(width: 180, height: 12),
              const SizedBox(height: 28),
              for (final w in const [120.0, 96.0, 110.0]) ...[
                Row(children: [Bone(width: w, height: 16), const Spacer(), const Bone(width: 56, height: 14)]),
                const SizedBox(height: 22),
              ],
            ],
          ),
        ),
        Text(status, style: t.bodyMedium),
        if (slow && app.engineReady && siteOf(url) == Site.youtube)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('YouTube прячет ссылки за JS-задачкой, на этом телефоне она решается до полуминуты.',
                style: t.bodySmall),
          ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({super.key, required this.error, required this.onRetry});
  final GrabError error;
  final Future<void> Function({bool update}) onRetry;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Note(error.message, fill: p.errFill, ink: p.errInk),
        if (error.raw != null && error.raw != error.message) ...[
          const SizedBox(height: 8),
          Text(error.raw!.trim(), style: mono(context, size: 12, color: p.textMuted), maxLines: 6, overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: OutlinedButton(onPressed: onRetry, child: const Text('Повторить'))),
            if (error.updateMayHelp) ...[
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: FilledButton(onPressed: () => onRetry(update: true), child: const Text('Обновить yt-dlp и повторить')),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

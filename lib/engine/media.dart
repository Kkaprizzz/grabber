import 'dart:convert';
import 'dart:math';

import 'links.dart';

/// One quality to offer: a yt-dlp format spec plus what the user sees.
class VideoOption {
  VideoOption({
    required this.label,
    required this.codec,
    required this.size,
    required this.approx,
    required this.spec,
    required this.streams,
  });

  /// "1080p", "720p60".
  final String label;

  /// "H.264", "VP9"…, shown small next to the label.
  final String codec;

  /// Bytes, or null when yt-dlp didn't say.
  final int? size;
  final bool approx;

  /// Format ids from the probe, with a fallback in case they vanished by
  /// the time the queue gets to it and the link is extracted again.
  final String spec;

  /// 2 when video and audio come separately and get merged.
  final int streams;
}

/// One picture or clip in a carousel (Instagram post, TikTok photos).
class Item {
  Item.image({required this.thumb, required this.url, required this.ext})
      : video = false,
        index = 0,
        streams = 1;
  Item.video({required this.thumb, required this.index, required this.streams})
      : video = true,
        url = null,
        ext = 'mp4';

  final bool video;
  final String? thumb;

  /// Direct image URL (photos are fetched over plain HTTP).
  final String? url;
  final String ext;

  /// yt-dlp's --playlist-items number for a clip.
  final int index;
  final int streams;
}

/// What a link turned out to be, from yt-dlp's JSON.
class Media {
  Media._({
    required this.probeId,
    required this.site,
    required this.url,
    required this.title,
    required this.uploader,
    required this.duration,
    required this.thumb,
    required this.aspect,
    required this.videos,
    required this.hasAudio,
    required this.audioSize,
    required this.items,
    required this.slideshow,
  });

  final String probeId;
  final Site site;

  /// The canonical page URL (yt-dlp's webpage_url): history and "already
  /// downloaded" go by it.
  final String url;
  final String title;
  final String? uploader;
  final int? duration;
  final String? thumb;

  /// width / height of the picture, for a preview shaped like the source.
  final double aspect;

  /// Best first. Empty for photo posts.
  final List<VideoOption> videos;

  final bool hasAudio;

  /// Size of the m4a (no conversion), if known.
  final int? audioSize;

  /// Carousel content; empty for a single video.
  final List<Item> items;

  /// TikTok photos with music: the pictures come from [items], the music is
  /// the audio option.
  final bool slideshow;

  bool get isCarousel => items.isNotEmpty;

  Media withItems(List<Item> items, {bool? slideshow}) => Media._(
        probeId: probeId,
        site: site,
        url: url,
        title: title,
        uploader: uploader,
        duration: duration,
        thumb: thumb,
        aspect: aspect,
        videos: videos,
        hasAudio: hasAudio,
        audioSize: audioSize,
        items: items,
        slideshow: slideshow ?? this.slideshow,
      );

  static Media parse(String json, String probeId, {required String fallbackUrl}) {
    final d = jsonDecode(json) as Map<String, dynamic>;
    final url = (d['webpage_url'] as String?) ?? fallbackUrl;
    final site = _siteOf(d, url);
    final entries = (d['entries'] as List?)?.cast<Map<String, dynamic>>();
    final formats = _usable(d['formats'] as List?, site);

    final items = <Item>[];
    if (entries != null) {
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        final ef = _usable(e['formats'] as List?, site);
        final index = (e['playlist_index'] as num?)?.toInt() ?? i + 1;
        if (ef.any(_hasVideo)) {
          final best = _bestVideo(ef);
          items.add(Item.video(
            thumb: e['thumbnail'] as String? ?? _bestThumb(e),
            index: index,
            streams: best != null && !_hasAudio(best) ? 2 : 1,
          ));
        } else if (_bestThumb(e) case final img?) {
          items.add(Item.image(thumb: img, url: img, ext: _imageExt(img)));
        }
      }
    } else if (formats.isEmpty && site == Site.instagram) {
      // A single-photo post: no formats, the picture is the thumbnail.
      if (_bestThumb(d) case final img?) items.add(Item.image(thumb: img, url: img, ext: _imageExt(img)));
    }

    final audioOnly = formats.where((f) => !_hasVideo(f) && _hasAudio(f)).toList();
    final m4a = _bestAudio(audioOnly.where(_isM4a).toList());
    final first = entries?.isNotEmpty ?? false ? entries!.first : d;

    return Media._(
      probeId: probeId,
      site: site,
      url: url,
      title: _title(d, site),
      uploader: (d['uploader'] ?? d['channel'] ?? d['uploader_id']) as String?,
      duration: (d['duration'] as num?)?.round(),
      thumb: (d['thumbnail'] as String?) ?? (first['thumbnail'] as String?) ?? _bestThumb(d),
      aspect: _aspect(d, formats, site),
      videos: _videoOptions(formats, audioOnly),
      hasAudio: formats.any(_hasAudio),
      audioSize: m4a == null ? null : _size(m4a).$1,
      items: items,
      slideshow: false,
    );
  }

  static Site _siteOf(Map<String, dynamic> d, String url) => switch ((d['extractor_key'] as String? ?? '').toLowerCase()) {
        'youtube' => Site.youtube,
        'tiktok' || 'vm.tiktok' => Site.tiktok,
        'instagram' || 'instagramios' => Site.instagram,
        _ => siteOf(url),
      };

  /// TikTok and Instagram "titles" are generated ("Video by …"); the
  /// caption's first line says more.
  static String _title(Map<String, dynamic> d, Site site) {
    final title = (d['title'] as String? ?? '').trim();
    if (site == Site.youtube) return title.isEmpty ? 'Без названия' : title;
    final desc = (d['description'] as String? ?? '').trim().split('\n').first.trim();
    final s = desc.isNotEmpty ? desc : title;
    if (s.isEmpty) return 'Без названия';
    return s.length > 90 ? '${s.substring(0, 88).trimRight()}…' : s;
  }

  static double _aspect(Map<String, dynamic> d, List<Map<String, dynamic>> formats, Site site) {
    final w = (d['width'] as num?) ?? formats.lastWhere(_hasVideo, orElse: () => const {})['width'] as num?;
    final h = (d['height'] as num?) ?? formats.lastWhere(_hasVideo, orElse: () => const {})['height'] as num?;
    if (w != null && h != null && w > 0 && h > 0) return w / h;
    return site == Site.youtube ? 16 / 9 : 9 / 16;
  }
}

// --- formats ---------------------------------------------------------------

List<Map<String, dynamic>> _usable(List? raw, Site site) {
  final all = (raw ?? const []).cast<Map<String, dynamic>>().where((f) {
    final id = f['format_id'] as String? ?? '';
    final note = (f['format_note'] as String? ?? '').toLowerCase();
    return f['protocol'] != 'mhtml' && // storyboards
        !note.contains('storyboard') &&
        f['has_drm'] != true &&
        !id.endsWith('-drc'); // YouTube's "dynamic range compressed" duplicate audio
  }).toList();
  // TikTok also offers the watermarked download; never pick it if there's another.
  final clean = all.where((f) => !(f['format_note'] as String? ?? '').toLowerCase().contains('watermark')).toList();
  return clean.any(_hasVideo) ? clean : all;
}

bool _hasVideo(Map<String, dynamic> f) {
  final v = f['vcodec'] as String?;
  if (v == 'none') return false;
  return v != null || f['height'] != null || f['width'] != null;
}

bool _hasAudio(Map<String, dynamic> f) => f['acodec'] != 'none';

bool _isM4a(Map<String, dynamic> f) =>
    f['ext'] == 'm4a' || (f['acodec'] as String? ?? '').startsWith('mp4a');

/// (bytes, approximate?) — null bytes when unknown.
(int?, bool) _size(Map<String, dynamic> f) {
  final exact = (f['filesize'] as num?)?.toInt();
  if (exact != null) return (exact, false);
  final approx = (f['filesize_approx'] as num?)?.toInt();
  return (approx, true);
}

String _codec(Map<String, dynamic> f) {
  final v = (f['vcodec'] as String? ?? '').toLowerCase();
  if (v.startsWith('avc') || v.startsWith('h264')) return 'H.264';
  if (v.startsWith('vp09') || v.startsWith('vp9')) return 'VP9';
  if (v.startsWith('av01')) return 'AV1';
  if (v.startsWith('hev') || v.startsWith('hvc') || v.startsWith('h265') || v.startsWith('bytevc1')) return 'H.265';
  return '';
}

/// How well a codec plays in a phone's gallery. AV1 doesn't at all on
/// older phones (the Galaxy S8 has no decoder), so it's never picked.
int _codecRank(Map<String, dynamic> f) => switch (_codec(f)) {
      'H.264' => 3,
      'VP9' => 2,
      'AV1' => -1,
      _ => 1,
    };

double _tbr(Map<String, dynamic> f) => (f['tbr'] as num? ?? f['vbr'] as num? ?? 0).toDouble();

Map<String, dynamic>? _bestVideo(List<Map<String, dynamic>> fs) {
  final v = fs.where((f) => _hasVideo(f) && _codecRank(f) >= 0).toList();
  if (v.isEmpty) return null;
  v.sort((a, b) {
    final h = ((b['height'] as num?) ?? 0).compareTo((a['height'] as num?) ?? 0);
    if (h != 0) return h;
    final c = _codecRank(b).compareTo(_codecRank(a));
    return c != 0 ? c : _tbr(b).compareTo(_tbr(a));
  });
  return v.first;
}

/// The track the user would hear: the original language first (YouTube
/// adds dubbed tracks), then bitrate.
Map<String, dynamic>? _bestAudio(List<Map<String, dynamic>> fs) {
  if (fs.isEmpty) return null;
  final sorted = [...fs]..sort((a, b) {
      final l = ((b['language_preference'] as num?) ?? 0).compareTo((a['language_preference'] as num?) ?? 0);
      if (l != 0) return l;
      final ab = (b['abr'] as num? ?? b['tbr'] as num? ?? 0).toDouble();
      final aa = (a['abr'] as num? ?? a['tbr'] as num? ?? 0).toDouble();
      return ab.compareTo(aa);
    });
  return sorted.first;
}

List<VideoOption> _videoOptions(List<Map<String, dynamic>> formats, List<Map<String, dynamic>> audioOnly) {
  // Group by the short side, so a vertical 576×1024 TikTok is "576p" like
  // on the site, and a horizontal 1920×1080 is "1080p".
  final groups = <String, List<Map<String, dynamic>>>{};
  final order = <String, int>{};
  for (final f in formats.where((f) => _hasVideo(f) && _codecRank(f) >= 0)) {
    final w = (f['width'] as num?)?.toInt(), h = (f['height'] as num?)?.toInt();
    final short = w != null && h != null ? min(w, h) : h ?? w;
    if (short == null) continue;
    final fps = (f['fps'] as num?)?.round() ?? 0;
    final label = '${short}p${fps >= 50 ? fps : ''}';
    (groups[label] ??= []).add(f);
    order[label] = short * 1000 + fps;
  }

  final m4a = _bestAudio(audioOnly.where(_isM4a).toList());
  final webm = _bestAudio(audioOnly.where((f) => !_isM4a(f)).toList());
  final anyAudio = _bestAudio(audioOnly);

  final options = <VideoOption>[];
  final labels = order.keys.toList()..sort((a, b) => order[b]!.compareTo(order[a]!));
  for (final label in labels) {
    final g = groups[label]!
      ..sort((a, b) {
        final c = _codecRank(b).compareTo(_codecRank(a));
        return c != 0 ? c : _tbr(b).compareTo(_tbr(a));
      });
    final v = g.first;
    final height = (v['height'] as num?)?.toInt();
    // Video and audio are merged into whatever container fits both without
    // re-encoding: H.264 + AAC → mp4, VP9 + Opus → webm.
    final a = _hasAudio(v) ? null : (v['ext'] == 'mp4' ? (m4a ?? anyAudio) : (webm ?? anyAudio));
    if (!_hasAudio(v) && a == null && audioOnly.isNotEmpty) continue;

    final (vs, va) = _size(v);
    final (asz, aa) = a == null ? (0, false) : _size(a);
    final size = vs == null || asz == null ? null : vs + asz;

    final exact = a == null ? '${v['format_id']}' : '${v['format_id']}+${a['format_id']}';
    final cap = height == null ? '' : '[height<=$height]';
    options.add(VideoOption(
      label: label,
      codec: _codec(v),
      size: size,
      approx: va || aa,
      spec: '$exact/bv*$cap[vcodec!^=av01]+ba/b$cap/b',
      streams: a == null ? 1 : 2,
    ));
  }
  return options;
}

String? _bestThumb(Map<String, dynamic> d) {
  final t = (d['thumbnails'] as List?)?.cast<Map<String, dynamic>>();
  if (t == null || t.isEmpty) return d['thumbnail'] as String?;
  Map<String, dynamic>? best;
  var area = -1;
  for (final x in t) {
    final a = ((x['width'] as num?) ?? 0).toInt() * ((x['height'] as num?) ?? 0).toInt();
    if (a >= area) {
      area = a;
      best = x;
    }
  }
  return best?['url'] as String?;
}

String _imageExt(String url) {
  final p = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  for (final e in ['.jpg', '.jpeg', '.png', '.webp', '.heic']) {
    if (p.endsWith(e)) return e.substring(1);
  }
  return 'jpg';
}

// --- the job for the native queue --------------------------------------------

enum AudioFormat { m4a, mp3 }

/// Estimated mp3 size: yt-dlp's --audio-quality 0 is VBR around 245 kbit/s.
int? mp3Size(int? duration) => duration == null ? null : duration * 245000 ~/ 8;

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 20).toRadixString(36)}';

Map<String, Object?> _step({
  required String kind,
  required String url,
  List<String> args = const [],
  Map<String, String> headers = const {},
  String? name,
  required String collection,
  int streams = 1,
  String? info,
}) =>
    {
      'kind': kind,
      'url': url,
      'args': args,
      'headers': headers,
      'name': name,
      'collection': collection,
      'streams': streams,
      'info': info,
    };

List<String> _audioArgs(AudioFormat f) => [
      '-f', f == AudioFormat.m4a ? 'ba[ext=m4a]/ba/b' : 'ba/b', //
      '-x', '--audio-format', f.name,
      if (f == AudioFormat.mp3) ...['--audio-quality', '0'],
      '--embed-metadata', '--embed-thumbnail', '--convert-thumbnails', 'jpg',
    ];

Map<String, Object?> _job(Media m, List<Map<String, Object?>> steps) => {
      'id': newId(),
      'url': m.url,
      'title': m.title,
      'platform': m.site.label,
      'thumb': m.thumb,
      'steps': steps,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };

Map<String, Object?> videoJob(Media m, VideoOption o) => _job(m, [
      _step(
        kind: 'ytdlp',
        url: m.url,
        args: ['-f', o.spec, '--merge-output-format', 'mp4/webm/mkv'],
        collection: 'video',
        streams: o.streams,
        info: m.probeId,
      ),
    ]);

Map<String, Object?> audioJob(Media m, AudioFormat f) => _job(m, [
      _step(kind: 'ytdlp', url: m.url, args: _audioArgs(f), collection: 'audio', info: m.probeId),
    ]);

/// Picked carousel items, plus the music of TikTok photos if [music].
Map<String, Object?> itemsJob(Media m, List<Item> picked, {bool music = false, AudioFormat audio = AudioFormat.m4a}) {
  final referer = switch (m.site) {
    Site.instagram => 'https://www.instagram.com/',
    Site.tiktok => 'https://www.tiktok.com/',
    _ => m.url,
  };
  final base = linkKey(m.url).replaceAll(RegExp(r'[^\w]'), '_');
  var n = 0;
  return _job(m, [
    for (final it in picked)
      if (it.video)
        _step(
          kind: 'ytdlp',
          url: m.url,
          args: ['--playlist-items', '${it.index}', '-f', 'bv*[vcodec!^=av01]+ba/b', '--merge-output-format', 'mp4/webm/mkv'],
          collection: 'video',
          streams: it.streams,
          info: m.probeId,
        )
      else
        _step(
          kind: 'http',
          url: it.url!,
          headers: {'Referer': referer},
          name: '${base}_${(++n).toString().padLeft(2, '0')}.${it.ext}',
          collection: 'image',
        ),
    if (music) _step(kind: 'ytdlp', url: m.url, args: _audioArgs(audio), collection: 'audio', info: m.probeId),
  ]);
}

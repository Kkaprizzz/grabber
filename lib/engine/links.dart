import 'dart:io';

enum Site {
  youtube('YouTube'),
  tiktok('TikTok'),
  instagram('Instagram'),
  other('Сайт');

  const Site(this.label);
  final String label;
}

final _urlRe = RegExp(r'''https?://[^\s<>"'«»]+''');

/// The link inside shared text. Apps share "Look at this! https://…" or a
/// title plus the link; a supported site wins over any other URL.
String? extractUrl(String text) {
  final all = _urlRe
      .allMatches(text)
      .map((m) => m.group(0)!.replaceFirst(RegExp(r'[).,!?:;]+$'), ''))
      .where((u) => Uri.tryParse(u)?.host.isNotEmpty ?? false)
      .toList();
  if (all.isEmpty) return null;
  return all.firstWhere((u) => siteOf(u) != Site.other, orElse: () => all.first);
}

/// "vk.com" for https://m.vk.com/… — a readable name for an unknown site.
String hostOf(String url) {
  final h = _host(url);
  return h.startsWith('m.') ? h.substring(2) : h;
}

String _host(String url) {
  final h = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return h.startsWith('www.') ? h.substring(4) : h;
}

Site siteOf(String url) {
  final h = _host(url);
  bool on(String d) => h == d || h.endsWith('.$d');
  if (on('youtube.com') || h == 'youtu.be' || on('youtube-nocookie.com')) return Site.youtube;
  if (on('tiktok.com')) return Site.tiktok;
  if (on('instagram.com') || h == 'instagr.am') return Site.instagram;
  return Site.other;
}

/// Sites worth offering from the clipboard. Anything yt-dlp knows works
/// through sharing or the input field; the banner stays for sites people
/// actually copy video links from, so it doesn't pop up for every article.
const _popular = [
  'vk.com', 'vk.ru', 'vkvideo.ru', 'rutube.ru', 'dzen.ru', 'twitter.com', 'x.com', 'reddit.com', 'redd.it',
  'twitch.tv', 'vimeo.com', 'pinterest.com', 'pin.it', 'ok.ru', 'facebook.com', 'fb.watch', 'soundcloud.com',
];

bool worthOffering(String url) {
  if (siteOf(url) != Site.other) return true;
  final h = _host(url);
  return _popular.any((d) => h == d || h.endsWith('.$d'));
}

/// What a link points at, without tracking parameters — to notice that
/// something was already downloaded.
String linkKey(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return url;
  final seg = u.pathSegments.where((s) => s.isNotEmpty).toList();
  switch (siteOf(url)) {
    case Site.youtube:
      final v = u.queryParameters['v'];
      if (v != null) return 'yt:$v';
      if (_host(url) == 'youtu.be' && seg.isNotEmpty) return 'yt:${seg[0]}';
      final i = seg.indexWhere((s) => s == 'shorts' || s == 'live' || s == 'embed');
      if (i >= 0 && i + 1 < seg.length) return 'yt:${seg[i + 1]}';
    case Site.tiktok:
      final i = seg.indexWhere((s) => s == 'video' || s == 'photo');
      if (i >= 0 && i + 1 < seg.length) return 'tt:${seg[i + 1]}';
    case Site.instagram:
      final i = seg.indexWhere((s) => s == 'p' || s == 'reel' || s == 'reels' || s == 'tv');
      if (i >= 0 && i + 1 < seg.length) return 'ig:${seg[i + 1]}';
    case Site.other:
      break;
  }
  return '${u.host}${u.path}';
}

/// TikTok's short links (vm.tiktok.com, /t/…) and photo posts need to be
/// seen as their full URL: yt-dlp doesn't know /photo/ links at all.
Future<String> resolveTikTok(String url) async {
  final u = Uri.parse(url);
  final isShort = u.host.startsWith('vm.') || u.host.startsWith('vt.') || u.path.startsWith('/t/');
  if (!isShort) return url;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    var current = u;
    for (var hop = 0; hop < 5; hop++) {
      final req = await client.headUrl(current);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, 'facebookexternalhit/1.1');
      final res = await req.close();
      await res.drain<void>();
      final loc = res.headers.value(HttpHeaders.locationHeader);
      if (!res.isRedirect || loc == null) break;
      current = current.resolve(loc);
    }
    return current.replace(query: '').toString().replaceFirst(RegExp(r'\?$'), '');
  } on Exception {
    return url; // yt-dlp will have its own go at the redirect
  } finally {
    client.close(force: true);
  }
}

/// A TikTok photo post (slideshow) under /photo/.
bool isTikTokPhoto(String url) => siteOf(url) == Site.tiktok && Uri.parse(url).pathSegments.contains('photo');

/// yt-dlp knows the same post under /video/: that gives metadata and music.
String tiktokAsVideo(String url) => url.replaceFirst('/photo/', '/video/');

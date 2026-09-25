import 'dart:convert';
import 'dart:io';

import 'media.dart';
import 'native.dart';

/// yt-dlp gets a TikTok photo post's music but not its pictures, so those
/// come from the post's page: TikTok embeds the post as JSON in
/// `__UNIVERSAL_DATA_FOR_REHYDRATION__`, under imagePost.images.
Future<List<Item>> tiktokPhotos(String url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    final res = await req.close();
    if (res.statusCode != 200) throw GrabError('TikTok не отдал страницу с фото (${res.statusCode})');
    final html = await res.transform(utf8.decoder).join();
    final m = RegExp(r'<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>', dotAll: true)
        .firstMatch(html);
    if (m == null) throw GrabError('TikTok не отдал фото: страница поменялась');
    final scope = (jsonDecode(m.group(1)!) as Map<String, dynamic>)['__DEFAULT_SCOPE__'] as Map<String, dynamic>?;
    final detail = scope?['webapp.video-detail'] as Map<String, dynamic>?;
    final item = (detail?['itemInfo'] as Map<String, dynamic>?)?['itemStruct'] as Map<String, dynamic>?;
    final images = ((item?['imagePost'] as Map<String, dynamic>?)?['images'] as List?)?.cast<Map<String, dynamic>>();
    if (images == null || images.isEmpty) {
      throw GrabError('TikTok не отдал фото этого поста');
    }
    return [
      for (final img in images)
        if (_pick(img) case final u?) Item.image(thumb: u, url: u, ext: u.contains('.webp') ? 'webp' : 'jpg'),
    ];
  } on GrabError {
    rethrow;
  } on Exception catch (e) {
    throw GrabError('Не получилось загрузить фото из TikTok', raw: '$e');
  } finally {
    client.close(force: true);
  }
}

/// Each picture has several mirrors; a JPEG one opens everywhere.
String? _pick(Map<String, dynamic> img) {
  final urls = ((img['imageURL'] as Map<String, dynamic>?)?['urlList'] as List?)?.cast<String>() ?? const [];
  if (urls.isEmpty) return null;
  return urls.firstWhere((u) => u.contains('jpeg') || u.contains('.jpg'), orElse: () => urls.first);
}

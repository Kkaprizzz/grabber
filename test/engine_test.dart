import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grabber/engine/links.dart';
import 'package:grabber/engine/media.dart';
import 'package:grabber/engine/native.dart';

void main() {
  group('links', () {
    test('finds the link inside shared text', () {
      expect(extractUrl('Смотри! https://vm.tiktok.com/ZMabc123/ классно'), 'https://vm.tiktok.com/ZMabc123/');
      expect(extractUrl('Title\nhttps://example.com/x https://youtu.be/abc?si=1'), 'https://youtu.be/abc?si=1');
      expect(extractUrl('нет ссылки'), isNull);
    });

    test('link keys ignore tracking junk', () {
      expect(linkKey('https://youtu.be/abc?si=xyz'), 'yt:abc');
      expect(linkKey('https://www.youtube.com/watch?v=abc&list=PL1'), 'yt:abc');
      expect(linkKey('https://youtube.com/shorts/abc'), 'yt:abc');
      expect(linkKey('https://www.tiktok.com/@u/photo/123?lang=en'), 'tt:123');
      expect(linkKey('https://www.instagram.com/reel/Cxyz/?igsh=1'), 'ig:Cxyz');
    });

    test('TikTok photo posts go to yt-dlp as videos', () {
      const url = 'https://www.tiktok.com/@u/photo/123';
      expect(isTikTokPhoto(url), isTrue);
      expect(tiktokAsVideo(url), 'https://www.tiktok.com/@u/video/123');
    });
  });

  group('media', () {
    Map<String, dynamic> f(String id, {String v = 'none', String a = 'none', int? w, int? h, String ext = 'mp4', int? size, String? note}) =>
        {'format_id': id, 'vcodec': v, 'acodec': a, 'width': w, 'height': h, 'ext': ext, 'filesize': size, 'format_note': note, 'tbr': 100};

    test('YouTube: H.264 preferred, AV1 never, merged with m4a', () {
      final json = jsonEncode({
        'extractor_key': 'Youtube',
        'webpage_url': 'https://www.youtube.com/watch?v=x',
        'title': 'T',
        'duration': 60,
        'formats': [
          f('140', a: 'mp4a.40.2', ext: 'm4a', size: 1000),
          f('251', a: 'opus', ext: 'webm', size: 900),
          f('137', v: 'avc1.640028', w: 1920, h: 1080, size: 10000),
          f('248', v: 'vp9', w: 1920, h: 1080, ext: 'webm', size: 8000),
          f('399', v: 'av01.0.08M.08', w: 1920, h: 1080, size: 7000),
          f('313', v: 'vp9', w: 3840, h: 2160, ext: 'webm', size: 50000),
          f('401', v: 'av01.0.12M.08', w: 3840, h: 2160, size: 40000),
          f('sb0', v: 'none', ext: 'mhtml')..['protocol'] = 'mhtml',
        ],
      });
      final m = Media.parse(json, 'p', fallbackUrl: '');
      expect(m.videos.map((o) => o.label), ['2160p', '1080p']);
      expect(m.videos[0].spec, startsWith('313+251/'));
      expect(m.videos[1].spec, startsWith('137+140/'));
      expect(m.videos[1].size, 11000);
      expect(m.videos[1].streams, 2);
      expect(m.audioSize, 1000);
    });

    test('TikTok: skips the watermarked download, labels by the short side', () {
      final json = jsonEncode({
        'extractor_key': 'TikTok',
        'webpage_url': 'https://www.tiktok.com/@u/video/1',
        'title': 'TikTok video #1',
        'description': 'подпись\nвторая строка',
        'formats': [
          f('download', v: 'h264', a: 'aac', w: 576, h: 1024, size: 3000, note: 'watermarked'),
          f('play', v: 'h264', a: 'aac', w: 576, h: 1024, size: 2500),
        ],
      });
      final m = Media.parse(json, 'p', fallbackUrl: '');
      expect(m.title, 'подпись');
      expect(m.videos.single.label, '576p');
      expect(m.videos.single.spec, startsWith('play/'));
      expect(m.videos.single.streams, 1);
      expect(m.aspect, lessThan(1));
    });

    test('Instagram carousel: photos by largest thumbnail, clips by index', () {
      final json = jsonEncode({
        '_type': 'playlist',
        'extractor_key': 'Instagram',
        'webpage_url': 'https://www.instagram.com/p/C1/',
        'title': 'Post by u',
        'entries': [
          {
            'thumbnails': [
              {'url': 'https://cdn/small.jpg', 'width': 320, 'height': 400},
              {'url': 'https://cdn/big.jpg?x=1', 'width': 1080, 'height': 1350},
            ],
          },
          {
            'playlist_index': 2,
            'thumbnail': 'https://cdn/v.jpg',
            'formats': [f('v', v: 'avc1', w: 720, h: 1280), f('a', a: 'mp4a', ext: 'm4a')],
          },
        ],
      });
      final m = Media.parse(json, 'p', fallbackUrl: '');
      expect(m.items.length, 2);
      expect(m.items[0].video, isFalse);
      expect(m.items[0].url, 'https://cdn/big.jpg?x=1');
      expect(m.items[1].video, isTrue);
      expect(m.items[1].index, 2);
      expect(m.items[1].streams, 2);

      final job = itemsJob(m, m.items);
      final steps = (job['steps'] as List).cast<Map<String, Object?>>();
      expect(steps[0]['kind'], 'http');
      expect(steps[0]['collection'], 'image');
      expect(steps[1]['kind'], 'ytdlp');
      expect(steps[1]['args'], containsAllInOrder(['--playlist-items', '2']));
    });

    test('other sites: yt-dlp name as label, title from the title, shape from the video', () {
      final json = jsonEncode({
        'extractor_key': 'VKWallPost',
        'webpage_url': 'https://vk.com/video-1_2',
        'title': 'Заголовок',
        'description': 'описание',
        'formats': [f('hls-720', v: 'avc1', a: 'mp4a', w: 1280, h: 720)..['protocol'] = 'm3u8_native'],
      });
      final m = Media.parse(json, 'p', fallbackUrl: '');
      expect(m.label, 'VK');
      expect(m.title, 'Заголовок');
      expect(m.aspect, closeTo(16 / 9, 0.01));
      expect(m.generic, isFalse);
      expect(videoJob(m, m.videos.single)['platform'], 'VK');
    });

    test('generic page: domain as label, bare file is a video', () {
      final json = jsonEncode({
        'extractor_key': 'Generic',
        'webpage_url': 'https://example.com/page',
        'webpage_url_domain': 'example.com',
        'title': 'page',
        'formats': [{'format_id': '0', 'ext': 'mp4', 'protocol': 'https', 'url': 'https://example.com/v.mp4'}],
      });
      final m = Media.parse(json, 'p', fallbackUrl: '');
      expect(m.label, 'example.com');
      expect(m.generic, isTrue);
      expect(m.videos.single.label, 'Лучшее');
    });

    test('audio-only sites open as audio with square art', () {
      final json = jsonEncode({
        'extractor_key': 'Soundcloud',
        'webpage_url': 'https://soundcloud.com/a/b',
        'title': 'Трек',
        'formats': [f('mp3', a: 'mp3', ext: 'mp3'), f('opus', a: 'opus', ext: 'opus')],
      });
      final m = Media.parse(json, 'p', fallbackUrl: '');
      expect(m.label, 'SoundCloud');
      expect(m.videos, isEmpty);
      expect(m.hasAudio, isTrue);
      expect(m.aspect, 1);
    });

    test('playlists and channels are refused, multi-video posts are a grid', () {
      Map<String, dynamic> clip(int i) => {
            'playlist_index': i,
            'formats': [f('v', v: 'avc1', a: 'mp4a', w: 1280, h: 720)],
          };
      String list(String key, int n, {int? total}) => jsonEncode({
            '_type': 'playlist',
            'extractor_key': key,
            'webpage_url': 'https://site/x',
            'playlist_count': total,
            'entries': [for (var i = 1; i <= n; i++) clip(i)],
          });
      expect(() => Media.parse(list('YoutubeTab', 3), 'p', fallbackUrl: ''), throwsA(isA<GrabError>()));
      expect(() => Media.parse(list('Reddit', 5, total: 120), 'p', fallbackUrl: ''), throwsA(isA<GrabError>()));
      expect(() => Media.parse(list('Reddit', maxItems + 1), 'p', fallbackUrl: ''), throwsA(isA<GrabError>()));
      final post = Media.parse(list('Twitter', 3), 'p', fallbackUrl: '');
      expect(post.items.length, 3);
      expect(post.items.every((i) => i.video), isTrue);
    });
  });
}

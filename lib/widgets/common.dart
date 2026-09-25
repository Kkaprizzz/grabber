import 'dart:io';

import 'package:flutter/material.dart';

import '../engine/native.dart';
import '../theme.dart';

String _num(double v, int digits) => v.toStringAsFixed(digits).replaceAll('.', ',');

String fmtBytes(num bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${_num(v, i < 2 || v >= 100 ? 0 : 1)} ${units[i]}';
}

/// "≈ 38 МБ" for sizes yt-dlp only estimated.
String fmtSize(int? bytes, {bool approx = false}) => bytes == null ? '' : '${approx ? '≈ ' : ''}${fmtBytes(bytes)}';

String _pad2(int v) => v.toString().padLeft(2, '0');

/// 252 → "4:12", 3725 → "1:02:05".
String fmtDuration(int secs) {
  final h = secs ~/ 3600, m = (secs % 3600) ~/ 60, s = secs % 60;
  return h > 0 ? '$h:${_pad2(m)}:${_pad2(s)}' : '$m:${_pad2(s)}';
}

String fmtDate(DateTime t) {
  final l = t.toLocal(), now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(l.year, l.month, l.day);
  final time = '${_pad2(l.hour)}:${_pad2(l.minute)}';
  if (day == today) return 'сегодня $time';
  if (day == today.subtract(const Duration(days: 1))) return 'вчера $time';
  return l.year == now.year ? '${_pad2(l.day)}.${_pad2(l.month)}' : '${_pad2(l.day)}.${_pad2(l.month)}.${l.year}';
}

/// "3 файла", "5 фото" — Russian plural forms.
String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  final w = m10 == 1 && m100 != 11
      ? one
      : m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)
          ? few
          : many;
  return '$n $w';
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? body,
  required String action,
  bool destructive = false,
}) async {
  final p = Palette.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: p.errFill, foregroundColor: p.errInk) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

void showError(BuildContext context, Object error) =>
    showInfo(context, error is GrabError ? error.message : 'Что-то пошло не так: $error');

void showInfo(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// A cover picture: from the network (probe, queue) or a local file
/// (history), decoded at display size — full-size YouTube covers are 1280 px
/// and would eat the Galaxy S8's memory in a list.
class Cover extends StatelessWidget {
  const Cover({super.key, this.url, this.file, required this.width, required this.height, this.radius = 8});

  final String? url;
  final String? file;
  final double width, height, radius;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cw = (width * dpr).round();
    Widget placeholder() => ColoredBox(color: p.surfaceMuted);
    Widget? img;
    if (file != null) {
      img = Image.file(File(file!), fit: BoxFit.cover, cacheWidth: cw, errorBuilder: (_, _, _) => placeholder());
    } else if (url != null) {
      img = Image.network(url!, fit: BoxFit.cover, cacheWidth: cw, errorBuilder: (_, _, _) => placeholder());
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: width, height: height, child: img ?? placeholder()),
    );
  }
}

/// History and queue rows show covers shaped like the source: YouTube is
/// landscape, TikTok and Instagram portrait.
double rowThumbWidth(String platform, double height) => platform == 'YouTube' ? height * 16 / 9 : height * 3 / 4;

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 8, 8),
        child: Row(
          children: [
            Expanded(child: Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Palette.of(context).textMuted))),
            ?trailing,
          ],
        ),
      );
}

/// A tinted note: warn for "already downloaded", error for failures.
class Note extends StatelessWidget {
  const Note(this.text, {super.key, required this.fill, required this.ink, this.action});
  final String text;
  final Color fill, ink;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(14, action == null ? 12 : 4, 4, action == null ? 12 : 4),
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            Expanded(child: Text(text, style: TextStyle(color: ink, fontSize: 14, height: 20 / 14))),
            ?action,
          ],
        ),
      );
}

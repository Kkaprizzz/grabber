import 'package:flutter/material.dart';

import '../engine/native.dart';
import '../state.dart';
import '../theme.dart';
import '../update/updater.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _appVersion;
  bool _checkingApp = false;

  @override
  void initState() {
    super.initState();
    Native.version().then((v) {
      if (mounted) setState(() => _appVersion = v.name);
    });
  }

  Future<void> _updateYtDlp() async {
    final app = AppScope.read(context);
    try {
      final r = await app.updateYtDlp();
      if (!mounted) return;
      showInfo(context, r.status == 'done' ? 'yt-dlp обновлён до ${r.version}' : 'Уже последняя версия');
    } on GrabError catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _checkApp() async {
    final app = AppScope.read(context);
    setState(() => _checkingApp = true);
    try {
      final rel = await checkForUpdate();
      await app.markAppChecked();
      if (!mounted) return;
      if (rel == null) {
        showInfo(context, 'Установлена последняя версия');
      } else {
        await offerUpdate(context, rel);
      }
    } on Object catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _checkingApp = false);
    }
  }

  Future<void> _clearHistory() async {
    final ok = await confirm(
      context,
      title: 'Очистить историю?',
      body: 'Список скачанного пропадёт. Сами файлы останутся в Галерее и Музыке.',
      action: 'Очистить',
    );
    if (ok) await Native.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = Palette.of(context);
    final t = Theme.of(context).textTheme;
    final checked = app.ytdlpCheckedAt;

    Widget busy() => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SectionLabel('Тема'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder(
              valueListenable: app.theme,
              builder: (_, mode, _) => SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('Как в системе')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Светлая')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Тёмная')),
                ],
                selected: {mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => app.setTheme(s.first),
              ),
            ),
          ),
          const SectionLabel('yt-dlp'),
          ListTile(
            title: const Text('Версия'),
            subtitle: Text(checked == null ? 'Ещё не обновлялся' : 'Проверено ${fmtDate(checked)} · сам проверяет раз в сутки'),
            trailing: app.ytdlp == null ? busy() : Text(app.ytdlp!, style: mono(context, size: 13, color: p.textMuted)),
          ),
          ListTile(
            title: const Text('Обновить сейчас'),
            subtitle: const Text('Если сайт что-то поменял и загрузки сломались'),
            trailing: app.updatingYtDlp ? busy() : null,
            onTap: app.updatingYtDlp || !app.engineReady ? null : _updateYtDlp,
          ),
          const SectionLabel('Приложение'),
          ListTile(
            title: const Text('Версия'),
            trailing: Text(_appVersion ?? '', style: mono(context, size: 13, color: p.textMuted)),
          ),
          ListTile(
            title: const Text('Проверить обновления'),
            trailing: _checkingApp ? busy() : null,
            onTap: _checkingApp ? null : _checkApp,
          ),
          const SectionLabel('История'),
          ListTile(
            title: const Text('Очистить историю'),
            subtitle: const Text('Файлы останутся на телефоне'),
            onTap: app.history.isEmpty ? null : _clearHistory,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Text(
              'Видео сохраняются в Movies/Grabber, звук — в Music/Grabber, фото — в Pictures/Grabber.',
              style: t.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

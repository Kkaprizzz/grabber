import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home.dart';
import 'state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await AppState.load();
  runApp(GrabberApp(state: state));
  unawaited(state.start());
}

class GrabberApp extends StatelessWidget {
  GrabberApp({super.key, required this.state});
  final AppState state;
  final _light = buildTheme(Palette.light);
  final _dark = buildTheme(Palette.dark);

  @override
  Widget build(BuildContext context) => AppScope(
        state: state,
        child: ValueListenableBuilder(
          valueListenable: state.theme,
          builder: (context, mode, _) => MaterialApp(
            title: 'Граббер',
            debugShowCheckedModeBanner: false,
            theme: _light,
            darkTheme: _dark,
            themeMode: mode,
            locale: const Locale('ru'),
            supportedLocales: const [Locale('ru')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: const HomeScreen(),
          ),
        ),
      );
}

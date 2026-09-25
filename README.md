# Граббер

Загрузчик видео для Android: TikTok (без водяного знака, видео и фото-слайды), YouTube (видео
и звук, выбор качества), Instagram (рилсы и посты, только публичные). Качает прямо на телефоне —
внутри yt-dlp, Python и ffmpeg ([youtubedl-android](https://github.com/yausername/youtubedl-android)),
никакого сервера.

- Ссылка приходит через «Поделиться», вставкой в поле или из буфера обмена.
- Очередь по одной загрузке, в фоне, с прогрессом в шторке.
- Видео → `Movies/Grabber`, звук → `Music/Grabber`, фото → `Pictures/Grabber`.
- yt-dlp обновляется сам раз в сутки с его GitHub; само приложение — из релизов этого репо.
- Android 8+ (arm64).

## Устройство

- `android/app/src/main/kotlin/…` — движок (`Engine.kt`), очередь и история (`Store.kt`),
  foreground-сервис загрузок (`DownloadService.kt`), сохранение в галерею (`Media.kt`),
  мост к Dart (`MainActivity.kt`).
- `lib/engine/` — разбор ответа yt-dlp в варианты качества (`media.dart`), ссылки
  (`links.dart`), фото из TikTok, которых yt-dlp не достаёт (`tiktok_photos.dart`).
- `lib/screens/` — главный экран, выбор, настройки. Дизайн — в [DESIGN.md](DESIGN.md).

Ссылку YouTube на медленном телефоне yt-dlp разбирает до полуминуты (JS-задачка плеера
решается в QuickJS), поэтому загрузка стартует с уже разобранного JSON (`--load-info-json`).

## Релиз

```sh
git tag -a v1.2.0 -m "Что изменилось" && git push origin v1.2.0
```

CI (`.github/workflows/release.yml`) собирает подписанный APK и выкладывает его с `.sha256`
в GitHub Release; приложение само предлагает обновиться. Ключ подписи — в секретах репо
(`ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`), локально — `android/key.properties`
(не в git).

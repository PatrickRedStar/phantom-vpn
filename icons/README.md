# Phantom VPN — Icon Pack

Два финальных варианта, готовы к продакшену:

- `v4-02-bone/` — **Bone Mascot** (тело цвета кости, лаймовые щёки/блики)
- `v4-03-scope/` — **Scope Mascot** (лаймовый призрак + oscilloscope-сетка)

## Структура пака (одинаково для обоих)

```
<variant>/
├── icon-512.svg                    # мастер-SVG, standalone
├── ic_launcher_foreground.svg      # adaptive icon foreground (108×108dp)
├── ic_launcher_background.svg      # adaptive icon background
├── ic_launcher_monochrome.svg      # themed icon (Android 13+)
│
├── android/                        # готовые Android-ресурсы
│   ├── drawable/                   # adaptive icon Vector Drawables
│   │   ├── ic_launcher_foreground.xml
│   │   ├── ic_launcher_background.xml
│   │   └── ic_launcher_monochrome.xml
│   ├── mipmap-anydpi-v26/          # adaptive icon декларации (API 26+)
│   │   ├── ic_launcher.xml
│   │   └── ic_launcher_round.xml
│   ├── mipmap-mdpi/ic_launcher(_round).png      # 48×48
│   ├── mipmap-hdpi/ic_launcher(_round).png      # 72×72
│   ├── mipmap-xhdpi/ic_launcher(_round).png     # 96×96
│   ├── mipmap-xxhdpi/ic_launcher(_round).png    # 144×144
│   ├── mipmap-xxxhdpi/ic_launcher(_round).png   # 192×192
│   └── play-store-512.png                       # для Google Play
│
├── ios/AppIcon.appiconset/         # для Xcode, с Contents.json
│   ├── icon-20pt@2x-iphone.png     # все 18 нужных размеров iPhone + iPad
│   ├── ...
│   └── Contents.json
│
├── macos/
│   ├── icon.iconset/               # для `iconutil -c icns icon.iconset`
│   │   ├── icon_16x16.png … icon_1024x1024.png
│   │   └── icon_*@2x.png
│   └── AppIcon.appiconset/         # для Xcode mac target
│       └── Contents.json
│
├── windows/
│   ├── icon-{16,24,32,48,64,96,128,256}.png
│   └── icon.ico                    # multi-resolution
│
├── linux/                          # hicolor-theme структура
│   ├── 16x16/phantom-vpn.png
│   ├── 22x22/phantom-vpn.png
│   ├── …
│   ├── 512x512/phantom-vpn.png
│   └── scalable/phantom-vpn.svg
│
└── web/
    ├── favicon.ico                 # 16/32/48 multi-res
    ├── favicon-{16,32,48,96,128,192,256,512}.png
    ├── apple-touch-icon.png        # 180×180
    ├── android-chrome-{192,512}.png
    ├── maskable-{192,512}.png
    └── site.webmanifest
```

## Как использовать

### Android

Скопировать содержимое `android/` в `apps/android/app/src/main/res/`:

```bash
cp -r v4-02-bone/android/* apps/android/app/src/main/res/
```

Файлы `mipmap-anydpi-v26/ic_launcher.xml` подхватятся на Android 8+ (adaptive icon), PNG в `mipmap-*` — fallback для более старых версий.

Для themed icons (Android 13+) система автоматически использует `ic_launcher_monochrome.xml` когда пользователь включает «tinted icons» в настройках.

### iOS

Drag-and-drop `ios/AppIcon.appiconset/` в Xcode → `Assets.xcassets/`.

### macOS

Для создания `.icns`:
```bash
cd v4-02-bone/macos
iconutil -c icns icon.iconset
```

Или drag-and-drop `macos/AppIcon.appiconset/` в Xcode mac target.

### Windows

Использовать `windows/icon.ico` как основную иконку приложения (поддерживает все размеры 16–256).

### Linux

Установить в системную тему:
```bash
for size in 16 22 24 32 48 64 96 128 192 256 512; do
  install -D linux/${size}x${size}/phantom-vpn.png \
    /usr/share/icons/hicolor/${size}x${size}/apps/phantom-vpn.png
done
install -D linux/scalable/phantom-vpn.svg \
  /usr/share/icons/hicolor/scalable/apps/phantom-vpn.svg
gtk-update-icon-cache /usr/share/icons/hicolor
```

### Web / PWA

Содержимое `web/` положить в корень сайта. В `<head>`:
```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
```

## Палитра

| Цвет         | Hex        | Роль                            |
|--------------|-----------:|---------------------------------|
| warm-black   | `#0A0908`  | фон                             |
| phosphor lime| `#C4FF3E`  | акцент (тело / щёки / блики)    |
| bone         | `#E8E2D0`  | тело (v4-02) / блики (v4-03)    |
| orange       | `#FF7A3D`  | румянец (v4-03)                 |
| surface      | `#17150F`  | тень от призрака                |
| grid         | `#2A2619`  | сетка (v4-03)                   |
| lime-dim     | `#4A6010`  | pulse-line (v4-03)              |

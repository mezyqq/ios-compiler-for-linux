[English](README.md) · **Русский**

# ipab — сборка .ipa на Linux

Собирает iOS-приложения из C, C++, Objective-C, Objective-C++ и Swift (включая SwiftUI) без Mac и Xcode.
Готовую `.ipa` ставишь через iloader: он переподписывает её твоим Apple ID.

```sh
./ipab new MyApp swift        # шаблоны: objc | swift | swiftui | c
./ipab build MyApp            # debug → MyApp/build/MyApp.ipa
./ipab build MyApp --release  # -Os / -O -wmo, dead_strip → версия +1, releases/<Имя>-<версия>.ipa (прошлый релиз удаляется)
./ipab clean MyApp
```

## Установка

```sh
git clone https://github.com/mezyqq/ios-compiler-for-linux.git && cd ios-compiler-for-linux
./setup.sh                              # ~4 ГБ: iOS SDK, Swift для Linux, ldid
ln -s "$PWD/ipab" ~/.local/bin/ipab     # по желанию: команда ipab из любой папки
```

Нужны `clang`, `lld`, `make`, `zip`, `curl`, `git`, а для сборки ldid — `libplist` и `openssl`
(Arch: `pacman -S clang lld libplist openssl`). `setup.sh` скачивает SDK из
[xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs), Swift с swift.org, собирает
[ldid](https://github.com/ProcursusTeam/ldid) и применяет к SDK правки из раздела ниже.
Повторный запуск пропускает то, что уже готово.

## Проект

```
MyApp/
  ipa.conf            имя, bundle id, MIN_IOS, фреймворки, флаги (это bash)
  src/                все .c .m .mm .cpp .cc .cxx .swift, рекурсивно
  res/                необязательно: копируется в корень .app как есть (картинки, json, шрифты…)
  Info.plist          необязательно: если есть, используется вместо сгенерированного
  Info.extra.plist    необязательно: дополнительные ключи, вставляются в сгенерированный
```

- **Swift + ObjC в одном проекте.** Если в `BRIDGING_HEADER` указан заголовок, из Swift видно то, что он импортирует. Из ObjC Swift виден через `#import "<Имя>-Swift.h"`.
- **Иконка:** `ICON="res/icon.png"`, квадрат 1024×1024.
- **Дополнительные ресурсы:** `EXTRA_RES="assets data/db"` — эти папки и файлы проекта кладутся в корень `.app` под своими именами (в дополнение к содержимому `res/`).
- **Релизы.** `--release` повышает `VERSION` и `BUILD` в `ipa.conf` после успешной сборки и кладёт `.ipa` в `releases/` этой папки (прошлый релиз проекта удаляется). Свою папку можно задать в `ipa.conf`: `RELEASES="$PROJ/releases"`. Если проект пишет карту символов (`LDFLAGS="-Wl,-map,$PROJ/build/$NAME.map"`), она тоже копируется в релизы — для расшифровки отчётов о вылетах.
- **Скорость.** Работает `make -j` (все ядра) с инкрементальной сборкой, а кэши модулей в `cache/` общие для всех проектов. Первая сборка Swift/SwiftUI на новом SDK долгая, около 40 с, пока строится кэш. Дальше пустая пересборка занимает ~30 мс, правка одного файла ~0.3 с.
  Число потоков задаёт `IPAB_JOBS=2 ipab build`.

## Что внутри

| | |
|---|---|
| `sdks/iPhoneOS26.5.sdk` | iOS SDK (используется новейший из `sdks/`, другой можно выбрать через `IPAB_SDK=...`) |
| `toolchains/swift` | Swift 6.4 для Linux (swift.org) |
| `toolchains/darwin-res` | resource-dir Swift для Darwin: clang-заголовки, shims, apinotes |
| `toolchains/bin/ldid` | ad-hoc подпись |
| `runtime/availability.c` | замена compiler-rt для `#available` / `@available` |
| системный `clang` + `ld64.lld` | компиляция C-семейства и линковка |

## Правки SDK (их делает setup.sh)

- **arm64-интерфейсы Swift.** В SDK 26.5 были только arm64e-версии `.swiftinterface`. Из них сгенерированы arm64-копии.
- **Дамповые `.tbd`.** 28 файлов (в основном `PrivateFrameworks/*.tbd`), сгенерированных дампером (`flat_namespace`), переименованы в `.tbd.dump`. Они перекрывали настоящие стабы Apple внутри `UIKit.tbd` и других, из-за чего lld не находил символы.

## Ограничения

- Нет `actool`/`ibtool`, поэтому `.xcassets`, `.storyboard` и `.xib` не компилируются. Интерфейс делай кодом (UIKit/SwiftUI), иконку — PNG.
- Пути с пробелами не поддерживаются.
- Минимальная iOS по умолчанию 15.0. Ниже можно, но Swift Concurrency и часть API недоступны.


## Смотри также

[ios-compiler](https://github.com/mezyqq/ios-compiler) — clang и lld, работающие на самом iPhone: собирают C / ObjC / C++ приложения в `.ipa` прямо на телефоне (использует SDK, установленный ipab).

## Лицензия

GNU General Public License v3.0 — см. [LICENSE](LICENSE).

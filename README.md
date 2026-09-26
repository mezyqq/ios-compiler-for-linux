**English** · [Русский](README.ru.md)

# ipab — build iOS .ipa on Linux

Builds iOS apps from C, C++, Objective-C, Objective-C++ and Swift (including SwiftUI) without a Mac or Xcode.
Install the resulting `.ipa` with a sideloading tool such as iloader, which re-signs it with your Apple ID.

```sh
./ipab new MyApp swift        # templates: objc | swift | swiftui | c
./ipab build MyApp            # debug → MyApp/build/MyApp.ipa
./ipab build MyApp --release  # -Os / -O -wmo, dead_strip → version +1, releases/<Name>-<version>.ipa (previous release is removed)
./ipab clean MyApp
```

## Installation

```sh
git clone https://github.com/mezyqq/ios-compiler-for-linux.git && cd ios-compiler-for-linux
./setup.sh                              # ~4 GB: iOS SDK, Swift for Linux, ldid
ln -s "$PWD/ipab" ~/.local/bin/ipab     # optional: run ipab from any directory
```

Requires `clang`, `lld`, `make`, `zip`, `curl`, `git`, plus `libplist` and `openssl` to build ldid
(Arch: `pacman -S clang lld libplist openssl`). `setup.sh` downloads the SDK from
[xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs) and Swift from swift.org, builds
[ldid](https://github.com/ProcursusTeam/ldid) and applies the SDK fixes described below.
Re-running it skips whatever is already done.

## Project

```
MyApp/
  ipa.conf            name, bundle id, MIN_IOS, frameworks, flags (it is bash)
  src/                all .c .m .mm .cpp .cc .cxx .swift files, recursively
  res/                optional: copied to the .app root as is (images, json, fonts…)
  Info.plist          optional: used instead of the generated one
  Info.extra.plist    optional: extra keys spliced into the generated one
```

- **Swift + ObjC in one project.** Set `BRIDGING_HEADER` and Swift sees whatever that header imports. ObjC sees Swift through `#import "<Name>-Swift.h"`.
- **Icon:** `ICON="res/icon.png"`, a 1024×1024 square.
- **Extra resources:** `EXTRA_RES="assets data/db"` — these project folders and files are copied to the `.app` root under their own names (in addition to the contents of `res/`).
- **Releases.** `--release` bumps `VERSION` and `BUILD` in `ipa.conf` after a successful build and puts the `.ipa` into `releases/` of the ipab folder (the project's previous release is removed). Set your own folder in `ipa.conf`: `RELEASES="$PROJ/releases"`. If the project writes a symbol map (`LDFLAGS="-Wl,-map,$PROJ/build/$NAME.map"`), it is copied to the releases too, for decoding crash reports.
- **Speed.** `make -j` on all cores with incremental builds; module caches in `cache/` are shared by all projects. The first Swift/SwiftUI build on a new SDK takes about 40 s while the cache is built. After that an empty rebuild takes ~30 ms and editing one file ~0.3 s.
  Set the number of jobs with `IPAB_JOBS=2 ipab build`.

## What's inside

| | |
|---|---|
| `sdks/iPhoneOS26.5.sdk` | iOS SDK (the newest one in `sdks/` is used; pick another with `IPAB_SDK=...`) |
| `toolchains/swift` | Swift 6.4 for Linux (swift.org) |
| `toolchains/darwin-res` | Swift resource-dir for Darwin: clang headers, shims, apinotes |
| `toolchains/bin/ldid` | ad-hoc signing |
| `runtime/availability.c` | compiler-rt replacement for `#available` / `@available` |
| system `clang` + `ld64.lld` | compiling the C family and linking |

## SDK fixes (applied by setup.sh)

- **arm64 Swift interfaces.** SDK 26.5 ships only arm64e `.swiftinterface` files; arm64 copies are generated from them.
- **Dumped `.tbd` files.** 28 files (mostly `PrivateFrameworks/*.tbd`) produced by a dumper (`flat_namespace`) are renamed to `.tbd.dump`. They shadowed Apple's real stubs inside `UIKit.tbd` and others, so lld could not find symbols.

## Limitations

- No `actool`/`ibtool`, so `.xcassets`, `.storyboard` and `.xib` are not compiled. Build the UI in code (UIKit/SwiftUI) and use a PNG icon.
- Paths with spaces are not supported.
- Default minimum iOS is 15.0. Lower works, but Swift Concurrency and some APIs are unavailable.

## See also

[ios-compiler](https://github.com/mezyqq/ios-compiler) — clang and lld running on the iPhone itself: builds C / ObjC / C++ apps into an `.ipa` right on the device (uses the SDK installed by ipab).

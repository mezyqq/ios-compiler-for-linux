#!/usr/bin/env bash
# setup.sh — ставит всё, что нужно ipab: iOS SDK, Swift для Linux, darwin-res, ldid.
# Повторный запуск пропускает готовые шаги. Нужны: clang, lld, make, zip, curl, git,
# для ldid ещё libplist и openssl (Arch: pacman -S clang lld libplist openssl).
set -euo pipefail

H=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SDKVER=${SDKVER:-26.5}
SWIFTVER=${SWIFTVER:-6.4}
SDK=$H/sdks/iPhoneOS$SDKVER.sdk
TC=$H/toolchains
SW=$TC/swift

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mошибка:\033[0m %s\n' "$*" >&2; exit 1; }

for x in clang ld.lld make zip curl git; do command -v $x >/dev/null || die "нет $x"; done
mkdir -p "$H/sdks" "$TC/bin"

# ---------------------------------------------------------------- iOS SDK
if [ ! -d "$SDK" ]; then
	say "iOS SDK $SDKVER (xybp888/iOS-SDKs, только эта папка)"
	T=$(mktemp -d "$H/sdks/.dl.XXXX")
	git clone -q --depth 1 --filter=blob:none --sparse https://github.com/xybp888/iOS-SDKs.git "$T"
	git -C "$T" sparse-checkout set "iPhoneOS$SDKVER.sdk"
	mv "$T/iPhoneOS$SDKVER.sdk" "$SDK"
	rm -rf "$T"
fi

say "правки SDK"
# 1) В SDK только arm64e-интерфейсы Swift: arm64-копия отличается лишь -target в swift-module-flags.
n=0
while IFS= read -r -d '' f; do
	d=$(dirname "$f")
	[ -f "$d/arm64-apple-ios.swiftinterface" ] && continue
	sed '/^\/\/ swift-module-flags:/s/-target arm64e-apple-ios/-target arm64-apple-ios/' "$f" > "$d/arm64-apple-ios.swiftinterface"
	[ -f "$d/arm64e-apple-ios.swiftdoc" ] && [ ! -e "$d/arm64-apple-ios.swiftdoc" ] && ln -s arm64e-apple-ios.swiftdoc "$d/arm64-apple-ios.swiftdoc"
	n=$((n + 1))
done < <(find "$SDK" -name 'arm64e-apple-ios.swiftinterface' -print0)
echo "   arm64-интерфейсов добавлено: $n"
# 2) .tbd, сгенерированные дампером (flat_namespace): перекрывают настоящие стабы внутри UIKit.tbd и др.,
#    и lld не находит символы. Список для SDK 26.5; в других версиях SDK может отличаться.
n=0
for f in \
	System/Library/Frameworks/DriverKit.framework/DriverKit.tbd \
	System/Library/Frameworks/FileProvider.framework/OverrideBundles/FileProviderOverride.bundle/FileProviderOverride.tbd \
	System/Library/Frameworks/FileProvider.framework/OverrideBundles/iCloudDriveFileProviderOverride.bundle/iCloudDriveFileProviderOverride.tbd \
	System/Library/Frameworks/OpenGLES.framework/GLEngine.bundle/GLEngine.tbd \
	System/Library/Frameworks/WatchKit.framework/WatchKit.tbd \
	System/Library/PrivateFrameworks/ARKitCore.framework/ARKitCore.tbd \
	System/Library/PrivateFrameworks/ARKitFoundation.framework/ARKitFoundation.tbd \
	System/Library/PrivateFrameworks/ARKitUI.framework/ARKitUI.tbd \
	System/Library/PrivateFrameworks/AudioToolboxCore.framework/AudioToolboxCore.tbd \
	System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture.tbd \
	System/Library/PrivateFrameworks/AVFCore.framework/AVFCore.tbd \
	System/Library/PrivateFrameworks/CollectionViewCore.framework/CollectionViewCore.tbd \
	System/Library/PrivateFrameworks/DocumentCamera.framework/DocumentCamera.tbd \
	System/Library/PrivateFrameworks/DocumentManager.framework/DocumentManager.tbd \
	System/Library/PrivateFrameworks/GameCenterFoundation.framework/GameCenterFoundation.tbd \
	System/Library/PrivateFrameworks/GameCenterUICore.framework/GameCenterUICore.tbd \
	System/Library/PrivateFrameworks/GameCenterUI.framework/GameCenterUI.tbd \
	System/Library/PrivateFrameworks/ktrace.framework/ktrace.tbd \
	System/Library/PrivateFrameworks/LegacyGameKit.framework/LegacyGameKit.tbd \
	System/Library/PrivateFrameworks/LiveExecutionResultsRuntime.framework/LiveExecutionResultsRuntime.tbd \
	System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore.tbd \
	System/Library/PrivateFrameworks/PassKitUI.framework/PassKitUI.tbd \
	System/Library/PrivateFrameworks/PrintKitUI.framework/PrintKitUI.tbd \
	System/Library/PrivateFrameworks/ShareSheet.framework/ShareSheet.tbd \
	System/Library/PrivateFrameworks/SignpostMetrics.framework/SignpostMetrics.tbd \
	System/Library/PrivateFrameworks/UIFoundation.framework/UIFoundation.tbd \
	System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore.tbd \
	System/Library/SubFrameworks/UIUtilities.framework/UIUtilities.tbd \
	; do
	[ -f "$SDK/$f" ] && mv "$SDK/$f" "$SDK/$f.dump" && n=$((n + 1))
done
echo "   дамповых .tbd убрано: $n"

# ---------------------------------------------------------------- Swift
if [ ! -x "$SW/usr/bin/swiftc" ]; then
	say "Swift $SWIFTVER для Linux (swift.org, сборка под Ubuntu 24.04 — работает и на других дистрибутивах)"
	U=https://download.swift.org/swift-$SWIFTVER-release/ubuntu2404/swift-$SWIFTVER-RELEASE/swift-$SWIFTVER-RELEASE-ubuntu24.04.tar.gz
	mkdir -p "$SW"
	curl -fL --retry 3 "$U" | tar xz -C "$SW" --strip-components=1
fi
# тулчейн слинкован с libncurses.so.6, а во многих дистрибутивах есть только libncursesw.so.6
LDC=$(ldconfig -p 2>/dev/null || true)
if ! grep -q "libncurses\.so\.6 " <<<"$LDC"; then
	L=$(awk "/libncursesw\\.so\\.6 /{print \$NF; exit}" <<<"$LDC")
	[ -n "$L" ] && ln -sfn "$L" "$SW/usr/lib/swift/linux/libncurses.so.6"
fi

# ---------------------------------------------------------------- darwin-res
# resource-dir Swift для Darwin: clang-заголовки и shims из тулчейна + apinotes для os и Dispatch
say "darwin-res"
R=$TC/darwin-res
mkdir -p "$R/apinotes"
ln -sfn ../swift/usr/lib/swift/clang "$R/clang"
ln -sfn ../swift/usr/lib/swift/shims "$R/shims"
cat > "$R/module.modulemap" <<'MM'
extern module SwiftShims "shims/module.modulemap"
extern module _SwiftConcurrencyShims "shims/module.modulemap"
extern module SwiftOverlayShims "shims/module.modulemap"
extern module _SynchronizationShims "shims/module.modulemap"
MM
cp "$SDK/usr/include/os.apinotes" "$R/apinotes/os.apinotes"
[ -s "$R/apinotes/Dispatch.apinotes" ] ||
	curl -fsSL -o "$R/apinotes/Dispatch.apinotes" https://raw.githubusercontent.com/swiftlang/swift/main/apinotes/Dispatch.apinotes

# ---------------------------------------------------------------- ldid
if [ ! -x "$TC/bin/ldid" ]; then
	say "ldid (ProcursusTeam/ldid)"
	[ -d "$TC/ldid-src" ] || git clone -q --depth 1 https://github.com/ProcursusTeam/ldid.git "$TC/ldid-src"
	make -C "$TC/ldid-src" -j"$(nproc)" >/dev/null
	cp "$TC/ldid-src/ldid" "$TC/bin/ldid"
fi

say "готово. Проверка: ./ipab new /tmp/Hello swift && ./ipab build /tmp/Hello"

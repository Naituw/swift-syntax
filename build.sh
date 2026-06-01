#!/bin/zsh
# 预编译 swift-syntax 为通用静态库 XCFramework。
#
# 用法:
#   ./build.sh [版本]
#   ./build.sh 602.0.0
#
# 环境变量:
#   SS_WORKDIR   中间产物目录(可复用已有的 clone/build)，默认 ./.work
#   SS_ARCHS     目标架构，默认 "arm64 x86_64"
#
# 产物: ./SwiftSyntaxPrebuilt.xcframework
#
# 关键点:
#   * 以 release + library evolution 构建，发出文本 .swiftinterface，
#     保证跨编译器版本可加载、可被消费方从接口重新编译。
#   * 仅打包对外可消费模块的接口；strip 调试符号、丢弃 abi.json 以减小体积。
set -euo pipefail

SS_VERSION="${1:-602.0.0}"
SS_REPO="https://github.com/swiftlang/swift-syntax.git"
SCRIPT_DIR="${0:A:h}"
WORK="${SS_WORKDIR:-$SCRIPT_DIR/.work}"
SRC="$WORK/swift-syntax"
BUILD="$WORK/build"
typeset -a ARCHS
ARCHS=(${=SS_ARCHS:-arm64 x86_64})

XC="$SCRIPT_DIR/SwiftSyntaxPrebuilt.xcframework"
SLICE_ID="macos-$(IFS=_; echo "${ARCHS[*]}")"   # e.g. macos-arm64_x86_64
SLICE="$XC/$SLICE_ID"
LIBNAME="libSwiftSyntaxPrebuilt.a"

# 对外可消费的模块（= 各 product 实际 import 的模块名）
typeset -a MODULES
MODULES=(
  SwiftSyntax SwiftParser SwiftParserDiagnostics SwiftBasicFormat SwiftDiagnostics
  SwiftOperators SwiftSyntaxBuilder SwiftSyntaxMacros SwiftSyntaxMacroExpansion
  SwiftCompilerPlugin SwiftCompilerPluginMessageHandling SwiftLibraryPluginProvider
  SwiftIDEUtils SwiftIfConfig SwiftLexicalLookup SwiftRefactor
  SwiftSyntaxMacrosTestSupport SwiftSyntaxMacrosGenericTestSupport
  SwiftWarningControl
)

echo "== swift-syntax $SS_VERSION → XCFramework ($SLICE_ID) =="
mkdir -p "$WORK"

# 1) clone（已存在则复用）
if [ ! -d "$SRC/.git" ]; then
  echo "-- clone $SS_REPO @ $SS_VERSION"
  git clone --depth 1 --branch "$SS_VERSION" "$SS_REPO" "$SRC"
else
  echo "-- reuse existing source: $SRC"
fi

# 2) 逐架构 release + library evolution 构建（已构建则复用）
for ARCH in $ARCHS; do
  REL="$BUILD/${ARCH}-apple-macosx/release"
  if [ -d "$REL" ] && [ -n "$(find "$REL" -name '*.o' -print -quit 2>/dev/null)" ]; then
    echo "-- reuse build for $ARCH"
    continue
  fi
  echo "-- build $ARCH"
  swift build --package-path "$SRC" --scratch-path "$BUILD" \
    -c release --arch "$ARCH" \
    -Xswiftc -emit-module-interface \
    -Xswiftc -enable-library-evolution
done

# 3) 每架构合并所有 .o 为静态库，再 lipo 成通用库，最后 strip 调试符号
rm -rf "$XC"
mkdir -p "$SLICE"
typeset -a ARCH_LIBS
ARCH_LIBS=()
for ARCH in $ARCHS; do
  REL="$BUILD/${ARCH}-apple-macosx/release"
  FL="$WORK/objs_${ARCH}.txt"
  find "$REL" -name '*.o' > "$FL"
  echo "-- $ARCH objects: $(wc -l < "$FL")"
  libtool -static -o "$WORK/lib_${ARCH}.a" -filelist "$FL"
  ARCH_LIBS+="$WORK/lib_${ARCH}.a"
done
lipo -create "${ARCH_LIBS[@]}" -output "$SLICE/$LIBNAME"
strip -S "$SLICE/$LIBNAME" 2>/dev/null || true
echo "-- universal lib: $(du -h "$SLICE/$LIBNAME" | cut -f1)"
lipo -info "$SLICE/$LIBNAME"

# 4) 收集各模块接口（公开/私有/package 接口 + swiftdoc），丢弃体积巨大且消费不需要的 abi.json
for M in $MODULES; do
  MDIR="$SLICE/${M}.swiftmodule"
  mkdir -p "$MDIR"
  for ARCH in $ARCHS; do
    REL="$BUILD/${ARCH}-apple-macosx/release"
    TRIPLE="${ARCH}-apple-macos"
    SRCB="$REL/${M}.build"
    [ -f "$SRCB/${M}.swiftinterface" ]          && cp "$SRCB/${M}.swiftinterface"          "$MDIR/${TRIPLE}.swiftinterface"
    [ -f "$SRCB/${M}.private.swiftinterface" ]  && cp "$SRCB/${M}.private.swiftinterface"  "$MDIR/${TRIPLE}.private.swiftinterface"
    [ -f "$SRCB/${M}.package.swiftinterface" ]  && cp "$SRCB/${M}.package.swiftinterface"  "$MDIR/${TRIPLE}.package.swiftinterface"
    [ -f "$REL/Modules/${M}.swiftdoc" ]         && cp "$REL/Modules/${M}.swiftdoc"         "$MDIR/${TRIPLE}.swiftdoc"
  done
done

# 5) Info.plist
SUPPORTED_ARCHS=""
for ARCH in $ARCHS; do SUPPORTED_ARCHS+="\t\t\t\t<string>${ARCH}</string>\n"; done
cat > "$XC/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>$LIBNAME</string>
			<key>LibraryIdentifier</key>
			<string>$SLICE_ID</string>
			<key>LibraryPath</key>
			<string>$LIBNAME</string>
			<key>SupportedArchitectures</key>
			<array>
$(printf "$SUPPORTED_ARCHS")			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

# 6) 打包 zip 并计算 checksum（用于 binaryTarget(url:checksum:) + GitHub Releases）
ZIP="$SCRIPT_DIR/SwiftSyntaxPrebuilt.xcframework.zip"
rm -f "$ZIP"
( cd "$SCRIPT_DIR" && zip -ry -q "$ZIP" "$(basename "$XC")" )
CHECKSUM="$(swift package compute-checksum "$ZIP")"

echo "== DONE =="
echo "  xcframework : $(du -sh "$XC" | cut -f1)"
echo "  zip         : $(du -h "$ZIP" | cut -f1)  ($ZIP)"
echo "  checksum    : $CHECKSUM"
echo ""
echo "下一步：把 $ZIP 作为 GitHub Release($SS_VERSION) 资产上传，"
echo "并确保 Package.swift 的 binaryTarget url 指向该 tag、checksum 为上面的值。"

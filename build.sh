#!/bin/zsh
# 预编译 swift-syntax 为通用静态库 XCFramework（全自动版）。
#
# 用法:
#   ./build.sh [版本]
#   ./build.sh 603.0.1
#
# 环境变量:
#   SS_WORKDIR        中间产物目录(可复用已有的 clone/build)，默认 ./.work
#   SS_ARCHS          目标架构，默认 "arm64 x86_64"
#   SS_RELEASE_REPO   发布二进制的 GitHub 仓库(owner/name)，默认 Naituw/swift-syntax
#   SS_SKIP_PACKAGE   设为 1 时只做"清单同步/体检"(dump 上游 products 并对比/写回)，
#                     跳过编译与打包，便于不动已发布 zip 的情况下校验流程。
#
# 产物: ./SwiftSyntaxPrebuilt.xcframework + ./SwiftSyntaxPrebuilt.xcframework.zip
#
# 防版本漂移设计（关键）:
#   * 对外暴露的 library product 清单不再手写，而是用 `swift package dump-package`
#     从上游真实 Package.swift 自动推导，并写回本仓库 Package.swift 的
#     AUTO-PRODUCTS 标记区。升级新版本时自动跟随上游增删(如 603 新增 SwiftWarningControl)。
#   * 要打包接口的模块清单不再手写，而是扫描构建产物里实际生成的 *.swiftinterface
#     自动发现，永不漏模块（含内部传递依赖模块）。
#   * 升级后自动把新的 url 版本号 + zip checksum 写回 Package.swift。
#   * 每次运行打印"相比上一版 product 的新增/删除"diff，便于人工复核。
#
# 关键编译点:
#   * release + library evolution，发出文本 .swiftinterface，跨编译器版本可加载。
#   * strip 调试符号、丢弃 abi.json 以减小体积。
set -euo pipefail

SS_VERSION="${1:-603.0.1}"
SS_REPO="https://github.com/swiftlang/swift-syntax.git"
SS_RELEASE_REPO="${SS_RELEASE_REPO:-Naituw/swift-syntax}"
SCRIPT_DIR="${0:A:h}"
MANIFEST="$SCRIPT_DIR/Package.swift"
WORK="${SS_WORKDIR:-$SCRIPT_DIR/.work}"
SRC="$WORK/swift-syntax"
BUILD="$WORK/build"
typeset -a ARCHS
ARCHS=(${=SS_ARCHS:-arm64 x86_64})

XC="$SCRIPT_DIR/SwiftSyntaxPrebuilt.xcframework"
SLICE_ID="macos-$(IFS=_; echo "${ARCHS[*]}")"   # e.g. macos-arm64_x86_64
SLICE="$XC/$SLICE_ID"
LIBNAME="libSwiftSyntaxPrebuilt.a"

echo "== swift-syntax $SS_VERSION → XCFramework ($SLICE_ID) =="
mkdir -p "$WORK"

# 1) clone（已存在则复用）
if [ ! -d "$SRC/.git" ]; then
  echo "-- clone $SS_REPO @ $SS_VERSION"
  git clone --depth 1 --branch "$SS_VERSION" "$SS_REPO" "$SRC"
else
  echo "-- reuse existing source: $SRC"
fi

# 2) 从上游 Package.swift 自动推导 library product 清单（权威，含下划线产品名）
echo "-- derive products from upstream (swift package dump-package)"
NEW_PRODUCTS="$(swift package dump-package --package-path "$SRC" | python3 -c '
import json,sys
d=json.load(sys.stdin)
libs=sorted(p["name"] for p in d["products"] if "library" in p.get("type",{}))
print("\n".join(libs))
')"
echo "$NEW_PRODUCTS" > "$WORK/products.txt"
echo "   upstream library products: $(echo "$NEW_PRODUCTS" | grep -c . )"

# 2b) 与当前 Package.swift 中记录的 product 做 diff（新增/删除一目了然）
OLD_PRODUCTS="$(python3 - "$MANIFEST" <<'PY'
import re,sys
try: src=open(sys.argv[1]).read()
except FileNotFoundError: sys.exit(0)
m=re.search(r'AUTO-PRODUCTS:BEGIN(.*?)AUTO-PRODUCTS:END', src, re.S)
if not m: sys.exit(0)
print("\n".join(sorted(re.findall(r'"([^"]+)"', m.group(1)))))
PY
)"
ADDED="$(comm -13 <(echo "$OLD_PRODUCTS") <(echo "$NEW_PRODUCTS") | grep . || true)"
REMOVED="$(comm -23 <(echo "$OLD_PRODUCTS") <(echo "$NEW_PRODUCTS") | grep . || true)"
[ -n "$ADDED" ]   && { echo "   [+] 新增 product:"; echo "$ADDED"   | sed 's/^/        /'; }
[ -n "$REMOVED" ] && { echo "   [-] 删除 product:"; echo "$REMOVED" | sed 's/^/        /'; }
[ -z "$ADDED$REMOVED" ] && echo "   product 清单与上游一致，无变化"

# 体检模式：只同步 product 清单到 Package.swift，不编译、不动 url/checksum
if [ "${SS_SKIP_PACKAGE:-0}" = "1" ]; then
  python3 - "$MANIFEST" "$WORK/products.txt" <<'PY'
import re,sys
path,plist=sys.argv[1],sys.argv[2]
prods=[l for l in open(plist).read().splitlines() if l.strip()]
block="let productNames: [String] = [\n" + "".join(f'    "{n}",\n' for n in prods) + "]"
src=open(path).read()
new=re.sub(r'(// AUTO-PRODUCTS:BEGIN[^\n]*\n).*?(\n// AUTO-PRODUCTS:END)', lambda m: m.group(1)+block+m.group(2), src, flags=re.S)
open(path,"w").write(new)
print("   Package.swift productNames 已同步（体检模式，未改 url/checksum）")
PY
  echo "== 体检完成（SS_SKIP_PACKAGE=1，未编译/打包）=="
  exit 0
fi

# 3) 逐架构 release + library evolution 构建（已构建则复用）
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

# 4) 每架构合并所有 .o 为静态库，再 lipo 成通用库，最后 strip 调试符号
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

# 5) 自动发现需要打包接口的模块（= 构建产物里实际生成 .swiftinterface 的模块），
#    永不漏模块；丢弃体积巨大且消费不需要的 abi.json。
typeset -a MODULES
MODULES=($(
  for ARCH in $ARCHS; do
    REL="$BUILD/${ARCH}-apple-macosx/release"
    find "$REL" -name '*.swiftinterface' -exec dirname {} \; 2>/dev/null
  done | sed 's#.*/##; s#\.build$##' | sort -u
))
echo "-- modules with interface to bundle: ${#MODULES[@]}"
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

# 6) Info.plist
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

# 7) 打包 zip 并计算 checksum（用于 binaryTarget(url:checksum:) + GitHub Releases）
ZIP="$SCRIPT_DIR/SwiftSyntaxPrebuilt.xcframework.zip"
rm -f "$ZIP"
( cd "$SCRIPT_DIR" && zip -ry -q "$ZIP" "$(basename "$XC")" )
CHECKSUM="$(swift package compute-checksum "$ZIP")"

# 8) 把 product 清单 + url 版本号 + checksum 全部写回 Package.swift（全自动）
python3 - "$MANIFEST" "$WORK/products.txt" "$SS_VERSION" "$CHECKSUM" "$SS_RELEASE_REPO" <<'PY'
import re,sys
path,plist,version,checksum,repo=sys.argv[1:6]
prods=[l for l in open(plist).read().splitlines() if l.strip()]
block="let productNames: [String] = [\n" + "".join(f'    "{n}",\n' for n in prods) + "]"
src=open(path).read()
src=re.sub(r'(// AUTO-PRODUCTS:BEGIN[^\n]*\n).*?(\n// AUTO-PRODUCTS:END)',
          lambda m: m.group(1)+block+m.group(2), src, flags=re.S)
src=re.sub(r'url:\s*"[^"]*"',
          f'url: "https://github.com/{repo}/releases/download/{version}/SwiftSyntaxPrebuilt.xcframework.zip"', src)
src=re.sub(r'checksum:\s*"[0-9a-f]+"', f'checksum: "{checksum}"', src)
open(path,"w").write(src)
print("   Package.swift 已写回：productNames / url / checksum")
PY

echo "== DONE =="
echo "  xcframework : $(du -sh "$XC" | cut -f1)"
echo "  zip         : $(du -h "$ZIP" | cut -f1)  ($ZIP)"
echo "  checksum    : $CHECKSUM"
echo ""
echo "下一步（升级流程）："
echo "  1) git add -A && git commit -m \"swift-syntax $SS_VERSION prebuilt\""
echo "  2) git tag $SS_VERSION && git push origin main $SS_VERSION"
echo "  3) gh release create $SS_VERSION \"$ZIP\" --title \"swift-syntax $SS_VERSION (prebuilt)\""
echo "     （务必上传本次生成的这个 zip，其 checksum 已写入 Package.swift）"

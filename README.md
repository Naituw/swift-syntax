# SwiftSyntaxPrebuilt

把 [`swift-syntax`](https://github.com/swiftlang/swift-syntax) 预编译为**通用静态库 XCFramework** 的 drop-in 二进制包，用于消除消费方在 `archive` / clean 构建时反复从源码编译 `swift-syntax` 的开销。

## 原理

- 以 `release` + **library evolution** 构建 `swift-syntax`，发出文本 `.swiftinterface`，保证跨编译器版本可加载。
- 把所有对外模块的 `.o` 合并为一个通用静态库，连同各模块接口打包成 `SwiftSyntaxPrebuilt.xcframework`。
- `Package.swift` 以 `name: "swift-syntax"` 的身份，声明与官方**完全一致的 product 名**，全部指向该 XCFramework 的 `binaryTarget`。
- 产物以 **GitHub Releases 资产**（zip）分发，`binaryTarget(url:checksum:)` 由 SwiftPM 直接 HTTP 下载并校验，**不依赖 Git-LFS**（SwiftPM 经 remote git 解析二进制包时不会 smudge LFS）。
- 消费方通过 SwiftPM **mirror** 把官方 `swift-syntax.git` 重定向到本仓库，源码与下游 API 调用均无需改动。
- 同一份二进制同时满足「宏插件目标」与「产品代码直接链接」两种用法。

> **重要**：SwiftPM 的包 identity 取自仓库 URL 末段，且 mirror 无法覆盖 identity。
> 因 TCA 等子包内部以 `package: "swift-syntax"` 引用，**本仓库必须命名为 `swift-syntax`**
> （即 `…/swift-syntax.git`，identity=`swift-syntax`），否则全图解析会报
> `unknown package …; valid packages are … 'swift-syntax'`。

## 版本

每个 `swift-syntax` 版本对应一个 git tag（例如 `602.0.0`）+ 一个同名 Release。该 tag 下的 `Package.swift` 里 `binaryTarget` 的 `url` 指向本 tag 的 Release 资产、`checksum` 为对应 zip 的校验和。消费方按版本号解析到对应 tag。

## 在主项目中接入（mirror）

在使用 swift-syntax 的 Xcode 工程 / SwiftPM 包里配置 mirror：

```bash
swift package config set-mirror \
  --original https://github.com/swiftlang/swift-syntax.git \
  --mirror   https://github.com/Naituw/swift-syntax.git
```

Xcode 工程则写入：
`<工程>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json`

```json
{
  "version": 1,
  "object": [
    {
      "original": "https://github.com/swiftlang/swift-syntax.git",
      "mirror": "https://github.com/Naituw/swift-syntax.git"
    }
  ]
}
```

## 重新构建 / 升级版本（全自动，防版本漂移）

```bash
./build.sh 603.0.1          # 编译 + 打包 + 自动同步清单/url/checksum
```

`build.sh` 升级到新版本时会**自动**完成以下事项，无需手工维护清单：

1. **自动推导 product 清单**：用 `swift package dump-package` 读取上游真实的
   `library` product 名（含 `_SwiftCompilerPluginMessageHandling` 这类下划线产品），
   写回 `Package.swift` 的 `AUTO-PRODUCTS:BEGIN/END` 标记区。上游增删 product
   （如 603 新增 `SwiftWarningControl`）会被自动跟随。
2. **自动发现要打包的模块接口**：扫描构建产物里实际生成的 `*.swiftinterface`，
   逐个收集，**永不漏模块**（含内部/版本探针模块）。
3. **自动写回 `url` 版本号 + zip `checksum`** 到 `Package.swift` 的 `binaryTarget`。
4. **打印 product 变更 diff**（相比上一版新增/删除了哪些 product），便于人工复核。

随后只需提交、打 tag、发 Release（脚本结尾会打印对应命令）：

```bash
git add -A && git commit -m "swift-syntax 603.0.1 prebuilt"
git tag 603.0.1 && git push origin main 603.0.1
gh release create 603.0.1 SwiftSyntaxPrebuilt.xcframework.zip \
  --title "swift-syntax 603.0.1 (prebuilt)"
```

> **务必上传 `build.sh` 本次生成的那个 zip**——它的 checksum 已被写进 `Package.swift`。
> 重新打包会因 zip 时间戳变化得到不同 checksum，导致与已发布资产不一致。

### 只体检不打包

不想动已发布产物、只想检查清单是否跟上游漂移时：

```bash
SS_SKIP_PACKAGE=1 ./build.sh 603.0.1   # 仅 dump 上游 products、打印 diff、同步清单，不编译
```

### 相关环境变量

| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `SS_WORKDIR` | clone/build 中间目录（可复用） | `./.work` |
| `SS_ARCHS` | 目标架构 | `arm64 x86_64` |
| `SS_RELEASE_REPO` | 发布二进制的 GitHub 仓库 | `Naituw/swift-syntax` |
| `SS_SKIP_PACKAGE` | =1 时只体检、不编译/打包 | （关） |

> 仅支持 macOS（`arm64` + `x86_64`）。如需其它平台/架构，调整 `SS_ARCHS` 与切片逻辑。

## 注意

- 大产物（xcframework / zip）**不入库**，仅作为 Release 资产分发；仓库只保留脚本与清单。
- 已 strip 调试符号并丢弃 `abi.json`（消费不需要）以减小体积。

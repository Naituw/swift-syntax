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

## 重新构建 / 升级版本

```bash
./build.sh 602.0.0          # 生成 xcframework + zip，并打印 checksum
```

脚本结束会打印 zip 路径与 checksum。随后：

1. 用该 checksum 与目标 tag 更新 `Package.swift` 的 `binaryTarget(url:checksum:)`；
2. 提交并打 tag：`git commit -am "swift-syntax <版本> prebuilt" && git tag <版本>`；
3. 推送：`git push && git push origin <版本>`；
4. 创建同名 GitHub Release 并上传 `SwiftSyntaxPrebuilt.xcframework.zip` 作为资产。

> 仅支持 macOS（`arm64` + `x86_64`）。如需其它平台/架构，调整 `build.sh` 的 `SS_ARCHS` 与切片逻辑。

## 注意

- 大产物（xcframework / zip）**不入库**，仅作为 Release 资产分发；仓库只保留脚本与清单。
- 已 strip 调试符号并丢弃 `abi.json`（消费不需要）以减小体积。

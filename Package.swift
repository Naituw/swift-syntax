// swift-tools-version: 5.10
import PackageDescription

// swift-syntax 的二进制 drop-in 包。
//
// 通过 SwiftPM mirror 把官方 https://github.com/swiftlang/swift-syntax.git
// 重定向到本仓库后，所有官方 product 名保持不变，但全部由同一个预编译
// 静态库 XCFramework(SwiftSyntaxPrebuilt) 提供，从而消费方在 archive/clean
// 构建时不再从源码编译 swift-syntax。
//
// 产物对应的 swift-syntax 版本由 git tag 标记（如 602.0.0）。

// 与官方 swift-syntax 完全一致的 library product 名。
// 下面这段由 build.sh 用 `swift package dump-package` 从上游自动生成，请勿手改。
// AUTO-PRODUCTS:BEGIN
let productNames: [String] = [
    "SwiftBasicFormat",
    "SwiftCompilerPlugin",
    "SwiftDiagnostics",
    "SwiftIDEUtils",
    "SwiftIfConfig",
    "SwiftLexicalLookup",
    "SwiftOperators",
    "SwiftParser",
    "SwiftParserDiagnostics",
    "SwiftRefactor",
    "SwiftSyntax",
    "SwiftSyntaxBuilder",
    "SwiftSyntaxMacroExpansion",
    "SwiftSyntaxMacros",
    "SwiftSyntaxMacrosGenericTestSupport",
    "SwiftSyntaxMacrosTestSupport",
    "SwiftWarningControl",
    "_SwiftCompilerPluginMessageHandling",
    "_SwiftLibraryPluginProvider",
]
// AUTO-PRODUCTS:END

let package = Package(
    name: "swift-syntax",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .macCatalyst(.v13),
    ],
    products: productNames.map { .library(name: $0, targets: ["SwiftSyntaxPrebuilt"]) },
    targets: [
        // 产物通过 GitHub Releases 资产分发（SwiftPM 直接 HTTP 下载并按 checksum 校验），
        // 不依赖 Git-LFS。url 中的版本号需与本 tag 一致；升级版本时由 build.sh 重新生成 checksum。
        .binaryTarget(
            name: "SwiftSyntaxPrebuilt",
            url: "https://github.com/Naituw/swift-syntax/releases/download/603.0.1/SwiftSyntaxPrebuilt.xcframework.zip",
            checksum: "0f38cd7ab04d139bceb2b3b7b36a0c954f0e66295732658a144a825d35998e4f"
        ),
    ]
)

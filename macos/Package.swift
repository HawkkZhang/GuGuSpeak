// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let sherpaHeaderDir = packageRoot
    .appendingPathComponent("ThirdParty/sherpa-onnx/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers")
    .path
let sherpaLibDir = packageRoot
    .appendingPathComponent("ThirdParty/sherpa-onnx/lib")
    .path
let onnxRuntimeHeaderDir = packageRoot
    .appendingPathComponent("ThirdParty/onnxruntime/include")
    .path

let sherpaSwiftSettings: [SwiftSetting] = [
    .unsafeFlags([
        "-import-objc-header",
        "Sources/DesktopVoiceInput/Services/Providers/SherpaOnnx-Bridging-Header.h",
        "-Xcc", "-I\(sherpaHeaderDir)",
    ]),
]

let sherpaLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", sherpaLibDir,
        "-lsherpa-onnx-c-api",
        "-lonnxruntime.1.24.4",
        "-lc++",
        "-Xlinker", "-rpath",
        "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath",
        "-Xlinker", sherpaLibDir,
    ]),
]

let package = Package(
    name: "DesktopVoiceInput",
    platforms: [
        .macOS("15.5"),
    ],
    targets: [
        .target(
            name: "SemanticOnnxBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I\(onnxRuntimeHeaderDir)"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", sherpaLibDir, "-lonnxruntime.1.24.4"]),
            ]
        ),
        .executableTarget(
            name: "DesktopVoiceInput",
            dependencies: ["SemanticOnnxBridge"],
            exclude: ["Assets.xcassets"],
            swiftSettings: sherpaSwiftSettings,
            linkerSettings: sherpaLinkerSettings
        ),
        .testTarget(
            name: "DesktopVoiceInputTests",
            dependencies: ["DesktopVoiceInput", "SemanticOnnxBridge"],
            swiftSettings: sherpaSwiftSettings,
            linkerSettings: sherpaLinkerSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

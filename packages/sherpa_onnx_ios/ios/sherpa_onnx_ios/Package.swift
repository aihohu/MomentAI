// swift-tools-version: 5.9
// Copyright 2026 hohu.org. Licensed under Apache-2.0.
import PackageDescription

let package = Package(
  name: "sherpa_onnx_ios",
  platforms: [.iOS(.v15)],
  products: [.library(name: "sherpa-onnx-ios", targets: ["sherpa_onnx_ios"])],
  targets: [
    .binaryTarget(name: "SherpaOnnxC", path: "SherpaOnnxC.xcframework"),
    .target(name: "sherpa_onnx_ios", dependencies: ["SherpaOnnxC"]),
  ]
)

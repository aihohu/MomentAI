# Third-party notices

MomentAI first-party code and documentation use Apache-2.0. Dependencies and models
retain their own terms. This file is not a blanket license for external assets.

## Dart and Flutter dependencies

[Resolved package inventory](third_party/dart-inventory.json) lists every package
resolved by `pubspec.lock`, including development tools. Original license/notice
texts are retained under `third_party/dart/`. The scoped
[CycloneDX inventory](third_party/dart-sbom.cdx.json) covers Dart packages only;
it is not a complete native or release-artifact SBOM.

Regenerate with `python3 scripts/collect_licenses.py` after dependency resolution.
Review changes to notices along with lockfile changes. Flutter SDK packages use
the SDK's own license when no per-package license file is supplied.

## Native runtime and platform dependencies

Android ARM64 and iOS use a source-built sherpa-onnx runtime with TTS disabled.
The [native input lock](native/runtime-lock.json) pins source archives and the
separate precompiled ONNX Runtime inputs. The
[native notice inventory](third_party/native/runtime/inventory.json) records original
notice hashes. Native dependencies retain their own terms, including Eigen MPL-2.0 and ONNX Runtime's transitive notices.
Original texts are retained under `third_party/native/runtime/` and included in
the offline license viewer. Large runtime binaries and source archives are not
stored in Git; use the native build steps in [README](README.md#build-from-source).

The runtime inventory covers sherpa-onnx, kaldi-native-fbank, kaldi-decoder, kaldifst,
OpenFST, simple-sentencepiece, nlohmann/json, hclust-cpp, KISS FFT, Eigen, ONNX
Runtime, and Android NDK notices. Embedded Darts-clone, ThreadPool, Hedley, and
complete upstream notice sets retain their attribution. Eigen uses
`EIGEN_MPL2_ONLY`; MPL-covered source availability remains a distribution duty.
ONNX Runtime is acquired as a pinned binary, not rebuilt by our runtime script;
retained publisher workflows identify provenance without proving reproducibility.

[Android coordinates and POMs](third_party/native/android-dependencies.json) include
compile/runtime resolution; some entries are compile-only. Corresponding
[artifact hashes and embedded notices](third_party/native/android-artifact-notices.json)
are retained. Flutter bundles its engine/component notices in the app's license
viewer. Apple system frameworks are linked from the OS, not redistributed here.

Run `python scripts/collect_native_notices.py --check` to verify offline bundle
synchronization. Dependency changes require inventory and original-notice review;
retain matching notices and make required covered source available with any binary distribution.

JUnit 4.13.2 (EPL-1.0) and Hamcrest Core 1.3 (BSD-3-Clause) are used only by
Android JVM tests. Their [original notices](third_party/android-test/inventory.json)
are retained separately and are not application runtime dependencies.

## Models and assets

Original model terms and exact source metadata are retained under
[third_party/models](third_party/models), including the
[provenance inventory](third_party/models/provenance.json). No model weights or
upstream sample recordings are committed. The available inputs are:

- Bundled Zipformer 14M: Apache-2.0; pinned model card and weight revision are
  identified in the provenance inventory and [build manifest](models/bundled.json).
- SenseVoice Small: separate [FunASR model agreement](third_party/models/FunASR-MODEL-LICENSE),
  with retained model names and author attribution; not licensed as Apache-2.0.
- Pyannote segmentation 3.0 INT8: retained original and conversion MIT notices,
  both with CNRS attribution.
- 3D-Speaker ERes2Net-Base Chinese 16k: Apache-2.0, with original model identity
  and converted-file integrity metadata.

Model and project notices are available offline in the app's license viewer.

## Logo and application icons

The MomentAI logo and application icons are original project artwork.
Copyright 2026 hohu.org, the MomentAI project owner.

The owner permits copying and redistribution of these assets with MomentAI source
and application distributions, including forks, provided this copyright and
permission notice is retained. This permission does not transfer ownership or
grant trademark rights, and does not imply endorsement of a modified distribution.
It does not grant a separate right to use the logo as another product’s identity.

This permission covers the application icon assets under
`ios/Runner/Assets.xcassets/AppIcon.appiconset/` and the `ic_launcher` assets under
`android/app/src/main/res/`. Third-party Material and Cupertino icons are excluded
and retain their own licenses.

## 中文说明

MomentAI（迹录时刻）的 Logo 与应用图标为项目自有作品，
版权所有 © 2026 hohu.org（MomentAI 项目所有者）。

允许随 MomentAI 源代码及应用发行版（包括分支项目）复制和分发上述图标，
但须保留本版权及授权说明。该授权不转让所有权、不授予商标权，
也不代表对修改后发行版的认可；不单独授权将 Logo 用作其他产品的标识。
Material、Cupertino 等第三方图标不在本授权范围内。

## Development build tools

Gradle wrapper 9.3.1 is a small build bootstrap distributed with this repository;
the full distribution remains a separate download. Matching upstream
[LICENSE](third_party/gradle/LICENSE), [NOTICE](third_party/gradle/NOTICE), and
[provenance/checksums](third_party/gradle/provenance.json) are retained.
The original complete notice set can name components absent from the wrapper JAR.
See the [Gradle wrapper documentation](https://docs.gradle.org/current/userguide/gradle_wrapper.html)
for generation and version-control requirements. The wrapper JAR and scripts are
regenerated using the checksum-pinned distribution; distribution integrity is also
verified by the committed `distributionSha256Sum`.

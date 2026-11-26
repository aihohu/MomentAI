# 从源码构建

[English](BUILDING.md) · [文档目录](README.zh-CN.md)

使用 POSIX shell，克隆后的命令均在仓库根目录执行。iOS 要求 macOS，Windows 开发尚未验证。
先安装以下工具：

| 工具 | 版本 |
| --- | --- |
| Flutter / Dart | Flutter 3.44.8，自带 Dart 3.12.2 |
| Python / Node.js | Python 3.11+、Node.js 22+ |
| Java / Android SDK | JDK 17；Platform 37.0、Build Tools 36.0.0、NDK 28.2.13676358 |
| 原生构建工具 | CMake 3.22.1+、make、支持 HTTPS 的 curl |
| iOS 工具链 | Xcode 27.2（27B52）、iOS 27.2 SDK；swift-format 6.4.4 |

把 Flutter 的 `bin` 加入 PATH，检查 `flutter --version`、`python3 --version`、`node --version`
和 `flutter doctor -v`，解决目标平台的环境问题。Xcode 不自带 CMake，须另行安装或通过
`MOMENTAI_CMAKE` 指定可执行文件。

```sh
git clone https://github.com/aihohu/MomentAI.git
cd MomentAI
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r scripts/requirements-dev.txt
npm ci --ignore-scripts
flutter pub get
flutter gen-l10n
git config core.hooksPath .githooks
python scripts/dev.py check
python scripts/dev.py test
python scripts/prepare_models.py
python scripts/prepare_models.py --verify-only
```

新 shell 需重新激活 `.venv`。共享检查不依赖设备或完整模型。
模型脚本按[固定清单](../models/bundled.json)获取内置模型并校验大小与 SHA-256，
已有文件可通过 `--from-directory /path/to/model-directory` 复用。
证书错误应修复信任配置，不关闭 TLS 或完整性校验。可选模型通过应用下载。

## Android

先安装 Android SDK Command-line Tools，再把占位路径替换为自己的安装目录：

```sh
export JAVA_HOME='/path/to/jdk-17'
export ANDROID_HOME='/path/to/android-sdk'
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
sdkmanager 'platform-tools' 'platforms;android-37.0' 'build-tools;36.0.0' \
  'ndk;28.2.13676358' 'cmake;3.22.1'
sdkmanager --licenses
python scripts/build_native_runtime.py --platform android
python scripts/audit_native_runtime.py --platform android
python scripts/setup_native_tools.py
python scripts/dev.py check --platform android
flutter build apk --debug --target-platform android-arm64 --no-pub
android/gradlew -p android -Ptarget-platform=android-arm64 :app:lintDebug :app:testDebugUnitTest
flutter devices
flutter run -d YOUR_ANDROID_DEVICE_ID --debug --no-pub
```

交互接受 SDK 许可，选择开启 USB 调试的 ARM64 设备，ID 使用 Flutter 列出的实际值。
SDK 查找失败时运行 `flutter config --android-sdk "$ANDROID_HOME"`。
Debug 标识为 `org.hohu.momentai.dev`，输出为 `build/app/outputs/flutter-apk/app-debug.apk`。

签名 Release 需要在 Git 外准备包含 `storeFile`（密钥库绝对路径）、`storePassword`、
`keyAlias`、`keyPassword` 的完整配置文件，然后运行：

```sh
export MOMENTAI_SIGNING_PROPERTIES='/absolute/path/to/android-signing.properties'
flutter build apk --release --target-platform android-arm64 --no-pub
```

Release 标识为 `org.hohu.momentai`，输出为 `build/app/outputs/flutter-apk/app-release.apk`。
不完整签名配置会被拒绝。不同密钥无法覆盖正式安装；保留记录，不通过卸载绕过签名冲突。

## iOS

CI 使用 GitHub 的 `xcode-27` Arm64 预览镜像，通过 `DEVELOPER_DIR` 显式选择
`/Applications/Xcode_27.2.app/Contents/Developer`。本地也应选择同版本 Xcode；
CI 在构建前核验 Xcode 构建号、SDK 和格式化工具版本，并使用 iOS 27.2 的 iPhone 18 Pro 运行测试。

应用和项目自构建的语音运行库最低支持 iOS 15.0。

```sh
python scripts/build_native_runtime.py --platform ios
python scripts/audit_native_runtime.py --platform ios
python scripts/dev.py check --platform ios
flutter build ios --release --no-codesign --no-pub
open ios/Runner.xcworkspace
```

未签名输出为 `build/ios/iphoneos/Runner.app`，不能安装到 iPhone 或作为 IPA 分发。
项目使用 Swift Package Manager，不需要 CocoaPods。
设备运行时选择 **Runner → Signing & Capabilities**，配置自己的 Apple 团队及已授权 Bundle ID，
在 **Product → Scheme → Edit Scheme → Run** 选择 **Release**，选中 iPhone 后运行。
独立构建可能需要自有 ID，对应独立数据容器。开发签名用于已配置设备，公开分发需要正确的渠道描述文件。
正式构建不得启用 `MOMENTAI_INTERNAL_TESTS`。

语音运行库依据[固定输入](../native/runtime-lock.json)从源码构建并关闭 TTS，须先于 Flutter 应用构建。
生成的库、源码归档、模型权重、缓存和 SDK 路径均留在 Git 外。
模型条款与原生依赖源码要求见[第三方说明](../THIRD_PARTY_NOTICES.md)。

## 验证与恢复

共享检查成功后再准备目标平台。共享检查不能证明麦克风权限、签名、文件提供方导入或 AI 连通性，
验证边界见[测试指南](TESTING.zh-CN.md)。模型缺失时重新运行 `prepare_models.py`，不能绕过哈希失败；
原生库缺失时重新执行对应平台运行库构建与审计，不能随意下载替代库。
运行库证据位于 `.local/validation/native/`，工具缓存仍在被忽略的 `.tools/`。
全新环境不要复制旧检出的 `.dart_tool`、`.venv`、SDK 路径配置或签名文件。

macOS 上单独安装的 Python 若缺少证书信任，而系统 CA 文件存在，可用
`SSL_CERT_FILE=/etc/ssl/cert.pem python scripts/prepare_models.py` 重试。
这仍然验证 TLS；信任或模型完整性检查继续失败时应停止。

网络失败时修复代理或 CA 信任，再重试同一命令。离线构建需要事先验证的输入，不能算作全新安装验证。
上述命令不会上传发行包，维护要求见[发布指南](RELEASING.zh-CN.md)。

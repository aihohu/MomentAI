# Build from source

[简体中文](BUILDING.zh-CN.md) · [Documentation](README.md)

Commands use a POSIX shell from the repository root after cloning. iOS requires
macOS; Windows development is unverified. Install these prerequisites first:

| Tool | Version |
| --- | --- |
| Flutter / Dart | Flutter 3.44.8, including Dart 3.12.2 |
| Python / Node.js | Python 3.11+, Node.js 22+ |
| Java / Android SDK | JDK 17; Platform 37.0, Build Tools 36.0.0, NDK 28.2.13676358 |
| Native build tools | CMake 3.22.1+, make, HTTPS-enabled curl |
| iOS toolchain | Xcode 27.2 (27B52), iOS 27.2 SDK; swift-format 6.4.4 |

Add Flutter's `bin` to PATH. Check `flutter --version`, `python3 --version`,
`node --version`, and `flutter doctor -v`; resolve issues for your target platform.
Xcode does not provide CMake. Install it separately or set `MOMENTAI_CMAKE` to its executable.

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

Reactivate `.venv` in each new shell. Shared checks do not require a device or full
models. The model script acquires the built-in model and verifies pinned sizes and
SHA-256 values from [models/bundled.json](../models/bundled.json). Existing files can
be reused with `--from-directory /path/to/model-directory`. Fix certificate trust
errors instead of disabling TLS or integrity checks. Optional models download in-app.

## Android

Install Android SDK Command-line Tools. Replace the placeholder installation paths:

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

Accept SDK licenses interactively. Select an ARM64 device with USB debugging enabled;
replace its ID with one listed by Flutter. If SDK discovery fails, run
`flutter config --android-sdk "$ANDROID_HOME"`. Debug uses `org.hohu.momentai.dev`
and produces `build/app/outputs/flutter-apk/app-debug.apk`.

For signed Release, create a properties file outside Git containing `storeFile`
(absolute keystore path), `storePassword`, `keyAlias`, and `keyPassword`, then run:

```sh
export MOMENTAI_SIGNING_PROPERTIES='/absolute/path/to/android-signing.properties'
flutter build apk --release --target-platform android-arm64 --no-pub
```

Release uses `org.hohu.momentai` and produces `build/app/outputs/flutter-apk/app-release.apk`.
Incomplete signing configuration is rejected. A different signing key cannot update
an official installation; preserve recordings and do not uninstall to bypass a conflict.

## iOS

CI uses GitHub's `xcode-27` Arm64 preview image and explicitly selects
`/Applications/Xcode_27.2.app/Contents/Developer` through `DEVELOPER_DIR`.
Select the same Xcode locally; CI verifies the Xcode build, SDK and formatter
versions before building, and runs tests on iPhone 18 Pro with iOS 27.2.

The app and project-owned speech runtime require iOS 15.0 or later.

```sh
python scripts/build_native_runtime.py --platform ios
python scripts/audit_native_runtime.py --platform ios
python scripts/dev.py check --platform ios
flutter build ios --release --no-codesign --no-pub
open ios/Runner.xcworkspace
```

The unsigned output is `build/ios/iphoneos/Runner.app`, which cannot be installed
on iPhone or distributed as an IPA. The project uses Swift Package Manager, without
CocoaPods. For device execution, select **Runner → Signing & Capabilities**, choose
your Apple team and an authorized Bundle ID, and select **Release** under
**Product → Scheme → Edit Scheme → Run**. Select the connected iPhone and run.
Independent builders may need a different ID, which creates a separate data container.
Development signing is for provisioned devices; public distribution needs the chosen
Apple channel's signing profile. Production builds must not enable `MOMENTAI_INTERNAL_TESTS`.

The speech runtime builds from [pinned inputs](../native/runtime-lock.json) with TTS
disabled. Run the matching native command before building Flutter. Generated
libraries, source archives, model weights, caches, and SDK paths stay outside Git.
See [Third-party notices](../THIRD_PARTY_NOTICES.md) for model terms and native source obligations.

## Verify and recover

Shared checks must finish successfully before platform preparation. They do not
prove microphone access, signing, import through a file provider, or AI connectivity.
See [testing](TESTING.md) for those boundaries. A missing model is resolved by
rerunning `prepare_models.py`; a hash failure must not be bypassed. A missing native
library requires the matching runtime build and audit, not a downloaded replacement.
Runtime evidence is written to `.local/validation/native/`; tool caches remain in
ignored `.tools/`. Do not copy a previous checkout's `.dart_tool`, `.venv`, SDK paths,
or signing files into a fresh setup.

On macOS, if a separately installed Python lacks certificate trust but the system
CA file is present, retry with `SSL_CERT_FILE=/etc/ssl/cert.pem python scripts/prepare_models.py`.
This keeps TLS verification enabled; stop if trust or model integrity still fails.

For network failures, fix proxy/CA access and retry the same command. An offline
build requires previously verified inputs; it is not a clean installation check.
No release is uploaded by these commands. See [release maintenance](RELEASING.md).

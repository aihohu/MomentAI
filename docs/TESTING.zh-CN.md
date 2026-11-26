# 验证改动

[English](TESTING.md) · [文档目录](README.zh-CN.md)

从[构建指南](BUILDING.zh-CN.md)准备依赖，在仓库根目录激活 `.venv` 后执行：

```sh
python scripts/dev.py check
python scripts/dev.py test
```

共享测试使用合成数据和模拟服务，不安装应用、不实际录音、不调用 AI 服务。
用 `python scripts/generate_m2_contract_fixtures.py` 生成确定性归档样例，检查变化；不能为了通过测试重写预期结果。
Android 交换样例由 `M3cContracts` 产生，iOS 返回样例对应
`RunnerTests.testAndroidProducedArchivesImportAndReexportWithMediaAndSpeakerHistory`。
原生导出含生成的 ID 和时间，验证内容与断言，不要求重新运行逐字节相同。
必须保留非法容器拒绝测试。

## Android

按构建指南准备工具链、运行库和模型后运行：

```sh
android/gradlew -p android -Ptarget-platform=android-arm64 :app:lintDebug :app:testDebugUnitTest :app:assembleDebugAndroidTest
```

这会执行应用模块 lint、JVM 测试并编译 instrumentation APK，不会在手机执行 instrumentation 测试。

## iOS

按构建指南准备后，从 `xcrun simctl list devices available` 选择隔离的模拟器并替换 ID：

```sh
flutter build ios --debug --simulator --config-only --no-pub
xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -skip-testing:RunnerTests/RunnerTests/testCommittedAudioPlayerStartsWithDeviceOutputFormat
```

被跳过的用例需要真实音频输出路由，应在空闲且已配置的设备上移除此排除项单独验证。
原生测试宿主不能代替签名产品验收。麦克风录制和故障注入需要明确选择空闲测试设备。
正式构建不得启用 `MOMENTAI_INTERNAL_TESTS`。原始证据存入 `.local/validation/`，
PR 和发行说明仅报告准确、脱敏的验证摘要。

## 文档与全新环境

`python scripts/dev.py check` 包含 Markdown 格式、发布清单、内部链接及锚点、双语对应和公开源码卫生检查。
这些是结构检查，不能代替内容评审。
`python scripts/check_documentation.py --archive PATH` 检查源码 TAR 或应用 ZIP/APK/IPA 是否混入私有过程路径；
通过不代表签名、权限或原生链接已验证。

安装验收应在 `.local/validation/` 下检出候选修订，创建新的虚拟环境和依赖缓存，
严格按[构建指南](BUILDING.zh-CN.md)顺序执行。
在本地证据中记录工具版本、命令、退出码、缓存与网络使用及任何替代步骤；使用缓存的构建须明确说明。
该检出不应进入分析范围，也不能复制真实录音进去。
应用和设备验收按[使用指南](USAGE.zh-CN.md)完成合成首次录音及传输，覆盖拒绝权限、录音中断、非法导入，
明确列出未执行项目。

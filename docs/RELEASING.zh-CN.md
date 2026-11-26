# 准备发布

[English](RELEASING.md) · [文档目录](README.zh-CN.md)

面向拥有签名权限并已完成[构建准备](BUILDING.zh-CN.md)的维护者。
[Quality 工作流](../.github/workflows/quality.yml)执行源码检查、Android Debug APK 与未签名 iOS 应用构建及测试，
不发布正式版本或上传测试结果附件。任务日志遵循仓库访问权限和保留设置。
签名与分发由维护者完成，CI 成功不等于发行批准。

## 候选与兼容性

1. 在 [pubspec.yaml](../pubspec.yaml) 更新应用版本和构建号，同步文档目录版本并提交经评审的变更。
   记录最终发布候选提交，确认对应 CI 结果通过。Node 工具包版本不是应用版本。
   重用已安装的构建号前须核对目标分发渠道要求。
2. 检查两端 store 和归档导入器的数据兼容性，验证打开上一支持版本的合成记录及往返交换。
   升级前保留已验证导出；旧程序无法理解新数据时不能靠降级恢复。
   不得通过卸载用户应用绕过签名或迁移错误。
3. 执行[共享和原生检查](TESTING.zh-CN.md)，再在所声明设备独立验收签名产品。
   覆盖权限拒绝及重试、暂停继续、中断、后台录音、锚点播放、模型和跨平台传输。
   准确记录跳过的检查、设备、系统、工具版本和已知限制。

## 打包与检查

按 [Android](BUILDING.zh-CN.md#android) 或 [iOS](BUILDING.zh-CN.md#ios) 指南签名，签名凭据不得纳入 Git 或发行附件。
Android 构建前确认 `MOMENTAI_SIGNING_PROPERTIES` 指向当前发行配置。
将实际 APK 的证书 SHA-256 与维护者记录的发行证书核对，不一致时不得发布。

iOS 在 Xcode 选择已配置签名的 Runner scheme，执行 **Product → Archive**，
再通过 Organizer 的 **Distribute App** 提交至 App Store Connect。
正式版本通过 App Store 分发，测试版本使用 TestFlight。未签名 `Runner.app` 只能作为构建验证产物。
核对产物应用标识、版本、签名身份和内置模型，产品构建不得开启 `ENABLE_INTERNAL_TOOLS` 或 `MOMENTAI_INTERNAL_TESTS`。

```sh
mkdir -p .local/validation/release
"${ANDROID_HOME:?Set ANDROID_HOME}/build-tools/36.0.0/apksigner" verify --verbose --print-certs \
  build/app/outputs/flutter-apk/app-release.apk \
  > .local/validation/release/android-signature.txt
git archive --format=tar HEAD -o .local/validation/release/source.tar
python scripts/check_documentation.py --archive .local/validation/release/source.tar
python scripts/check_documentation.py --archive build/app/outputs/flutter-apk/app-release.apk
```

源码归档对应已提交的 `HEAD`，不包含工作区修改，应在候选提交后运行。
签名报告仅用于本地核验，不公开签名配置或诊断报告。按构建指南用 `audit_native_runtime.py` 检查原生链接，
用 `python scripts/check_android_native_alignment.py build/app/outputs/flutter-apk/app-release.apk` 检查 Android 对齐，
按[第三方声明](../THIRD_PARTY_NOTICES.md)审查许可覆盖。
归档路径筛查不能代替这些检查，也不能证明没有个人数据。

## 选择公开内容

复核[文档发布清单](manifest.json)、候选差异和可达历史。
发行说明包含真实应用版本、源码修订、支持平台、变更、迁移恢复方式及已知限制。
GitHub Releases 提供经过正式签名的 Android Release APK、SHA-256 校验和及已评审的发行说明。
发行标签须指向通过验收的候选提交。iOS 提供 App Store 链接，不上传 IPA。
校验和从最终发行产物生成，验证记录保留在本地。
不上传 `.local/`、原始验收日志、源码缓存或签名凭据。
必需检查失败时不得发布；已分发产物需要修正时，递增版本和构建号并更新发行说明。
公开源码归档保留正式文档和法律声明。仓库未配置自动发行任务或固定发布周期。

漏洞处理遵循[安全政策](../SECURITY.md)，保留现有[许可证](../LICENSE)、[署名](../NOTICE)和图标声明。
无法获得独立评审时明确说明，不能将本地验证描述为批准。

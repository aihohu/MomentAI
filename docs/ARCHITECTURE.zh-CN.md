# 安全地扩展应用

[English](ARCHITECTURE.md) · [文档目录](README.zh-CN.md)

面向已完成[构建准备](BUILDING.zh-CN.md)的开发者。

| 职责 | 实现入口 |
| --- | --- |
| 依赖构造与应用入口 | [main.dart](../lib/main.dart) |
| 产品导航与记录详情所有权 | [协调器](../lib/product/app_coordinator.dart)、[详情控制器](../lib/product/session_detail_controller.dart) |
| 领域数据 | [domain](../lib/domain) |
| 录音和播放方法及事件契约 | [PoCBridge](../lib/poc/poc_bridge.dart) |
| 记录增删改查和交换 | [repository](../lib/core/session/session_repository.dart)、[transfer gateway](../lib/core/session/session_transfer_gateway.dart) |
| 原生持久化 | [Swift store](../ios/Runner/SessionStore.swift)、[Kotlin store](../android/app/src/main/kotlin/org/hohu/momentai/SessionStore.kt) |
| AI 服务、凭据及文档存储 | [服务接线](../lib/product/ai_services.dart)、[AI core](../lib/core/ai) |

历史命名 `PoCBridge` 仍被产品使用，并不是无用示例。沿产品控制器、Dart gateway、两端原生处理器追踪功能；
只增加 Dart 方法不会实现平台能力。

## 持久化与音频边界

已提交音频为 16 kHz 单声道 PCM16，数据库提交与已提交采样边界决定持久音频。
暂停不插入静音；显示分组和精修必须保留原始音频锚点，不能虚构逐字时间戳。
派生文字和说话人结果保留来源标识；持久化失败不能显示为已保存。
同一记录详情拥有共享的 AI 状态，总结和对话不能通过竞争重载覆盖较新的历史。

交换格式修改须同时核对 [iOS 导入器](../ios/Runner/SessionImporter.swift)和
[Android 归档实现](../android/app/src/main/kotlin/org/hohu/momentai/SessionArchive.kt)，包括两端 ZIP 读取器。
它们在导入记录可见前验证结构、路径、大小边界和内容。
[合成样例生成器](../scripts/generate_m2_contract_fixtures.py)及原生交换测试提供可执行契约证据。
本文不重复所有字段，也不承诺稳定的第三方归档写入 API。

## 安全边界

原生代码负责麦克风和相机权限、录音生命周期与文件访问。
Android 录音在私有 no-backup 存储；iOS 录音使用 Application Support，交换文件使用 Documents，
详见[使用隐私说明](USAGE.zh-CN.md#功能与隐私)。远程 AI 使用经校验的 HTTPS 地址、授权和安全凭据存储；
服务商与文件分享目标是独立的信任边界。模型下载哈希只验证固定输入，不能证明转写准确性。

## 扩展流程

1. 先在 `.local/plans/` 明确预期行为、失败恢复和数据兼容性；协作决策通过 Issue 或 PR 共享，不附私有证据。
2. 按表格确定负责模块，契约变动时同步 gateway 和两端原生处理器。持久化结构修改进入各端 store 的迁移路径，
   测试打开旧数据，不能通过删除旧数据完成迁移。
3. 在 `lib/l10n/app_en.arb`、`app_zh.arb` 及必要的原生资源补齐中英文，运行 `flutter gen-l10n`。
   依赖在 `main.dart` 或 `AiServices` 接入，匹配既有所有权和生命周期。
4. 增加合成数据行为回归，执行[受影响检查](TESTING.zh-CN.md)，同步双语指南。产品发行不得开启内部故障工具。

新增长期架构取舍时，在 `docs/decisions/` 维护经过评审的 ADR，并加入清单和导航。
不能把事后整理的说明伪称为已接受的历史决策。本项目没有独立插件注册 API。

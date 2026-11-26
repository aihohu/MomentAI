# Change the application safely

[简体中文](ARCHITECTURE.zh-CN.md) · [Documentation](README.md)

For developers extending existing behavior after [build setup](BUILDING.md).

| Responsibility | Implementation entry |
| --- | --- |
| Dependency construction and app entry | [main.dart](../lib/main.dart) |
| Product navigation and session detail ownership | [app coordinator](../lib/product/app_coordinator.dart), [detail controller](../lib/product/session_detail_controller.dart) |
| Domain data | [domain](../lib/domain) |
| Capture/playback method and event contracts | [PoCBridge](../lib/poc/poc_bridge.dart) |
| Session CRUD and exchange | [repository](../lib/core/session/session_repository.dart), [transfer gateway](../lib/core/session/session_transfer_gateway.dart) |
| Native persistence | [Swift store](../ios/Runner/SessionStore.swift), [Kotlin store](../android/app/src/main/kotlin/org/hohu/momentai/SessionStore.kt) |
| AI provider, credentials and document storage | [service wiring](../lib/product/ai_services.dart), [AI core](../lib/core/ai) |

The historical `PoCBridge` name is used by the product. It is not an unused example.
Follow a feature from its product controller to the Dart gateway, then both native
handlers; adding a Dart method alone does not implement a platform capability.

## Persistence and audio boundaries

Committed audio is mono PCM16 at 16 kHz. Database commits and committed sample
bounds define durable audio. Pause does not insert silence. Display grouping and
refinement must preserve original audio anchors; they cannot invent word timestamps.
Derived text/speaker results retain their source identity. A failed persistence
operation must not be presented as saved. One session-detail owner shares AI state
between summary and conversation; competing reloads must not replace newer history.

Review exchange changes against both [iOS importer](../ios/Runner/SessionImporter.swift)
and [Android archive implementation](../android/app/src/main/kotlin/org/hohu/momentai/SessionArchive.kt),
including their ZIP readers. They validate archive structure, paths, size bounds and
payloads before publishing an imported session. The [synthetic fixture generator](../scripts/generate_m2_contract_fixtures.py)
and native exchange tests are executable contract evidence. This page does not
repeat every field or promise a stable third-party archive writer API.

## Security boundaries

Native code owns microphone/camera permissions, capture lifecycle and filesystem
access. Android uses private no-backup recording storage; iOS uses Application
Support for recordings and Documents for exchange. See [user privacy](USAGE.md#features-and-privacy).
Remote AI uses validated HTTPS endpoints, consent, and secure credential storage;
providers and file-sharing destinations are separate trust boundaries. Model download
hashes verify the pinned input, not the correctness of a transcription.

## Extension workflow

1. Write the proposed behavior, failure/recovery cases and data compatibility in
   `.local/plans/`; share collaborative decisions in an Issue or PR without private evidence.
2. Identify the owner in the table and update the gateway plus both native handlers
   if the contract changes. Put persistent schema changes in each platform's store
   migration path; test opening older data instead of deleting it.
3. Add English/Chinese UI strings in `lib/l10n/app_en.arb` and `app_zh.arb` and native
   resources when needed; run `flutter gen-l10n`. Register dependencies in `main.dart`
   or `AiServices`, matching the existing ownership lifetime.
4. Add synthetic behavioral regressions, run [affected checks](TESTING.md), and update
   both guide languages. Never enable internal fault tools in a product release.

Record new long-lived tradeoffs as reviewed ADRs under `docs/decisions/` and add them
to the manifest and navigation. Do not label a reconstructed explanation an accepted
historical decision. There is no independent plugin registration API in this project.

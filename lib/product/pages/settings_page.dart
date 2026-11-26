import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../core/models/local_model_manager.dart';
import '../../core/system/product_system_gateway.dart';
import '../../l10n/language_picker.dart';
import '../ai_services.dart';
import '../app_coordinator.dart';
import '../product_formatters.dart';
import '../product_theme.dart';
import 'ai_settings_page.dart';
import 'local_models_page.dart';

class ProductSettingsPage extends StatelessWidget {
  const ProductSettingsPage({
    super.key,
    required this.coordinator,
    required this.onOpenRecords,
    this.openDiagnostics,
    this.aiServices,
    this.localModelManager,
  });

  final AppCoordinator coordinator;
  final VoidCallback onOpenRecords;
  final VoidCallback? openDiagnostics;
  final AiServices? aiServices;
  final LocalModelManager? localModelManager;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return AnimatedBuilder(
      animation: Listenable.merge([coordinator, ?localModelManager]),
      builder: (context, _) => Column(
        children: [
          AppBar(centerTitle: true, title: Text(l10n.settings)),
          Expanded(
            child: RefreshIndicator(
              onRefresh: coordinator.refresh,
              child: CustomScrollView(
                key: const PageStorageKey('product-settings'),
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                    sliver: SliverList.list(children: _contents(context)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _contents(BuildContext context) => [
    const LanguagePicker(),
    const SizedBox(height: 18),
    if (coordinator.systemError != null) ...[
      Card(
        color: ProductColors.amberSoft,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(
                Icons.sync_problem_rounded,
                color: ProductColors.amber,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.couldNotUpdateDeviceStatusTryAgain)),
              TextButton(
                onPressed: coordinator.refresh,
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 18),
    ],
    _SectionTitle(title: l10n.localStorage),
    const SizedBox(height: 10),
    if (!coordinator.storage.canStartRecording) ...[
      Card(
        color: ProductColors.amberSoft,
        child: ListTile(
          leading: const Icon(
            Icons.warning_amber_rounded,
            color: ProductColors.amber,
          ),
          title: Text(l10n.notEnoughSpaceForANewRecording),
          subtitle: Text(
            l10n.atLeastOfFreeSpaceIsRequired(
              (formatBytes(
                coordinator.storage.minimumRequiredBytes,
              )).toString(),
            ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onOpenRecords,
        ),
      ),
      const SizedBox(height: 10),
    ],
    Card(
      child: Column(
        children: [
          _SettingsRow(
            icon: Icons.folder_outlined,
            title: l10n.momentaiStorage,
            value: formatBytes(coordinator.storage.appUsedBytes),
          ),
          const Divider(height: 1, indent: 54),
          _SettingsRow(
            icon: Icons.sd_storage_outlined,
            title: l10n.availableDeviceStorage,
            value: formatBytes(coordinator.storage.availableBytes),
          ),
          const Divider(height: 1, indent: 54),
          _SettingsRow(
            icon: Icons.library_music_outlined,
            title: l10n.localRecordings,
            value: l10n.entries((coordinator.storage.sessionCount).toString()),
          ),
        ],
      ),
    ),
    const SizedBox(height: 26),
    _SectionTitle(title: l10n.speechTranscription),
    const SizedBox(height: 10),
    Card(
      child: ListTile(
        key: const Key('product-model-version'),
        minTileHeight: 66,
        leading: const Icon(Icons.memory_rounded, color: ProductColors.forest),
        title: Text(l10n.transcriptionModel),
        subtitle: Text(
          productModelName(
            localModelManager?.snapshot.activeRealtimeModelId ??
                coordinator.system.modelId,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.inUse,
              style: TextStyle(
                color: ProductColors.forest,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded),
          ],
        ),
        onTap: () => _openLocalModels(context),
      ),
    ),
    const SizedBox(height: 8),
    Text(
      l10n.transcriptionRunsOnThisDeviceWithoutUploading,
      style: TextStyle(
        color: ProductColors.mutedInk,
        fontSize: 12,
        height: 1.4,
      ),
    ),
    const SizedBox(height: 26),
    _SectionTitle(title: l10n.assistant),
    const SizedBox(height: 10),
    Card(
      child: ListTile(
        key: const Key('product-ai-settings'),
        leading: const Icon(
          Icons.auto_awesome_outlined,
          color: ProductColors.forest,
        ),
        title: Text(l10n.aiServices),
        subtitle: Text(l10n.connectYourAiServiceToSummarizeOr),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                AiSettingsPage(services: aiServices ?? AiServices.platform()),
          ),
        ),
      ),
    ),
    const SizedBox(height: 26),
    _SectionTitle(title: l10n.permissions),
    const SizedBox(height: 10),
    Card(
      child: Column(
        children: [
          _PermissionRow(
            key: const Key('product-microphone-permission'),
            icon: Icons.mic_outlined,
            title: l10n.microphone,
            purpose: l10n.usedToRecordAudio,
            status: coordinator.system.microphonePermission,
            loading: coordinator.isLoading,
            readFailed: coordinator.systemError != null,
            onOpenSettings: () => _openSystemSettings(context),
            requesting: coordinator.requestingPermission,
            onRequest: () =>
                _requestPermission(context, ProductPermission.microphone),
          ),
          const Divider(height: 1, indent: 54),
          _PermissionRow(
            key: const Key('product-camera-permission'),
            icon: Icons.photo_camera_outlined,
            title: l10n.camera,
            purpose: l10n.usedToTakePhotosAndAttachThem,
            status: coordinator.system.cameraPermission,
            loading: coordinator.isLoading,
            readFailed: coordinator.systemError != null,
            onOpenSettings: () => _openSystemSettings(context),
            requesting: coordinator.requestingPermission,
            onRequest: () =>
                _requestPermission(context, ProductPermission.camera),
          ),
        ],
      ),
    ),
    const SizedBox(height: 8),
    Text(
      l10n.youCanChangePermissionsInSystemSettings,
      style: TextStyle(
        color: ProductColors.mutedInk,
        fontSize: 12,
        height: 1.4,
      ),
    ),
    const SizedBox(height: 26),
    _SectionTitle(title: l10n.privacyAndData),
    const SizedBox(height: 10),
    Card(
      child: Padding(
        padding: EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline_rounded, color: ProductColors.forest),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.youControlYourData,
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 6),
                  Text(
                    l10n.recordingsAreSavedOnThisDeviceBy,
                    style: TextStyle(
                      height: 1.45,
                      color: ProductColors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 10),
    Card(
      child: Padding(
        padding: EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.record_voice_over_outlined, color: ProductColors.forest),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.respectOthersPrivacy,
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 6),
                  Text(
                    l10n.informParticipantsAndObtainConsentBeforeRecording,
                    style: TextStyle(
                      height: 1.45,
                      color: ProductColors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    const SizedBox(height: 26),
    _SectionTitle(title: l10n.about),
    const SizedBox(height: 10),
    Card(
      child: Column(
        children: [
          _SettingsRow(
            icon: Icons.info_outline_rounded,
            title: l10n.version,
            value: _versionLabel(coordinator.system),
          ),
          ListTile(
            key: const Key('open-licenses'),
            leading: const Icon(Icons.description_outlined),
            title: Text(MaterialLocalizations.of(context).licensesPageTitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'MomentAI',
              applicationLegalese:
                  'Copyright 2026 MomentAI contributors.\nLogo © 2026 hohu.org.',
            ),
          ),
        ],
      ),
    ),
    if (!kReleaseMode && openDiagnostics != null) ...[
      const SizedBox(height: 26),
      _SectionTitle(title: l10n.internalTools),
      const SizedBox(height: 10),
      Card(
        child: ListTile(
          key: const Key('open-diagnostics'),
          minTileHeight: 58,
          leading: const Icon(Icons.developer_mode_rounded),
          title: Text(l10n.developerConsole),
          subtitle: Text(l10n.faultInjectionAndStageValidationTools),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: openDiagnostics,
        ),
      ),
    ],
  ];

  Future<void> _openSystemSettings(BuildContext context) async {
    try {
      await coordinator.openSystemSettings();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.couldNotOpenSystemSettingsTryAgain)),
      );
    }
  }

  Future<void> _requestPermission(
    BuildContext context,
    ProductPermission permission,
  ) async {
    try {
      await coordinator.requestPermission(permission);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.couldNotRequestPermissionTryAgainShortly)),
      );
    }
  }

  void _openLocalModels(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LocalTranscriptionModelsPage(
          coordinator: coordinator,
          manager: localModelManager,
        ),
      ),
    );
  }

  static String _versionLabel(ProductSystemOverview overview) {
    if (overview.appVersion.isEmpty) return l10n.loading797;
    return 'v${overview.appVersion}';
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      child: Row(
        children: [
          Icon(icon, size: 22, color: ProductColors.forest),
          const SizedBox(width: 14),
          Expanded(child: Text(title)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(color: ProductColors.mutedInk),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.purpose,
    required this.status,
    required this.loading,
    required this.readFailed,
    required this.onOpenSettings,
    required this.requesting,
    required this.onRequest,
  });

  final IconData icon;
  final String title;
  final String purpose;
  final ProductPermissionStatus status;
  final bool loading;
  final bool readFailed;
  final VoidCallback onOpenSettings;
  final bool requesting;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final canRequest = status.canRequest;
    final actionable = status.requiresSettings || canRequest;
    return ListTile(
      minTileHeight: 58,
      leading: Icon(icon, color: ProductColors.forest),
      title: Text(title),
      subtitle: Text(_permissionHint(status)),
      trailing: actionable
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  canRequest
                      ? (requesting
                            ? l10n.waitingForPermission
                            : l10n.allowAccess)
                      : l10n.systemSettings,
                  style: const TextStyle(color: ProductColors.vermilion),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: ProductColors.vermilion,
                ),
              ],
            )
          : Text(
              _permissionLabel(status),
              style: TextStyle(
                color: status == ProductPermissionStatus.authorized
                    ? ProductColors.forest
                    : ProductColors.mutedInk,
                fontWeight: FontWeight.w700,
              ),
            ),
      onTap: requesting
          ? null
          : canRequest
          ? onRequest
          : actionable
          ? onOpenSettings
          : null,
    );
  }

  String _permissionLabel(ProductPermissionStatus status) => switch (status) {
    ProductPermissionStatus.authorized => l10n.allowed,
    ProductPermissionStatus.notDetermined => l10n.askWhenUsed,
    ProductPermissionStatus.notGranted => l10n.notAllowed,
    ProductPermissionStatus.denied => l10n.denied,
    ProductPermissionStatus.restricted => l10n.restrictedByDevice,
    ProductPermissionStatus.unavailable => l10n.unavailable,
    ProductPermissionStatus.unknown =>
      readFailed
          ? l10n.couldNotRead
          : loading
          ? l10n.loading797
          : l10n.unknownStatus,
  };

  String _permissionHint(ProductPermissionStatus status) => switch (status) {
    ProductPermissionStatus.authorized => l10n.readyToUse,
    ProductPermissionStatus.notDetermined => l10n.theSystemWillAskWhenYouFirst,
    ProductPermissionStatus.notGranted => l10n.notAllowedTapToGrantAccess(
      (purpose).toString(),
    ),
    ProductPermissionStatus.denied =>
      l10n.existingContentIsUnaffectedChangeAccessIn,
    ProductPermissionStatus.restricted =>
      l10n.thisPermissionIsRestrictedOnThisDevice,
    ProductPermissionStatus.unavailable =>
      l10n.thisFeatureIsUnavailableOnThisDevice,
    ProductPermissionStatus.unknown =>
      readFailed
          ? l10n.couldNotReadStatusPullDownTo
          : loading
          ? l10n.readingSystemStatus
          : l10n.couldNotCheckPermissionPullDownTo,
  };
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../core/capture/capture_gateway.dart';
import '../core/models/local_model_manager.dart';
import '../core/session/session_experience_gateway.dart';
import '../core/session/session_repository.dart';
import '../core/session/session_transfer_gateway.dart';
import '../core/system/product_system_gateway.dart';
import '../domain/session/session_summary.dart';
import '../poc/poc_bridge.dart';
import 'ai_services.dart';
import 'app_coordinator.dart';
import 'local_search.dart';
import 'pages/capture_page.dart';
import 'pages/home_page.dart';
import 'pages/local_models_page.dart';
import 'pages/records_page.dart';
import 'pages/recovery_page.dart';
import 'pages/session_detail_page.dart';
import 'pages/session_import_page.dart';
import 'pages/settings_page.dart';

class MomentAIProductShell extends StatefulWidget {
  const MomentAIProductShell({
    super.key,
    required this.captureGateway,
    required this.sessionRepository,
    required this.sessionExperienceGateway,
    required this.systemGateway,
    this.diagnosticsBuilder,
    this.transferGateway = const NativeSessionTransferGateway(),
    this.aiServices,
    this.localModelManager,
    this.backgroundModelWorkActivity,
  });

  final CaptureGateway captureGateway;
  final SessionRepository sessionRepository;
  final SessionExperienceGateway sessionExperienceGateway;
  final ProductSystemGateway systemGateway;
  final WidgetBuilder? diagnosticsBuilder;
  final SessionTransferGateway transferGateway;
  final AiServices? aiServices;
  final LocalModelManager? localModelManager;
  final ValueListenable<bool>? backgroundModelWorkActivity;

  @override
  State<MomentAIProductShell> createState() => _MomentAIProductShellState();
}

class _MomentAIProductShellState extends State<MomentAIProductShell> {
  late final AppCoordinator _coordinator;
  late final AiServices _aiServices;
  var _selectedIndex = 0;
  var _importOpen = false;

  @override
  void initState() {
    super.initState();
    _aiServices = widget.aiServices ?? AiServices.platform();
    _coordinator = AppCoordinator(
      captureGateway: widget.captureGateway,
      sessionRepository: widget.sessionRepository,
      systemGateway: widget.systemGateway,
      modelOperationActive: () =>
          (widget.localModelManager?.hasOperation ?? false) ||
          (widget.backgroundModelWorkActivity?.value ?? false),
      modelOperationChanges: Listenable.merge([
        widget.localModelManager,
        widget.backgroundModelWorkActivity,
      ]),
    );
    unawaited(_coordinator.initialize());
    unawaited(widget.localModelManager?.initialize());
  }

  @override
  void dispose() {
    _coordinator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final pages = [
      ProductHomePage(
        coordinator: _coordinator,
        active: _selectedIndex == 0,
        onOpenCapture: _openCapture,
        onOpenRecords: () => setState(() => _selectedIndex = 1),
        onOpenSession: _openSession,
        onOpenRecovery: _openRecovery,
        onOpenSettings: () => setState(() => _selectedIndex = 2),
        localModelManager: widget.localModelManager,
        onOpenModels: _openLocalModels,
      ),
      ProductRecordsPage(
        coordinator: _coordinator,
        onOpenSession: _openSession,
        gateway: widget.sessionExperienceGateway,
        active: _selectedIndex == 1,
        onImport: _openImport,
        onOpenSearchHit: (session, target) =>
            _openSession(session, searchTarget: target),
      ),
      ProductSettingsPage(
        coordinator: _coordinator,
        aiServices: _aiServices,
        localModelManager: widget.localModelManager,
        onOpenRecords: () => setState(() => _selectedIndex = 1),
        openDiagnostics: widget.diagnosticsBuilder == null
            ? null
            : _openDiagnostics,
      ),
    ];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _selectedIndex, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
          if (index == 1) unawaited(_coordinator.refreshSessions());
        },
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: l10n.home,
          ),
          NavigationDestination(
            icon: Icon(Icons.view_timeline_outlined),
            selectedIcon: Icon(Icons.view_timeline_rounded),
            label: l10n.recordings,
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: l10n.settings,
          ),
        ],
      ),
    );
  }

  void _openCapture() {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute(
            builder: (_) => ProductCapturePage(
              coordinator: _coordinator,
              onOpenDetails: _replaceCaptureWithDetails,
            ),
          ),
        )
        .then((_) => _coordinator.refreshSessions());
  }

  Future<void> _openLocalModels() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => LocalTranscriptionModelsPage(
        coordinator: _coordinator,
        manager: widget.localModelManager,
      ),
    ),
  );

  void _openSession(
    SessionSummary session, {
    SearchNavigationTarget? searchTarget,
  }) {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute(
            builder: (_) => ProductSessionDetailPage(
              session: session,
              gateway: widget.sessionExperienceGateway,
              coordinator: _coordinator,
              initialSearchTarget: searchTarget,
              aiServices: _aiServices,
              transferGateway: widget.transferGateway,
              onOpenModels: _openLocalModels,
            ),
          ),
        )
        .then((_) => _coordinator.refreshSessions());
  }

  void _openRecovery(RecoveryCandidate candidate) {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute(
            builder: (_) => ProductRecoveryPage(
              candidate: candidate,
              coordinator: _coordinator,
              gateway: widget.sessionExperienceGateway,
              aiServices: _aiServices,
            ),
          ),
        )
        .then((_) => _coordinator.refreshSessions());
  }

  Future<void> _openImport() async {
    if (_importOpen || _coordinator.hasActiveCapture || _coordinator.isBusy) {
      return;
    }
    _importOpen = true;
    try {
      final session = await Navigator.of(context).push<SessionSummary>(
        MaterialPageRoute(
          builder: (_) => SessionImportPage(gateway: widget.transferGateway),
        ),
      );
      if (!mounted) return;
      await _coordinator.refreshSessions();
      if (mounted && session != null) _openSession(session);
    } finally {
      _importOpen = false;
    }
  }

  Future<void> _replaceCaptureWithDetails(String sessionId) async {
    final session = await widget.sessionRepository.getSession(sessionId);
    if (!mounted) return;
    await Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute(
        builder: (_) => ProductSessionDetailPage(
          session: session,
          gateway: widget.sessionExperienceGateway,
          coordinator: _coordinator,
          transcriptionMayBeFinishing: true,
          showSavedConfirmation: true,
          aiServices: _aiServices,
          transferGateway: widget.transferGateway,
          onOpenModels: _openLocalModels,
        ),
      ),
    );
  }

  void _openDiagnostics() {
    final builder = widget.diagnosticsBuilder;
    if (builder == null) return;
    Navigator.of(context).push<void>(MaterialPageRoute(builder: builder));
  }
}

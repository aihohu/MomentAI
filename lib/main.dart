import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import 'core/asr/full_text_refinement_service.dart';
import 'core/asr/sherpa_onnx_transcription_provider.dart';
import 'core/asr/stage1_transcription_controller.dart';
import 'core/capture/capture_gateway.dart';
import 'core/models/local_model_manager.dart';
import 'core/playback/stage1_playback_controller.dart';
import 'core/project_licenses.dart';
import 'core/session/session_experience_gateway.dart';
import 'core/session/session_repository.dart';
import 'core/speaker/speaker_diarization_service.dart';
import 'core/system/product_system_gateway.dart';
import 'l10n/language_controller.dart';
import 'poc/poc_bridge.dart';
import 'poc/poc_page.dart';
import 'product/product_shell.dart';
import 'product/product_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerProjectLicenses();
  final languageController = LanguageController();
  await languageController.initialize();
  final bridge = NativePoCBridge();
  late final SenseVoiceFullTextRefinementService fullTextRefinementService;
  late final Stage1TranscriptionController transcriptionController;
  late final SherpaSpeakerDiarizationService speakerDiarizationService;
  final localModelManager = LocalModelManager(
    resourceBusy: () =>
        transcriptionController.activeSessionId != null ||
        transcriptionController.hasPendingRefinements ||
        transcriptionController.recoveryCatchUpInProgress ||
        transcriptionController.faultOperationInProgress ||
        fullTextRefinementService.hasActiveJobs ||
        speakerDiarizationService.hasActiveJobs,
  );
  fullTextRefinementService = SenseVoiceFullTextRefinementService(
    modelResolver: localModelManager,
  );
  final transcriptionProvider = SherpaOnnxTranscriptionProvider(
    modelResolver: localModelManager,
  );
  localModelManager.attachRuntimeSwitcher(transcriptionProvider);
  transcriptionController = Stage1TranscriptionController(
    bridge: bridge,
    provider: transcriptionProvider,
    fullTextRefinementService: fullTextRefinementService,
  );
  speakerDiarizationService = SherpaSpeakerDiarizationService(
    modelResolver: localModelManager,
    resourceBusy: () =>
        transcriptionController.activeSessionId != null ||
        transcriptionController.hasPendingRefinements ||
        transcriptionController.recoveryCatchUpInProgress ||
        transcriptionController.faultOperationInProgress ||
        fullTextRefinementService.hasActiveJobs ||
        localModelManager.hasOperation,
  );
  final playbackController = Stage1PlaybackController(bridge: bridge);
  final sessionRepository = NativeSessionRepository();
  final captureGateway = ProductCaptureGateway(bridge);
  final systemGateway = NativeProductSystemGateway();
  unawaited(transcriptionController.initialize());
  unawaited(playbackController.initialize());
  runApp(
    MomentAIApp(
      languageController: languageController,
      bridge: bridge,
      fullTextRefinementService: fullTextRefinementService,
      localModelManager: localModelManager,
      transcriptionController: transcriptionController,
      playbackController: playbackController,
      speakerDiarizationService: speakerDiarizationService,
      sessionRepository: sessionRepository,
      captureGateway: captureGateway,
      systemGateway: systemGateway,
    ),
  );
}

class MomentAIApp extends StatelessWidget {
  const MomentAIApp({
    super.key,
    required this.bridge,
    this.fullTextRefinementService,
    this.localModelManager,
    this.transcriptionController,
    this.playbackController,
    this.speakerDiarizationService,
    this.sessionRepository,
    this.captureGateway,
    this.systemGateway,
    this.languageController,
  });

  final LanguageController? languageController;
  final PoCBridge bridge;
  final FullTextRefinementService? fullTextRefinementService;
  final LocalModelManager? localModelManager;
  final Stage1TranscriptionController? transcriptionController;
  final Stage1PlaybackController? playbackController;
  final SpeakerDiarizationService? speakerDiarizationService;
  final SessionRepository? sessionRepository;
  final CaptureGateway? captureGateway;
  final ProductSystemGateway? systemGateway;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode &&
        (sessionRepository == null ||
            captureGateway == null ||
            systemGateway == null)) {
      throw StateError('Product services are required outside debug builds.');
    }
    final home =
        sessionRepository != null &&
            captureGateway != null &&
            systemGateway != null
        ? MomentAIProductShell(
            sessionRepository: sessionRepository!,
            captureGateway: captureGateway!,
            systemGateway: systemGateway!,
            localModelManager: localModelManager,
            backgroundModelWorkActivity: speakerDiarizationService?.activity,
            sessionExperienceGateway: ProductSessionExperienceGateway(
              bridge,
              transcriptionController: transcriptionController,
              fullTextRefinementService: fullTextRefinementService,
              speakerDiarizationService: speakerDiarizationService,
              refinementResourceBusy: () =>
                  localModelManager?.hasOperation ?? false,
            ),
            diagnosticsBuilder:
                kDebugMode &&
                    const bool.fromEnvironment('ENABLE_INTERNAL_TOOLS')
                ? (_) => PoCPage(
                    bridge: bridge,
                    transcriptionController: transcriptionController,
                    playbackController: playbackController,
                  )
                : null,
          )
        : PoCPage(
            bridge: bridge,
            transcriptionController: transcriptionController,
            playbackController: playbackController,
          );
    Widget application() => MaterialApp(
      onGenerateTitle: (context) => context.strings.momentai,
      debugShowCheckedModeBanner: false,
      theme: buildProductTheme(),
      locale: languageController?.locale ?? applicationLocale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
    );
    final controller = languageController;
    if (controller == null) return application();
    return LanguageScope(
      controller: controller,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) => application(),
      ),
    );
  }
}

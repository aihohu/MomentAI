import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/asr/full_text_refinement_service.dart';
import 'package:momentai/core/capture/capture_gateway.dart';
import 'package:momentai/core/models/local_model_manager.dart';
import 'package:momentai/core/models/local_model_manifest.dart';
import 'package:momentai/core/models/local_model_runtime.dart';
import 'package:momentai/core/session/session_experience_gateway.dart';
import 'package:momentai/core/session/session_repository.dart';
import 'package:momentai/core/session/session_transfer_gateway.dart';
import 'package:momentai/core/system/product_system_gateway.dart';
import 'package:momentai/domain/audio/playback_snapshot.dart';
import 'package:momentai/domain/session/session_summary.dart';
import 'package:momentai/domain/speaker/speaker_diarization.dart';
import 'package:momentai/domain/timeline/timeline_item.dart';
import 'package:momentai/domain/transcript/refined_full_text.dart';
import 'package:momentai/l10n/app_localization.dart';
import 'package:momentai/l10n/language_controller.dart';
import 'package:momentai/poc/poc_bridge.dart';
import 'package:momentai/product/app_coordinator.dart';
import 'package:momentai/product/local_search.dart';
import 'package:momentai/product/pages/local_models_page.dart';
import 'package:momentai/product/product_shell.dart';
import 'package:momentai/product/product_theme.dart';
import 'package:momentai/product/session_detail_controller.dart';
import 'package:momentai/product/widgets/product_timeline_card.dart';
import 'package:momentai/product/widgets/searchable_full_text.dart';
import 'package:momentai/product/widgets/virtual_full_text.dart';

void main() {
  test(
    'unchanged content polls preserve export while changed sources invalidate it',
    () async {
      final gateway = _FakeSessionExperienceGateway();
      final controller = SessionDetailController(
        session: _summary(
          id: 'session_2',
          title: 'Export',
          startedAt: DateTime.utc(2026),
          durationMs: 125000,
        ),
        gateway: gateway,
      );
      addTearDown(controller.dispose);
      final refined = RefinedFullTextDocument.fromMap({
        'sessionId': 'session_2',
        'fullText': 'Saved text',
      });
      gateway.refinementSnapshot = FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.ready,
        document: refined,
      );
      final speakers = gateway._speakerDocument(
        sessionId: 'session_2',
        requestedSpeakerCount: 2,
      );
      gateway.speakerSnapshot = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: speakers,
      );
      await controller.refreshContent();
      await controller.generateExport();
      final exported = controller.exportResult;
      expect(exported, isNotNull);
      gateway.refinementSnapshot = FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.ready,
        document: RefinedFullTextDocument.fromMap(refined.toMap()),
      );
      gateway.speakerSnapshot = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: SpeakerDiarizationDocument.fromMap(speakers.toMap()),
      );
      await controller.refreshContent();
      expect(controller.exportResult, same(exported));
      await controller.shareExport();
      expect(gateway.shareCount, 1);
      gateway.refinementSnapshot = FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.ready,
        document: RefinedFullTextDocument.fromMap({
          ...refined.toMap(),
          'fullText': 'Revised text',
        }),
      );
      await controller.refreshContent();
      expect(controller.exportResult, isNull);
      await controller.generateExport();
      gateway.speakerSnapshot = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: speakers.applyEdit(
          const SpeakerEdit.rename('speaker_1', 'Alice'),
        ),
      );
      await controller.refreshContent();
      expect(controller.exportResult, isNull);
      await controller.generateExport();
      gateway.timelineItems.add(_captureTranscript(10));
      await controller.refreshContent();
      expect(controller.exportResult, isNull);
    },
  );

  for (final language in ['en', 'zh']) {
    for (final size in [
      const Size(466, 678),
      const Size(678, 466),
      const Size(669, 951),
      const Size(951, 669),
      const Size(402, 874),
      const Size(874, 402),
      const Size(1032, 1376),
      const Size(1376, 1032),
      const Size(508, 1376),
      const Size(320, 1024),
    ]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'home keeps long records clear of its action at $size / $scale ($language)',
          (tester) async {
            setApplicationLanguage(language);
            addTearDown(() => setApplicationLanguage('zh'));
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final capture = _FakeCaptureGateway();
            final repository = _FakeSessionRepository(
              initialItems: List.generate(
                6,
                (index) => _summary(
                  id: 'long_$index',
                  title: language == 'en'
                      ? 'Product design conversation about recording, learning and lasting memories $index'
                      : '关于记录、学习与长久记忆的产品设计讨论和周末灵感随想 $index',
                  startedAt: DateTime(2026, 11, 14 - index, 9),
                  durationMs: 444000 + index * 1000,
                  imageCount: 1,
                  bookmarkCount: 1,
                ),
              ),
            );
            await tester.pumpWidget(_testApp(repository, capture));
            await tester.pumpAndSettle();
            final action = find.byKey(const Key('product-primary-action'));
            final list = find.byKey(const PageStorageKey('product-home'));
            final viewport = tester.getRect(list);
            expect(
              viewport.bottom,
              lessThanOrEqualTo(tester.getRect(action).top),
            );
            expect(action.hitTestable(), findsOneWidget);
            // Reach the third card's metadata, including in short landscape windows.
            final duration = find.textContaining('00:07:26');
            await tester.scrollUntilVisible(
              duration,
              160,
              scrollable: find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .first,
            );
            await tester.pumpAndSettle();
            final metadata = tester.getRect(duration);
            expect(metadata.top, greaterThanOrEqualTo(viewport.top));
            expect(metadata.bottom, lessThanOrEqualTo(viewport.bottom));
            expect(metadata.overlaps(tester.getRect(action)), isFalse);
            await tester.tap(duration);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('product-session-detail')),
              findsOneWidget,
            );
            await tester.tap(find.byType(BackButton));
            await tester.pumpAndSettle();
            await tester.tap(action);
            await tester.pumpAndSettle();
            expect(capture.startTitles, hasLength(1));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final language in ['zh', 'en']) {
    testWidgets(
      'playback stays readable and reachable at 320pt and 2x text ($language)',
      (tester) async {
        setApplicationLanguage(language);
        addTearDown(() => setApplicationLanguage('zh'));
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            _testApp(_FakeSessionRepository(), _FakeCaptureGateway()),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('product-session-session_2')),
            150,
            scrollable: find
                .descendant(
                  of: find.byKey(const PageStorageKey('product-home')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('product-session-session_2')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('product-playback-toggle')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (final key in [
            'product-playback-position',
            'product-playback-status',
          ]) {
            final label = find.byKey(Key(key));
            expect(label, findsOneWidget);
            expect(
              find.ancestor(of: label, matching: find.byType(FittedBox)),
              findsNothing,
            );
            expect(tester.getRect(label).right, lessThanOrEqualTo(320));
          }
          for (final key in [
            'product-playback-toggle',
            'product-playback-stop',
            'product-playback-sound',
            'product-session-ai',
          ]) {
            final rect = tester.getRect(find.byKey(Key(key)));
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.bottom, lessThanOrEqualTo(568));
          }
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await tester.tap(find.byKey(const Key('product-playback-stop')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(language == 'en' ? 'Settings' : '设置').last,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(language == 'en' ? 'Home' : '首页').last);
          await tester.pumpAndSettle();
          await _startProductCapture(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('end-product-recording')).hitTestable(),
            findsOneWidget,
          );
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'playback sound panel adjusts, boosts, restores and survives reopening',
    (tester) async {
      final experience = _FakeSessionExperienceGateway();
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-playback-sound')));
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(
        find.byKey(const Key('playback-volume-slider')),
      );
      slider.onChanged!(0.35);
      await tester.pumpAndSettle();
      expect(experience.soundSettings.volume, 0.35);
      await tester.tap(find.byKey(const Key('playback-enhancement-switch')));
      await tester.pumpAndSettle();
      expect(experience.soundSettings.enhanced, isFalse);
      Navigator.of(
        tester.element(find.byKey(const Key('playback-volume-slider'))),
      ).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-playback-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-playback-toggle')));
      await tester.pumpAndSettle();
      expect(experience.soundSettings.volume, 0.35);
      await tester.tap(find.byKey(const Key('product-playback-sound')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('playback-volume-slider')))
            .value,
        0.35,
      );
      await tester.tap(find.byKey(const Key('playback-sound-reset')));
      await tester.pumpAndSettle();
      expect(experience.soundSettings.volume, 1);
      expect(experience.soundSettings.enhanced, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'full text note search plays the capture anchor and returns to its timeline event',
    (tester) async {
      final experience = _FakeSessionExperienceGateway();
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('detail-fulltext-tab')));
      await tester.pumpAndSettle();
      await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
      await tester.enterText(
        find.byKey(const Key('detail-search-field')),
        '现场随想',
      );
      await tester.pumpAndSettle();
      expect(find.text('1/1 处命中'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail-search-play')));
      await tester.pumpAndSettle();
      expect(experience.lastAnchorId, 'evt_thought_product');
      expect(experience.lastPlaybackSample, 32000);
      expect(experience.lastAnchorType, 'thought');
      await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
      final jump = find.byKey(
        const ValueKey('fulltext-event-timeline-evt_thought_product'),
      );
      await tester.ensureVisible(jump);
      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(find.byType(VirtualFullText), findsNothing);
      final card = find.byKey(
        const ValueKey('product-timeline-evt_thought_product'),
      );
      expect(card.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved long recording requires confirmation before manual refinement and disables repeats',
    (tester) async {
      final experience = _FakeSessionExperienceGateway()
        ..manualRefinementGate = Completer<void>();
      final repository = _FakeSessionRepository(
        initialItems: [
          _summary(
            id: 'long',
            title: 'Long imported recording',
            startedAt: DateTime(2026, 9, 20),
            durationMs: 11137200,
          ),
        ],
      );
      await tester.pumpWidget(
        _testApp(repository, _FakeCaptureGateway(), experience: experience),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-long')));
      await tester.pumpAndSettle();
      await _tapDetailMenuAction(tester, const Key('detail-refine-fulltext'));
      expect(
        find.text(
          '${l10n.manualRefinementExplanation}\n\n${l10n.manualRefinementLongRecording}',
        ),
        findsOneWidget,
      );
      expect(experience.manualRefinementCount, 0);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(experience.manualRefinementCount, 0);
      await tester.tap(find.byKey(const Key('detail-fulltext-tab')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('fulltext-refine-action')),
      );
      await tester.tap(find.byKey(const Key('fulltext-refine-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-fulltext-refinement')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(experience.manualRefinementCount, 1);
      expect(experience.lastRefinementForce, isFalse);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('fulltext-refine-action')))
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const Key('transcript-processing-banner')),
        findsOneWidget,
      );
      experience.manualRefinementGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('transcript-processing-banner')),
        findsNothing,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('fulltext-refine-action')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long full text virtualizes and searches beyond the mounted viewport',
    (tester) async {
      final timeline = List.generate(
        900,
        (i) => TimelineItem.fromMap({
          'kind': 'transcript',
          'segmentId': 'long_$i',
          'sampleOffset': i * 16000,
          'endSample': (i + 1) * 16000,
          'text': '${i == 870 ? '远处目标' : '普通内容'}第$i段，${'这是用于检查长全文滚动的句子。' * 5}',
        }),
      );
      final experience = _FakeSessionExperienceGateway(timeline: timeline);
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('detail-fulltext-tab')));
      await tester.tap(find.byKey(const Key('detail-fulltext-tab')));
      await tester.pumpAndSettle();
      expect(find.byType(VirtualFullText), findsOneWidget);
      expect(find.byType(SearchableFullText), findsNothing);
      await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
      await tester.enterText(
        find.byKey(const Key('detail-search-field')),
        '远处目标',
      );
      await tester.pumpAndSettle();
      final reader = tester.widget<VirtualFullText>(
        find.byType(VirtualFullText),
      );
      final state = tester.state<VirtualFullTextState>(
        find.byType(VirtualFullText),
      );
      final range = searchTextRanges(reader.text, '远处目标').single;
      final rect = state.matchRect(range);
      expect(rect, isNotNull);
      final viewport = tester.getRect(
        find.byKey(const Key('product-session-detail')),
      );
      expect(rect!.top, greaterThanOrEqualTo(viewport.top));
      expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
      await tester.tap(find.byKey(const Key('detail-search-play')));
      await tester.pumpAndSettle();
      expect(experience.lastPlaybackSample, 870 * 16000);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'English home settings and models remain usable at 390pt and 2x text',
    (tester) async {
      setApplicationLanguage('en');
      addTearDown(() => setApplicationLanguage('zh'));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final modelRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('momentai-l10n-models-'),
      ))!;
      addTearDown(
        () => tester.runAsync(() => modelRoot.delete(recursive: true)),
      );
      final models = _modelCenterForWidget(modelRoot);
      await tester.runAsync(models.initialize);
      await tester.runAsync(models.dismissRefinementSuggestion);
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          localModelManager: models,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final model = find.byKey(const Key('product-model-version'));
      await tester.scrollUntilVisible(model, 250);
      await tester.ensureVisible(model);
      await tester.pumpAndSettle();
      expect(model.hitTestable(), findsOneWidget);
      await tester.tap(model);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(LocalTranscriptionModelsPage), findsOneWidget);
      expect(find.textContaining('Mandarin'), findsWidgets);
    },
  );

  testWidgets(
    'open recording updates cached speaker labels after locale changes',
    (tester) async {
      final languages = LanguageController(
        store: _MemoryLanguagePreferences(),
        systemLocale: () => const Locale('zh'),
        nativeSync: (_) async {},
      );
      await languages.initialize();
      addTearDown(languages.dispose);
      addTearDown(() => setApplicationLanguage('zh'));
      final experience = _FakeSessionExperienceGateway();
      experience.speakerSnapshot = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: experience._speakerDocument(
          sessionId: 'session_2',
          requestedSpeakerCount: 1,
        ),
      );
      final home = MomentAIProductShell(
        captureGateway: _FakeCaptureGateway(),
        sessionRepository: _FakeSessionRepository(),
        sessionExperienceGateway: experience,
        systemGateway: _FakeProductSystemGateway(),
        transferGateway: _FakeTransferGateway(),
      );
      await tester.pumpWidget(
        LanguageScope(
          controller: languages,
          child: AnimatedBuilder(
            animation: languages,
            builder: (context, _) => MaterialApp(
              locale: languages.locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              theme: buildProductTheme(),
              home: home,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      expect(find.text('说话人 1'), findsWidgets);
      await languages.select(AppLanguage.en);
      await tester.pumpAndSettle();
      expect(find.text('Speaker 1'), findsWidgets);
      expect(find.text('说话人 1'), findsNothing);
      expect(experience.speakerSnapshot.document!.labels.names, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching language keeps an active capture and navigation alive',
    (tester) async {
      final languages = LanguageController(
        store: _MemoryLanguagePreferences(),
        systemLocale: () => const Locale('zh'),
        nativeSync: (_) async {},
      );
      await languages.initialize();
      addTearDown(languages.dispose);
      addTearDown(() => setApplicationLanguage('zh'));
      final capture = _FakeCaptureGateway();
      final home = MomentAIProductShell(
        captureGateway: capture,
        sessionRepository: _FakeSessionRepository(),
        sessionExperienceGateway: _FakeSessionExperienceGateway(),
        systemGateway: _FakeProductSystemGateway(),
        transferGateway: _FakeTransferGateway(),
      );
      await tester.pumpWidget(
        LanguageScope(
          controller: languages,
          child: AnimatedBuilder(
            animation: languages,
            builder: (context, _) => MaterialApp(
              locale: languages.locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              theme: buildProductTheme(),
              home: home,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _startProductCapture(tester);
      final original = tester.state(
        find.byType(MomentAIProductShell, skipOffstage: false),
      );
      final sessionId = capture.current.sessionId;
      await languages.select(AppLanguage.en);
      await tester.pumpAndSettle();
      expect(capture.current.sessionId, sessionId);
      expect(capture.startTitles, hasLength(1));
      expect(capture.stopCount, 0);
      expect(capture.recordingPauseCount, 0);
      expect(
        tester.state(find.byType(MomentAIProductShell, skipOffstage: false)),
        same(original),
      );
      expect(find.text('Recording'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'speaker edits invalidate cached archives and cannot race a share',
    () async {
      final gateway = _FakeSessionExperienceGateway();
      final controller = SessionDetailController(
        session: _summary(
          id: 'session_2',
          title: '样例',
          startedAt: DateTime.utc(2026, 9, 10),
          durationMs: 125000,
        ),
        gateway: gateway,
      );
      addTearDown(controller.dispose);
      final original = gateway._speakerDocument(
        sessionId: 'session_2',
        requestedSpeakerCount: 2,
      );
      controller.speakerDiarization = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: original,
      );
      await controller.generateExport();
      expect(controller.exportResult, isNotNull);
      expect(
        await controller.editSpeakers(
          original,
          const SpeakerEdit.rename('speaker_1', '小林'),
        ),
        isTrue,
      );
      expect(controller.exportResult, isNull);
      await controller.shareExport();
      expect(gateway.shareCount, 0);
      controller.sharing = true;
      expect(
        await controller.editSpeakers(
          controller.speakerDiarization.document!,
          const SpeakerEdit.undo(),
        ),
        isFalse,
      );
      await controller.deleteSpeakerDiarization();
      expect(gateway.speakerDeletionCount, 0);
      controller.sharing = false;
      await controller.generateExport();
      controller.speakerDiarizationBusy = true;
      await controller.shareExport();
      expect(gateway.shareCount, 0);
    },
  );

  test('SessionSummary parses native product fields', () {
    final summary = SessionSummary.fromMap({
      'sessionId': 'session_1',
      'directory': '/tmp/session_1',
      'title': '用户访谈',
      'state': 'completed_with_gaps',
      'startedAtWall': '2026-08-17T12:00:00Z',
      'stoppedAtWall': '2026-08-17T12:10:00Z',
      'durationSamples': 160000,
      'durationMs': 10000,
      'chunkCount': 10,
      'transcriptCount': 4,
      'imageCount': 2,
      'thoughtCount': 1,
      'bookmarkCount': 3,
      'recoveryCount': 1,
      'hasConfirmedGaps': true,
      'exportAvailable': true,
    });

    expect(summary.status, SessionStatus.completedWithGaps);
    expect(summary.anchorCount, 6);
    expect(summary.hasConfirmedGaps, isTrue);
    expect(summary.exportAvailable, isTrue);
  });

  testWidgets('renders product home and real session list', (tester) async {
    final repository = _FakeSessionRepository();
    final capture = _FakeCaptureGateway();
    await tester.pumpWidget(_testApp(repository, capture));
    await tester.pumpAndSettle();

    expect(find.text('迹录时刻'), findsOneWidget);
    expect(find.text('本地模式'), findsOneWidget);
    expect(find.text('开始记录'), findsOneWidget);
    expect(find.text('现场访谈'), findsWidgets);

    await tester.tap(find.text('记录').last);
    await tester.pumpAndSettle();
    final records = find.byKey(const PageStorageKey('product-records'));
    expect(
      find.descendant(of: records, matching: find.text('现场访谈')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: records, matching: find.text('课程笔记')),
      findsOneWidget,
    );
    expect(repository.listCount, greaterThanOrEqualTo(2));
  });

  for (final initialPermission in [
    ProductPermissionStatus.notDetermined,
    ProductPermissionStatus.notGranted,
  ]) {
    testWidgets(
      'home waits for $initialPermission authorization before starting',
      (tester) async {
        final completion = Completer<void>();
        final system = _FakeProductSystemGateway(
          microphonePermission: initialPermission,
        )..requestCompletion = completion.future;
        final capture = _FakeCaptureGateway();
        await tester.pumpWidget(
          _testApp(_FakeSessionRepository(), capture, system: system),
        );
        await tester.pumpAndSettle();
        expect(system.requestedPermissions, isEmpty);
        await tester.tap(find.byKey(const Key('product-primary-action')));
        await tester.pump();
        expect(system.requestedPermissions, [ProductPermission.microphone]);
        expect(capture.startTitles, isEmpty);
        expect(
          tester
              .widget<FloatingActionButton>(
                find.byKey(const Key('product-primary-action')),
              )
              .onPressed,
          isNull,
        );
        expect(find.byKey(const Key('product-capture-page')), findsNothing);
        completion.complete();
        await tester.pumpAndSettle();
        expect(capture.startTitles, hasLength(1));
        expect(capture.current.state, 'recording');
        expect(system.requestedPermissions, [ProductPermission.microphone]);
      },
    );
  }

  testWidgets(
    'home denial does not record and a later authorized retry starts',
    (tester) async {
      final system = _FakeProductSystemGateway(
        microphonePermission: ProductPermissionStatus.notGranted,
      )..requestOutcome = ProductPermissionStatus.notGranted;
      final capture = _FakeCaptureGateway();
      await tester.pumpWidget(
        _testApp(_FakeSessionRepository(), capture, system: system),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-primary-action')));
      await tester.pumpAndSettle();
      expect(capture.startTitles, isEmpty);
      expect(find.text('未获得麦克风权限，你可以再次点击授权。'), findsOneWidget);
      system.requestOutcome = ProductPermissionStatus.authorized;
      await tester.tap(find.byKey(const Key('product-primary-action')));
      await tester.pumpAndSettle();
      expect(capture.startTitles, hasLength(1));
      expect(system.requestedPermissions, [
        ProductPermission.microphone,
        ProductPermission.microphone,
      ]);
    },
  );

  testWidgets(
    'home rechecks a revoked grant and does not misreport unavailable capture as denial',
    (tester) async {
      final system = _FakeProductSystemGateway();
      final capture = _FakeCaptureGateway()
        ..startError = UnsupportedError('no native recorder');
      await tester.pumpWidget(
        _testApp(_FakeSessionRepository(), capture, system: system),
      );
      await tester.pumpAndSettle();
      system.microphonePermission = ProductPermissionStatus.denied;
      await tester.tap(find.byKey(const Key('product-primary-action')));
      await tester.pumpAndSettle();
      expect(capture.startTitles, isEmpty);
      expect(system.requestedPermissions, isEmpty);
      expect(find.text('麦克风未授权，请在系统设置中开启。'), findsOneWidget);
      ScaffoldMessenger.of(
        tester.element(find.byKey(const Key('product-primary-action'))),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      system.microphonePermission = ProductPermissionStatus.authorized;
      await tester.tap(find.byKey(const Key('product-primary-action')));
      await tester.pumpAndSettle();
      expect(find.text('当前版本尚未接入此设备的录音功能。'), findsOneWidget);
      expect(find.text('查看权限'), findsNothing);
      expect(capture.startTitles, hasLength(1));
    },
  );

  test(
    'camera permission uses the same gate and cannot start camera after denial',
    () async {
      final system = _FakeProductSystemGateway(
        cameraPermission: ProductPermissionStatus.notDetermined,
      )..requestOutcome = ProductPermissionStatus.denied;
      final capture = _FakeCaptureGateway();
      final coordinator = AppCoordinator(
        captureGateway: capture,
        sessionRepository: _FakeSessionRepository(),
        systemGateway: system,
      );
      addTearDown(coordinator.dispose);
      await coordinator.startRecording('test');
      await expectLater(
        coordinator.openCamera(),
        throwsA(isA<ProductPermissionException>()),
      );
      expect(system.requestedPermissions, [ProductPermission.camera]);
      expect(capture.cameraCount, 0);
      expect(capture.current.state, 'recording');
    },
  );

  testWidgets('home permission read failure never starts recording', (
    tester,
  ) async {
    final system = _FakeProductSystemGateway();
    final capture = _FakeCaptureGateway();
    await tester.pumpWidget(
      _testApp(_FakeSessionRepository(), capture, system: system),
    );
    await tester.pumpAndSettle();
    system.overviewError = StateError('read failed');
    await tester.tap(find.byKey(const Key('product-primary-action')));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法读取麦克风权限，请重试。'), findsOneWidget);
    expect(capture.startTitles, isEmpty);
    expect(system.requestedPermissions, isEmpty);
  });

  testWidgets('starts and safely ends from the product flow', (tester) async {
    final repository = _FakeSessionRepository();
    final capture = _FakeCaptureGateway();
    await tester.pumpWidget(_testApp(repository, capture));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('product-primary-action')));
    await tester.pumpAndSettle();

    expect(find.text('开始一条记录'), findsNothing);
    expect(capture.startTitles, hasLength(1));
    expect(capture.startTitles.single, endsWith(' 的记录'));
    expect(find.byKey(const Key('product-capture-duration')), findsOneWidget);
    expect(find.text('已安全保存到'), findsOneWidget);

    await tester.tap(find.byKey(const Key('end-product-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-end-product-recording')));
    await tester.pumpAndSettle();

    expect(capture.stopCount, 1);
    expect(find.byKey(const Key('product-capture-complete')), findsNothing);
    expect(find.byKey(const Key('finish-product-capture')), findsNothing);
    expect(find.byKey(const Key('product-session-detail')), findsOneWidget);
    expect(find.text('产品化录音'), findsWidgets);
    expect(find.byKey(const Key('capture-saved-confirmation')), findsOneWidget);
    expect(repository.getSessionCount, 1);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-primary-action')), findsOneWidget);
    expect(find.text('开始记录'), findsOneWidget);
  });

  testWidgets(
    'local search opens late timeline hits and plays their exact samples',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final timeline = List.generate(
        65,
        (index) => TimelineItem.fromMap({
          'kind': 'transcript',
          'segmentId': 'search_segment_$index',
          'sampleOffset': index * 16000 + 53,
          'endSample': (index + 1) * 16000 + 53,
          'text': index == 61
              ? '目标 目标'
              : index == 62
              ? '目标'
              : '普通第 $index 段',
        }),
      );
      final experience = _FakeSessionExperienceGateway(timeline: timeline);
      final repository = _FakeSessionRepository(
        initialItems: [
          _summary(
            id: 'session_2',
            title: '搜索访谈',
            startedAt: DateTime(2026, 8, 30),
            durationMs: 65000,
          ),
        ],
      );
      await tester.pumpWidget(
        _testApp(repository, _FakeCaptureGateway(), experience: experience),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录').last);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('records-search-field'));
      await tester.enterText(field, '访谈');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-session-session_2')),
        findsOneWidget,
      );
      await tester.enterText(field, '目标');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final firstHit = find.byKey(
        const ValueKey('search-hit-session_2-search_segment_61:0'),
      );
      await tester.ensureVisible(firstHit);
      await tester.tap(firstHit);
      await tester.pumpAndSettle();
      expect(find.text('1/3 处命中'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('product-timeline-search_segment_61')),
        findsOneWidget,
      );
      expect(experience.lastPlaybackSample, -1);
      await tester.tap(find.byKey(const Key('detail-search-next')));
      await tester.pumpAndSettle();
      expect(find.text('2/3 处命中'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail-search-next')));
      await tester.pumpAndSettle();
      expect(find.text('3/3 处命中'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail-search-play')));
      await tester.pumpAndSettle();
      expect(experience.lastPlaybackSample, 62 * 16000 + 53);
      expect(experience.lastAnchorId, 'search_segment_62');
      await tester.tap(find.byKey(const Key('detail-search-previous')));
      await tester.pumpAndSettle();
      experience.emitPlaybackPosition(64 * 16000 + 53);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('detail-return-to-playback')),
        findsOneWidget,
      );
      expect(find.text('2/3 处命中'), findsOneWidget);
      await tester.tap(find.byKey(const Key('detail-return-to-playback')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('product-timeline-search_segment_64')),
        findsOneWidget,
      );
      await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
      expect(find.byKey(const Key('detail-search-field')), findsNothing);
    },
  );

  testWidgets(
    'detail search uses the selected text layer and remains usable at 2x',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final timeline = [
        TimelineItem.fromMap({
          'kind': 'transcript',
          'segmentId': 'layer',
          'sampleOffset': 16053,
          'endSample': 32000,
          'text': '实时原词',
        }),
      ];
      final experience = _FakeSessionExperienceGateway(
        timeline: timeline,
        refinementSnapshot: FullTextRefinementSnapshot(
          status: FullTextRefinementStatus.ready,
          document: RefinedFullTextDocument(
            sessionId: 'session_2',
            modelId: senseVoiceFullTextModelId,
            fullText: '精修新词',
            sourceAudioSamples: 32000,
            sampleRate: 16000,
            createdAt: DateTime.utc(2026, 8, 30),
            segments: const [],
            initializationMs: 0,
            decodeMs: 0,
            realTimeFactor: 0,
            peakRssBytes: 0,
            sourceTimelineFingerprint: sourceTimelineFingerprint(
              refinementTimelineSources(timeline),
            ),
            timelineProjection: const [
              RefinedTimelineSegment(
                segmentId: 'layer',
                startSample: 16053,
                endSample: 32000,
                refinedText: '精修新词',
                fallback: false,
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
      await tester.enterText(
        find.byKey(const Key('detail-search-field')),
        '精修',
      );
      await tester.pumpAndSettle();
      expect(find.text('1/1 处命中'), findsOneWidget);
      final menu = find.byKey(const Key('timeline-text-layer-menu'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('timeline-text-layer-live')));
      await tester.pumpAndSettle();
      expect(find.text('0 处命中'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('detail-search-field')),
        '实时',
      );
      await tester.pumpAndSettle();
      expect(find.text('1/1 处命中'), findsOneWidget);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail search fills the space above the playback bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _testApp(_FakeSessionRepository(), _FakeCaptureGateway()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));

    final detail = find.byKey(const Key('product-session-detail'));
    final scaffold = tester.widget<Scaffold>(
      find.ancestor(of: detail, matching: find.byType(Scaffold)).first,
    );
    final body = tester.getRect(find.byWidget(scaffold.body!));
    final timeline = tester.getRect(detail);
    expect(
      timeline.bottom,
      closeTo(body.bottom, 1),
      reason:
          'Opening an empty search must not leave unused half-screen space.',
    );
    final searchField = find.byKey(const Key('detail-search-field'));
    expect(tester.widget<TextField>(searchField).focusNode!.hasFocus, isTrue);
    await tester.enterText(searchField, '不存在的关键词');
    await tester.pumpAndSettle();
    expect(tester.getRect(detail).bottom, closeTo(body.bottom, 1));
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(tester.getRect(detail).bottom, closeTo(body.bottom, 1));
    await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
    expect(find.byKey(const Key('detail-search-field')), findsNothing);
    expect(tester.getRect(detail).bottom, closeTo(body.bottom, 1));
  });

  testWidgets(
    'detail search actions stay tappable with large text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 62);
      tester.view.viewPadding = const FakeViewPadding(top: 62, bottom: 34);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final experience = _FakeSessionExperienceGateway();
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
      await tester.enterText(
        find.byKey(const Key('detail-search-field')),
        experience.timelineItems.firstWhere((item) => item.isTranscript).text,
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final panelRect = tester.getRect(
        find.byKey(const Key('detail-search-panel')),
      );
      for (final key in [
        'detail-search-previous',
        'detail-search-next',
        'detail-search-play',
      ]) {
        expect(
          find.byKey(Key(key)).hitTestable(),
          findsOneWidget,
          reason: '$key must be usable without scrolling a hidden toolbar.',
        );
        final buttonRect = tester.getRect(find.byKey(Key(key)));
        expect(buttonRect.top, greaterThanOrEqualTo(panelRect.top));
        expect(buttonRect.bottom, lessThanOrEqualTo(panelRect.bottom));
      }
      final playGesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('detail-search-play'))),
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('detail-search-field')))
            .focusNode!
            .hasFocus,
        isTrue,
        reason: 'Do not relayout the toolbar before the first tap completes.',
      );
      await playGesture.up();
      await tester.pumpAndSettle();
      expect(
        experience.lastPlaybackSample,
        experience.timelineItems
            .firstWhere((item) => item.isTranscript)
            .sampleOffset,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('detail-search-field')))
            .focusNode!
            .hasFocus,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (refined, withSpeakers) in [
    (false, true),
    (true, true),
    (true, false),
  ]) {
    testWidgets(
      'merged turns keep late search anchors, glyph visibility and playback selection: refined=$refined speakers=$withSpeakers',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final timeline = _fullTextSearchTimeline();
        final experience = _FakeSessionExperienceGateway(timeline: timeline);
        if (withSpeakers) {
          experience.speakerSnapshot = SpeakerDiarizationSnapshot(
            status: SpeakerDiarizationStatus.ready,
            document: experience._speakerDocument(
              sessionId: 'session_2',
              requestedSpeakerCount: 1,
            ),
          );
        }
        if (refined) {
          experience.refinementSnapshot = FullTextRefinementSnapshot(
            status: FullTextRefinementStatus.ready,
            document: RefinedFullTextDocument(
              sessionId: 'session_2',
              modelId: senseVoiceFullTextModelId,
              fullText: timeline.map((i) => i.text).join(),
              sourceAudioSamples: timeline.last.endSample,
              sampleRate: 16000,
              createdAt: DateTime.utc(2026, 9, 22),
              segments: const [],
              initializationMs: 0,
              decodeMs: 0,
              realTimeFactor: 0,
              peakRssBytes: 0,
              sourceTimelineFingerprint: sourceTimelineFingerprint(
                refinementTimelineSources(timeline),
              ),
              timelineProjection: [
                for (final item in timeline)
                  RefinedTimelineSegment(
                    segmentId: item.eventId,
                    startSample: item.sampleOffset,
                    endSample: item.endSample,
                    refinedText: item.text,
                    fallback: false,
                  ),
              ],
            ),
          );
        }
        await tester.pumpWidget(
          _testApp(
            _FakeSessionRepository(),
            _FakeCaptureGateway(),
            experience: experience,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('product-session-session_2')),
        );
        await tester.pumpAndSettle();
        await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
        await tester.enterText(
          find.byKey(const Key('detail-search-field')),
          '目标',
        );
        await tester.pumpAndSettle();
        expect(find.text('1/2 处命中'), findsOneWidget);
        await tester.tap(find.byKey(const Key('detail-search-next')));
        await tester.pumpAndSettle();
        final activeRow = find.byWidgetPredicate(
          (w) => w is ProductTimelineRow && w.activeSearchRange != null,
        );
        final row = tester.widget<ProductTimelineRow>(activeRow);
        if (refined) {
          expect(row.item.sampleOffset, greaterThan(0));
          expect(
            row.item.sampleOffset,
            lessThanOrEqualTo(timeline[61].sampleOffset),
          );
          expect(row.displayText, contains('目标第61段'));
          expect(row.displayText!.length, lessThan(300));
          expect(row.speakerLabel == null, !withSpeakers);
        } else {
          expect(row.item.playbackId, timeline.first.playbackId);
          expect(row.displayText, timeline.map((i) => i.text).join(' '));
        }
        final rich = find
            .descendant(of: activeRow, matching: find.byType(RichText))
            .evaluate()
            .map((e) => e.renderObject)
            .whereType<RenderParagraph>()
            .firstWhere((r) => r.text.toPlainText() == row.displayText);
        final boxes = rich.getBoxesForSelection(
          TextSelection(
            baseOffset: row.activeSearchRange!.start,
            extentOffset: row.activeSearchRange!.end,
          ),
        );
        final rect = boxes.first.toRect().shift(
          rich.localToGlobal(Offset.zero),
        );
        final viewport = tester.getRect(
          find.byKey(const Key('product-session-detail')),
        );
        expect(rect.top, greaterThanOrEqualTo(viewport.top));
        expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
        await tester.tap(find.byKey(const Key('detail-search-play')));
        await tester.pumpAndSettle();
        expect(experience.lastPlaybackSample, timeline[61].sampleOffset);
        expect(experience.lastAnchorId, timeline[61].eventId);
        expect(tester.widget<ProductTimelineRow>(activeRow).selected, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final withSpeakers in [false, true]) {
    testWidgets(
      'full text search reveals late glyphs and plays exact anchors: speakers=$withSpeakers',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final timeline = _fullTextSearchTimeline();
        final experience = _FakeSessionExperienceGateway(timeline: timeline);
        if (withSpeakers) {
          experience.speakerSnapshot = SpeakerDiarizationSnapshot(
            status: SpeakerDiarizationStatus.ready,
            document: experience._speakerDocument(
              sessionId: 'session_2',
              requestedSpeakerCount: 2,
            ),
          );
        }
        await tester.pumpWidget(
          _testApp(
            _FakeSessionRepository(),
            _FakeCaptureGateway(),
            experience: experience,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('product-session-session_2')),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('detail-fulltext-tab')),
        );
        await tester.tap(find.byKey(const Key('detail-fulltext-tab')));
        await tester.pumpAndSettle();
        await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
        final field = find.byKey(const Key('detail-search-field'));
        expect(tester.widget<TextField>(field).decoration!.labelText, '搜索全文');
        await tester.enterText(field, '目标');
        await tester.pumpAndSettle();
        expect(find.text('1/2 处命中'), findsOneWidget);
        _expectFullTextMatchVisible(tester, '目标', 0);
        expect(experience.lastPlaybackSample, -1);
        await tester.tap(find.byKey(const Key('detail-search-next')));
        await tester.pumpAndSettle();
        expect(find.text('2/2 处命中'), findsOneWidget);
        _expectFullTextMatchVisible(tester, '目标', 1);
        await tester.tap(find.byKey(const Key('detail-search-play')));
        await tester.pumpAndSettle();
        expect(experience.lastPlaybackSample, 61 * 16000 + 53);
        expect(experience.lastAnchorId, 'full_segment_61');
        expect(tester.widget<TextField>(field).decoration!.labelText, '搜索全文');
        await tester.tap(find.byKey(const Key('detail-search-previous')));
        await tester.pumpAndSettle();
        _expectFullTextMatchVisible(tester, '目标', 0);
        await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
        expect(
          tester
              .widget<SearchableFullText>(find.byType(SearchableFullText))
              .paragraphs,
          isEmpty,
        );
        expect(find.byKey(const Key('correct-speaker-count')), findsNothing);
        final text = tester.widget<Text>(
          find.byKey(const Key('transcript-full-text-content')),
        );
        expect(text.data, timeline.map((item) => item.text).join('\n\n'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'search view switching preserves query hits and independent offsets',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: _FakeSessionExperienceGateway(
            timeline: _fullTextSearchTimeline(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
      await tester.enterText(
        find.byKey(const Key('detail-search-field')),
        '目标',
      );
      await tester.pumpAndSettle();
      final timelineOffset = _detailScrollOffset(tester);
      expect(timelineOffset, greaterThan(0));
      await _switchSearchView(tester, 'fulltext');
      await tester.tap(find.byKey(const Key('detail-search-next')));
      await tester.pumpAndSettle();
      final fullTextOffset = _detailScrollOffset(tester);
      expect(fullTextOffset, greaterThan(1000));
      expect(find.text('2/2 处命中'), findsOneWidget);
      await _switchSearchView(tester, 'timeline');
      expect(_detailScrollOffset(tester), closeTo(timelineOffset, 1));
      expect(find.text('1/2 处命中'), findsOneWidget);
      await _switchSearchView(tester, 'fulltext');
      expect(_detailScrollOffset(tester), closeTo(fullTextOffset, 1));
      expect(find.text('2/2 处命中'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('detail-search-field')))
            .controller!
            .text,
        '目标',
      );
      _expectFullTextMatchVisible(tester, '目标', 1);
    },
  );

  testWidgets(
    'full text search uses displayed refinement and disables unverified audio',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final experience = _FakeSessionExperienceGateway(
        refinementSnapshot: FullTextRefinementSnapshot(
          status: FullTextRefinementStatus.ready,
          document: RefinedFullTextDocument(
            sessionId: 'session_2',
            modelId: senseVoiceFullTextModelId,
            fullText: '仅全文存在的词。再次提到仅全文。',
            sourceAudioSamples: 100000,
            sampleRate: 16000,
            createdAt: DateTime.utc(2026, 8, 31),
            segments: const [],
            initializationMs: 0,
            decodeMs: 0,
            realTimeFactor: 0,
            peakRssBytes: 0,
          ),
        ),
      );
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('detail-fulltext-tab')));
      await tester.pumpAndSettle();
      await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
      await tester.enterText(
        find.byKey(const Key('detail-search-field')),
        '仅全文',
      );
      await tester.pumpAndSettle();
      expect(find.text('1/2 处命中'), findsOneWidget);
      expect(find.text('此处暂无可靠音频锚点，仅定位文字。'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('detail-search-play')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('detail-search-next')));
      await tester.pumpAndSettle();
      expect(find.text('2/2 处命中'), findsOneWidget);
      expect(experience.lastPlaybackSample, -1);
      final fullText = tester.widget<VirtualFullText>(
        find.byType(VirtualFullText),
      );
      expect(fullText.text, startsWith('仅全文存在的词。再次提到仅全文。'));
      expect(fullText.attachments.every((a) => a.unplaced), isTrue);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('detail-search-next')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('detail-search-play')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('full text search updates in place when refinement completes', (
    tester,
  ) async {
    final completion = Completer<FullTextRefinementSnapshot>();
    final timeline = [
      TimelineItem.fromMap({
        'kind': 'transcript',
        'segmentId': 'refining_full',
        'sampleOffset': 16053,
        'endSample': 32053,
        'text': '实时关键词',
      }),
    ];
    final experience = _FakeSessionExperienceGateway(
      timeline: timeline,
      refinementFuture: completion.future,
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-fulltext-tab')));
    await tester.pumpAndSettle();
    await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
    await tester.enterText(find.byKey(const Key('detail-search-field')), '关键词');
    await tester.pumpAndSettle();
    expect(find.text('1/1 处命中'), findsOneWidget);
    final before = _detailScrollOffset(tester);
    completion.complete(
      FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.ready,
        document: RefinedFullTextDocument(
          sessionId: 'session_2',
          modelId: senseVoiceFullTextModelId,
          fullText: '精修关键词关键词',
          sourceAudioSamples: 32053,
          sampleRate: 16000,
          createdAt: DateTime.utc(2026, 8, 31),
          segments: const [],
          initializationMs: 0,
          decodeMs: 0,
          realTimeFactor: 0,
          peakRssBytes: 0,
          sourceTimelineFingerprint: sourceTimelineFingerprint(
            refinementTimelineSources(timeline),
          ),
          timelineProjection: const [
            RefinedTimelineSegment(
              segmentId: 'refining_full',
              startSample: 16053,
              endSample: 32053,
              refinedText: '精修关键词关键词',
              fallback: false,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1/2 处命中'), findsOneWidget);
    expect(_detailScrollOffset(tester), closeTo(before, 1));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('detail-search-field')))
          .decoration!
          .labelText,
      '搜索全文',
    );
    await tester.tap(find.byKey(const Key('detail-search-next')));
    await tester.pumpAndSettle();
    _expectFullTextMatchVisible(tester, '关键词', 1);
    await tester.tap(find.byKey(const Key('detail-search-play')));
    await tester.pumpAndSettle();
    expect(experience.lastPlaybackSample, 16053);
    expect(timeline.single.text, '实时关键词');
  });

  testWidgets('detail search revalidates hits when refinement completes', (
    tester,
  ) async {
    final completion = Completer<FullTextRefinementSnapshot>();
    final timeline = [
      TimelineItem.fromMap({
        'kind': 'transcript',
        'segmentId': 'updated',
        'sampleOffset': 16053,
        'endSample': 32000,
        'text': '实时关键词',
      }),
    ];
    final experience = _FakeSessionExperienceGateway(
      timeline: timeline,
      refinementFuture: completion.future,
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    await _tapDetailMenuAction(tester, const Key('detail-search-toggle'));
    await tester.enterText(find.byKey(const Key('detail-search-field')), '关键词');
    await tester.pumpAndSettle();
    expect(find.text('1/1 处命中'), findsOneWidget);
    completion.complete(
      FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.ready,
        document: RefinedFullTextDocument(
          sessionId: 'session_2',
          modelId: senseVoiceFullTextModelId,
          fullText: '更准确的关键词和另一个关键词',
          sourceAudioSamples: 32000,
          sampleRate: 16000,
          createdAt: DateTime.utc(2026, 8, 31),
          segments: const [],
          initializationMs: 0,
          decodeMs: 0,
          realTimeFactor: 0,
          peakRssBytes: 0,
          sourceTimelineFingerprint: sourceTimelineFingerprint(
            refinementTimelineSources(timeline),
          ),
          timelineProjection: const [
            RefinedTimelineSegment(
              segmentId: 'updated',
              startSample: 16053,
              endSample: 32000,
              refinedText: '更准确的关键词和另一个关键词',
              fallback: false,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1/2 处命中'), findsOneWidget);
    expect(timeline.single.text, '实时关键词');
    await tester.tap(find.byKey(const Key('detail-search-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-search-play')));
    await tester.pumpAndSettle();
    expect(experience.lastPlaybackSample, 16053);
    expect(experience.lastAnchorId, 'updated');
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale list search hits are revalidated before navigation', (
    tester,
  ) async {
    final timeline = [
      TimelineItem.fromMap({
        'kind': 'transcript',
        'segmentId': 'stale',
        'sampleOffset': 16053,
        'endSample': 32000,
        'text': '旧关键词',
      }),
    ];
    final experience = _FakeSessionExperienceGateway(timeline: timeline);
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('记录').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('records-search-field')),
      '旧关键词',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    timeline[0] = TimelineItem.fromMap({
      'kind': 'transcript',
      'segmentId': 'stale',
      'sampleOffset': 16053,
      'endSample': 32000,
      'text': '更新后的文字',
    });
    await tester.tap(
      find.byKey(const ValueKey('search-hit-session_2-stale:0')),
    );
    await tester.pumpAndSettle();
    expect(find.text('0 处命中'), findsOneWidget);
    expect(find.text('文字已更新或暂时无法读取，请重新选择命中；原始资料没有改变。'), findsOneWidget);
    expect(experience.lastPlaybackSample, -1);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('detail-search-play')))
          .onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配内容，请尝试其他关键词。'), findsOneWidget);
  });

  testWidgets('terminal updates navigate only once while details are loading', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repository = _FakeSessionRepository(getSessionGate: gate);
    final capture = _FakeCaptureGateway();
    await tester.pumpWidget(_testApp(repository, capture));
    await tester.pumpAndSettle();

    await _startProductCapture(tester);
    await tester.tap(find.byKey(const Key('end-product-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-end-product-recording')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(repository.getSessionCount, 1);
    expect(find.text('录音已安全保存，正在打开详情…'), findsOneWidget);

    capture.emit(capture.current);
    capture.emit(capture.current);
    await tester.pump();
    expect(repository.getSessionCount, 1);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-session-detail')), findsOneWidget);
    expect(repository.getSessionCount, 1);
  });

  testWidgets('a transient detail read failure stays recoverable', (
    tester,
  ) async {
    final repository = _FakeSessionRepository(getSessionFailuresRemaining: 1);
    final capture = _FakeCaptureGateway();
    await tester.pumpWidget(_testApp(repository, capture));
    await tester.pumpAndSettle();

    await _startProductCapture(tester);
    await tester.tap(find.byKey(const Key('end-product-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-end-product-recording')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('记录已安全保存，但暂时无法打开详情。'), findsOneWidget);
    expect(find.byKey(const Key('retry-open-capture-details')), findsOneWidget);
    expect(repository.getSessionCount, 1);

    await tester.tap(find.byKey(const Key('retry-open-capture-details')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const Key('product-session-detail')), findsOneWidget);
    expect(repository.getSessionCount, 2);
  });

  testWidgets('completed with gaps opens details with a persistent warning', (
    tester,
  ) async {
    final repository = _FakeSessionRepository(
      activeSessionStatus: SessionStatus.completedWithGaps,
    );
    final capture = _FakeCaptureGateway(stopState: 'completed_with_gaps');
    await tester.pumpWidget(_testApp(repository, capture));
    await tester.pumpAndSettle();

    await _startProductCapture(tester);
    await tester.tap(find.byKey(const Key('end-product-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-end-product-recording')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('product-session-detail')), findsOneWidget);
    expect(find.text('已保全的连续资料已安全保存。'), findsOneWidget);
    expect(find.text('这条记录存在确认缺口。时间线和播放只使用连续且校验通过的原始资料。'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('这条记录存在确认缺口。时间线和播放只使用连续且校验通过的原始资料。'), findsOneWidget);
  });

  for (final language in ['zh', 'en']) {
    testWidgets(
      'one stable processing notice across stages and tabs ($language)',
      (tester) async {
        setApplicationLanguage(language);
        addTearDown(() => setApplicationLanguage('zh'));
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        tester.platformDispatcher.textScaleFactorTestValue = 1.8;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final experience = _FakeSessionExperienceGateway(
          transcriptionFinishing: true,
        );
        await tester.pumpWidget(
          _testApp(
            _FakeSessionRepository(),
            _FakeCaptureGateway(),
            experience: experience,
          ),
        );
        await tester.pumpAndSettle();
        // Enter from the saved-record list, without the just-recorded hint.
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('product-session-session_2')),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('product-session-session_2')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final notice = find.byKey(const Key('transcript-processing-banner'));
        expect(notice, findsOneWidget);
        expect(
          find.text(l10n.transcriptProcessingTranscribing),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('timeline-text-layer-status')),
          findsNothing,
        );
        final size = tester.getSize(notice);
        for (final phase in [
          TranscriptionPhase.waitingForRefinement,
          TranscriptionPhase.refining,
        ]) {
          experience.phaseOverride = phase;
          await tester.pump(const Duration(seconds: 2));
          await tester.pump();
          expect(tester.getSize(notice), size);
          expect(
            find.text(
              phase == TranscriptionPhase.refining
                  ? l10n.transcriptProcessingRefining
                  : l10n.transcriptProcessingWaiting,
            ),
            findsOneWidget,
          );
        }
        await tester.ensureVisible(
          find.byKey(const Key('detail-fulltext-tab')),
        );
        await tester.tap(find.byKey(const Key('detail-fulltext-tab')));
        await tester.pump();
        expect(notice, findsOneWidget);
        expect(
          find.byKey(const Key('full-text-refining-banner')),
          findsNothing,
        );
        expect(find.text(l10n.transcriptProcessingRefining), findsOneWidget);
        experience.phaseOverride = TranscriptionPhase.idle;
        experience.transcriptionFinishing = false;
        experience.refinementSnapshot = const FullTextRefinementSnapshot(
          status: FullTextRefinementStatus.failed,
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text(l10n.transcriptProcessingFailed), findsOneWidget);
        expect(
          find.byKey(const Key('full-text-refinement-failed')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: notice,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        expect(tester.getSize(notice), size);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('direct details show live text while SenseVoice finishes', (
    tester,
  ) async {
    final refinement = Completer<FullTextRefinementSnapshot>();
    final timeline = _FakeSessionExperienceGateway().timelineItems;
    final sources = refinementTimelineSources(timeline);
    final experience = _FakeSessionExperienceGateway(
      timeline: timeline,
      refinementFuture: refinement.future,
      transcriptionFinishing: true,
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();

    await _startProductCapture(tester);
    await tester.tap(find.byKey(const Key('end-product-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-end-product-recording')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('product-session-detail')), findsOneWidget);
    expect(find.text('正在转写，已有内容可先查看'), findsOneWidget);
    final detailList = find.descendant(
      of: find.byKey(const Key('product-session-detail')),
      matching: find.byType(ListView),
    );
    await tester.drag(detailList, const Offset(0, -520));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('这是一条产品转写。'), findsOneWidget);

    experience.transcriptionFinishing = false;
    refinement.complete(
      FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.ready,
        document: RefinedFullTextDocument(
          sessionId: 'session_active',
          modelId: senseVoiceFullTextModelId,
          fullText: '这是一条停止后自动完成的精修文字。',
          sourceAudioSamples: 2_000_000,
          sampleRate: 16000,
          createdAt: DateTime.utc(2026, 8, 30),
          segments: const [],
          initializationMs: 1,
          decodeMs: 10,
          realTimeFactor: 0.1,
          peakRssBytes: 1,
          sourceTimelineFingerprint: sourceTimelineFingerprint(sources),
          composerVersion: refinedTimelineComposerVersion,
          timelineProjection: const [
            RefinedTimelineSegment(
              segmentId: 'seg_product_1',
              startSample: 16000,
              endSample: 32000,
              refinedText: '这是一条停止后自动完成的精修文字。',
              fallback: false,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    await tester.drag(detailList, const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(find.text('正在转写，已有内容可先查看'), findsNothing);
  });

  testWidgets(
    'other-session speaker completion enables analysis without navigation',
    (tester) async {
      final activity = ValueNotifier(true);
      addTearDown(activity.dispose);
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          backgroundModelWorkActivity: activity,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: find.byKey(const Key('product-session-detail')),
        matching: find.byType(Scrollable),
      );
      final analyze = find.byKey(const Key('analyze-speakers'));
      await tester.scrollUntilVisible(analyze, 420, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(analyze).onPressed, isNull);
      activity.value = false;
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(analyze).onPressed, isNotNull);
      activity.value = true;
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(analyze).onPressed, isNull);
    },
  );

  testWidgets(
    'failed speaker rebuild keeps the old badges and exposes a retry',
    (tester) async {
      final pending = Completer<SpeakerDiarizationDocument>();
      final experience = _FakeSessionExperienceGateway(
        speakerAnalysisFuture: pending.future,
      );
      final previous = experience._speakerDocument(
        sessionId: 'session_2',
        requestedSpeakerCount: 2,
      );
      experience.speakerSnapshot = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: previous,
      );
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('correct-speaker-count')));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('confirm-speaker-analysis'));
      await tester.ensureVisible(confirm);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(experience.lastForceRebuild, isTrue);
      expect(experience.speakerDeletionCount, 0);
      expect(find.text('说话人分析 · 2 人'), findsOneWidget);
      pending.completeError(StateError('model unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('说话人分析 · 2 人'), findsOneWidget);
      expect(find.byKey(const Key('speaker-rebuild-error')), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('correct-speaker-count')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'speaker names and merges update the timeline and can be undone',
    (tester) async {
      final experience = _FakeSessionExperienceGateway();
      experience.speakerSnapshot = SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: experience._speakerDocument(
          sessionId: 'session_2',
          requestedSpeakerCount: 3,
        ),
      );
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('edit-speaker_1')));
      await tester.tap(find.byKey(const Key('edit-speaker_1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('speaker-name-input')), '小林');
      await tester.tap(find.byKey(const Key('save-speaker-name')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('speaker-name-input')), findsNothing);
      expect(
        experience.speakerSnapshot.document!.displayName('speaker_1'),
        '小林',
      );
      expect(find.text('小林'), findsWidgets);

      await tester.ensureVisible(find.byKey(const Key('edit-speaker_3')));
      await tester.tap(find.byKey(const Key('edit-speaker_3')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('speaker-merge-target')));
      await tester.tap(find.byKey(const Key('speaker-merge-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小林').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('merge-speakers')));
      await tester.tap(find.byKey(const Key('merge-speakers')));
      await tester.pumpAndSettle();
      expect(experience.speakerSnapshot.document!.speakerCount, 2);
      expect(find.byKey(const Key('edit-speaker_3')), findsNothing);
      expect(find.text('说话人分析 · 2 人'), findsOneWidget);
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const Key('speaker-result-actions'))),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('speaker-result-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('undo-speaker-edit')));
      await tester.pumpAndSettle();
      expect(experience.speakerSnapshot.document!.speakerCount, 3);
      expect(
        experience.speakerSnapshot.document!.displayName('speaker_1'),
        '小林',
      );
      expect(find.byKey(const Key('edit-speaker_3')), findsOneWidget);

      await tester.tap(find.byKey(const Key('correct-speaker-count')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('speaker-rebuild-replaces-edits')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('speaker analysis can use a known speaker count', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final experience = _FakeSessionExperienceGateway(
      timeline: List.generate(
        40,
        (index) => TimelineItem.fromMap({
          'kind': 'transcript',
          'segmentId': 'speaker_entry_$index',
          'sampleOffset': index * 32000,
          'endSample': (index + 1) * 32000,
          'text': '第 $index 段访谈内容。',
        }),
      ),
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    final detailScrollable = find.descendant(
      of: find.byKey(const Key('product-session-detail')),
      matching: find.byType(Scrollable),
    );
    final analyze = find.byKey(const Key('analyze-speakers'));
    // The first screen must offer analysis even when the timeline is long.
    expect(analyze.hitTestable(), findsOneWidget);
    await tester.tap(analyze);
    await tester.pumpAndSettle();

    expect(find.text('说话人分析'), findsWidgets);
    final confirm = find.byKey(const Key('confirm-speaker-analysis'));
    expect(confirm.hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const Key('speaker-count-selector')));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(844, 390);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speaker-count-2')).last);
    await tester.pumpAndSettle();
    expect(confirm.hitTestable(), findsOneWidget);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(experience.lastRequestedSpeakerCount, 2);
    expect(experience.speakerAnalysisCount, 1);
    await tester.fling(detailScrollable, const Offset(0, 1600), 1800);
    await tester.pumpAndSettle();
    expect(find.text('说话人分析 · 2 人'), findsOneWidget);
    expect(find.text('本地分析 · 已指定 2 人'), findsOneWidget);
  });

  testWidgets('re-entered detail reconnects to running speaker analysis', (
    tester,
  ) async {
    final analysis = Completer<SpeakerDiarizationDocument>();
    final experience = _FakeSessionExperienceGateway(
      speakerSnapshot: const SpeakerDiarizationSnapshot.processing(
        requestedSpeakerCount: 2,
      ),
      speakerAnalysisFuture: analysis.future,
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(experience.speakerAnalysisCount, 1);
    expect(experience.lastRequestedSpeakerCount, 2);
    expect(find.text('正在按 2 人分析，离开页面后仍会继续。'), findsOneWidget);
    experience.speakerSnapshot = const SpeakerDiarizationSnapshot.processing(
      requestedSpeakerCount: 2,
      message: '正在处理第 2/19 段 · 25% · 已用时 2:30',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('正在处理第 2/19 段'), findsOneWidget);
    expect(find.textContaining('关闭 App 会中断'), findsOneWidget);
    expect(experience.speakerAnalysisCount, 1);

    analysis.complete(
      SpeakerDiarizationDocument(
        sessionId: 'session_2',
        modelId: speakerDiarizationModelId,
        sourceAudioSamples: 2_000_000,
        sampleRate: 16000,
        sourceChunkFingerprint: 'sha256:test',
        createdAt: '2026-09-07T00:00:00Z',
        segments: const [
          SpeakerDiarizationSegment(
            speakerId: 'speaker_1',
            startSample: 0,
            endSample: 1_000_000,
          ),
          SpeakerDiarizationSegment(
            speakerId: 'speaker_2',
            startSample: 1_000_000,
            endSample: 2_000_000,
          ),
        ],
        processingMs: 10,
        realTimeFactor: 0.1,
        peakRssBytes: 1,
        windowCount: 1,
        requestedSpeakerCount: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('说话人分析 · 2 人'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('opens raw timeline and plays exact anchor samples', (
    tester,
  ) async {
    final speakerDocument = SpeakerDiarizationDocument(
      sessionId: 'session_2',
      modelId: speakerDiarizationModelId,
      sourceAudioSamples: 2_000_000,
      sampleRate: 16000,
      sourceChunkFingerprint: 'sha256:test',
      createdAt: '2026-09-05T00:00:00Z',
      segments: const [
        SpeakerDiarizationSegment(
          speakerId: 'speaker_1',
          startSample: 0,
          endSample: 2_000_000,
        ),
      ],
      processingMs: 10,
      realTimeFactor: 0.1,
      peakRssBytes: 1,
      windowCount: 1,
    );
    final experience = _FakeSessionExperienceGateway(
      speakerSnapshot: SpeakerDiarizationSnapshot(
        status: SpeakerDiarizationStatus.ready,
        document: speakerDocument,
      ),
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    expect(find.text('时间线'), findsNWidgets(2));
    expect(find.byKey(const Key('detail-ai-summary-tab')), findsOneWidget);
    expect(find.byKey(const Key('product-session-ai')), findsOneWidget);
    expect(find.text('说话人分析 · 1 人'), findsOneWidget);
    expect(find.text('说话人 1'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('这是一条产品转写。'),
      120,
      scrollable: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    expect(find.text('这是一条产品转写。'), findsOneWidget);
    expect(find.byKey(const Key('product-playback-slider')), findsOneWidget);
    final historyTime = find.byKey(
      const ValueKey('timeline-time-seg_product_1'),
    );
    final historyRail = find.byKey(
      const ValueKey('timeline-rail-seg_product_1'),
    );
    final historyContent = find.byKey(
      const ValueKey('product-timeline-seg_product_1'),
    );
    expect(historyTime, findsOneWidget);
    expect(historyRail, findsOneWidget);
    final historyContentRect = tester.getRect(historyContent);
    expect(
      tester.getCenter(historyTime).dx,
      inInclusiveRange(historyContentRect.left, historyContentRect.right),
    );
    expect(tester.getCenter(historyRail).dx, lessThan(historyContentRect.left));
    expect(
      tester.getBottomLeft(historyTime).dy,
      lessThan(tester.getTopLeft(find.text('这是一条产品转写。')).dy),
    );

    final initialPlaybackButton = tester.widget<IconButton>(
      find.byKey(const Key('product-playback-toggle')),
    );
    expect(initialPlaybackButton.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('product-playback-toggle')));
    await tester.pumpAndSettle();
    expect(experience.lastPlaybackSample, 0);
    expect(experience.lastAnchorId, 'session_2');
    expect(experience.lastAnchorType, 'session');
    await tester.tap(find.byKey(const Key('product-playback-stop')));
    await tester.pumpAndSettle();

    final transcriptCard = find.byKey(
      const ValueKey('product-timeline-seg_product_1'),
    );
    await tester.ensureVisible(transcriptCard);
    await tester.pumpAndSettle();
    await tester.tap(transcriptCard);
    await tester.pumpAndSettle();
    expect(experience.lastPlaybackSample, 16000);
    expect(experience.lastAnchorType, 'transcript');
    expect(find.byKey(const Key('product-playback-slider')), findsOneWidget);

    await tester.drag(
      find.descendant(
        of: find.byKey(const Key('product-session-detail')),
        matching: find.byType(ListView),
      ),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-fulltext-tab')));
    await tester.pumpAndSettle();
    expect(find.text('连续全文'), findsOneWidget);
    expect(find.textContaining('这是一条产品转写。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('play-fulltext-seg_product_1')),
      findsNothing,
    );
    expect(find.byKey(const Key('speaker-full-text-content')), findsNothing);
    expect(find.byKey(const Key('correct-speaker-count')), findsNothing);
    expect(
      tester.widget<VirtualFullText>(find.byType(VirtualFullText)).text,
      startsWith('这是一条产品转写。'),
    );

    await tester.tap(find.byKey(const Key('detail-timeline-tab')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('product-playback-toggle')));
    await tester.pumpAndSettle();
    expect(experience.pauseCount, 1);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('play-image-evt_image_product')),
      300,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('play-image-evt_image_product')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('play-image-evt_image_product')),
    );
    await tester.pumpAndSettle();
    expect(experience.lastPlaybackSample, 64000);
    expect(experience.lastAnchorType, 'image');

    final imagePreview = find.byKey(
      const ValueKey('open-image-/tmp/missing-product-image.jpg'),
    );
    await tester.ensureVisible(imagePreview);
    await tester.pumpAndSettle();
    await tester.tap(imagePreview);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('play-from-original-image')), findsOneWidget);
    expect(find.text('00:00:04'), findsOneWidget);
    await tester.tap(find.byKey(const Key('play-from-original-image')));
    await tester.pumpAndSettle();
    expect(experience.lastPlaybackSample, 64000);
    expect(experience.lastAnchorType, 'image');

    await tester.drag(
      find.byKey(const Key('product-playback-slider')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(experience.seekCount, 1);
    expect(experience.current.positionSample, greaterThan(64000));
  });

  testWidgets(
    'playback follows position samples until manual scrolling pauses it',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final timeline = List<TimelineItem>.generate(
        14,
        (index) => TimelineItem.fromMap({
          'kind': 'transcript',
          'segmentId': 'playback_segment_$index',
          'sampleOffset': index * 16000,
          'endSample': (index + 1) * 16000,
          'startMs': index * 1000,
          'endMs': (index + 1) * 1000,
          'text': '播放跟随测试第 ${index + 1} 段，保留真实 sample 锚点。',
        }),
      );
      final experience = _FakeSessionExperienceGateway(timeline: timeline);
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();

      final first = find.byKey(
        const ValueKey('product-timeline-playback_segment_0'),
      );
      await tester.scrollUntilVisible(first, 180);
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(experience.lastAnchorId, 'playback_segment_0');

      experience.emitPlaybackPosition(9 * 16000);
      await tester.pumpAndSettle();
      final ninth = find.byKey(
        const ValueKey('product-timeline-playback_segment_9'),
      );
      expect(ninth, findsOneWidget);
      expect(tester.widget<Material>(ninth).color, ProductColors.forestSoft);
      expect(experience.lastAnchorId, 'playback_segment_0');

      final detailList = find.descendant(
        of: find.byKey(const Key('product-session-detail')),
        matching: find.byType(ListView),
      );
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: detailList, matching: find.byType(Scrollable)),
      );
      await tester.drag(detailList, const Offset(0, 320));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('detail-return-to-playback')),
        findsOneWidget,
      );
      final pausedOffset = scrollable.position.pixels;

      experience.emitPlaybackPosition(12 * 16000);
      await tester.pump(const Duration(milliseconds: 300));
      expect(scrollable.position.pixels, closeTo(pausedOffset, 1));
      expect(
        find.byKey(const Key('detail-return-to-playback')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('detail-return-to-playback')));
      await tester.pumpAndSettle();
      final twelfth = find.byKey(
        const ValueKey('product-timeline-playback_segment_12'),
      );
      expect(twelfth, findsOneWidget);
      expect(tester.widget<Material>(twelfth).color, ProductColors.forestSoft);
      expect(find.byKey(const Key('detail-return-to-playback')), findsNothing);

      await tester.tap(find.byKey(const Key('product-playback-toggle')));
      await tester.pumpAndSettle();
      expect(experience.pauseCount, 1);
      expect(tester.widget<Material>(twelfth).color, ProductColors.forestSoft);
      await tester.tap(find.byKey(const Key('product-playback-toggle')));
      await tester.pumpAndSettle();
      expect(experience.resumeCount, 1);
      expect(tester.widget<Material>(twelfth).color, ProductColors.forestSoft);
    },
  );

  testWidgets(
    'playback follow materializes timeline pages beyond fifty items',
    (tester) async {
      final timeline = List<TimelineItem>.generate(
        65,
        (index) => TimelineItem.fromMap({
          'kind': 'transcript',
          'segmentId': 'paged_segment_$index',
          'sampleOffset': index * 16000,
          'endSample': (index + 1) * 16000,
          'startMs': index * 1000,
          'endMs': (index + 1) * 1000,
          'text': '分页播放跟随第 ${index + 1} 段。',
        }),
      );
      final experience = _FakeSessionExperienceGateway(timeline: timeline);
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-playback-toggle')));
      await tester.pumpAndSettle();

      experience.emitPlaybackPosition(60 * 16000);
      await tester.pumpAndSettle();

      final target = find.byKey(
        const ValueKey('product-timeline-paged_segment_60'),
      );
      expect(target, findsOneWidget);
      expect(tester.widget<Material>(target).color, ProductColors.forestSoft);
    },
  );

  testWidgets('timeline defaults to refined text and switches to live source', (
    tester,
  ) async {
    final rawTimeline = _FakeSessionExperienceGateway().timelineItems;
    final sources = refinementTimelineSources(rawTimeline);
    final experience = _FakeSessionExperienceGateway(
      timeline: rawTimeline,
      refinementSnapshot: FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.ready,
        document: RefinedFullTextDocument(
          sessionId: 'session_2',
          modelId: senseVoiceFullTextModelId,
          fullText: '这是一条精修后的产品转写。',
          sourceAudioSamples: 2_000_000,
          sampleRate: 16000,
          createdAt: DateTime.utc(2026, 8, 30),
          segments: const [],
          initializationMs: 1,
          decodeMs: 10,
          realTimeFactor: 0.1,
          peakRssBytes: 1,
          sourceTimelineFingerprint: sourceTimelineFingerprint(sources),
          composerVersion: refinedTimelineComposerVersion,
          timelineProjection: const [
            RefinedTimelineSegment(
              segmentId: 'seg_product_1',
              startSample: 16000,
              endSample: 32000,
              refinedText: '这是一条精修后的产品转写。',
              fallback: false,
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();

    expect(find.text('这是一条精修后的产品转写。'), findsOneWidget);
    expect(find.text('这是一条产品转写。'), findsNothing);
    expect(find.text('精修文字'), findsOneWidget);
    expect(find.text('SenseVoice · 本地精修 · 原始时间与音频锚点已保留'), findsOneWidget);

    await tester.tap(find.byKey(const Key('timeline-text-layer-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timeline-text-layer-live')));
    await tester.pumpAndSettle();

    expect(find.text('实时原文'), findsOneWidget);
    expect(find.text('这是一条产品转写。'), findsOneWidget);
    expect(find.text('这是一条精修后的产品转写。'), findsNothing);
    expect(find.text('录音时实时生成的原始转写'), findsOneWidget);

    final detailList = find.descendant(
      of: find.byKey(const Key('product-session-detail')),
      matching: find.byType(ListView),
    );
    await tester.drag(detailList, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('product-timeline-seg_product_1')),
    );
    await tester.pumpAndSettle();
    expect(experience.lastPlaybackSample, 16000);
    expect(experience.lastAnchorId, 'seg_product_1');
    expect(experience.lastAnchorType, 'transcript');

    await tester.drag(detailList, const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timeline-text-layer-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timeline-text-layer-refined')));
    await tester.pumpAndSettle();
    expect(find.text('这是一条精修后的产品转写。'), findsOneWidget);
  });

  for (final anchorIndex in [8, 38]) {
    testWidgets(
      'refinement completion preserves the visible source after regrouping: $anchorIndex',
      (tester) async {
        final refinementCompleter = Completer<FullTextRefinementSnapshot>();
        final timeline = List<TimelineItem>.generate(
          80,
          (index) => TimelineItem.fromMap({
            'kind': 'transcript',
            'segmentId': 'seg_scroll_$index',
            'sampleOffset': index * 16000,
            'endSample': (index + 1) * 16000,
            'startMs': index * 1000,
            'endMs': (index + 1) * 1000,
            'text': '第 ${index + 1} 段实时原文。',
          }),
        );
        final sources = refinementTimelineSources(timeline);
        final readySnapshot = FullTextRefinementSnapshot(
          status: FullTextRefinementStatus.ready,
          document: RefinedFullTextDocument(
            sessionId: 'session_2',
            modelId: senseVoiceFullTextModelId,
            fullText: '滚动锚点精修全文。',
            sourceAudioSamples: 80 * 16000,
            sampleRate: 16000,
            createdAt: DateTime.utc(2026, 8, 30),
            segments: const [],
            initializationMs: 1,
            decodeMs: 10,
            realTimeFactor: 0.1,
            peakRssBytes: 1,
            sourceTimelineFingerprint: sourceTimelineFingerprint(sources),
            composerVersion: refinedTimelineComposerVersion,
            timelineProjection: List<RefinedTimelineSegment>.generate(
              80,
              (index) => RefinedTimelineSegment(
                segmentId: 'seg_scroll_$index',
                startSample: index * 16000,
                endSample: (index + 1) * 16000,
                refinedText: index < 8
                    ? '第 ${index + 1} 段精修文字，${'补充上下文，' * 12}'
                    : '第 ${index + 1} 段精修文字。',
                fallback: false,
              ),
            ),
          ),
        );
        final experience = _FakeSessionExperienceGateway(
          timeline: timeline,
          refinementFuture: refinementCompleter.future,
        );
        await tester.pumpWidget(
          _testApp(
            _FakeSessionRepository(),
            _FakeCaptureGateway(),
            experience: experience,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('product-session-session_2')),
        );
        await tester.pumpAndSettle();

        final anchor = find.byKey(
          ValueKey('product-timeline-seg_scroll_$anchorIndex'),
        );
        await tester.scrollUntilVisible(anchor, 240);
        await tester.ensureVisible(anchor);
        await tester.pumpAndSettle();
        double glyphTop(String needle) {
          final paragraph = find
              .byType(RichText)
              .evaluate()
              .map((e) => e.renderObject)
              .whereType<RenderParagraph>()
              .singleWhere((r) => r.text.toPlainText().contains(needle));
          final start = paragraph.text.toPlainText().indexOf(needle);
          final box = paragraph
              .getBoxesForSelection(
                TextSelection(baseOffset: start, extentOffset: start + 1),
              )
              .first;
          return box.top + paragraph.localToGlobal(Offset.zero).dy;
        }

        final before = glyphTop('第 ${anchorIndex + 1} 段实时原文。');

        refinementCompleter.complete(readySnapshot);
        await tester.pumpAndSettle();

        final after = glyphTop('第 ${anchorIndex + 1} 段精修文字。');
        expect((after - before).abs(), lessThan(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('shows SenseVoice refined paragraphs in the full-text view', (
    tester,
  ) async {
    final experience = _FakeSessionExperienceGateway(
      refinementSnapshot: FullTextRefinementSnapshot(
        status: FullTextRefinementStatus.ready,
        document: RefinedFullTextDocument(
          sessionId: 'session_2',
          modelId: senseVoiceFullTextModelId,
          fullText: '这是带标点的第一段。\n\nGood morning, MomentAI.',
          sourceAudioSamples: 2000000,
          sampleRate: 16000,
          createdAt: DateTime.utc(2026, 8, 28, 15),
          segments: const [],
          initializationMs: 2800,
          decodeMs: 7000,
          realTimeFactor: 0.07,
          peakRssBytes: 800000000,
        ),
      ),
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-fulltext-tab')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('refined-full-text-card')), findsOneWidget);
    expect(find.text('SenseVoice · 本地精修'), findsOneWidget);
    final reader = tester.widget<VirtualFullText>(find.byType(VirtualFullText));
    expect(reader.text, startsWith('这是带标点的第一段。\n\nGood morning, MomentAI.'));
    expect(reader.attachments, isNotEmpty);
    expect(reader.attachments.every((a) => a.unplaced), isTrue);
  });

  testWidgets('generates verified export summary and opens sharing', (
    tester,
  ) async {
    final experience = _FakeSessionExperienceGateway();
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();

    await _tapDetailMenuAction(tester, const Key('product-session-export'));
    expect(find.text('分享与导出'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('generate-product-export')),
    );
    await tester.tap(find.byKey(const Key('generate-product-export')));
    await tester.pumpAndSettle();

    expect(experience.exportCount, 1);
    expect(find.text('2.0 MB'), findsOneWidget);
    expect(find.text('5 项'), findsWidgets);
    expect(find.text('精修文字 1 段'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('share-product-export')));
    await tester.tap(find.byKey(const Key('share-product-export')));
    await tester.pumpAndSettle();
    expect(experience.shareCount, 1);
    expect(experience.lastSharedPath, '/tmp/session_2.momentai');
  });

  testWidgets('never exposes failed capture events as playable anchors', (
    tester,
  ) async {
    final experience = _FakeSessionExperienceGateway(
      timeline: [
        TimelineItem.fromMap({
          'kind': 'captureEvent',
          'eventId': 'evt_failed_thought',
          'type': 'thought',
          'captureState': 'failed',
          'sampleOffset': 32000,
          'atMs': 2000,
          'text': '未提交的随想',
        }),
        TimelineItem.fromMap({
          'kind': 'captureEvent',
          'eventId': 'evt_failed_image',
          'type': 'image',
          'captureState': 'failed',
          'sampleOffset': 48000,
          'atMs': 3000,
        }),
      ],
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        experience: experience,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();

    expect(find.text('此现场事件未提交成功，不会作为可播放锚点。'), findsNWidgets(2));
    final thoughtCard = find.byKey(
      const ValueKey('product-timeline-evt_failed_thought'),
    );
    final thoughtTap = tester.widget<InkWell>(
      find.descendant(of: thoughtCard, matching: find.byType(InkWell)).first,
    );
    expect(thoughtTap.onTap, isNull);
    final imagePlay = tester.widget<TextButton>(
      find.byKey(const ValueKey('play-image-evt_failed_image')),
    );
    expect(imagePlay.onPressed, isNull);
    final imagePreview = tester.widget<InkWell>(
      find.byKey(const ValueKey('open-image-')),
    );
    expect(imagePreview.onTap, isNull);
    expect(experience.lastPlaybackSample, -1);
  });

  testWidgets(
    'shares text markdown and audio independently with duplicate protection',
    (tester) async {
      final transfer = _FakeTransferGateway();
      final experience = _FakeSessionExperienceGateway();
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
          transfer: transfer,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await _tapDetailMenuAction(tester, const Key('product-session-export'));
      for (final format in SessionShareFormat.values) {
        transfer.shareGate = Completer<void>();
        final button = find.byKey(Key('share-session-${format.name}'));
        await tester.tap(button);
        await tester.pump();
        await tester.tap(button);
        expect(transfer.formats.last, format);
        expect(transfer.formats.length, format.index + 1);
        expect(transfer.lastSessionId, 'session_2');
        transfer.shareGate!.complete();
        await tester.pumpAndSettle();
      }
      expect(experience.exportCount, 0);
      expect(experience.shareCount, 0);
    },
  );

  testWidgets(
    'copies the complete share text only on request with duplicate protection',
    (tester) async {
      final transfer = _FakeTransferGateway()..readTextGate = Completer<void>();
      final first = '${'甲' * 110}。';
      final second = '${'乙' * 110}。';
      final experience = _FakeSessionExperienceGateway(
        timeline: [
          TimelineItem.fromMap({
            'kind': 'transcript',
            'segmentId': 'reading_copy',
            'sampleOffset': 0,
            'endSample': 32000,
            'text': '$first$second',
          }),
        ],
      );
      final clipboardWrites = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardWrites.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          experience: experience,
          transfer: transfer,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await _tapDetailMenuAction(tester, const Key('product-session-export'));
      expect(find.text('纯文本 TXT'), findsOneWidget);
      expect(transfer.readTextCount, 0);
      expect(clipboardWrites, isEmpty);

      final copy = find.byKey(const Key('copy-session-text'));
      await tester.tap(copy);
      await tester.pump();
      await tester.tap(copy);
      expect(transfer.readTextCount, 1);
      expect(transfer.lastSessionId, 'session_2');
      expect(transfer.lastReadingText, '$first\n\n$second');
      for (final format in SessionShareFormat.values) {
        final button = tester.widget<OutlinedButton>(
          find.byKey(Key('share-session-${format.name}')),
        );
        expect(button.onPressed, isNull);
      }
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('generate-product-export')),
            )
            .onPressed,
        isNull,
      );
      expect(clipboardWrites, isEmpty);
      expect(find.byKey(const Key('session-copy-notice')), findsNothing);
      transfer.readTextGate!.complete();
      await tester.pumpAndSettle();
      expect(clipboardWrites, [transfer.shareText]);
      expect(find.text('全文已复制，可粘贴到微信发送。'), findsOneWidget);
      expect(transfer.formats, isEmpty);
      expect(experience.exportCount, 0);
      expect(experience.shareCount, 0);

      transfer.shareGate = Completer<void>();
      await tester.tap(find.byKey(const Key('share-session-text')));
      await tester.pump();
      expect(transfer.lastReadingText, '$first\n\n$second');
      expect(find.byKey(const Key('session-copy-notice')), findsNothing);
      expect(tester.widget<OutlinedButton>(copy).onPressed, isNull);
      transfer.shareGate!.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('copy failures are visible and retryable without false success', (
    tester,
  ) async {
    final transfer = _FakeTransferGateway()
      ..readTextError = PlatformException(code: 'text', message: '文字读取失败');
    var failClipboard = true;
    final clipboardWrites = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          if (failClipboard) {
            throw PlatformException(code: 'clipboard', message: '复制失败');
          }
          clipboardWrites.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        transfer: transfer,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    await _tapDetailMenuAction(tester, const Key('product-session-export'));
    final copy = find.byKey(const Key('copy-session-text'));
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(find.text('文字读取失败'), findsOneWidget);
    expect(find.byKey(const Key('session-copy-notice')), findsNothing);
    expect(clipboardWrites, isEmpty);

    transfer.readTextError = null;
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(find.text('复制失败'), findsOneWidget);
    expect(find.byKey(const Key('session-copy-notice')), findsNothing);
    expect(clipboardWrites, isEmpty);

    failClipboard = false;
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(clipboardWrites, [transfer.shareText]);
    expect(transfer.readTextCount, 3);
    expect(find.text('复制失败'), findsNothing);
    expect(find.text('全文已复制，可粘贴到微信发送。'), findsOneWidget);
  });

  testWidgets(
    'leaving detail while preparing copy does not write the clipboard',
    (tester) async {
      final transfer = _FakeTransferGateway()..readTextGate = Completer<void>();
      var clipboardWrites = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboardWrites++;
          return null;
        },
      );
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          transfer: transfer,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
      await tester.pumpAndSettle();
      await _tapDetailMenuAction(tester, const Key('product-session-export'));
      await tester.tap(find.byKey(const Key('copy-session-text')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      transfer.readTextGate!.complete();
      await tester.pumpAndSettle();
      expect(clipboardWrites, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'import requires preview confirmation and opens only one independent copy',
    (tester) async {
      final repository = _FakeSessionRepository();
      final transfer = _FakeTransferGateway(repository: repository)
        ..commitGate = Completer<void>();
      await tester.pumpWidget(
        _testApp(repository, _FakeCaptureGateway(), transfer: transfer),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-product-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('choose-session-import')));
      await tester.pumpAndSettle();
      expect(repository.items, hasLength(2));
      expect(transfer.commitCount, 0);
      expect(find.textContaining('同 ID 记录已存在'), findsOneWidget);
      expect(find.textContaining('原记录存在已确认缺口'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('confirm-session-import')),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('session-import-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-session-import')));
      await tester.pump();
      expect(transfer.commitCount, 1);
      expect(transfer.asCopy, isTrue);
      expect(find.byKey(const Key('confirm-session-import')), findsNothing);
      transfer.commitGate!.complete();
      await tester.pumpAndSettle();
      expect(repository.items, hasLength(3));
      expect(find.byKey(const Key('product-session-detail')), findsOneWidget);
      expect(find.text('导入副本'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('product-session-detail')), findsNothing);
      expect(
        find.byKey(const PageStorageKey('product-records')),
        findsOneWidget,
      );
    },
  );

  testWidgets('cancels checked import without adding records', (tester) async {
    final repository = _FakeSessionRepository();
    final transfer = _FakeTransferGateway(repository: repository);
    await tester.pumpWidget(
      _testApp(repository, _FakeCaptureGateway(), transfer: transfer),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('记录').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-product-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-session-import')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('cancel-session-import')),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('session-import-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel-session-import')));
    await tester.pumpAndSettle();
    expect(transfer.cancelCount, 1);
    expect(transfer.commitCount, 0);
    expect(repository.items, hasLength(2));
  });

  testWidgets('shows import validation failure and allows a clean retry', (
    tester,
  ) async {
    final transfer = _FakeTransferGateway()
      ..pickError = PlatformException(
        code: 'SessionTransferError',
        message: 'manifest 文件大小或 SHA-256 校验失败。',
      );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        transfer: transfer,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('记录').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-product-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-session-import')));
    await tester.pumpAndSettle();
    expect(find.textContaining('SHA-256 校验失败'), findsOneWidget);
    expect(find.byKey(const Key('confirm-session-import')), findsNothing);
    transfer.pickError = null;
    await tester.tap(find.byKey(const Key('choose-session-import')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirm-session-import')), findsOneWidget);
    expect(transfer.commitCount, 0);
  });

  testWidgets('import confirmation stays usable at 390pt and 2x text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final transfer = _FakeTransferGateway();
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        transfer: transfer,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('记录').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-product-session')));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('session-import-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('choose-session-import')),
      300,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-session-import')));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('confirm-session-import'));
    await tester.scrollUntilVisible(confirm, 300, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.getRect(confirm).right, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(transfer.cancelCount, 1);
  });

  testWidgets('share options fit at 390pt and 2x text', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final transfer = _FakeTransferGateway();
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        transfer: transfer,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    await _tapDetailMenuAction(tester, const Key('product-session-export'));
    for (final format in SessionShareFormat.values) {
      final button = find.byKey(Key('share-session-${format.name}'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getRect(button).right, lessThanOrEqualTo(390));
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    expect(transfer.formats, SessionShareFormat.values);
    final copy = find.byKey(const Key('copy-session-text'));
    await tester.ensureVisible(copy);
    await tester.pumpAndSettle();
    expect(copy.hitTestable(), findsOneWidget);
    expect(tester.getRect(copy).right, lessThanOrEqualTo(390));
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(transfer.readTextCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('commits photo thought and bookmark before showing them', (
    tester,
  ) async {
    final capture = _FakeCaptureGateway();
    await tester.pumpWidget(_testApp(_FakeSessionRepository(), capture));
    await tester.pumpAndSettle();
    await _startProductCapture(tester);

    await tester.tap(find.byKey(const Key('product-capture-bookmark')));
    await tester.pumpAndSettle();
    expect(capture.bookmarkCount, 1);
    final bookmarkCard = find.byKey(
      const ValueKey('product-timeline-evt_bookmark_1'),
    );
    await tester.scrollUntilVisible(bookmarkCard, 180);
    expect(bookmarkCard, findsOneWidget);
    expect(
      find.descendant(of: bookmarkCard, matching: find.text('重点')),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(const Key('product-capture-thought')),
    );
    await tester.tap(find.byKey(const Key('product-capture-thought')));
    await tester.pumpAndSettle();
    final saveThought = tester.widget<FilledButton>(
      find.byKey(const Key('save-product-thought')),
    );
    expect(saveThought.onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('product-thought-input')),
      '先确认用户真正需要什么。',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('save-product-thought')));
    await tester.tap(find.byKey(const Key('save-product-thought')));
    await tester.pumpAndSettle();
    expect(capture.thoughts, ['先确认用户真正需要什么。']);
    await tester.scrollUntilVisible(find.text('先确认用户真正需要什么。'), 180);
    expect(find.text('先确认用户真正需要什么。'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('product-capture-photo')));
    await tester.tap(find.byKey(const Key('product-capture-photo')));
    await tester.pumpAndSettle();
    expect(find.text('拍照时，录音会继续'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-open-product-camera')));
    await tester.pumpAndSettle();
    expect(capture.cameraCount, 1);
    final imageCard = find.byKey(
      const ValueKey('product-timeline-evt_image_1'),
    );
    await tester.scrollUntilVisible(imageCard, 180);
    expect(imageCard, findsOneWidget);
    expect(
      find.descendant(of: imageCard, matching: find.text('照片')),
      findsOneWidget,
    );
  });

  testWidgets('shows committed live transcripts as read-only full text', (
    tester,
  ) async {
    final capture = _FakeCaptureGateway();
    capture.timelineItems.add(
      TimelineItem.fromMap({
        'kind': 'transcript',
        'segmentId': 'capture_transcript_1',
        'sampleOffset': 16000,
        'startMs': 1000,
        'endMs': 2000,
        'text': '这是一段已提交的实时转写。',
      }),
    );
    await tester.pumpWidget(_testApp(_FakeSessionRepository(), capture));
    await tester.pumpAndSettle();
    await _startProductCapture(tester);

    await tester.drag(
      find.byKey(const Key('product-capture-page')),
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('product-timeline-capture_transcript_1')),
      findsOneWidget,
    );
    final captureTime = find.byKey(
      const ValueKey('timeline-time-capture_transcript_1'),
    );
    final captureRail = find.byKey(
      const ValueKey('timeline-rail-capture_transcript_1'),
    );
    final captureContent = find.byKey(
      const ValueKey('product-timeline-capture_transcript_1'),
    );
    expect(captureTime, findsOneWidget);
    expect(captureRail, findsOneWidget);
    final captureContentRect = tester.getRect(captureContent);
    expect(
      tester.getCenter(captureTime).dx,
      inInclusiveRange(captureContentRect.left, captureContentRect.right),
    );
    expect(tester.getCenter(captureRail).dx, lessThan(captureContentRect.left));
    expect(
      tester.getBottomLeft(captureTime).dy,
      lessThan(tester.getTopLeft(find.text('这是一段已提交的实时转写。')).dy),
    );
    await tester.ensureVisible(find.byKey(const Key('capture-fulltext-tab')));
    await tester.tap(find.byKey(const Key('capture-fulltext-tab')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('product-capture-page')),
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    expect(find.text('已提交转写'), findsOneWidget);
    expect(find.text('这是一段已提交的实时转写。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('play-fulltext-capture_transcript_1')),
      findsNothing,
    );
    final fullText = tester.widget<SelectableText>(
      find.byKey(const Key('transcript-full-text-content')),
    );
    expect(fullText.data, '这是一段已提交的实时转写。');
    expect(fullText.data, isNot(contains('00:')));
    expect(find.byKey(const Key('product-capture-photo')), findsOneWidget);
    expect(find.byKey(const Key('end-product-recording')), findsOneWidget);
  });

  testWidgets('live timeline follows new items until the user scrolls away', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final capture = _FakeCaptureGateway();
    capture.timelineItems.addAll(
      List.generate(8, (index) => _captureTranscript(index)),
    );
    await tester.pumpWidget(_testApp(_FakeSessionRepository(), capture));
    await tester.pumpAndSettle();
    await _startProductCapture(tester);

    final captureList = find.byKey(const Key('product-capture-page'));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: captureList, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    expect(scrollable.position.extentAfter, lessThan(1));

    scrollable.position.jumpTo(
      (scrollable.position.maxScrollExtent - 320).clamp(
        0,
        scrollable.position.maxScrollExtent,
      ),
    );
    ScrollUpdateNotification(
      metrics: scrollable.position,
      context: tester.element(captureList),
      dragDetails: DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: Offset(0, 20),
        primaryDelta: 20,
      ),
      scrollDelta: -20,
    ).dispatch(tester.element(captureList));
    await tester.pump();
    expect(scrollable.position.extentAfter, greaterThan(24));
    expect(find.byKey(const Key('capture-jump-to-latest')), findsOneWidget);
    final pausedOffset = scrollable.position.pixels;

    capture.timelineItems.add(_captureTranscript(8));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(scrollable.position.pixels, closeTo(pausedOffset, 1));
    expect(find.byKey(const Key('capture-jump-to-latest')), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture-jump-to-latest')));
    await tester.pumpAndSettle();
    expect(scrollable.position.extentAfter, lessThan(1));
    expect(
      find.byKey(const ValueKey('product-timeline-capture_transcript_8')),
      findsOneWidget,
    );
  });

  testWidgets('leaves capture for home without stopping active recording', (
    tester,
  ) async {
    final capture = _FakeCaptureGateway();
    await tester.pumpWidget(_testApp(_FakeSessionRepository(), capture));
    await tester.pumpAndSettle();
    await _startProductCapture(tester);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('返回首页并继续录音？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-background-recording')));
    await tester.pumpAndSettle();

    expect(capture.stopCount, 0);
    expect(find.text('继续记录'), findsOneWidget);
    expect(find.text('正在录音'), findsWidgets);

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('product-model-version')),
      220,
    );
    await tester.tap(find.byKey(const Key('product-model-version')));
    await tester.pumpAndSettle();
    expect(find.textContaining('录音正在进行'), findsOneWidget);
  });

  testWidgets(
    'Android interruption offers explicit resume without changing iOS behavior',
    (tester) async {
      final capture = _FakeCaptureGateway(startState: 'interrupted');
      await tester.pumpWidget(_testApp(_FakeSessionRepository(), capture));
      await tester.pumpAndSettle();
      await _startProductCapture(tester);
      expect(find.text('等待恢复'), findsOneWidget);
      capture.current = PoCSnapshot.fromMap({
        'state': 'interrupted',
        'canResumeAfterInterruption': true,
        'sessionId': 'session_active',
        'directory': '/tmp/session_active',
        'capturedMs': 2000,
        'committedMs': 2000,
      });
      capture.emit(capture.current);
      await tester.pumpAndSettle();
      expect(find.text('继续录音'), findsOneWidget);
      await tester.tap(find.byKey(const Key('toggle-product-recording-pause')));
      await tester.pumpAndSettle();
      expect(capture.recordingResumeCount, 1);
      expect(capture.current.sessionId, 'session_active');
      expect(capture.current.state, 'recording');
    },
  );

  testWidgets('disables atomic capture actions while audio is interrupted', (
    tester,
  ) async {
    final capture = _FakeCaptureGateway(startState: 'interrupted');
    await tester.pumpWidget(_testApp(_FakeSessionRepository(), capture));
    await tester.pumpAndSettle();
    await _startProductCapture(tester);

    expect(find.text('恢复后可继续添加'), findsOneWidget);
    final photoInkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const Key('product-capture-photo')),
        matching: find.byType(InkWell),
      ),
    );
    final thoughtInkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const Key('product-capture-thought')),
        matching: find.byType(InkWell),
      ),
    );
    final bookmarkInkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const Key('product-capture-bookmark')),
        matching: find.byType(InkWell),
      ),
    );
    expect(photoInkWell.onTap, isNull);
    expect(thoughtInkWell.onTap, isNull);
    expect(bookmarkInkWell.onTap, isNull);
  });

  testWidgets(
    'user pause freezes the sample anchor and resume keeps the same session',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final capture = _FakeCaptureGateway();
      await tester.pumpWidget(_testApp(_FakeSessionRepository(), capture));
      await tester.pumpAndSettle();
      await _startProductCapture(tester);

      final sessionId = capture.current.sessionId;
      // Pausing first flushes the in-memory tail, so the durable pause anchor
      // must equal the last captured sample rather than the prior high-water.
      final sampleAnchor = capture.current.capturedMs * 16;
      await tester.tap(find.byKey(const Key('toggle-product-recording-pause')));
      await tester.pumpAndSettle();

      expect(capture.recordingPauseCount, 1);
      expect(capture.current.state, 'paused');
      expect(capture.current.sessionId, sessionId);
      expect(capture.current.capturedMs, capture.current.committedMs);
      expect(find.text('录音已暂停 · 音频时间不会前进'), findsOneWidget);
      expect(find.text('继续录音'), findsOneWidget);
      expect(capture.timelineItems.last.sampleOffset, sampleAnchor);

      final bookmarkInkWell = tester.widget<InkWell>(
        find.descendant(
          of: find.byKey(const Key('product-capture-bookmark')),
          matching: find.byType(InkWell),
        ),
      );
      expect(bookmarkInkWell.onTap, isNotNull);
      await tester.tap(find.byKey(const Key('product-capture-bookmark')));
      await tester.pumpAndSettle();
      expect(capture.bookmarkCount, 1);
      expect(capture.timelineItems.last.sampleOffset, sampleAnchor);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('返回首页并保持暂停？'), findsOneWidget);
      await tester.tap(find.text('留在这里'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('toggle-product-recording-pause')));
      await tester.pumpAndSettle();

      expect(capture.recordingResumeCount, 1);
      expect(capture.current.state, 'recording');
      expect(capture.current.sessionId, sessionId);
      expect(capture.current.committedMs * 16, sampleAnchor);
      final pauseEvents = capture.timelineItems.where(
        (item) =>
            item.type == 'user_pause_began' || item.type == 'user_pause_ended',
      );
      expect(pauseEvents, hasLength(2));
      expect(pauseEvents.map((item) => item.sampleOffset).toSet(), {
        sampleAnchor,
      });
      expect(
        find.descendant(
          of: find.byKey(const Key('toggle-product-recording-pause')),
          matching: find.text('暂停录音'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('a paused recording can still stop and save', (tester) async {
    final capture = _FakeCaptureGateway();
    await tester.pumpWidget(_testApp(_FakeSessionRepository(), capture));
    await tester.pumpAndSettle();
    await _startProductCapture(tester);

    await tester.tap(find.byKey(const Key('toggle-product-recording-pause')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('end-product-recording')));
    await tester.pumpAndSettle();

    expect(find.textContaining('音频当前已暂停'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-end-product-recording')));
    await tester.pumpAndSettle();

    expect(capture.stopCount, 1);
    expect(capture.current.state, 'completed');
    expect(capture.current.rpoMs, 0);
  });

  testWidgets('keeps capture controls usable at 390pt width', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(_FakeSessionRepository(), _FakeCaptureGateway()),
    );
    await tester.pumpAndSettle();
    await _startProductCapture(tester);

    expect(find.byKey(const Key('product-capture-photo')), findsOneWidget);
    expect(find.byKey(const Key('product-capture-thought')), findsOneWidget);
    expect(find.byKey(const Key('product-capture-bookmark')), findsOneWidget);
    expect(find.byKey(const Key('end-product-recording')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the product shell usable at 390pt width', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(_FakeSessionRepository(), _FakeCaptureGateway()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-primary-action')), findsOneWidget);

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.text('迹录时刻占用空间'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('meets labeled target, iOS target, and contrast guidelines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _testApp(_FakeSessionRepository(), _FakeCaptureGateway()),
    );
    await tester.pumpAndSettle();

    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));

    await tester.tap(find.text('记录').last);
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));

    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));

    await tester.tap(find.text('首页').last);
    await tester.pumpAndSettle();
    await _startProductCapture(tester);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });

  testWidgets('keeps core tasks usable with 2x Dynamic Type at 390pt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final capture = _FakeCaptureGateway();
    capture.timelineItems.addAll([
      _captureTranscript(0),
      TimelineItem.fromMap({
        'kind': 'captureEvent',
        'eventId': 'capture_image_accessibility',
        'type': 'image',
        'captureState': 'committed',
        'sampleOffset': 48000,
        'atMs': 3000,
        'assetPath': '/tmp/missing-capture-accessibility-image.jpg',
        'wallTime': '2026-08-30T12:00:03Z',
      }),
    ]);

    await tester.pumpWidget(_testApp(_FakeSessionRepository(), capture));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-primary-action')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('记录').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const PageStorageKey('product-records')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-session-detail')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('play-image-evt_image_product')),
      220,
      scrollable: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.text('迹录时刻占用空间'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('首页').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('product-primary-action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-capture-page')), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('product-capture-page')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('product-timeline-capture_image_accessibility'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('end-product-recording')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps recovery and denied permissions usable at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    const candidate = RecoveryCandidate(
      sessionId: 'session_accessibility_recovery',
      directory: '/tmp/session_accessibility_recovery',
      state: 'recording',
      committedMs: 52000,
      rpoMs: 1200,
      rpoPass: true,
      title: '需要安全恢复的现场访谈',
      imageCommittedCount: 3,
      imagePendingCount: 1,
    );
    final system = _FakeProductSystemGateway(
      microphonePermission: ProductPermissionStatus.denied,
      cameraPermission: ProductPermissionStatus.restricted,
    );
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(
          recoveryScans: const [
            [candidate],
          ],
        ),
        system: system,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('查看并恢复'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('查看并恢复'));
    await tester.tap(find.text('查看并恢复'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-recovery-page')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('recover-product-session')),
      220,
    );
    expect(find.byKey(const Key('recover-product-session')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('product-microphone-permission')),
      220,
    );
    await tester.ensureVisible(
      find.byKey(const Key('product-microphone-permission')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('product-microphone-permission')));
    await tester.pumpAndSettle();
    expect(system.openSettingsCount, 1);
  });

  testWidgets('omits diagnostics when no internal route is injected', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(_FakeSessionRepository(), _FakeCaptureGateway()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open-diagnostics')), findsNothing);
    expect(find.text('开发者控制台'), findsNothing);
  });

  testWidgets('opens diagnostics only when an internal route is injected', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        _FakeSessionRepository(),
        _FakeCaptureGateway(),
        diagnosticsBuilder: (_) =>
            const Scaffold(body: Center(child: Text('内部诊断占位页'))),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('open-diagnostics')),
      220,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-diagnostics')));
    await tester.pumpAndSettle();

    expect(find.text('内部诊断占位页'), findsOneWidget);
  });

  testWidgets('renames, exports before deletion, and then deletes atomically', (
    tester,
  ) async {
    final repository = _FakeSessionRepository();
    final experience = _FakeSessionExperienceGateway();
    await tester.pumpWidget(
      _testApp(repository, _FakeCaptureGateway(), experience: experience),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();

    await _openDetailManageSheet(tester);
    await tester.tap(find.byKey(const Key('rename-product-session')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rename-product-session-input')),
      '新版现场访谈',
    );
    await tester.tap(find.byKey(const Key('save-product-session-name')));
    await tester.pumpAndSettle();
    expect(repository.renameCount, 1);
    expect(find.text('新版现场访谈'), findsWidgets);

    await _openDetailManageSheet(tester);
    await tester.tap(find.byKey(const Key('delete-product-session')));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除这条记录？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('export-before-product-delete')));
    await tester.pumpAndSettle();
    expect(experience.exportCount, 1);
    expect(repository.deleteCount, 0);
    expect(find.text('分享与导出'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await _openDetailManageSheet(tester);
    await tester.tap(find.byKey(const Key('delete-product-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-product-delete')));
    await tester.pumpAndSettle();
    expect(repository.deleteCount, 1);
    expect(find.byKey(const Key('product-session-detail')), findsNothing);
    expect(find.text('新版现场访谈'), findsNothing);
  });

  testWidgets('preserves rename input when the native write fails', (
    tester,
  ) async {
    final repository = _FakeSessionRepository(failRename: true);
    await tester.pumpWidget(_testApp(repository, _FakeCaptureGateway()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    await _openDetailManageSheet(tester);
    await tester.tap(find.byKey(const Key('rename-product-session')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rename-product-session-input')),
      '不会丢失的名称',
    );
    await tester.tap(find.byKey(const Key('save-product-session-name')));
    await tester.pumpAndSettle();

    expect(find.text('名称未修改，输入内容已保留；请重试。'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('rename-product-session-input')),
          )
          .controller
          ?.text,
      '不会丢失的名称',
    );
  });

  testWidgets('keeps the session when permanent deletion fails', (
    tester,
  ) async {
    final repository = _FakeSessionRepository(failDelete: true);
    await tester.pumpWidget(_testApp(repository, _FakeCaptureGateway()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('product-session-session_2')));
    await tester.pumpAndSettle();
    await _openDetailManageSheet(tester);
    await tester.tap(find.byKey(const Key('delete-product-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-product-delete')));
    await tester.pumpAndSettle();

    expect(repository.deleteCount, 1);
    expect(find.byKey(const Key('product-session-detail')), findsOneWidget);
    expect(find.text('删除失败，原始记录仍保留；请重试。'), findsOneWidget);
    expect(
      repository.items.any((item) => item.sessionId == 'session_2'),
      isTrue,
    );
  });

  testWidgets('settings opens the offline license viewer', (tester) async {
    await tester.pumpWidget(
      _testApp(_FakeSessionRepository(), _FakeCaptureGateway()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('open-licenses')),
      220,
    );
    await tester.tap(find.byKey(const Key('open-licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.textContaining('Logo © 2026 hohu.org.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'permission read failure ends loading and can recover on resume',
    (tester) async {
      final system = _FakeProductSystemGateway()
        ..overviewError = StateError('native unavailable');
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          system: system,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('product-camera-permission')),
        220,
      );
      expect(find.text('读取失败'), findsNWidgets(2));
      expect(find.text('正在读取系统状态'), findsNothing);
      system.overviewError = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      // Removing the error banner changes which sliver children are mounted.
      await tester.scrollUntilVisible(
        find.byKey(const Key('product-camera-permission')),
        -120,
      );
      expect(find.text('已允许'), findsNWidgets(2));
      expect(find.text('读取失败'), findsNothing);
    },
  );

  testWidgets(
    'Android requests only the selected permission and refreshes the result',
    (tester) async {
      final system = _FakeProductSystemGateway(
        microphonePermission: ProductPermissionStatus.notGranted,
        cameraPermission: ProductPermissionStatus.notGranted,
      );
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          system: system,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('product-camera-permission')),
        220,
      );
      expect(find.text('授权'), findsNWidgets(2));
      expect(system.requestedPermissions, isEmpty);
      expect(system.openSettingsCount, 0);
      await tester.tap(find.byKey(const Key('product-microphone-permission')));
      await tester.pumpAndSettle();
      expect(system.openSettingsCount, 0);
      expect(system.requestedPermissions, [ProductPermission.microphone]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      system.microphonePermission = ProductPermissionStatus.authorized;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('已允许'), findsOneWidget);
      expect(find.text('授权'), findsOneWidget);
    },
  );

  testWidgets(
    'permission request prevents duplicate prompts and handles denial',
    (tester) async {
      final completion = Completer<void>();
      final system =
          _FakeProductSystemGateway(
              microphonePermission: ProductPermissionStatus.notGranted,
              cameraPermission: ProductPermissionStatus.notGranted,
            )
            ..requestOutcome = ProductPermissionStatus.denied
            ..requestCompletion = completion.future;
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          system: system,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('product-camera-permission')),
        220,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const Key('product-camera-permission'))),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-camera-permission')));
      await tester.pump();
      expect(find.text('等待授权'), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('product-microphone-permission')));
      expect(system.requestedPermissions, [ProductPermission.camera]);
      completion.complete();
      await tester.pumpAndSettle();
      expect(find.text('系统设置'), findsOneWidget);
      expect(find.text('授权'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('product-camera-permission')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('product-camera-permission')));
      await tester.pumpAndSettle();
      expect(system.openSettingsCount, 1);
      expect(system.requestedPermissions, [ProductPermission.camera]);
    },
  );

  testWidgets('permission request cancellation allows a later retry', (
    tester,
  ) async {
    final system = _FakeProductSystemGateway(
      microphonePermission: ProductPermissionStatus.notGranted,
    )..requestCompletion = Future<void>.value();
    await tester.pumpWidget(
      _testApp(_FakeSessionRepository(), _FakeCaptureGateway(), system: system),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('product-microphone-permission')),
      220,
    );
    final completion = Completer<void>();
    system.requestCompletion = completion.future;
    await tester.tap(find.byKey(const Key('product-microphone-permission')));
    await tester.pump();
    completion.completeError(PlatformException(code: 'permission_cancelled'));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法申请权限，请稍后重试。'), findsOneWidget);
    expect(find.text('等待授权'), findsNothing);
    system.requestCompletion = null;
    await tester.tap(find.byKey(const Key('product-microphone-permission')));
    await tester.pumpAndSettle();
    expect(system.requestedPermissions.length, 2);
    expect(find.text('授权'), findsNothing);
  });

  testWidgets('shows real permissions and opens iOS settings when denied', (
    tester,
  ) async {
    final system = _FakeProductSystemGateway(
      microphonePermission: ProductPermissionStatus.denied,
      cameraPermission: ProductPermissionStatus.restricted,
    );
    await tester.pumpWidget(
      _testApp(_FakeSessionRepository(), _FakeCaptureGateway(), system: system),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('product-model-version')),
      220,
    );
    expect(find.text('普通话 · 均衡'), findsOneWidget);
    await tester.tap(find.byKey(const Key('product-model-version')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('local-models-page')), findsOneWidget);
    expect(find.textContaining('模型中心尚未连接'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('product-microphone-permission')),
      220,
    );
    expect(find.text('系统设置'), findsWidgets);
    await tester.tap(find.byKey(const Key('product-microphone-permission')));
    await tester.pumpAndSettle();
    expect(system.openSettingsCount, 1);
  });

  testWidgets(
    'model center downloads, installs and safely switches realtime model',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final modelRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('momentai-model-widget-'),
      ))!;
      addTearDown(
        () => tester.runAsync(() => modelRoot.delete(recursive: true)),
      );
      final switcher = _WidgetModelSwitcher();
      final models = _modelCenterForWidget(modelRoot)
        ..attachRuntimeSwitcher(switcher);
      await tester.runAsync(models.initialize);
      await tester.runAsync(models.dismissRefinementSuggestion);
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          localModelManager: models,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('设置').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.scrollUntilVisible(
        find.byKey(const Key('product-model-version')),
        220,
      );
      await tester.tap(find.byKey(const Key('product-model-version')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final refinementCard = find.byKey(
        const Key('local-model-$senseVoiceRefinementModelId'),
      );
      await tester.scrollUntilVisible(refinementCard, 220);
      expect(find.text('全文精修'), findsOneWidget);
      expect(find.text('多语种精修'), findsOneWidget);
      expect(find.text('SenseVoice Small · 本地运行'), findsOneWidget);
      final balancedButton = find.byKey(
        const Key('primary-model-$balancedRealtimeModelId'),
      );
      await tester.scrollUntilVisible(balancedButton, 260);
      await tester.ensureVisible(balancedButton);
      await tester.pump();
      await tester.tap(balancedButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('固定字节数、归档 SHA-256'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(() => models.download(balancedRealtimeModelId));
      await tester.pump();
      expect(tester.widget<FilledButton>(balancedButton).onPressed, isNotNull);
      expect(find.text('设为使用'), findsOneWidget);

      expect(find.byKey(const Key('switch-realtime-model')), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(balancedButton);
        for (
          var i = 0;
          i < 100 &&
              models.snapshot.activeRealtimeModelId != balancedRealtimeModelId;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.fling(
        find.byKey(const Key('local-models-page')),
        const Offset(0, 1200),
        2000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(
          of: find.byKey(const Key('current-local-model')),
          matching: find.text('当前实时转写模型：普通话 · 均衡'),
        ),
        findsOneWidget,
      );
      expect(
        models.snapshot.stateFor(balancedRealtimeModelId)?.phase,
        LocalModelInstallPhase.active,
      );

      final balancedActions = find.byKey(
        const Key('model-actions-$balancedRealtimeModelId'),
      );
      await tester.scrollUntilVisible(balancedActions, 220);
      await tester.tap(balancedActions);
      await tester.pumpAndSettle();
      expect(find.textContaining('当前使用中，请先切换模型'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      final lightweightButton = find.byKey(
        const Key('primary-model-$lightweightRealtimeModelId'),
      );
      await tester.scrollUntilVisible(lightweightButton, -260);
      await tester.ensureVisible(lightweightButton);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(lightweightButton);
        for (
          var i = 0;
          i < 100 &&
              models.snapshot.activeRealtimeModelId !=
                  lightweightRealtimeModelId;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(switcher.modelIds, contains(lightweightRealtimeModelId));
      expect(models.snapshot.activeRealtimeModelId, lightweightRealtimeModelId);

      await tester.scrollUntilVisible(balancedActions, 240);
      await tester.ensureVisible(balancedActions);
      await tester.pumpAndSettle();
      await tester.tap(balancedActions);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除模型'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('confirm-model-remove-$balancedRealtimeModelId')),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => models.remove(balancedRealtimeModelId));
      await tester.pumpAndSettle();
      expect(
        models.snapshot.stateFor(balancedRealtimeModelId)?.phase,
        LocalModelInstallPhase.unavailable,
      );
    },
  );

  testWidgets(
    'home shows missing refinement as a modal and hides after later',
    (tester) async {
      final modelRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('momentai-model-suggestion-'),
      ))!;
      addTearDown(
        () => tester.runAsync(() => modelRoot.delete(recursive: true)),
      );
      final models = _modelCenterForWidget(modelRoot)
        ..attachRuntimeSwitcher(_WidgetModelSwitcher());
      final partial = File(
        '${modelRoot.path}/downloads/'
        '$senseVoiceRefinementModelId-test-v1.tar.bz2.part',
      );
      await tester.runAsync(() async {
        await partial.parent.create(recursive: true);
        await partial.writeAsBytes(const [9, 8], flush: true);
      });
      await tester.runAsync(models.initialize);
      await tester.pumpWidget(
        _testApp(
          _FakeSessionRepository(),
          _FakeCaptureGateway(),
          localModelManager: models,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(models.snapshot.initialized, isTrue);
      expect(models.snapshot.shouldSuggestRefinementDownload, isTrue);
      expect(
        find.byKey(const Key('refinement-model-suggestion-dialog')),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('继续安装全文精修'), findsOneWidget);
      expect(find.textContaining('已保留'), findsOneWidget);
      await tester.tap(find.byKey(const Key('dismiss-refinement-suggestion')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byKey(const Key('refinement-model-suggestion-dialog')),
        findsNothing,
      );
      expect(models.snapshot.refinementSuggestionDismissed, isTrue);
    },
  );

  test('model operations block new recording and recovery mutation', () async {
    final capture = _FakeCaptureGateway();
    final coordinator = AppCoordinator(
      captureGateway: capture,
      sessionRepository: _FakeSessionRepository(),
      systemGateway: _FakeProductSystemGateway(),
      modelOperationActive: () => true,
    );
    addTearDown(coordinator.dispose);

    await expectLater(
      coordinator.startRecording('不应开始'),
      throwsA(isA<StateError>()),
    );
    expect(capture.startTitles, isEmpty);
    await expectLater(
      coordinator.recoverSession(
        const RecoveryCandidate(
          sessionId: 'blocked',
          directory: '/tmp/blocked',
          state: 'recording',
          committedMs: 0,
          rpoMs: 0,
          rpoPass: true,
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(capture.recoverCount, 0);
  });

  testWidgets('revalidates, recovers, catches up ASR, and opens details', (
    tester,
  ) async {
    const candidate = RecoveryCandidate(
      sessionId: 'session_recovered',
      directory: '/tmp/session_recovered',
      state: 'recording',
      committedMs: 12000,
      rpoMs: 1200,
      rpoPass: true,
      title: '待恢复访谈',
      imageCommittedCount: 2,
      imagePendingCount: 1,
    );
    final recovered = _summary(
      id: 'session_recovered',
      title: '待恢复访谈',
      startedAt: DateTime(2026, 8, 17, 20),
      durationMs: 12000,
      imageCount: 2,
    );
    final repository = _FakeSessionRepository(initialItems: [recovered]);
    final capture = _FakeCaptureGateway(
      recoveryScans: const [
        [candidate],
        [candidate],
        [],
      ],
      recoveryOutcome: const RecoveryOutcome(
        sessionId: 'session_recovered',
        directory: '/tmp/session_recovered',
        state: 'completed',
        committedMs: 12000,
        observedMs: 12000,
        rpoMs: 0,
        rpoPass: true,
        quarantinedFiles: 0,
        corruptChunks: 0,
        discardedSamples: 0,
        imageCommittedCount: 2,
        imageFailedCount: 0,
        capturePendingCount: 0,
      ),
    );
    final experience = _FakeSessionExperienceGateway();
    await tester.pumpWidget(
      _testApp(repository, capture, experience: experience),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('查看并恢复'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-recovery-page')), findsOneWidget);
    expect(find.text('最大可能缺口'), findsOneWidget);
    expect(find.text('1 张'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recover-product-session')));
    await tester.pumpAndSettle();

    expect(capture.recoverCount, 1);
    expect(experience.recoveryTranscriptionCount, 1);
    expect(find.byKey(const Key('product-session-detail')), findsOneWidget);
    expect(find.textContaining('恢复完成，原始资料连续'), findsOneWidget);
  });

  testWidgets('revalidates a recovery candidate before mutating native data', (
    tester,
  ) async {
    const staleCandidate = RecoveryCandidate(
      sessionId: 'session_stale',
      directory: '/tmp/session_stale',
      state: 'recording',
      committedMs: 1000,
      rpoMs: 0,
      rpoPass: true,
    );
    final capture = _FakeCaptureGateway(
      recoveryScans: [
        const [staleCandidate],
        const [],
      ],
    );
    final coordinator = AppCoordinator(
      captureGateway: capture,
      sessionRepository: _FakeSessionRepository(),
      systemGateway: _FakeProductSystemGateway(),
    );
    addTearDown(coordinator.dispose);

    await coordinator.initialize();
    expect(coordinator.recoveryCandidates, const [staleCandidate]);

    await expectLater(
      coordinator.recoverSession(staleCandidate),
      throwsA(isA<StateError>()),
    );
    expect(capture.recoverCount, 0);
    expect(coordinator.recoveryCandidates, isEmpty);
  });
}

List<TimelineItem> _fullTextSearchTimeline() => List.generate(
  65,
  (index) => TimelineItem.fromMap({
    'kind': 'transcript',
    'segmentId': 'full_segment_$index',
    'sampleOffset': index * 16000 + 53,
    'endSample': (index + 1) * 16000 + 53,
    'text':
        '${index == 5 || index == 61 ? '目标' : '普通'}第$index段，'
        '${'用于验证长全文的原始文字。' * 3}',
  }),
);

Future<void> _tapDetailMenuAction(WidgetTester tester, Key actionKey) async {
  await tester.tap(find.byKey(const Key('product-session-actions')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(actionKey));
  await tester.pumpAndSettle();
}

Future<void> _openDetailManageSheet(WidgetTester tester) =>
    _tapDetailMenuAction(tester, const Key('detail-manage-session'));

Future<void> _switchSearchView(WidgetTester tester, String view) async {
  await tester.tap(find.byKey(const Key('detail-search-view-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('detail-search-view-$view')));
  await tester.pumpAndSettle();
}

double _detailScrollOffset(WidgetTester tester) => tester
    .widget<ListView>(
      find.descendant(
        of: find.byKey(const Key('product-session-detail')),
        matching: find.byType(ListView),
      ),
    )
    .controller!
    .offset;

void _expectFullTextMatchVisible(WidgetTester tester, String query, int index) {
  final finder = find.byType(SearchableFullText);
  final widget = tester.widget<SearchableFullText>(finder);
  final state = tester.state<SearchableFullTextState>(finder);
  final range = searchTextRanges(widget.text, query)[index];
  final rect = state.matchRect(range);
  expect(rect, isNotNull);
  final viewport = tester.getRect(
    find.byKey(const Key('product-session-detail')),
  );
  expect(rect!.top, greaterThanOrEqualTo(viewport.top));
  expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
}

Widget _testApp(
  SessionRepository repository,
  CaptureGateway capture, {
  SessionExperienceGateway? experience,
  ProductSystemGateway? system,
  WidgetBuilder? diagnosticsBuilder,
  SessionTransferGateway? transfer,
  LocalModelManager? localModelManager,
  ValueNotifier<bool>? backgroundModelWorkActivity,
}) => MaterialApp(
  locale: applicationLocale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  theme: buildProductTheme(),
  home: MomentAIProductShell(
    captureGateway: capture,
    sessionRepository: repository,
    sessionExperienceGateway: experience ?? _FakeSessionExperienceGateway(),
    systemGateway: system ?? _FakeProductSystemGateway(),
    diagnosticsBuilder: diagnosticsBuilder,
    transferGateway: transfer ?? _FakeTransferGateway(),
    localModelManager: localModelManager,
    backgroundModelWorkActivity: backgroundModelWorkActivity,
  ),
);

Future<void> _startProductCapture(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('product-primary-action')));
  await tester.pumpAndSettle();
}

TimelineItem _captureTranscript(int index) => TimelineItem.fromMap({
  'kind': 'transcript',
  'segmentId': 'capture_transcript_$index',
  'sampleOffset': index * 32000,
  'endSample': (index + 1) * 32000,
  'startMs': index * 2000,
  'endMs': (index + 1) * 2000,
  'text': '这是录音中的第 ${index + 1} 段实时转写内容。',
});

class _FakeTransferGateway implements SessionTransferGateway {
  _FakeTransferGateway({this.repository});
  final _FakeSessionRepository? repository;
  final formats = <SessionShareFormat>[];
  Completer<void>? shareGate;
  Completer<void>? readTextGate;
  Completer<void>? commitGate;
  String? lastSessionId;
  String? lastReadingText;
  Object? pickError;
  Object? readTextError;
  int readTextCount = 0;
  final shareText =
      '分享标题\n文字来源：SenseVoice 精修\n⚠️ 已确认缺口\n\n${List.filled(1000, '完整中文段落 🎙️\n').join()}\n随想\n保留最后一句。';
  int commitCount = 0;
  int cancelCount = 0;
  bool? asCopy;

  @override
  Future<void> shareSession(
    String sessionId,
    SessionShareFormat format, {
    String? readingText,
  }) async {
    lastReadingText = readingText;
    lastSessionId = sessionId;
    formats.add(format);
    await shareGate?.future;
  }

  @override
  Future<String> readSessionText(
    String sessionId, {
    String? readingText,
  }) async {
    lastReadingText = readingText;
    lastSessionId = sessionId;
    readTextCount++;
    await readTextGate?.future;
    if (readTextError != null) throw readTextError!;
    return shareText;
  }

  @override
  Future<SessionImportPreview?> pickImport() async {
    if (pickError != null) throw pickError!;
    return SessionImportPreview(
      token: 'checked-token',
      sessionId: 'session_2',
      title: '待导入记录',
      startedAt: DateTime(2026, 8, 31, 21),
      stoppedAt: DateTime(2026, 8, 31, 21, 2, 23),
      durationSamples: 228_853,
      archiveBytes: 800000,
      timelineItemCount: 6,
      hasConfirmedGaps: true,
      conflict: true,
    );
  }

  @override
  Future<SessionSummary> commitImport(
    String token, {
    required bool asCopy,
  }) async {
    expect(token, 'checked-token');
    commitCount++;
    this.asCopy = asCopy;
    await commitGate?.future;
    final session = _summary(
      id: 'session_import_copy',
      title: '导入副本',
      startedAt: DateTime(2026, 8, 31, 21),
      durationMs: 143000,
    );
    repository?.items.add(session);
    return session;
  }

  @override
  Future<void> cancelImport() async {
    cancelCount++;
  }
}

class _FakeSessionRepository implements SessionRepository {
  _FakeSessionRepository({
    List<SessionSummary>? initialItems,
    this.failRename = false,
    this.failDelete = false,
    this.getSessionGate,
    this.activeSessionStatus = SessionStatus.completed,
    this.getSessionFailuresRemaining = 0,
  }) : items =
           initialItems ??
           [
             _summary(
               id: 'session_2',
               title: '现场访谈',
               startedAt: DateTime(2026, 8, 17, 15),
               durationMs: 65000,
               imageCount: 2,
             ),
             _summary(
               id: 'session_1',
               title: '课程笔记',
               startedAt: DateTime(2026, 8, 16, 9),
               durationMs: 125000,
               bookmarkCount: 3,
             ),
           ];

  var listCount = 0;
  final List<SessionSummary> items;
  final bool failRename;
  final bool failDelete;
  final Completer<void>? getSessionGate;
  final SessionStatus activeSessionStatus;
  int getSessionFailuresRemaining;
  var renameCount = 0;
  var deleteCount = 0;
  var getSessionCount = 0;

  @override
  Future<void> deleteSession(String sessionId) async {
    deleteCount += 1;
    if (failDelete) throw StateError('delete failed');
    items.removeWhere((session) => session.sessionId == sessionId);
  }

  @override
  Future<SessionSummary> getSession(String sessionId) async {
    getSessionCount += 1;
    await getSessionGate?.future;
    if (getSessionFailuresRemaining > 0) {
      getSessionFailuresRemaining -= 1;
      throw StateError('transient detail read failure');
    }
    if (sessionId == 'session_active') {
      return _summary(
        id: sessionId,
        title: '产品化录音',
        startedAt: DateTime(2026, 8, 17, 16),
        durationMs: 2000,
        status: activeSessionStatus,
      );
    }
    return items.singleWhere((session) => session.sessionId == sessionId);
  }

  @override
  Future<List<SessionSummary>> listSessions() async {
    listCount += 1;
    return List.unmodifiable(items);
  }

  @override
  Future<SessionSummary> renameSession(String sessionId, String title) async {
    renameCount += 1;
    if (failRename) throw StateError('rename failed');
    final index = items.indexWhere((item) => item.sessionId == sessionId);
    final current = items[index];
    final renamed = _copySummary(current, title: title.trim());
    items[index] = renamed;
    return renamed;
  }

  @override
  Future<StorageOverview> storageOverview() async => const StorageOverview(
    appUsedBytes: 24 * 1024 * 1024,
    availableBytes: 12 * 1024 * 1024 * 1024,
    totalBytes: 128 * 1024 * 1024 * 1024,
    minimumRequiredBytes: 512 * 1024 * 1024,
    canStartRecording: true,
    sessionCount: 2,
  );

  @override
  Stream<List<SessionSummary>> watchSessions() => const Stream.empty();
}

class _FakeCaptureGateway implements CaptureGateway {
  _FakeCaptureGateway({
    List<List<RecoveryCandidate>>? recoveryScans,
    this.startState = 'recording',
    this.stopState = 'completed',
    this.recoveryOutcome,
  }) : _recoveryScans = recoveryScans ?? const [];

  final _events = StreamController<PoCSnapshot>.broadcast(sync: true);
  PoCSnapshot current = PoCSnapshot.idle();
  final startTitles = <String>[];
  Object? startError;
  final List<List<RecoveryCandidate>> _recoveryScans;
  final String startState;
  final String stopState;
  final RecoveryOutcome? recoveryOutcome;
  var stopCount = 0;
  var recordingPauseCount = 0;
  var recordingResumeCount = 0;
  var recoverCount = 0;
  var scanCount = 0;
  var cameraCount = 0;
  var bookmarkCount = 0;
  final thoughts = <String>[];
  final timelineItems = <TimelineItem>[];

  void emit(PoCSnapshot snapshot) => _events.add(snapshot);

  @override
  Stream<PoCSnapshot> get events => _events.stream;

  @override
  Future<RecoveryOutcome> recover(String directory) async {
    recoverCount += 1;
    return recoveryOutcome ??
        RecoveryOutcome(
          sessionId: directory.split('/').last,
          directory: directory,
          state: 'completed',
          committedMs: 1000,
          observedMs: 1000,
          rpoMs: 0,
          rpoPass: true,
          quarantinedFiles: 0,
          corruptChunks: 0,
          discardedSamples: 0,
          imageCommittedCount: 0,
          imageFailedCount: 0,
          capturePendingCount: 0,
        );
  }

  @override
  Future<Map<Object?, Object?>> openCamera() async {
    cameraCount += 1;
    timelineItems.add(
      TimelineItem.fromMap({
        'kind': 'captureEvent',
        'eventId': 'evt_image_$cameraCount',
        'type': 'image',
        'captureState': 'committed',
        'sampleOffset': current.committedMs * 16,
        'atMs': current.committedMs,
        'assetPath': 'assets/image_$cameraCount.jpg',
      }),
    );
    return {
      'photoCount': 1,
      'firstMediaMs': current.committedMs,
      'lastMediaMs': current.committedMs,
    };
  }

  @override
  Future<Map<Object?, Object?>> addBookmark() async {
    bookmarkCount += 1;
    timelineItems.add(
      TimelineItem.fromMap({
        'kind': 'captureEvent',
        'eventId': 'evt_bookmark_$bookmarkCount',
        'type': 'bookmark',
        'captureState': 'committed',
        'sampleOffset': current.committedMs * 16,
        'atMs': current.committedMs,
      }),
    );
    return {
      'eventId': 'evt_bookmark_$bookmarkCount',
      'atMs': current.committedMs,
    };
  }

  @override
  Future<Map<Object?, Object?>> addThought(String text) async {
    thoughts.add(text.trim());
    timelineItems.add(
      TimelineItem.fromMap({
        'kind': 'captureEvent',
        'eventId': 'evt_thought_${thoughts.length}',
        'type': 'thought',
        'captureState': 'committed',
        'sampleOffset': current.committedMs * 16,
        'atMs': current.committedMs,
        'payload': {'text': text.trim(), 'source': 'user_text'},
      }),
    );
    return {
      'eventId': 'evt_thought_${thoughts.length}',
      'atMs': current.committedMs,
      'text': text.trim(),
    };
  }

  @override
  Future<List<RecoveryCandidate>> scanRecovery() async {
    final index = scanCount;
    scanCount += 1;
    if (index >= _recoveryScans.length) return const [];
    return _recoveryScans[index];
  }

  @override
  Future<PoCSnapshot> snapshot() async => current;

  @override
  Future<List<TimelineItem>> timeline(String directory) async =>
      List.unmodifiable(timelineItems);

  @override
  Future<PoCSnapshot> start({required String title}) async {
    startTitles.add(title);
    if (startError != null) throw startError!;
    current = PoCSnapshot(
      state: startState,
      capturedMs: 2000,
      committedMs: 1800,
      rpoMs: 200,
      chunkCount: 2,
      asrMode: 'normal',
      asrQueueDepth: 0,
      asrDroppedBuffers: 0,
      asrDroppedSamples: 0,
      asrFailedSamples: 0,
      directory: '/tmp/session_active',
      sessionId: 'session_active',
    );
    return current;
  }

  @override
  Future<PoCSnapshot> stop() async {
    stopCount += 1;
    current = PoCSnapshot(
      state: stopState,
      capturedMs: current.capturedMs,
      committedMs: current.capturedMs,
      rpoMs: 0,
      chunkCount: current.chunkCount,
      asrMode: current.asrMode,
      asrQueueDepth: 0,
      asrDroppedBuffers: current.asrDroppedBuffers,
      asrDroppedSamples: current.asrDroppedSamples,
      asrFailedSamples: current.asrFailedSamples,
      directory: current.directory,
      sessionId: current.sessionId,
      event: 'session_stopped',
    );
    return current;
  }

  @override
  Future<PoCSnapshot> pause() async {
    recordingPauseCount += 1;
    current = PoCSnapshot(
      state: 'paused',
      capturedMs: current.capturedMs,
      committedMs: current.capturedMs,
      rpoMs: 0,
      chunkCount: current.chunkCount,
      asrMode: current.asrMode,
      asrQueueDepth: current.asrQueueDepth,
      asrDroppedBuffers: current.asrDroppedBuffers,
      asrDroppedSamples: current.asrDroppedSamples,
      asrFailedSamples: current.asrFailedSamples,
      directory: current.directory,
      sessionId: current.sessionId,
      event: 'user_pause_began',
      userPauseCount: current.userPauseCount + 1,
      totalUserPausedMs: current.totalUserPausedMs,
    );
    timelineItems.add(
      TimelineItem.fromMap({
        'kind': 'event',
        'type': 'user_pause_began',
        'sampleOffset': current.committedMs * 16,
        'atMs': current.committedMs,
        'payload': const {'pause_id': 'pause_test'},
      }),
    );
    return current;
  }

  @override
  Future<PoCSnapshot> resume() async {
    recordingResumeCount += 1;
    current = PoCSnapshot(
      state: 'recording',
      capturedMs: current.capturedMs,
      committedMs: current.committedMs,
      rpoMs: 0,
      chunkCount: current.chunkCount,
      asrMode: current.asrMode,
      asrQueueDepth: current.asrQueueDepth,
      asrDroppedBuffers: current.asrDroppedBuffers,
      asrDroppedSamples: current.asrDroppedSamples,
      asrFailedSamples: current.asrFailedSamples,
      directory: current.directory,
      sessionId: current.sessionId,
      event: 'user_pause_ended',
      userPauseCount: current.userPauseCount,
      totalUserPausedMs: current.totalUserPausedMs + 1000,
    );
    timelineItems.add(
      TimelineItem.fromMap({
        'kind': 'event',
        'type': 'user_pause_ended',
        'sampleOffset': current.committedMs * 16,
        'atMs': current.committedMs,
        'payload': const {
          'pause_id': 'pause_test',
          'duration_ms': 1000,
          'end_reason': 'resumed',
        },
      }),
    );
    return current;
  }
}

class _FakeProductSystemGateway implements ProductSystemGateway {
  _FakeProductSystemGateway({
    this.microphonePermission = ProductPermissionStatus.authorized,
    this.cameraPermission = ProductPermissionStatus.authorized,
  });

  ProductPermissionStatus microphonePermission;
  ProductPermissionStatus cameraPermission;
  Object? overviewError;
  var openSettingsCount = 0;
  final requestedPermissions = <ProductPermission>[];
  ProductPermissionStatus requestOutcome = ProductPermissionStatus.authorized;
  Future<void>? requestCompletion;

  @override
  Future<void> requestPermission(ProductPermission permission) async {
    requestedPermissions.add(permission);
    await requestCompletion;
    if (permission == ProductPermission.microphone) {
      microphonePermission = requestOutcome;
    } else {
      cameraPermission = requestOutcome;
    }
  }

  @override
  Future<ProductSystemOverview> overview() async {
    if (overviewError != null) throw overviewError!;
    return ProductSystemOverview(
      microphonePermission: microphonePermission,
      cameraPermission: cameraPermission,
      appVersion: '1.0.0',
      buildNumber: '1',
      modelId: 'sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30',
    );
  }

  @override
  Future<void> openSystemSettings() async {
    openSettingsCount += 1;
  }
}

class _FakeSessionExperienceGateway implements SessionExperienceGateway {
  _FakeSessionExperienceGateway({
    List<TimelineItem>? timeline,
    this.refinementSnapshot = const FullTextRefinementSnapshot.unavailable(),
    this.refinementFuture,
    this.transcriptionFinishing = false,
    this.speakerSnapshot = const SpeakerDiarizationSnapshot.unavailable(),
    this.speakerAnalysisFuture,
  }) : timelineItems = timeline ?? _defaultTimeline();

  final _playbackEvents = StreamController<PlaybackSnapshot>.broadcast(
    sync: true,
  );
  final List<TimelineItem> timelineItems;
  FullTextRefinementSnapshot refinementSnapshot;
  final Future<FullTextRefinementSnapshot>? refinementFuture;
  final Future<SpeakerDiarizationDocument>? speakerAnalysisFuture;
  bool transcriptionFinishing;
  TranscriptionPhase? phaseOverride;

  @override
  TranscriptionPhase transcriptionPhase(String sessionId) =>
      phaseOverride ??
      (transcriptionFinishing
          ? TranscriptionPhase.transcribing
          : TranscriptionPhase.idle);
  SpeakerDiarizationSnapshot speakerSnapshot;
  PlaybackSnapshot current = PlaybackSnapshot.idle();
  var lastPlaybackSample = -1;
  var lastAnchorId = '';
  var lastAnchorType = '';
  var pauseCount = 0;
  var resumeCount = 0;
  var seekCount = 0;
  var stopCount = 0;
  var exportCount = 0;
  var shareCount = 0;
  var recoveryTranscriptionCount = 0;
  var manualRefinementCount = 0;
  bool lastRefinementForce = false;
  Completer<void>? manualRefinementGate;
  @override
  Future<void> refineFullText({
    required String sessionId,
    required String directory,
    bool forceRebuild = false,
  }) async {
    manualRefinementCount++;
    lastRefinementForce = forceRebuild;
    transcriptionFinishing = true;
    phaseOverride = TranscriptionPhase.refining;
    try {
      await manualRefinementGate?.future;
    } finally {
      transcriptionFinishing = false;
      phaseOverride = TranscriptionPhase.idle;
    }
  }

  var speakerAnalysisCount = 0;
  int? lastRequestedSpeakerCount;
  bool lastForceRebuild = false;
  int speakerDeletionCount = 0;
  String? lastSharedPath;

  void emitPlaybackPosition(int positionSample, {String state = 'playing'}) {
    current = _playback(
      state: state,
      directory: current.directory,
      positionSample: positionSample,
      anchorId: current.anchorId,
      anchorType: current.anchorType,
    );
    _playbackEvents.add(current);
  }

  @override
  Stream<PlaybackSnapshot> get playbackEvents => _playbackEvents.stream;

  @override
  bool isTranscriptionFinishing(String sessionId) => transcriptionFinishing;

  @override
  Future<FullTextRefinementSnapshot> fullTextRefinement(
    String directory,
  ) async =>
      refinementFuture == null ? refinementSnapshot : await refinementFuture!;

  @override
  Future<void> recoverTranscription({
    required String sessionId,
    required String directory,
  }) async {
    recoveryTranscriptionCount += 1;
  }

  @override
  Future<List<TimelineItem>> timeline(String directory) async =>
      List.unmodifiable(timelineItems);

  @override
  Future<SpeakerDiarizationSnapshot> speakerDiarization(
    String directory,
  ) async => speakerSnapshot;

  @override
  Future<SpeakerDiarizationDocument> analyzeSpeakers({
    required String sessionId,
    required String directory,
    int? requestedSpeakerCount,
    bool forceRebuild = false,
  }) async {
    speakerAnalysisCount += 1;
    lastRequestedSpeakerCount = requestedSpeakerCount;
    lastForceRebuild = forceRebuild;
    final provided = speakerAnalysisFuture;
    final document = provided == null
        ? _speakerDocument(
            sessionId: sessionId,
            requestedSpeakerCount: requestedSpeakerCount,
          )
        : await provided;
    speakerSnapshot = SpeakerDiarizationSnapshot(
      status: SpeakerDiarizationStatus.ready,
      document: document,
      requestedSpeakerCount: document.requestedSpeakerCount,
    );
    return document;
  }

  SpeakerDiarizationDocument _speakerDocument({
    required String sessionId,
    required int? requestedSpeakerCount,
  }) {
    final count = requestedSpeakerCount ?? 1;
    return SpeakerDiarizationDocument(
      sessionId: sessionId,
      modelId: speakerDiarizationModelId,
      sourceAudioSamples: 2_000_000,
      sampleRate: 16000,
      sourceChunkFingerprint: 'sha256:test',
      createdAt: '2026-09-05T00:00:00Z',
      segments: List.generate(
        count,
        (index) => SpeakerDiarizationSegment(
          speakerId: 'speaker_${index + 1}',
          startSample: index * (2_000_000 ~/ count),
          endSample: (index + 1) * (2_000_000 ~/ count),
        ),
      ),
      processingMs: 10,
      realTimeFactor: 0.1,
      peakRssBytes: 1,
      windowCount: 1,
      requestedSpeakerCount: requestedSpeakerCount,
    );
  }

  @override
  Future<SpeakerDiarizationDocument> editSpeakers(
    String directory, {
    required SpeakerDiarizationDocument expectedDocument,
    required SpeakerEdit edit,
  }) async {
    final document = expectedDocument.applyEdit(edit);
    speakerSnapshot = SpeakerDiarizationSnapshot(
      status: SpeakerDiarizationStatus.ready,
      document: document,
      requestedSpeakerCount: document.requestedSpeakerCount,
    );
    return document;
  }

  @override
  Future<void> deleteSpeakerDiarization(String directory) async {
    speakerDeletionCount++;
    speakerSnapshot = const SpeakerDiarizationSnapshot.unavailable();
  }

  @override
  Future<PlaybackSnapshot> startPlayback(
    String directory, {
    required int sampleOffset,
    required String anchorId,
    required String anchorType,
  }) async {
    lastPlaybackSample = sampleOffset;
    lastAnchorId = anchorId;
    lastAnchorType = anchorType;
    current = _playback(
      state: 'playing',
      directory: directory,
      positionSample: sampleOffset,
      anchorId: anchorId,
      anchorType: anchorType,
    );
    return current;
  }

  PlaybackSoundSettings soundSettings = const PlaybackSoundSettings();

  @override
  Future<PlaybackSoundSettings> getPlaybackSound() async => soundSettings;

  @override
  Future<PlaybackSoundSettings> setPlaybackSound(
    PlaybackSoundSettings settings,
  ) async => soundSettings = settings;

  @override
  Future<PlaybackSnapshot> pausePlayback() async {
    pauseCount += 1;
    current = _copyPlayback(state: 'paused');
    return current;
  }

  @override
  Future<PlaybackSnapshot> resumePlayback() async {
    resumeCount += 1;
    current = _copyPlayback(state: 'playing');
    return current;
  }

  @override
  Future<PlaybackSnapshot> seekPlayback(int sampleOffset) async {
    seekCount += 1;
    current = _playback(
      state: current.state,
      directory: current.directory,
      positionSample: sampleOffset,
      anchorId: current.anchorId,
      anchorType: current.anchorType,
    );
    return current;
  }

  @override
  Future<PlaybackSnapshot> stopPlayback() async {
    stopCount += 1;
    current = PlaybackSnapshot.idle();
    return current;
  }

  @override
  Future<SessionExportResult> exportSession(String directory) async {
    exportCount += 1;
    return const SessionExportResult(
      sessionId: 'session_2',
      exportId: 'export_product',
      directory: '/tmp/export_product',
      archivePath: '/tmp/session_2.momentai',
      markdownPath: '/tmp/export_product/session.md',
      jsonPath: '/tmp/export_product/session.json',
      jsonlPath: '/tmp/export_product/timeline.jsonl',
      audioPath: '/tmp/export_product/audio/session.wav',
      manifestPath: '/tmp/export_product/manifest.json',
      audioSamples: 2_000_000,
      durationMs: 125000,
      timelineItemCount: 5,
      transcriptCount: 1,
      imageCount: 1,
      payloadFileCount: 6,
      archiveByteCount: 2 * 1024 * 1024,
      archiveSha256:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      canonicalTextStatus: 'ready',
      canonicalTextLayer: 'refined',
      refinedTranscriptCount: 1,
    );
  }

  @override
  Future<void> shareExport(String archivePath) async {
    shareCount += 1;
    lastSharedPath = archivePath;
  }

  PlaybackSnapshot _copyPlayback({required String state}) => _playback(
    state: state,
    directory: current.directory,
    positionSample: current.positionSample,
    anchorId: current.anchorId,
    anchorType: current.anchorType,
  );

  static PlaybackSnapshot _playback({
    required String state,
    required String directory,
    required int positionSample,
    required String anchorId,
    required String anchorType,
  }) => PlaybackSnapshot(
    state: state,
    sessionId: 'session_2',
    directory: directory,
    sampleRate: 16000,
    positionSample: positionSample,
    durationSamples: 2_000_000,
    positionMs: positionSample * 1000 ~/ 16000,
    durationMs: 125000,
    anchorId: anchorId,
    anchorType: anchorType,
    peakBufferedBytes: 65536,
    outputPortType: 'Speaker',
    outputPortName: 'Speaker',
    outputVolume: 0.7,
    signalGainDb: 16,
    limiterThreshold: 0.92,
  );

  static List<TimelineItem> _defaultTimeline() => [
    TimelineItem.fromMap({
      'kind': 'event',
      'sequence': 1,
      'type': 'session_started',
      'sampleOffset': 0,
      'atMs': 0,
    }),
    TimelineItem.fromMap({
      'kind': 'transcript',
      'segmentId': 'seg_product_1',
      'sampleOffset': 16000,
      'endSample': 32000,
      'startMs': 1000,
      'endMs': 2000,
      'text': '这是一条产品转写。',
    }),
    TimelineItem.fromMap({
      'kind': 'captureEvent',
      'eventId': 'evt_thought_product',
      'type': 'thought',
      'captureState': 'committed',
      'sampleOffset': 32000,
      'atMs': 2000,
      'text': '这是现场随想。',
      'payload': {'text': '这是现场随想。'},
    }),
    TimelineItem.fromMap({
      'kind': 'captureEvent',
      'eventId': 'evt_bookmark_product',
      'type': 'bookmark',
      'captureState': 'committed',
      'sampleOffset': 48000,
      'atMs': 3000,
    }),
    TimelineItem.fromMap({
      'kind': 'captureEvent',
      'eventId': 'evt_image_product',
      'type': 'image',
      'captureState': 'committed',
      'sampleOffset': 64000,
      'atMs': 4000,
      'assetPath': '/tmp/missing-product-image.jpg',
      'wallTime': '2026-08-17T12:00:04Z',
    }),
  ];
}

SessionSummary _copySummary(SessionSummary source, {required String title}) =>
    SessionSummary(
      sessionId: source.sessionId,
      directory: source.directory,
      title: title,
      status: source.status,
      startedAt: source.startedAt,
      stoppedAt: source.stoppedAt,
      durationSamples: source.durationSamples,
      durationMs: source.durationMs,
      chunkCount: source.chunkCount,
      transcriptCount: source.transcriptCount,
      imageCount: source.imageCount,
      thoughtCount: source.thoughtCount,
      bookmarkCount: source.bookmarkCount,
      recoveryCount: source.recoveryCount,
      hasConfirmedGaps: source.hasConfirmedGaps,
      exportAvailable: source.exportAvailable,
    );

SessionSummary _summary({
  required String id,
  required String title,
  required DateTime startedAt,
  required int durationMs,
  int imageCount = 0,
  int bookmarkCount = 0,
  SessionStatus status = SessionStatus.completed,
}) => SessionSummary(
  sessionId: id,
  directory: '/tmp/$id',
  title: title,
  status: status,
  startedAt: startedAt,
  stoppedAt: startedAt.add(Duration(milliseconds: durationMs)),
  durationSamples: durationMs * 16,
  durationMs: durationMs,
  chunkCount: durationMs ~/ 1000,
  transcriptCount: 2,
  imageCount: imageCount,
  thoughtCount: 0,
  bookmarkCount: bookmarkCount,
  recoveryCount: 0,
  hasConfirmedGaps: status == SessionStatus.completedWithGaps,
  exportAvailable: true,
);

LocalModelManager _modelCenterForWidget(Directory root) {
  final payloads = <String, List<int>>{
    'encoder': [1],
    'decoder': [2],
    'joiner': [3],
    'tokens': [4],
    'model': [5],
  };
  final archive = [9, 8, 7, 6];
  LocalModelFileManifest file(String logicalName) => LocalModelFileManifest(
    logicalName: logicalName,
    archivePath: logicalName,
    assetPath: 'asset/$logicalName',
    byteCount: payloads[logicalName]!.length,
    sha256: sha256.convert(payloads[logicalName]!).toString(),
  );

  final archiveHash = sha256.convert(archive).toString();
  LocalModelManifest downloadable({
    required String id,
    required String name,
    required LocalModelKind kind,
    required List<LocalModelFileManifest> files,
    String? technicalName,
  }) => LocalModelManifest(
    id: id,
    version: 'test-v1',
    name: name,
    description: '测试模型',
    kind: kind,
    languages: const ['普通话'],
    qualityLabel: '测试',
    installedByteCount: files.length,
    minimumMemoryBytes: 1,
    license: 'test',
    technicalName: technicalName,
    downloadSources: [
      LocalModelDownloadSource(
        name: '测试源',
        uri: Uri.parse('https://example.test/$id.tar.bz2'),
      ),
    ],
    archiveByteCount: archive.length,
    archiveSha256: archiveHash,
    files: files,
  );

  return LocalModelManager(
    catalog: [
      LocalModelManifest(
        id: lightweightRealtimeModelId,
        version: 'test-v1',
        name: '普通话 · 轻量',
        description: '测试模型',
        kind: LocalModelKind.realtime,
        languages: const ['普通话'],
        qualityLabel: '轻量',
        installedByteCount: 4,
        minimumMemoryBytes: 1,
        license: 'test',
        bundled: true,
        files: [
          file('encoder'),
          file('decoder'),
          file('joiner'),
          file('tokens'),
        ],
      ),
      downloadable(
        id: senseVoiceRefinementModelId,
        name: '多语种精修',
        technicalName: 'SenseVoice Small · 本地运行',
        kind: LocalModelKind.refinement,
        files: [file('model'), file('tokens')],
      ),
      downloadable(
        id: balancedRealtimeModelId,
        name: '普通话 · 均衡',
        kind: LocalModelKind.realtime,
        files: [
          file('encoder'),
          file('decoder'),
          file('joiner'),
          file('tokens'),
        ],
      ),
    ],
    rootResolver: () async => root,
    downloader: _WidgetModelDownloader(archive),
    extractor: _WidgetModelExtractor(payloads),
    assetSource: _WidgetModelAssetSource(payloads),
    storageProbe: const _WidgetModelStorageProbe(),
  );
}

class _WidgetModelDownloader implements LocalModelArtifactDownloader {
  const _WidgetModelDownloader(this.bytes);

  final List<int> bytes;

  @override
  Future<void> download({
    required Uri uri,
    required File destination,
    required int expectedBytes,
    required LocalModelCancellation cancellation,
    required ValueChanged<int> onProgress,
  }) async {
    await destination.writeAsBytes(bytes, flush: true);
    onProgress(bytes.length);
  }
}

class _WidgetModelExtractor implements LocalModelArchiveExtractor {
  const _WidgetModelExtractor(this.payloads);

  final Map<String, List<int>> payloads;

  @override
  Future<void> extract({
    required File archive,
    required Directory destination,
    required LocalModelManifest manifest,
    required LocalModelDownloadArtifact artifact,
  }) async {
    for (final file in manifest.files.where(
      (file) => file.artifactId == artifact.id,
    )) {
      await File(
        '${destination.path}/${file.archivePath}',
      ).writeAsBytes(payloads[file.archivePath]!, flush: true);
    }
  }
}

class _WidgetModelAssetSource implements LocalModelAssetSource {
  const _WidgetModelAssetSource(this.payloads);

  final Map<String, List<int>> payloads;

  @override
  Future<void> copyAsset(String assetPath, File destination) => destination
      .writeAsBytes(payloads[assetPath.split('/').last]!, flush: true);
}

class _WidgetModelStorageProbe implements LocalModelStorageProbe {
  const _WidgetModelStorageProbe();

  @override
  Future<void> prepareStorage(String path) async {}

  @override
  Future<int?> availableBytes(String path) async => 1024 * 1024 * 1024;
}

class _WidgetModelSwitcher implements RealtimeModelRuntimeSwitcher {
  final List<String> modelIds = [];

  @override
  Future<void> switchToRealtimeModel(RealtimeModelFiles candidate) async {
    modelIds.add(candidate.modelId);
  }
}

class _MemoryLanguagePreferences implements LanguagePreferenceStore {
  String? language;
  @override
  Future<String?> read() async => language;
  @override
  Future<void> write(String value) async {
    language = value;
  }
}

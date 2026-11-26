import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/models/local_model_manager.dart';
import 'package:momentai/core/models/local_model_manifest.dart';
import 'package:momentai/core/models/local_model_runtime.dart';
import 'package:momentai/l10n/app_localization.dart';

void main() {
  late Directory root;
  late Map<String, List<int>> modelPayloads;
  late List<int> archiveBytes;
  late List<LocalModelManifest> catalog;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('momentai-model-center-');
    modelPayloads = {
      'encoder.bin': [1, 2, 3],
      'decoder.bin': [4, 5],
      'joiner.bin': [6],
      'tokens.txt': [7, 8, 9, 10],
      'model.bin': [11, 12, 13, 14],
    };
    archiveBytes = [21, 22, 23, 24, 25, 26];
    catalog = _catalog(modelPayloads, archiveBytes);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('HTTP downloader reapplies Range across secure redirects', () async {
    final destination = File('${root.path}/redirect.part');
    await destination.writeAsBytes([21, 22], flush: true);
    final transport = _QueuedHttpTransport([
      LocalModelHttpResponse(
        statusCode: HttpStatus.found,
        redirectLocation: Uri.parse('https://cdn.example.test/model'),
        body: const Stream.empty(),
      ),
      LocalModelHttpResponse(
        statusCode: HttpStatus.partialContent,
        contentRange: 'bytes 2-5/6',
        contentLength: 4,
        body: Stream.value([23, 24, 25, 26]),
      ),
    ]);

    await HttpLocalModelArtifactDownloader(
      transportFactory: () => transport,
    ).download(
      uri: Uri.parse('https://origin.example.test/model'),
      destination: destination,
      expectedBytes: 6,
      cancellation: LocalModelCancellation(),
      onProgress: (_) {},
    );

    expect(await destination.readAsBytes(), archiveBytes);
    expect(transport.uris, [
      Uri.parse('https://origin.example.test/model'),
      Uri.parse('https://cdn.example.test/model'),
    ]);
    expect(transport.rangeStarts, [2, 2]);
  });

  test('HTTP downloader safely restarts when Range returns 200', () async {
    final destination = File('${root.path}/no-range.part');
    await destination.writeAsBytes([21, 22], flush: true);
    final progress = <int>[];
    final transport = _QueuedHttpTransport([
      LocalModelHttpResponse(
        statusCode: HttpStatus.ok,
        contentLength: 6,
        body: Stream.value(archiveBytes),
      ),
    ]);

    await HttpLocalModelArtifactDownloader(
      transportFactory: () => transport,
    ).download(
      uri: Uri.parse('https://origin.example.test/model'),
      destination: destination,
      expectedBytes: 6,
      cancellation: LocalModelCancellation(),
      onProgress: progress.add,
    );

    expect(await destination.readAsBytes(), archiveBytes);
    expect(transport.rangeStarts, [2]);
    expect(progress.first, 0);
    expect(progress.last, archiveBytes.length);
  });

  test('HTTP downloader never exposes signed redirect queries', () async {
    final destination = File('${root.path}/signed-redirect.part');
    await destination.writeAsBytes([21, 22], flush: true);
    final signedUri = Uri.parse(
      'https://cdn.example.test/model?auth_key=must-not-leak',
    );
    final transport = _QueuedHttpTransport([
      LocalModelHttpResponse(
        statusCode: HttpStatus.found,
        redirectLocation: signedUri,
        body: const Stream.empty(),
      ),
      LocalModelHttpResponse(
        statusCode: HttpStatus.partialContent,
        contentRange: 'bytes 2-5/6',
        contentLength: 4,
        body: Stream.error(HttpException('failed', uri: signedUri)),
      ),
    ]);

    Object? failure;
    try {
      await HttpLocalModelArtifactDownloader(
        transportFactory: () => transport,
      ).download(
        uri: Uri.parse('https://origin.example.test/model'),
        destination: destination,
        expectedBytes: 6,
        cancellation: LocalModelCancellation(),
        onProgress: (_) {},
      );
    } catch (error) {
      failure = error;
    }

    expect(failure, isA<LocalModelDownloadSourceException>());
    expect('$failure', isNot(contains('auth_key')));
    expect('$failure', isNot(contains('must-not-leak')));
    expect(await destination.readAsBytes(), [21, 22]);
  });

  test('HTTP downloader rejects a mismatched Content-Range', () async {
    final destination = File('${root.path}/bad-range.part');
    await destination.writeAsBytes([21, 22], flush: true);
    final transport = _QueuedHttpTransport([
      LocalModelHttpResponse(
        statusCode: HttpStatus.partialContent,
        contentRange: 'bytes 1-5/6',
        contentLength: 5,
        body: Stream.value([22, 23, 24, 25, 26]),
      ),
    ]);

    await expectLater(
      HttpLocalModelArtifactDownloader(
        transportFactory: () => transport,
      ).download(
        uri: Uri.parse('https://origin.example.test/model'),
        destination: destination,
        expectedBytes: 6,
        cancellation: LocalModelCancellation(),
        onProgress: (_) {},
      ),
      throwsA(isA<LocalModelOperationException>()),
    );
    expect(await destination.readAsBytes(), [21, 22]);
  });

  test('HTTP downloader rejects an insecure redirect', () async {
    final destination = File('${root.path}/insecure-redirect.part');
    final transport = _QueuedHttpTransport([
      LocalModelHttpResponse(
        statusCode: HttpStatus.found,
        redirectLocation: Uri.parse('http://cdn.example.test/model'),
        body: const Stream.empty(),
      ),
    ]);

    await expectLater(
      HttpLocalModelArtifactDownloader(
        transportFactory: () => transport,
      ).download(
        uri: Uri.parse('https://origin.example.test/model'),
        destination: destination,
        expectedBytes: 6,
        cancellation: LocalModelCancellation(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<LocalModelOperationException>().having(
          (error) => error.message,
          'message',
          contains('不安全'),
        ),
      ),
    );
    expect(transport.uris, hasLength(1));
  });

  test(
    'resumes a partial artifact then verifies and atomically installs',
    () async {
      final partial = File(
        '${root.path}/downloads/$balancedRealtimeModelId-v2.tar.bz2.part',
      );
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(archiveBytes.take(2).toList());
      final downloader = _Downloader(archiveBytes);
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: downloader,
      );

      await manager.initialize();
      expect(
        manager.snapshot.stateFor(balancedRealtimeModelId)?.phase,
        LocalModelInstallPhase.paused,
      );
      await manager.download(balancedRealtimeModelId);

      expect(downloader.resumeOffsets, [2]);
      final state = manager.snapshot.stateFor(balancedRealtimeModelId)!;
      expect(state.phase, LocalModelInstallPhase.installed);
      expect(state.downloadedBytes, archiveBytes.length);
      expect(await partial.exists(), isFalse);
      final installed = Directory(
        '${root.path}/installed/$balancedRealtimeModelId/'
        '${catalog[1].installationName}',
      );
      expect(await File('${installed.path}/install.json').exists(), isTrue);
      expect(await File('${installed.path}/encoder.bin').readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  for (final modelId in [
    balancedRealtimeModelId,
    senseVoiceRefinementModelId,
  ]) {
    final version = modelId == balancedRealtimeModelId ? 'v2' : 'v3';
    test('$modelId succeeds from ModelScope without using fallback', () async {
      final downloader = _Downloader(archiveBytes);
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: downloader,
      );
      await manager.initialize();

      await manager.download(modelId);

      expect(downloader.uris.map((uri) => uri.host), [
        'modelscope.example.test',
      ]);
      expect(
        manager.snapshot.stateFor(modelId)?.phase,
        LocalModelInstallPhase.installed,
      );
    });

    test('$modelId falls back from ModelScope to GitHub', () async {
      final downloader = _FailoverDownloader(archiveBytes);
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: downloader,
      );
      await manager.initialize();

      await manager.download(modelId);

      expect(downloader.uris.map((uri) => uri.host), [
        'modelscope.example.test',
        'github.example.test',
      ]);
      expect(downloader.resumeOffsets, [0, 0]);
      expect(
        manager.snapshot.stateFor(modelId)?.phase,
        LocalModelInstallPhase.installed,
      );
    });

    test('$modelId resumes the same partial across sources', () async {
      final partial = File(
        '${root.path}/downloads/$modelId-$version.tar.bz2.part',
      );
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(archiveBytes.take(2).toList(), flush: true);
      final downloader = _FailoverDownloader(
        archiveBytes,
        firstAttemptBytes: 1,
      );
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: downloader,
      );
      await manager.initialize();

      await manager.download(modelId);

      expect(downloader.resumeOffsets, [2, 3]);
      expect(downloader.uris.map((uri) => uri.host), [
        'modelscope.example.test',
        'github.example.test',
      ]);
      expect(await partial.exists(), isFalse);
      expect(
        manager.snapshot.stateFor(modelId)?.phase,
        LocalModelInstallPhase.installed,
      );
    });

    test('both $modelId sources failing preserves the legal partial', () async {
      final partial = File(
        '${root.path}/downloads/$modelId-$version.tar.bz2.part',
      );
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(archiveBytes.take(2).toList(), flush: true);
      final downloader = _FailoverDownloader(
        archiveBytes,
        firstAttemptBytes: 1,
        failEveryAttempt: true,
      );
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: downloader,
      );
      await manager.initialize();

      await expectLater(
        manager.download(modelId),
        throwsA(isA<LocalModelDownloadSourceException>()),
      );

      expect(downloader.resumeOffsets, [2, 3]);
      expect(await partial.readAsBytes(), archiveBytes.take(3).toList());
      final state = manager.snapshot.stateFor(modelId)!;
      expect(state.phase, LocalModelInstallPhase.failed);
      expect(state.downloadedBytes, 3);
    });

    test(
      '$modelId SHA mismatch restarts the GitHub fallback from zero in English',
      () async {
        setApplicationLanguage('en');
        addTearDown(() => setApplicationLanguage('zh'));
        final downloader = _IntegrityFallbackDownloader(archiveBytes);
        final manager = _manager(
          root: root,
          catalog: catalog,
          payloads: modelPayloads,
          downloader: downloader,
        );
        await manager.initialize();

        await manager.download(modelId);

        expect(downloader.resumeOffsets, [0, 0]);
        expect(
          manager.snapshot.stateFor(modelId)?.phase,
          LocalModelInstallPhase.installed,
        );
      },
    );
  }

  test('explicit restart discards a partial before downloading', () async {
    final partial = File(
      '${root.path}/downloads/$balancedRealtimeModelId-v2.tar.bz2.part',
    );
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(archiveBytes.take(2).toList());
    final downloader = _Downloader(archiveBytes);
    final manager = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: downloader,
    );
    await manager.initialize();

    await manager.restartDownload(balancedRealtimeModelId);

    expect(downloader.resumeOffsets, [0]);
    expect(
      manager.snapshot.stateFor(balancedRealtimeModelId)?.phase,
      LocalModelInstallPhase.installed,
    );
  });

  test('refinement suggestion dismissal survives relaunch', () async {
    final first = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: _Downloader(archiveBytes),
    );
    await first.initialize();
    expect(first.snapshot.shouldSuggestRefinementDownload, isTrue);

    await first.dismissRefinementSuggestion();
    expect(first.snapshot.shouldSuggestRefinementDownload, isFalse);

    final relaunched = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: _Downloader(archiveBytes),
    );
    await relaunched.initialize();
    expect(relaunched.snapshot.shouldSuggestRefinementDownload, isFalse);
  });

  test('legacy inline suggestion dismissal does not suppress modal', () async {
    await File(
      '${root.path}/refinement_suggestion_v1.json',
    ).writeAsString('{"schemaVersion":1,"dismissed":true}\n', flush: true);
    final manager = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: _Downloader(archiveBytes),
    );

    await manager.initialize();

    expect(manager.snapshot.shouldSuggestRefinementDownload, isTrue);
  });

  test('active balanced model must switch before deletion', () async {
    final manager = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: _Downloader(archiveBytes),
    )..attachRuntimeSwitcher(_Switcher());
    await manager.initialize();
    await manager.download(balancedRealtimeModelId);
    await manager.activateRealtime(balancedRealtimeModelId);

    await expectLater(
      manager.remove(balancedRealtimeModelId),
      throwsA(isA<LocalModelOperationException>()),
    );
    await manager.activateRealtime(lightweightRealtimeModelId);
    await manager.remove(balancedRealtimeModelId);

    expect(
      manager.snapshot.stateFor(balancedRealtimeModelId)?.phase,
      LocalModelInstallPhase.unavailable,
    );
  });

  test(
    'a failed runtime switch preserves the old active model and pointer',
    () async {
      final switcher = _Switcher(fail: true);
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: _Downloader(archiveBytes),
      )..attachRuntimeSwitcher(switcher);
      await manager.initialize();
      await manager.download(balancedRealtimeModelId);

      await expectLater(
        manager.activateRealtime(balancedRealtimeModelId),
        throwsA(isA<StateError>()),
      );
      expect(
        manager.snapshot.activeRealtimeModelId,
        lightweightRealtimeModelId,
      );
      expect(
        manager.snapshot.stateFor(lightweightRealtimeModelId)?.phase,
        LocalModelInstallPhase.active,
      );
      expect(
        await File('${root.path}/active_realtime_v1.json').readAsString(),
        contains(lightweightRealtimeModelId),
      );
    },
  );

  test(
    'switch reserves validation, blocks duplicate taps and releases on failure',
    () async {
      final switcher = _DeferredSwitcher();
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: _Downloader(archiveBytes),
      )..attachRuntimeSwitcher(switcher);
      await manager.initialize();
      await manager.download(balancedRealtimeModelId);
      final phases = <LocalModelInstallPhase>[];
      manager.addListener(
        () => phases.add(
          manager.snapshot.stateFor(balancedRealtimeModelId)!.phase,
        ),
      );
      final first = manager.activateRealtime(balancedRealtimeModelId);
      await switcher.started.future;
      expect(phases, contains(LocalModelInstallPhase.verifying));
      expect(
        manager.snapshot.stateFor(balancedRealtimeModelId)!.phase,
        LocalModelInstallPhase.switching,
      );
      expect(manager.hasOperation, isTrue);
      await expectLater(
        manager.activateRealtime(balancedRealtimeModelId),
        throwsA(isA<LocalModelOperationException>()),
      );
      expect(switcher.calls, 1);
      switcher.finish.complete();
      await first;
      expect(manager.hasOperation, isFalse);
      expect(manager.snapshot.activeRealtimeModelId, balancedRealtimeModelId);
    },
  );

  test(
    'candidate verification failure releases the switch slot and keeps old pointer',
    () async {
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: _Downloader(archiveBytes),
      )..attachRuntimeSwitcher(_Switcher());
      await manager.initialize();
      await manager.download(balancedRealtimeModelId);
      final file = File(
        '${root.path}/installed/${catalog[1].id}/${catalog[1].installationName}/${catalog[1].files.first.archivePath}',
      );
      await file.writeAsBytes([0]);
      await expectLater(
        manager.activateRealtime(balancedRealtimeModelId),
        throwsA(isA<LocalModelOperationException>()),
      );
      expect(manager.hasOperation, isFalse);
      expect(
        manager.snapshot.activeRealtimeModelId,
        lightweightRealtimeModelId,
      );
      expect(
        manager.snapshot.stateFor(balancedRealtimeModelId)!.phase,
        LocalModelInstallPhase.failed,
      );
    },
  );

  test('successful switch persists and is restored after relaunch', () async {
    final first = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: _Downloader(archiveBytes),
    )..attachRuntimeSwitcher(_Switcher());
    await first.initialize();
    await first.download(balancedRealtimeModelId);
    await first.activateRealtime(balancedRealtimeModelId);
    expect(first.snapshot.activeRealtimeModelId, balancedRealtimeModelId);
    expect(
      first.snapshot.stateFor(balancedRealtimeModelId)?.phase,
      LocalModelInstallPhase.active,
    );

    final relaunched = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: _Downloader(archiveBytes),
    );
    await relaunched.initialize();
    expect(relaunched.snapshot.activeRealtimeModelId, balancedRealtimeModelId);
    expect(
      (await relaunched.activeRealtimeModelFiles()).paths['tokens'],
      endsWith('tokens.txt'),
    );
  });

  test(
    'relaunch removes a leftover archive only after a valid install',
    () async {
      final first = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: _Downloader(archiveBytes),
      );
      await first.initialize();
      await first.download(balancedRealtimeModelId);
      final artifact = File(
        '${root.path}/downloads/$balancedRealtimeModelId-v2.tar.bz2.part',
      );
      await artifact.writeAsBytes(archiveBytes, flush: true);

      final relaunched = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: _Downloader(archiveBytes),
      );
      await relaunched.initialize();

      expect(await artifact.exists(), isFalse);
      expect(
        relaunched.snapshot.stateFor(balancedRealtimeModelId)?.phase,
        LocalModelInstallPhase.installed,
      );
    },
  );

  test(
    'pointer commit failure switches the runtime back to old model',
    () async {
      final switcher = _RecordingSwitcher();
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: _Downloader(archiveBytes),
      )..attachRuntimeSwitcher(switcher);
      await manager.initialize();
      await manager.download(balancedRealtimeModelId);
      final pointer = File('${root.path}/active_realtime_v1.json');
      await pointer.delete();
      await Directory(pointer.path).create();

      await expectLater(
        manager.activateRealtime(balancedRealtimeModelId),
        throwsA(isA<FileSystemException>()),
      );

      expect(switcher.modelIds, [
        balancedRealtimeModelId,
        lightweightRealtimeModelId,
      ]);
      expect(
        manager.snapshot.activeRealtimeModelId,
        lightweightRealtimeModelId,
      );
      expect(
        manager.snapshot.stateFor(lightweightRealtimeModelId)?.phase,
        LocalModelInstallPhase.active,
      );
    },
  );

  test(
    'archive hash mismatch is deleted and never becomes installed',
    () async {
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: _Downloader([99, 98, 97, 96, 95, 94]),
      );
      await manager.initialize();

      await expectLater(
        manager.download(balancedRealtimeModelId),
        throwsA(
          isA<LocalModelOperationException>().having(
            (error) => error.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(
        manager.snapshot.stateFor(balancedRealtimeModelId)?.phase,
        LocalModelInstallPhase.failed,
      );
      expect(
        await File(
          '${root.path}/downloads/$balancedRealtimeModelId-v2.tar.bz2.part',
        ).exists(),
        isFalse,
      );
    },
  );

  test('resource activity rejects download before any network write', () async {
    final downloader = _Downloader(archiveBytes);
    final manager = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: downloader,
      resourceBusy: () => true,
    );
    await manager.initialize();

    await expectLater(
      manager.download(balancedRealtimeModelId),
      throwsA(isA<LocalModelOperationException>()),
    );
    expect(downloader.resumeOffsets, isEmpty);
  });

  test(
    'storage preflight rejects before download and keeps current model',
    () async {
      final downloader = _Downloader(archiveBytes);
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: downloader,
        storageProbe: const _StorageProbe(available: 0),
      );
      await manager.initialize();

      await expectLater(
        manager.download(balancedRealtimeModelId),
        throwsA(
          isA<LocalModelOperationException>().having(
            (error) => error.message,
            'message',
            contains('存储空间不足'),
          ),
        ),
      );
      expect(downloader.resumeOffsets, isEmpty);
      expect(
        manager.snapshot.activeRealtimeModelId,
        lightweightRealtimeModelId,
      );
    },
  );

  test(
    'backup exclusion failure does not block bundled transcription',
    () async {
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: _Downloader(archiveBytes),
        storageProbe: const _ThrowingStorageProbe(prepareFailure: true),
      );

      await manager.initialize();

      expect(manager.snapshot.initialized, isTrue);
      expect(
        manager.snapshot.activeRealtimeModelId,
        lightweightRealtimeModelId,
      );
      expect(manager.snapshot.globalMessage, contains('备份排除'));
    },
  );

  test('unknown available storage stops before network access', () async {
    final downloader = _Downloader(archiveBytes);
    final manager = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: downloader,
      storageProbe: const _ThrowingStorageProbe(availableFailure: true),
    );
    await manager.initialize();

    await expectLater(
      manager.download(balancedRealtimeModelId),
      throwsA(
        isA<LocalModelOperationException>().having(
          (error) => error.message,
          'message',
          contains('无法确认设备可用空间'),
        ),
      ),
    );
    expect(downloader.resumeOffsets, isEmpty);
  });

  test('pause keeps partial bytes and a later download resumes them', () async {
    final downloader = _PauseThenResumeDownloader(archiveBytes);
    final manager = _manager(
      root: root,
      catalog: catalog,
      payloads: modelPayloads,
      downloader: downloader,
    );
    await manager.initialize();

    final firstAttempt = manager.download(balancedRealtimeModelId);
    await downloader.firstChunkWritten.future;
    manager.pause(balancedRealtimeModelId);
    await firstAttempt;
    final paused = manager.snapshot.stateFor(balancedRealtimeModelId)!;
    expect(paused.phase, LocalModelInstallPhase.paused);
    expect(paused.downloadedBytes, 2);

    await manager.download(balancedRealtimeModelId);
    expect(downloader.resumeOffsets, [0, 2]);
    expect(
      manager.snapshot.stateFor(balancedRealtimeModelId)?.phase,
      LocalModelInstallPhase.installed,
    );
  });

  test(
    'installed SenseVoice resolves without becoming a realtime choice',
    () async {
      final manager = _manager(
        root: root,
        catalog: catalog,
        payloads: modelPayloads,
        downloader: _Downloader(archiveBytes),
      );
      await manager.initialize();
      expect(await manager.refinementModelFiles(), isNull);
      await manager.download(senseVoiceRefinementModelId);
      expect(manager.snapshot.shouldSuggestRefinementDownload, isFalse);
      final files = await manager.refinementModelFiles();
      expect(files?.modelId, senseVoiceRefinementModelId);
      expect(files?.modelPath, endsWith('model.bin'));
      expect(
        manager.snapshot.activeRealtimeModelId,
        lightweightRealtimeModelId,
      );
    },
  );

  test('installs a composite direct-file speaker model atomically', () async {
    final segmentation = [31, 32];
    final embedding = [41, 42, 43];
    final speaker = LocalModelManifest(
      id: speakerDiarizationModelId,
      version: 'v1',
      name: 'speaker',
      description: 'test',
      kind: LocalModelKind.speakerDiarization,
      languages: const ['zh'],
      qualityLabel: 'test',
      installedByteCount: segmentation.length + embedding.length,
      minimumMemoryBytes: 1,
      license: 'test',
      downloadArtifacts: [
        LocalModelDownloadArtifact(
          id: 'segmentation',
          fileName: 'segmentation.onnx',
          byteCount: segmentation.length,
          sha256: sha256.convert(segmentation).toString(),
          format: LocalModelArtifactFormat.directFile,
          installPath: 'segmentation.onnx',
          downloadSources: [
            LocalModelDownloadSource(
              name: 'mirror',
              uri: Uri.parse('https://example.test/segmentation.onnx'),
            ),
          ],
        ),
        LocalModelDownloadArtifact(
          id: 'embedding',
          fileName: 'embedding.onnx',
          byteCount: embedding.length,
          sha256: sha256.convert(embedding).toString(),
          format: LocalModelArtifactFormat.directFile,
          installPath: 'embedding.onnx',
          downloadSources: [
            LocalModelDownloadSource(
              name: 'mirror',
              uri: Uri.parse('https://example.test/embedding.onnx'),
            ),
          ],
        ),
      ],
      files: [
        LocalModelFileManifest(
          logicalName: 'segmentation',
          archivePath: 'segmentation.onnx',
          artifactId: 'segmentation',
          byteCount: segmentation.length,
          sha256: sha256.convert(segmentation).toString(),
        ),
        LocalModelFileManifest(
          logicalName: 'embedding',
          archivePath: 'embedding.onnx',
          artifactId: 'embedding',
          byteCount: embedding.length,
          sha256: sha256.convert(embedding).toString(),
        ),
      ],
    );
    final manager = _manager(
      root: root,
      catalog: [...catalog, speaker],
      payloads: modelPayloads,
      downloader: _ExpectedSizeDownloader({
        segmentation.length: segmentation,
        embedding.length: embedding,
      }),
    );
    await manager.initialize();

    await manager.download(speakerDiarizationModelId);

    final files = await manager.speakerDiarizationModelFiles();
    expect(files?.segmentationPath, endsWith('segmentation.onnx'));
    expect(files?.embeddingPath, endsWith('embedding.onnx'));
    expect(await File(files!.segmentationPath).readAsBytes(), segmentation);
    expect(await File(files.embeddingPath).readAsBytes(), embedding);
    expect(
      manager.snapshot.stateFor(speakerDiarizationModelId)?.downloadedBytes,
      segmentation.length + embedding.length,
    );
  });

  test(
    'real tar.bz2 extractor accepts exact files and rejects traversal',
    () async {
      final manifest = catalog[1];
      final archive = Archive();
      for (final file in manifest.files) {
        final bytes = modelPayloads[file.archivePath]!;
        archive.addFile(
          ArchiveFile(
            '${manifest.id}/${file.archivePath}',
            bytes.length,
            bytes,
          ),
        );
      }
      final encoded = BZip2Encoder().encode(TarEncoder().encode(archive));
      final artifact = File('${root.path}/valid.tar.bz2');
      await artifact.writeAsBytes(encoded);
      final destination = Directory('${root.path}/valid-output');

      await const TarBzip2LocalModelArchiveExtractor().extract(
        archive: artifact,
        destination: destination,
        manifest: manifest,
        artifact: manifest.artifacts.single,
      );
      expect(await File('${destination.path}/tokens.txt').readAsBytes(), [
        7,
        8,
        9,
        10,
      ]);

      final unsafeArchive = Archive()
        ..addFile(ArchiveFile('../outside', 1, [1]));
      final unsafeArtifact = File('${root.path}/unsafe.tar.bz2');
      await unsafeArtifact.writeAsBytes(
        BZip2Encoder().encode(TarEncoder().encode(unsafeArchive)),
      );
      await expectLater(
        const TarBzip2LocalModelArchiveExtractor().extract(
          archive: unsafeArtifact,
          destination: Directory('${root.path}/unsafe-output'),
          manifest: manifest,
          artifact: manifest.artifacts.single,
        ),
        throwsA(isA<LocalModelOperationException>()),
      );
      expect(await File('${root.path}/outside').exists(), isFalse);
    },
  );

  test(
    'installation reports work separately from completed download',
    () async {
      final gate = Completer<void>();
      final extractor = _DeferredExtractor(modelPayloads, gate);
      final manager = LocalModelManager(
        catalog: catalog,
        rootResolver: () async => root,
        downloader: _Downloader(archiveBytes),
        extractor: extractor,
        assetSource: _AssetSource(modelPayloads),
        storageProbe: const _StorageProbe(),
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      final installing = manager.download(balancedRealtimeModelId);
      await extractor.started.future;
      final state = manager.snapshot.stateFor(balancedRealtimeModelId)!;
      expect(state.phase, LocalModelInstallPhase.installing);
      expect(state.progress, 1);
      expect(state.message, contains('正在解压'));
      gate.complete();
      await installing;
      expect(
        manager.snapshot.stateFor(balancedRealtimeModelId)!.phase,
        LocalModelInstallPhase.installed,
      );
      expect(
        manager.snapshot.stateFor(balancedRealtimeModelId)!.message,
        isNull,
      );
    },
  );

  test('unverified real-time models cannot be offered for download', () {
    final manager = LocalModelManager();
    addTearDown(manager.dispose);
    expect(manager.catalog.map((model) => model.id), {
      lightweightRealtimeModelId,
      senseVoiceRefinementModelId,
      speakerDiarizationModelId,
    });
    for (final id in [balancedRealtimeModelId, enhancedRealtimeModelId]) {
      expect(manager.snapshot.stateFor(id), isNull);
    }
  });

  test('official catalog defines verifiable model artifacts', () async {
    final senseVoice = OfficialLocalModelCatalog.models.firstWhere(
      (manifest) => manifest.id == senseVoiceRefinementModelId,
    );
    expect(senseVoice.downloadSources.map((source) => source.name), [
      'ModelScope',
      'GitHub',
    ]);
    expect(
      senseVoice.downloadSources.first.uri,
      Uri.parse(
        'https://modelscope.cn/api/v1/models/'
        'aihohu/SenseVoiceSmall-ONNX-INT8/repo?Revision=master&'
        'FilePath=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
      ),
    );
    expect(senseVoice.archiveByteCount, 163002883);
    expect(
      senseVoice.archiveSha256,
      '7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e',
    );
    for (final manifest in OfficialLocalModelCatalog.models) {
      expect(manifest.files, isNotEmpty);
      for (final file in manifest.files) {
        expect(file.byteCount, greaterThan(0));
        expect(file.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      }
      if (manifest.downloadable) {
        expect(manifest.artifacts, isNotEmpty);
        for (final artifact in manifest.artifacts) {
          expect(artifact.byteCount, greaterThan(0));
          expect(artifact.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
          expect(
            artifact.downloadSources.every(
              (source) => source.uri.scheme == 'https',
            ),
            isTrue,
          );
        }
      }
    }
  });
}

LocalModelManager _manager({
  required Directory root,
  required List<LocalModelManifest> catalog,
  required Map<String, List<int>> payloads,
  required LocalModelArtifactDownloader downloader,
  bool Function()? resourceBusy,
  LocalModelStorageProbe storageProbe = const _StorageProbe(),
}) => LocalModelManager(
  catalog: catalog,
  rootResolver: () async => root,
  downloader: downloader,
  extractor: _Extractor(payloads),
  assetSource: _AssetSource(payloads),
  storageProbe: storageProbe,
  resourceBusy: resourceBusy,
);

List<LocalModelManifest> _catalog(
  Map<String, List<int>> payloads,
  List<int> archiveBytes,
) {
  LocalModelFileManifest file(String logical, String name) =>
      LocalModelFileManifest(
        logicalName: logical,
        archivePath: name,
        assetPath: 'asset/$name',
        byteCount: payloads[name]!.length,
        sha256: sha256.convert(payloads[name]!).toString(),
      );

  final archiveHash = sha256.convert(archiveBytes).toString();
  return [
    LocalModelManifest(
      id: lightweightRealtimeModelId,
      version: 'v1',
      name: '轻量',
      description: 'test',
      kind: LocalModelKind.realtime,
      languages: const ['zh'],
      qualityLabel: 'light',
      installedByteCount: 10,
      minimumMemoryBytes: 1,
      license: 'test',
      bundled: true,
      files: [
        file('encoder', 'encoder.bin'),
        file('decoder', 'decoder.bin'),
        file('joiner', 'joiner.bin'),
        file('tokens', 'tokens.txt'),
      ],
    ),
    LocalModelManifest(
      id: balancedRealtimeModelId,
      version: 'v2',
      name: '均衡',
      description: 'test',
      kind: LocalModelKind.realtime,
      languages: const ['zh'],
      qualityLabel: 'balanced',
      installedByteCount: 10,
      minimumMemoryBytes: 1,
      license: 'test',
      downloadSources: [
        LocalModelDownloadSource(
          name: 'ModelScope',
          uri: Uri.parse('https://modelscope.example.test/balanced.tar.bz2'),
        ),
        LocalModelDownloadSource(
          name: 'GitHub',
          uri: Uri.parse('https://github.example.test/balanced.tar.bz2'),
        ),
      ],
      archiveByteCount: archiveBytes.length,
      archiveSha256: archiveHash,
      files: [
        file('encoder', 'encoder.bin'),
        file('decoder', 'decoder.bin'),
        file('joiner', 'joiner.bin'),
        file('tokens', 'tokens.txt'),
      ],
    ),
    LocalModelManifest(
      id: senseVoiceRefinementModelId,
      version: 'v3',
      name: '精修',
      description: 'test',
      kind: LocalModelKind.refinement,
      languages: const ['zh'],
      qualityLabel: 'refine',
      installedByteCount: 8,
      minimumMemoryBytes: 1,
      license: 'test',
      downloadSources: [
        LocalModelDownloadSource(
          name: 'ModelScope',
          uri: Uri.parse('https://modelscope.example.test/refine.tar.bz2'),
        ),
        LocalModelDownloadSource(
          name: 'GitHub',
          uri: Uri.parse('https://github.example.test/refine.tar.bz2'),
        ),
      ],
      archiveByteCount: archiveBytes.length,
      archiveSha256: archiveHash,
      files: [file('model', 'model.bin'), file('tokens', 'tokens.txt')],
    ),
  ];
}

class _Downloader implements LocalModelArtifactDownloader {
  _Downloader(this.bytes);

  final List<int> bytes;
  final List<Uri> uris = [];
  final List<int> resumeOffsets = [];

  @override
  Future<void> download({
    required Uri uri,
    required File destination,
    required int expectedBytes,
    required LocalModelCancellation cancellation,
    required void Function(int value) onProgress,
  }) async {
    uris.add(uri);
    final offset = await destination.exists() ? await destination.length() : 0;
    resumeOffsets.add(offset);
    final sink = await destination.open(mode: FileMode.append);
    try {
      await sink.writeFrom(bytes.skip(offset).toList());
      await sink.flush();
      onProgress(await destination.length());
    } finally {
      await sink.close();
    }
  }
}

class _ExpectedSizeDownloader implements LocalModelArtifactDownloader {
  const _ExpectedSizeDownloader(this.payloads);

  final Map<int, List<int>> payloads;

  @override
  Future<void> download({
    required Uri uri,
    required File destination,
    required int expectedBytes,
    required LocalModelCancellation cancellation,
    required void Function(int value) onProgress,
  }) async {
    final bytes = payloads[expectedBytes]!;
    await destination.writeAsBytes(bytes, flush: true);
    onProgress(bytes.length);
  }
}

class _FailoverDownloader implements LocalModelArtifactDownloader {
  _FailoverDownloader(
    this.bytes, {
    this.firstAttemptBytes = 0,
    this.failEveryAttempt = false,
  });

  final List<int> bytes;
  final int firstAttemptBytes;
  final bool failEveryAttempt;
  final List<Uri> uris = [];
  final List<int> resumeOffsets = [];

  @override
  Future<void> download({
    required Uri uri,
    required File destination,
    required int expectedBytes,
    required LocalModelCancellation cancellation,
    required void Function(int value) onProgress,
  }) async {
    uris.add(uri);
    final offset = await destination.exists() ? await destination.length() : 0;
    resumeOffsets.add(offset);
    if (uris.length == 1) {
      if (firstAttemptBytes > 0) {
        final sink = await destination.open(mode: FileMode.append);
        try {
          await sink.writeFrom(
            bytes.skip(offset).take(firstAttemptBytes).toList(),
          );
          await sink.flush();
        } finally {
          await sink.close();
        }
        onProgress(await destination.length());
      }
    }
    if (uris.length == 1 || failEveryAttempt) {
      throw const LocalModelDownloadSourceException('测试下载源不可用。');
    }
    final sink = await destination.open(mode: FileMode.append);
    try {
      await sink.writeFrom(bytes.skip(offset).toList());
      await sink.flush();
      onProgress(await destination.length());
    } finally {
      await sink.close();
    }
  }
}

class _IntegrityFallbackDownloader implements LocalModelArtifactDownloader {
  _IntegrityFallbackDownloader(this.bytes);

  final List<int> bytes;
  final List<int> resumeOffsets = [];

  @override
  Future<void> download({
    required Uri uri,
    required File destination,
    required int expectedBytes,
    required LocalModelCancellation cancellation,
    required void Function(int value) onProgress,
  }) async {
    final offset = await destination.exists() ? await destination.length() : 0;
    resumeOffsets.add(offset);
    if (resumeOffsets.length == 1) {
      await destination.writeAsBytes(
        List<int>.filled(bytes.length, 99),
        flush: true,
      );
    } else {
      await destination.writeAsBytes(bytes, flush: true);
    }
    onProgress(bytes.length);
  }
}

class _QueuedHttpTransport implements LocalModelHttpTransport {
  _QueuedHttpTransport(this.responses);

  final List<LocalModelHttpResponse> responses;
  final List<Uri> uris = [];
  final List<int?> rangeStarts = [];

  @override
  Future<LocalModelHttpResponse> get(
    Uri uri, {
    required int? rangeStart,
  }) async {
    uris.add(uri);
    rangeStarts.add(rangeStart);
    return responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

class _PauseThenResumeDownloader implements LocalModelArtifactDownloader {
  _PauseThenResumeDownloader(this.bytes);

  final List<int> bytes;
  final firstChunkWritten = Completer<void>();
  final resumeOffsets = <int>[];
  var calls = 0;

  @override
  Future<void> download({
    required Uri uri,
    required File destination,
    required int expectedBytes,
    required LocalModelCancellation cancellation,
    required void Function(int value) onProgress,
  }) async {
    calls += 1;
    final offset = await destination.exists() ? await destination.length() : 0;
    resumeOffsets.add(offset);
    if (calls == 1) {
      await destination.writeAsBytes(bytes.take(2).toList(), flush: true);
      onProgress(2);
      final cancelled = Completer<void>();
      cancellation.addListener(cancelled.complete);
      firstChunkWritten.complete();
      await cancelled.future;
      throw const LocalModelDownloadPaused();
    }
    final sink = await destination.open(mode: FileMode.append);
    try {
      await sink.writeFrom(bytes.skip(offset).toList());
      await sink.flush();
      onProgress(bytes.length);
    } finally {
      await sink.close();
    }
  }
}

class _Extractor implements LocalModelArchiveExtractor {
  const _Extractor(this.payloads);

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

class _AssetSource implements LocalModelAssetSource {
  const _AssetSource(this.payloads);

  final Map<String, List<int>> payloads;

  @override
  Future<void> copyAsset(String assetPath, File destination) => destination
      .writeAsBytes(payloads[assetPath.split('/').last]!, flush: true);
}

class _StorageProbe implements LocalModelStorageProbe {
  const _StorageProbe({this.available = 1024 * 1024 * 1024});

  final int available;

  @override
  Future<void> prepareStorage(String path) async {}

  @override
  Future<int?> availableBytes(String path) async => available;
}

class _ThrowingStorageProbe implements LocalModelStorageProbe {
  const _ThrowingStorageProbe({
    this.prepareFailure = false,
    this.availableFailure = false,
  });

  final bool prepareFailure;
  final bool availableFailure;

  @override
  Future<void> prepareStorage(String path) async {
    if (prepareFailure) throw StateError('injected backup exclusion failure');
  }

  @override
  Future<int?> availableBytes(String path) async {
    if (availableFailure) throw StateError('injected storage probe failure');
    return 1024 * 1024 * 1024;
  }
}

class _Switcher implements RealtimeModelRuntimeSwitcher {
  _Switcher({this.fail = false});

  final bool fail;

  @override
  Future<void> switchToRealtimeModel(RealtimeModelFiles candidate) async {
    if (fail) throw StateError('injected switch failure');
  }
}

class _RecordingSwitcher implements RealtimeModelRuntimeSwitcher {
  final modelIds = <String>[];

  @override
  Future<void> switchToRealtimeModel(RealtimeModelFiles candidate) async {
    modelIds.add(candidate.modelId);
  }
}

class _DeferredExtractor implements LocalModelArchiveExtractor {
  _DeferredExtractor(this.payloads, this.gate);
  final Map<String, List<int>> payloads;
  final Completer<void> gate;
  final started = Completer<void>();
  @override
  Future<void> extract({
    required File archive,
    required Directory destination,
    required LocalModelManifest manifest,
    required LocalModelDownloadArtifact artifact,
  }) async {
    started.complete();
    await gate.future;
    await _Extractor(payloads).extract(
      archive: archive,
      destination: destination,
      manifest: manifest,
      artifact: artifact,
    );
  }
}

class _DeferredSwitcher implements RealtimeModelRuntimeSwitcher {
  final started = Completer<void>();
  final finish = Completer<void>();
  int calls = 0;
  @override
  Future<void> switchToRealtimeModel(RealtimeModelFiles candidate) async {
    calls++;
    started.complete();
    await finish.future;
  }
}

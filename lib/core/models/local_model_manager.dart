import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:momentai/l10n/app_localization.dart';
import 'package:path_provider/path_provider.dart';

import 'local_model_manifest.dart';
import 'local_model_runtime.dart';

enum LocalModelInstallPhase {
  unavailable,
  bundled,
  paused,
  downloading,
  verifying,
  installing,
  switching,
  removing,
  installed,
  active,
  failed,
}

const _refinementSuggestionFileName = 'refinement_suggestion_v2.json';
const _refinementSuggestionSchemaVersion = 2;

class LocalModelInstallState {
  const LocalModelInstallState({
    required this.manifest,
    required this.phase,
    this.downloadedBytes = 0,
    this.resumedFromBytes = 0,
    this.bytesPerSecond = 0,
    this.message,
  });

  final LocalModelManifest manifest;
  final LocalModelInstallPhase phase;
  final int downloadedBytes;
  final int resumedFromBytes;
  final double bytesPerSecond;
  final String? message;

  int get totalBytes => manifest.downloadable
      ? manifest.downloadByteCount
      : manifest.installedByteCount;

  double? get progress {
    if (totalBytes <= 0) return null;
    return (downloadedBytes / totalBytes).clamp(0, 1);
  }

  bool get installed =>
      phase == LocalModelInstallPhase.bundled ||
      phase == LocalModelInstallPhase.installed ||
      phase == LocalModelInstallPhase.active;

  bool get busy =>
      phase == LocalModelInstallPhase.downloading ||
      phase == LocalModelInstallPhase.verifying ||
      phase == LocalModelInstallPhase.installing ||
      phase == LocalModelInstallPhase.switching ||
      phase == LocalModelInstallPhase.removing;

  LocalModelInstallState copyWith({
    LocalModelInstallPhase? phase,
    int? downloadedBytes,
    int? resumedFromBytes,
    double? bytesPerSecond,
    String? message,
    bool clearMessage = false,
    bool clearTransferMetrics = false,
  }) => LocalModelInstallState(
    manifest: manifest,
    phase: phase ?? this.phase,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    resumedFromBytes: clearTransferMetrics
        ? 0
        : (resumedFromBytes ?? this.resumedFromBytes),
    bytesPerSecond: clearTransferMetrics
        ? 0
        : (bytesPerSecond ?? this.bytesPerSecond),
    message: clearMessage ? null : (message ?? this.message),
  );
}

class LocalModelManagerSnapshot {
  const LocalModelManagerSnapshot({
    required this.initialized,
    required this.activeRealtimeModelId,
    required this.models,
    this.refinementSuggestionDismissed = false,
    this.globalMessage,
  });

  const LocalModelManagerSnapshot.loading()
    : initialized = false,
      activeRealtimeModelId = lightweightRealtimeModelId,
      models = const [],
      refinementSuggestionDismissed = false,
      globalMessage = null;

  final bool initialized;
  final String activeRealtimeModelId;
  final List<LocalModelInstallState> models;
  final bool refinementSuggestionDismissed;
  final String? globalMessage;

  LocalModelInstallState? stateFor(String modelId) {
    for (final state in models) {
      if (state.manifest.id == modelId) return state;
    }
    return null;
  }

  bool get hasOperation => models.any((state) => state.busy);

  bool get shouldSuggestRefinementDownload {
    if (!initialized || refinementSuggestionDismissed) return false;
    return stateFor(senseVoiceRefinementModelId)?.installed != true;
  }
}

class LocalModelOperationException implements Exception {
  const LocalModelOperationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalModelIntegrityException extends LocalModelOperationException {
  const LocalModelIntegrityException(super.message);
}

class LocalModelDownloadSourceException extends LocalModelOperationException {
  const LocalModelDownloadSourceException(super.message);
}

class LocalModelDownloadPaused implements Exception {
  const LocalModelDownloadPaused();
}

class LocalModelCancellation {
  bool _cancelled = false;
  final List<VoidCallback> _listeners = [];

  bool get isCancelled => _cancelled;

  void addListener(VoidCallback listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<VoidCallback>.from(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}

abstract interface class LocalModelArtifactDownloader {
  Future<void> download({
    required Uri uri,
    required File destination,
    required int expectedBytes,
    required LocalModelCancellation cancellation,
    required ValueChanged<int> onProgress,
  });
}

class LocalModelHttpResponse {
  const LocalModelHttpResponse({
    required this.statusCode,
    required this.body,
    this.redirectLocation,
    this.contentRange,
    this.contentLength = -1,
  });

  final int statusCode;
  final Stream<List<int>> body;
  final Uri? redirectLocation;
  final String? contentRange;
  final int contentLength;
}

abstract interface class LocalModelHttpTransport {
  Future<LocalModelHttpResponse> get(Uri uri, {required int? rangeStart});

  void close({bool force = false});
}

class IoLocalModelHttpTransport implements LocalModelHttpTransport {
  IoLocalModelHttpTransport()
    : _client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 60)
        ..idleTimeout = const Duration(seconds: 30)
        ..userAgent = 'MomentAI-ModelCenter/1';

  final HttpClient _client;

  @override
  Future<LocalModelHttpResponse> get(
    Uri uri, {
    required int? rangeStart,
  }) async {
    final request = await _client.getUrl(uri);
    request.followRedirects = false;
    request.maxRedirects = 0;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (rangeStart != null) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$rangeStart-');
    }
    final response = await request.close();
    final location = response.headers.value(HttpHeaders.locationHeader);
    return LocalModelHttpResponse(
      statusCode: response.statusCode,
      body: response,
      redirectLocation: location == null ? null : uri.resolve(location),
      contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
      contentLength: response.contentLength,
    );
  }

  @override
  void close({bool force = false}) => _client.close(force: force);
}

class HttpLocalModelArtifactDownloader implements LocalModelArtifactDownloader {
  HttpLocalModelArtifactDownloader({
    LocalModelHttpTransport Function()? transportFactory,
  }) : _transportFactory = transportFactory ?? IoLocalModelHttpTransport.new;

  static const _maximumRedirects = 5;
  final LocalModelHttpTransport Function() _transportFactory;

  @override
  Future<void> download({
    required Uri uri,
    required File destination,
    required int expectedBytes,
    required LocalModelCancellation cancellation,
    required ValueChanged<int> onProgress,
  }) async {
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw LocalModelDownloadSourceException(l10n.theModelDownloadUrlMustBeA);
    }
    await destination.parent.create(recursive: true);
    var existing = await destination.exists() ? await destination.length() : 0;
    if (existing < 0 || existing > expectedBytes) {
      await destination.delete();
      existing = 0;
    }
    if (existing == expectedBytes) {
      onProgress(existing);
      return;
    }

    final transport = _transportFactory();
    cancellation.addListener(() => transport.close(force: true));
    RandomAccessFile? sink;
    try {
      var target = uri;
      LocalModelHttpResponse? response;
      for (var redirectCount = 0; ; redirectCount++) {
        if (!_isSecureModelUri(target)) {
          throw LocalModelDownloadSourceException(
            l10n.theModelDownloadWasRedirectedToAn,
          );
        }
        response = await transport.get(
          target,
          rangeStart: existing > 0 ? existing : null,
        );
        if (!_isRedirectStatus(response.statusCode)) break;
        final next = response.redirectLocation;
        await response.body.drain<void>();
        if (next == null) {
          throw LocalModelDownloadSourceException(
            l10n.theModelDownloadRedirectHasNoDestination,
          );
        }
        if (redirectCount >= _maximumRedirects) {
          throw LocalModelDownloadSourceException(
            l10n.tooManyModelDownloadRedirects,
          );
        }
        target = next;
      }

      final resolvedResponse = response;
      var append = existing > 0;
      if (append && resolvedResponse.statusCode == HttpStatus.ok) {
        final contentLength = resolvedResponse.contentLength;
        if (contentLength >= 0 && contentLength != expectedBytes) {
          throw LocalModelDownloadSourceException(
            l10n.theServerIgnoredTheResumeRequestAnd,
          );
        }
        append = false;
      }
      if ((!append && resolvedResponse.statusCode != HttpStatus.ok) ||
          (append &&
              resolvedResponse.statusCode != HttpStatus.partialContent)) {
        throw LocalModelDownloadSourceException(
          l10n.modelDownloadFailedHttp(
            (resolvedResponse.statusCode).toString(),
          ),
        );
      }
      if (append &&
          !_contentRangeIsValid(
            resolvedResponse,
            expectedStart: existing,
            expectedTotal: expectedBytes,
          )) {
        throw LocalModelDownloadSourceException(
          l10n.theServerReturnedAnIncorrectByteRange,
        );
      }

      sink = await destination.open(
        mode: append ? FileMode.append : FileMode.write,
      );
      var written = append ? existing : 0;
      onProgress(written);
      await for (final chunk in resolvedResponse.body) {
        if (cancellation.isCancelled) throw const LocalModelDownloadPaused();
        written += chunk.length;
        if (written > expectedBytes) {
          throw LocalModelIntegrityException(
            l10n.theModelFileExceedsItsDeclaredSize,
          );
        }
        await sink.writeFrom(chunk);
        onProgress(written);
      }
      await sink.flush();
      if (cancellation.isCancelled) throw const LocalModelDownloadPaused();
      if (written != expectedBytes) {
        throw LocalModelDownloadSourceException(
          l10n.modelDownloadIsIncompleteBytesYouCan(
            (written).toString(),
            (expectedBytes).toString(),
          ),
        );
      }
    } on LocalModelDownloadPaused {
      rethrow;
    } on FileSystemException {
      rethrow;
    } on LocalModelOperationException {
      rethrow;
    } catch (_) {
      if (cancellation.isCancelled) throw const LocalModelDownloadPaused();
      throw LocalModelDownloadSourceException(
        l10n.theModelDownloadConnectionOrTransferWas,
      );
    } finally {
      await sink?.close();
      transport.close(force: true);
    }
  }
}

bool _isSecureModelUri(Uri uri) => uri.scheme == 'https' && uri.host.isNotEmpty;

bool _isRedirectStatus(int statusCode) => const {
  HttpStatus.movedPermanently,
  HttpStatus.found,
  HttpStatus.seeOther,
  HttpStatus.temporaryRedirect,
  HttpStatus.permanentRedirect,
}.contains(statusCode);

bool _contentRangeIsValid(
  LocalModelHttpResponse response, {
  required int expectedStart,
  required int expectedTotal,
}) {
  final value = response.contentRange;
  if (value == null) return false;
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
  if (match == null) return false;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final total = int.tryParse(match.group(3)!);
  if (start != expectedStart ||
      end == null ||
      total != expectedTotal ||
      end < expectedStart ||
      end >= expectedTotal) {
    return false;
  }
  final expectedContentLength = end - expectedStart + 1;
  return response.contentLength < 0 ||
      response.contentLength == expectedContentLength;
}

abstract interface class LocalModelArchiveExtractor {
  Future<void> extract({
    required File archive,
    required Directory destination,
    required LocalModelManifest manifest,
    required LocalModelDownloadArtifact artifact,
  });
}

class TarBzip2LocalModelArchiveExtractor implements LocalModelArchiveExtractor {
  const TarBzip2LocalModelArchiveExtractor();

  @override
  Future<void> extract({
    required File archive,
    required Directory destination,
    required LocalModelManifest manifest,
    required LocalModelDownloadArtifact artifact,
  }) => Isolate.run(
    () => _extractTarBzip2Model(
      archive.path,
      destination.path,
      artifact.archiveRoot ?? manifest.id,
      {
        for (final file in manifest.files)
          if (file.artifactId == artifact.id) file.archivePath: file.byteCount,
      },
    ),
  );
}

Future<void> _extractTarBzip2Model(
  String archivePath,
  String destinationPath,
  String archiveRoot,
  Map<String, int> expectedFiles,
) async {
  final destination = Directory(destinationPath);
  await destination.create(recursive: true);
  final temporaryTar = File('$destinationPath/.payload.tar');
  InputFileStream? compressed;
  OutputFileStream? uncompressed;
  InputFileStream? tarInput;
  try {
    compressed = InputFileStream(archivePath);
    uncompressed = OutputFileStream(temporaryTar.path);
    BZip2Decoder().decodeBuffer(compressed, output: uncompressed, verify: true);
    await compressed.close();
    compressed = null;
    await uncompressed.close();
    uncompressed = null;

    tarInput = InputFileStream(temporaryTar.path);
    final decoded = TarDecoder().decodeBuffer(tarInput);
    final extracted = <String>{};
    for (final entry in decoded.files) {
      final name = entry.name;
      if (name.contains('\\') ||
          name.startsWith('/') ||
          name.split('/').any((part) => part == '..')) {
        throw LocalModelIntegrityException(
          l10n.theModelArchiveContainsAnUnsafePath,
        );
      }
      if (entry.isSymbolicLink) {
        throw LocalModelIntegrityException(
          l10n.symbolicLinksAreNotAllowedInModel,
        );
      }
      for (final expected in expectedFiles.entries) {
        if (name != '$archiveRoot/${expected.key}') continue;
        if (!entry.isFile || entry.size != expected.value) {
          throw LocalModelIntegrityException(
            l10n.unexpectedModelFileSize((expected.key).toString()),
          );
        }
        if (!extracted.add(expected.key)) {
          throw LocalModelIntegrityException(
            l10n.duplicateFileInModelArchive((expected.key).toString()),
          );
        }
        final output = OutputFileStream('$destinationPath/${expected.key}');
        entry.writeContent(output);
        await output.close();
      }
    }
    final missing = expectedFiles.keys.where(
      (name) => !extracted.contains(name),
    );
    if (missing.isNotEmpty) {
      throw LocalModelIntegrityException(
        l10n.missingFileInModelArchive((missing.join('、')).toString()),
      );
    }
  } finally {
    await compressed?.close();
    await uncompressed?.close();
    await tarInput?.close();
    if (await temporaryTar.exists()) await temporaryTar.delete();
  }
}

abstract interface class LocalModelAssetSource {
  Future<void> copyAsset(String assetPath, File destination);
}

class BundleLocalModelAssetSource implements LocalModelAssetSource {
  const BundleLocalModelAssetSource();

  @override
  Future<void> copyAsset(String assetPath, File destination) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes, flush: true);
  }
}

abstract interface class LocalModelStorageProbe {
  Future<void> prepareStorage(String path);

  Future<int?> availableBytes(String path);
}

class PlatformLocalModelStorageProbe implements LocalModelStorageProbe {
  const PlatformLocalModelStorageProbe();

  static const _channel = MethodChannel('momentai/model_center');

  @override
  Future<void> prepareStorage(String path) =>
      _channel.invokeMethod<void>('prepareModelStorage', {'path': path});

  @override
  Future<int?> availableBytes(String path) async {
    final value = await _channel.invokeMethod<Object?>(
      'availableStorageBytes',
      {'path': path},
    );
    return switch (value) {
      int bytes => bytes,
      num bytes => bytes.round(),
      _ => null,
    };
  }
}

typedef LocalModelRootResolver = Future<Directory> Function();
typedef LocalModelResourceBusy = bool Function();

class LocalModelManager extends ChangeNotifier
    implements LocalModelRuntimeResolver {
  LocalModelManager({
    List<LocalModelManifest>? catalog,
    LocalModelRootResolver? rootResolver,
    LocalModelArtifactDownloader? downloader,
    LocalModelArchiveExtractor? extractor,
    LocalModelAssetSource? assetSource,
    LocalModelStorageProbe? storageProbe,
    LocalModelResourceBusy? resourceBusy,
  }) : catalog = List.unmodifiable(catalog ?? OfficialLocalModelCatalog.models),
       _rootResolver = rootResolver ?? _defaultRootResolver,
       _downloader = downloader ?? HttpLocalModelArtifactDownloader(),
       _extractor = extractor ?? const TarBzip2LocalModelArchiveExtractor(),
       _assetSource = assetSource ?? const BundleLocalModelAssetSource(),
       _storageProbe = storageProbe ?? const PlatformLocalModelStorageProbe(),
       _resourceBusy = resourceBusy ?? _neverBusy;

  final List<LocalModelManifest> catalog;
  final LocalModelRootResolver _rootResolver;
  final LocalModelArtifactDownloader _downloader;
  final LocalModelArchiveExtractor _extractor;
  final LocalModelAssetSource _assetSource;
  final LocalModelStorageProbe _storageProbe;
  final LocalModelResourceBusy _resourceBusy;
  final Map<String, LocalModelInstallState> _states = {};
  final Map<String, LocalModelCancellation> _cancellations = {};

  Future<void>? _initialization;
  Future<void>? _refinementSuggestionPersistence;
  Directory? _root;
  bool _initialized = false;
  bool _refinementSuggestionDismissed = false;
  RealtimeModelRuntimeSwitcher? _runtimeSwitcher;
  String _activeRealtimeModelId = lightweightRealtimeModelId;
  String? _globalMessage;

  LocalModelManagerSnapshot get snapshot => LocalModelManagerSnapshot(
    initialized: _initialized,
    activeRealtimeModelId: _activeRealtimeModelId,
    models: [
      for (final manifest in catalog)
        _states[manifest.id] ??
            LocalModelInstallState(
              manifest: manifest,
              phase: LocalModelInstallPhase.unavailable,
            ),
    ],
    refinementSuggestionDismissed: _refinementSuggestionDismissed,
    globalMessage: _globalMessage,
  );

  bool get hasOperation => _states.values.any((state) => state.busy);

  void attachRuntimeSwitcher(RealtimeModelRuntimeSwitcher switcher) {
    _runtimeSwitcher = switcher;
  }

  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;
    late final Future<void> future;
    future = () async {
      try {
        await _initializeOnce();
      } finally {
        if (!_initialized && identical(_initialization, future)) {
          _initialization = null;
        }
      }
    }();
    _initialization = future;
    return future;
  }

  Future<void> _initializeOnce() async {
    final root = await _rootResolver();
    _root = root;
    await root.create(recursive: true);
    _refinementSuggestionDismissed = await _readRefinementSuggestion(root);
    try {
      await _storageProbe.prepareStorage(root.path);
    } catch (_) {
      _globalMessage = l10n.couldNotExcludeTheModelFolderFrom;
    }
    await _cleanStaging(root);
    for (final manifest in catalog) {
      if (manifest.bundled) {
        await _ensureBundledModel(root, manifest);
      } else {
        final installed = await _hasValidInstallMarker(root, manifest);
        var partialBytes = await _downloadedBytes(root, manifest);
        if (installed && partialBytes > 0) {
          await _deleteDownloads(root, manifest);
          partialBytes = 0;
        }
        _states[manifest.id] = LocalModelInstallState(
          manifest: manifest,
          phase: installed
              ? LocalModelInstallPhase.installed
              : partialBytes > 0
              ? LocalModelInstallPhase.paused
              : LocalModelInstallPhase.unavailable,
          downloadedBytes: installed
              ? manifest.downloadByteCount
              : partialBytes,
          message: !installed && partialBytes > 0
              ? l10n.yourDownloadProgressIsSavedYouCan
              : null,
        );
      }
    }
    final restoredSelection = await _restoreActiveSelection(root);
    if (!restoredSelection) {
      await _persistActiveSelection(
        root,
        _manifest(lightweightRealtimeModelId),
      );
    }
    _refreshActivePhases();
    _initialized = true;
    notifyListeners();
  }

  Future<void> _cleanStaging(Directory root) async {
    final staging = Directory('${root.path}/staging');
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
  }

  Future<void> _ensureBundledModel(
    Directory root,
    LocalModelManifest manifest,
  ) async {
    if (await _hasValidInstallMarker(root, manifest)) {
      _states[manifest.id] = LocalModelInstallState(
        manifest: manifest,
        phase: LocalModelInstallPhase.bundled,
        downloadedBytes: manifest.installedByteCount,
      );
      return;
    }
    final staging = Directory(
      '${root.path}/staging/${manifest.id}-${DateTime.now().microsecondsSinceEpoch}',
    );
    await staging.create(recursive: true);
    try {
      for (final file in manifest.files) {
        final assetPath = file.assetPath;
        if (assetPath == null) {
          throw LocalModelOperationException(
            l10n.missingBundledModelAsset((file.archivePath).toString()),
          );
        }
        await _assetSource.copyAsset(
          assetPath,
          File('${staging.path}/${file.archivePath}'),
        );
      }
      await _verifyFilesInDirectory(staging, manifest, fullHash: true);
      await _writeInstallMarker(staging, manifest);
      await _commitInstallation(root, staging, manifest);
      _states[manifest.id] = LocalModelInstallState(
        manifest: manifest,
        phase: LocalModelInstallPhase.bundled,
        downloadedBytes: manifest.installedByteCount,
      );
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> download(String modelId) async {
    await initialize();
    final manifest = _manifest(modelId);
    if (!manifest.downloadable) {
      throw LocalModelOperationException(l10n.thisModelIsIncludedWithTheApp);
    }
    _ensureResourcesIdle();
    if (hasOperation) {
      throw LocalModelOperationException(
        l10n.anotherModelOperationIsInProgress,
      );
    }
    if (await _hasValidInstallMarker(_root!, manifest)) {
      _setState(
        modelId,
        LocalModelInstallPhase.installed,
        downloadedBytes: manifest.downloadByteCount,
      );
      return;
    }

    final existing = await _downloadedBytes(_root!, manifest);
    await _ensureStorage(manifest, existing);
    final cancellation = LocalModelCancellation();
    _cancellations[modelId] = cancellation;
    final transferClock = Stopwatch()..start();
    var transferBaseBytes = existing;
    _setState(
      modelId,
      LocalModelInstallPhase.downloading,
      downloadedBytes: existing,
      resumedFromBytes: transferBaseBytes,
      bytesPerSecond: 0,
      clearMessage: true,
    );
    var lastReportedBytes = existing;

    void resetTransferMetrics(int downloaded, {String? message}) {
      transferBaseBytes = downloaded;
      lastReportedBytes = downloaded;
      transferClock
        ..reset()
        ..start();
      _setState(
        modelId,
        LocalModelInstallPhase.downloading,
        downloadedBytes: downloaded,
        resumedFromBytes: downloaded,
        bytesPerSecond: 0,
        message: message,
        clearMessage: message == null,
      );
    }

    void reportProgress(int downloaded) {
      if (cancellation.isCancelled) return;
      if (downloaded < lastReportedBytes) {
        resetTransferMetrics(downloaded);
        return;
      }
      if (downloaded != manifest.downloadByteCount &&
          downloaded - lastReportedBytes < 512 * 1024) {
        return;
      }
      lastReportedBytes = downloaded;
      final elapsedSeconds =
          transferClock.elapsedMicroseconds / Duration.microsecondsPerSecond;
      final speed = elapsedSeconds > 0
          ? (downloaded - transferBaseBytes) / elapsedSeconds
          : 0.0;
      _setState(
        modelId,
        LocalModelInstallPhase.downloading,
        downloadedBytes: downloaded,
        resumedFromBytes: transferBaseBytes,
        bytesPerSecond: speed,
        clearMessage: true,
      );
    }

    try {
      var completedBytes = 0;
      for (final artifact in manifest.artifacts) {
        final part = _downloadFile(_root!, manifest, artifact);
        await part.parent.create(recursive: true);
        final partBytes = await part.exists() ? await part.length() : 0;
        if (partBytes > artifact.byteCount) {
          await part.delete();
        }
        var verified = false;
        for (
          var sourceIndex = 0;
          sourceIndex < artifact.downloadSources.length;
          sourceIndex++
        ) {
          final source = artifact.downloadSources[sourceIndex];
          try {
            await _downloader.download(
              uri: source.uri,
              destination: part,
              expectedBytes: artifact.byteCount,
              cancellation: cancellation,
              onProgress: (bytes) => reportProgress(completedBytes + bytes),
            );
            _ensureResourcesIdle();
            _setState(
              modelId,
              LocalModelInstallPhase.verifying,
              downloadedBytes: completedBytes + artifact.byteCount,
              clearMessage: true,
              clearTransferMetrics: true,
            );
            await _verifyArtifact(part, artifact);
            verified = true;
            break;
          } on LocalModelDownloadPaused {
            rethrow;
          } catch (error) {
            final integrityFailure = _isIntegrityFailure(error);
            final sourceFailure = error is LocalModelDownloadSourceException;
            final hasFallback =
                sourceIndex + 1 < artifact.downloadSources.length;
            if ((!sourceFailure && !integrityFailure) || !hasFallback) {
              if (integrityFailure && await part.exists()) {
                await part.delete();
              }
              if (sourceFailure) {
                throw LocalModelDownloadSourceException(
                  l10n.downloadFromFailed(
                    (source.name).toString(),
                    (_message(error)).toString(),
                  ),
                );
              }
              rethrow;
            }
            if (integrityFailure && await part.exists()) {
              await part.delete();
            }
            final retainedBytes = await part.exists() ? await part.length() : 0;
            final fallback = artifact.downloadSources[sourceIndex + 1];
            resetTransferMetrics(
              completedBytes + retainedBytes,
              message: integrityFailure
                  ? l10n.verificationFailedForDownloadingAgainFrom(
                      (source.name).toString(),
                      (fallback.name).toString(),
                    )
                  : l10n.isUnavailableSwitchingTo(
                      (source.name).toString(),
                      (fallback.name).toString(),
                    ),
            );
          }
        }
        if (!verified) {
          throw LocalModelOperationException(
            l10n.noModelDownloadSourceIsAvailable,
          );
        }
        completedBytes += artifact.byteCount;
      }
      _ensureResourcesIdle();
      _setState(
        modelId,
        LocalModelInstallPhase.installing,
        downloadedBytes: manifest.downloadByteCount,
        clearMessage: true,
        clearTransferMetrics: true,
      );
      await _installDownloadedArtifacts(manifest);
      _setState(
        modelId,
        LocalModelInstallPhase.installed,
        downloadedBytes: manifest.downloadByteCount,
        clearMessage: true,
        clearTransferMetrics: true,
      );
      await _deleteDownloads(_root!, manifest);
    } on LocalModelDownloadPaused {
      final bytes = await _downloadedBytes(_root!, manifest);
      _setState(
        modelId,
        LocalModelInstallPhase.paused,
        downloadedBytes: bytes,
        message: l10n.downloadPausedSavedYouCanResumeFrom(
          (_formatBytes(bytes)).toString(),
        ),
      );
    } catch (error) {
      final bytes = await _downloadedBytes(_root!, manifest);
      _setState(
        modelId,
        LocalModelInstallPhase.failed,
        downloadedBytes: bytes,
        message: _message(error),
      );
      rethrow;
    } finally {
      _cancellations.remove(modelId);
    }
  }

  void pause(String modelId) => _cancellations[modelId]?.cancel();

  Future<void> restartDownload(String modelId) async {
    await initialize();
    _ensureResourcesIdle();
    if (hasOperation) {
      throw LocalModelOperationException(
        l10n.anotherModelOperationIsInProgress,
      );
    }
    final manifest = _manifest(modelId);
    if (!manifest.downloadable) {
      throw LocalModelOperationException(l10n.thisModelIsIncludedWithTheApp);
    }
    await _deleteDownloads(_root!, manifest);
    _setState(
      modelId,
      LocalModelInstallPhase.unavailable,
      downloadedBytes: 0,
      clearMessage: true,
      clearTransferMetrics: true,
    );
    await download(modelId);
  }

  Future<void> dismissRefinementSuggestion() async {
    if (!_initialized) await initialize();
    if (_refinementSuggestionDismissed) {
      await _refinementSuggestionPersistence;
      return;
    }
    _refinementSuggestionDismissed = true;
    notifyListeners();
    late final Future<void> persistence;
    persistence = _writeJsonAtomically(
      File('${_root!.path}/$_refinementSuggestionFileName'),
      {'schemaVersion': _refinementSuggestionSchemaVersion, 'dismissed': true},
    );
    _refinementSuggestionPersistence = persistence;
    try {
      await persistence;
    } catch (_) {
      _refinementSuggestionDismissed = false;
      notifyListeners();
      rethrow;
    } finally {
      if (identical(_refinementSuggestionPersistence, persistence)) {
        _refinementSuggestionPersistence = null;
      }
    }
  }

  Future<void> verify(String modelId) async {
    await initialize();
    if (hasOperation) {
      throw LocalModelOperationException(
        l10n.anotherModelOperationIsInProgress,
      );
    }
    _ensureResourcesIdle();
    final manifest = _manifest(modelId);
    final previous = _states[modelId];
    if (previous?.installed != true) {
      throw LocalModelOperationException(l10n.theModelIsNotInstalled);
    }
    _setState(modelId, LocalModelInstallPhase.verifying, clearMessage: true);
    try {
      await _verifyInstalledFiles(_root!, manifest, fullHash: true);
      _setState(
        modelId,
        modelId == _activeRealtimeModelId
            ? LocalModelInstallPhase.active
            : manifest.bundled
            ? LocalModelInstallPhase.bundled
            : LocalModelInstallPhase.installed,
        message: l10n.verificationPassed,
      );
    } catch (error) {
      _setState(
        modelId,
        LocalModelInstallPhase.failed,
        message: _message(error),
      );
      rethrow;
    }
  }

  Future<void> activateRealtime(String modelId) async {
    await initialize();
    _ensureResourcesIdle();
    if (hasOperation) {
      throw LocalModelOperationException(
        l10n.anotherModelOperationIsInProgress,
      );
    }
    final manifest = _manifest(modelId);
    if (manifest.kind != LocalModelKind.realtime) {
      throw LocalModelOperationException(l10n.aRefinementModelCannotBeUsedFor);
    }
    if (modelId == _activeRealtimeModelId) return;
    final switcher = _runtimeSwitcher;
    if (switcher == null) {
      throw LocalModelOperationException(
        l10n.theLiveTranscriptionEngineIsNotReady,
      );
    }
    final previous = _activeRealtimeModelId;
    RealtimeModelFiles? previousFiles;
    var runtimeSwitched = false;
    var candidateVerified = false;
    _globalMessage = null;
    // Reserve the operation before the first file read: hashing can take seconds
    // on older phones, and concurrent taps must not race native model lifetimes.
    _setState(modelId, LocalModelInstallPhase.verifying, clearMessage: true);
    try {
      final candidate = await _realtimeFiles(manifest, fullHash: true);
      candidateVerified = true;
      previousFiles = await _realtimeFiles(_manifest(previous), fullHash: true);
      _ensureResourcesIdle();
      _setState(modelId, LocalModelInstallPhase.switching, clearMessage: true);
      await switcher.switchToRealtimeModel(candidate);
      runtimeSwitched = true;
      await _persistActiveSelection(_root!, manifest);
      _activeRealtimeModelId = modelId;
      _states[modelId] = _states[modelId]!.copyWith(
        phase: LocalModelInstallPhase.installed,
      );
      _globalMessage = l10n.switchedTo((manifest.name).toString());
      _refreshActivePhases();
      notifyListeners();
    } catch (error) {
      Object? rollbackError;
      if (runtimeSwitched) {
        try {
          await switcher.switchToRealtimeModel(previousFiles!);
        } catch (value) {
          rollbackError = value;
        }
      }
      _activeRealtimeModelId = previous;
      _refreshActivePhases();
      _globalMessage = rollbackError == null
          ? l10n.switchFailedStillUsing((_manifest(previous).name).toString())
          : l10n.theSwitchCouldNotBeSavedAnd;
      _setState(
        modelId,
        candidateVerified
            ? LocalModelInstallPhase.installed
            : LocalModelInstallPhase.failed,
        message: rollbackError == null
            ? _message(error)
            : l10n.restoreFailed(
                (_message(error)).toString(),
                (_message(rollbackError)).toString(),
              ),
      );
      if (rollbackError != null) {
        throw LocalModelOperationException(_globalMessage!);
      }
      rethrow;
    }
  }

  Future<void> remove(String modelId) async {
    await initialize();
    _ensureResourcesIdle();
    if (hasOperation) {
      throw LocalModelOperationException(
        l10n.anotherModelOperationIsInProgress,
      );
    }
    final manifest = _manifest(modelId);
    if (manifest.bundled) {
      throw LocalModelOperationException(
        l10n.theBuiltInLightweightModelCannotBe,
      );
    }
    if (modelId == _activeRealtimeModelId) {
      throw LocalModelOperationException(
        l10n.theActiveLiveModelCannotBeDeleted,
      );
    }
    _setState(modelId, LocalModelInstallPhase.removing, clearMessage: true);
    try {
      final directory = _installationDirectory(_root!, manifest);
      if (await directory.exists()) await directory.delete(recursive: true);
      await _deleteDownloads(_root!, manifest);
      _setState(
        modelId,
        LocalModelInstallPhase.unavailable,
        downloadedBytes: 0,
        clearMessage: true,
      );
    } catch (error) {
      _setState(
        modelId,
        LocalModelInstallPhase.installed,
        message: l10n.couldNotDeleteTheModelItIs((_message(error)).toString()),
      );
      rethrow;
    }
  }

  @override
  Future<RealtimeModelFiles> activeRealtimeModelFiles() async {
    await initialize();
    var manifest = _manifest(_activeRealtimeModelId);
    try {
      return await _realtimeFiles(manifest, fullHash: true);
    } catch (_) {
      manifest = _manifest(lightweightRealtimeModelId);
      final fallback = await _realtimeFiles(manifest, fullHash: true);
      _activeRealtimeModelId = lightweightRealtimeModelId;
      await _persistActiveSelection(_root!, manifest);
      _globalMessage = l10n.thePreviousLiveModelFailedVerificationSwitched;
      _refreshActivePhases();
      notifyListeners();
      return fallback;
    }
  }

  @override
  Future<RefinementModelFiles?> refinementModelFiles() async {
    await initialize();
    final manifest = _manifest(senseVoiceRefinementModelId);
    if (_states[manifest.id]?.installed != true) return null;
    try {
      final paths = await _installedPaths(manifest, fullHash: false);
      return RefinementModelFiles(
        modelId: manifest.id,
        modelPath: paths['model']!,
        tokensPath: paths['tokens']!,
      );
    } catch (error) {
      _setState(
        manifest.id,
        LocalModelInstallPhase.failed,
        message: _message(error),
      );
      return null;
    }
  }

  @override
  Future<SpeakerDiarizationModelFiles?> speakerDiarizationModelFiles() async {
    await initialize();
    final manifest = _manifest(speakerDiarizationModelId);
    if (_states[manifest.id]?.installed != true) return null;
    try {
      final paths = await _installedPaths(manifest, fullHash: false);
      return SpeakerDiarizationModelFiles(
        modelId: manifest.id,
        segmentationPath: paths['segmentation']!,
        embeddingPath: paths['embedding']!,
      );
    } catch (error) {
      _setState(
        manifest.id,
        LocalModelInstallPhase.failed,
        message: _message(error),
      );
      return null;
    }
  }

  Future<RealtimeModelFiles> _realtimeFiles(
    LocalModelManifest manifest, {
    required bool fullHash,
  }) async {
    final paths = await _installedPaths(manifest, fullHash: fullHash);
    return RealtimeModelFiles(modelId: manifest.id, paths: paths);
  }

  Future<Map<String, String>> _installedPaths(
    LocalModelManifest manifest, {
    required bool fullHash,
  }) async {
    await _verifyInstalledFiles(_root!, manifest, fullHash: fullHash);
    final directory = _installationDirectory(_root!, manifest);
    return {
      for (final file in manifest.files)
        file.logicalName: '${directory.path}/${file.archivePath}',
    };
  }

  Future<void> _verifyArtifact(
    File file,
    LocalModelDownloadArtifact artifact,
  ) async {
    final actualBytes = await file.length();
    if (actualBytes != artifact.byteCount) {
      throw LocalModelIntegrityException(
        l10n.theDownloadedModelSizeDoesNotMatch,
      );
    }
    final actualHash = await _fileSha256(file);
    if (actualHash != artifact.sha256) {
      throw LocalModelIntegrityException(
        l10n.theDownloadedModelFailedShaVerification,
      );
    }
  }

  Future<void> _installDownloadedArtifacts(LocalModelManifest manifest) async {
    final staging = Directory(
      '${_root!.path}/staging/${manifest.id}-${DateTime.now().microsecondsSinceEpoch}',
    );
    await staging.create(recursive: true);
    final watch = Stopwatch()..start();
    var phase = 'preparing';
    var observedBytes = 0;
    var checking = false;
    var finished = false;
    Future<void> report() async {
      if (checking || finished) return;
      checking = true;
      try {
        final payload = File('${staging.path}/.payload.tar');
        if (await payload.exists()) observedBytes = await payload.length();
        if (finished) return;
        final time =
            '${watch.elapsed.inMinutes}:${(watch.elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
        _setState(
          manifest.id,
          LocalModelInstallPhase.installing,
          message: phase == 'verifying'
              ? l10n.modelInstallVerifying(time)
              : l10n.modelInstallExtracting(_formatBytes(observedBytes), time),
        );
      } on FileSystemException {
        // The extractor may remove its temporary tar.
      } finally {
        checking = false;
      }
    }

    await report();
    final progressTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(report()),
    );
    try {
      for (final artifact in manifest.artifacts) {
        final part = _downloadFile(_root!, manifest, artifact);
        await _verifyArtifact(part, artifact);
        switch (artifact.format) {
          case LocalModelArtifactFormat.tarBzip2:
            await _extractor.extract(
              archive: part,
              destination: staging,
              manifest: manifest,
              artifact: artifact,
            );
            break;
          case LocalModelArtifactFormat.directFile:
            final installPath = artifact.installPath;
            if (installPath == null || !_isSafeRelativePath(installPath)) {
              throw LocalModelIntegrityException(
                l10n.theModelFileHasNoSafeInstallation,
              );
            }
            final output = File('${staging.path}/$installPath');
            await output.parent.create(recursive: true);
            await part.openRead().pipe(output.openWrite());
            break;
        }
      }
      phase = 'verifying';
      await report();
      await _verifyFilesInDirectory(staging, manifest, fullHash: true);
      await _writeInstallMarker(staging, manifest);
      await _commitInstallation(_root!, staging, manifest);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    } finally {
      finished = true;
      progressTimer.cancel();
      watch.stop();
    }
  }

  Future<void> _commitInstallation(
    Directory root,
    Directory staging,
    LocalModelManifest manifest,
  ) async {
    final finalDirectory = _installationDirectory(root, manifest);
    await finalDirectory.parent.create(recursive: true);
    if (await finalDirectory.exists()) {
      if (await _verifyDirectoryMarker(finalDirectory, manifest)) {
        await staging.delete(recursive: true);
        return;
      }
      final quarantine = Directory(
        '${finalDirectory.path}.invalid-${DateTime.now().microsecondsSinceEpoch}',
      );
      await finalDirectory.rename(quarantine.path);
      try {
        await staging.rename(finalDirectory.path);
        await quarantine.delete(recursive: true);
      } catch (_) {
        if (!await finalDirectory.exists() && await quarantine.exists()) {
          await quarantine.rename(finalDirectory.path);
        }
        rethrow;
      }
      return;
    }
    await staging.rename(finalDirectory.path);
  }

  Future<void> _writeInstallMarker(
    Directory directory,
    LocalModelManifest manifest,
  ) => _writeJsonAtomically(File('${directory.path}/install.json'), {
    'schemaVersion': 1,
    'catalogSchemaVersion': OfficialLocalModelCatalog.schemaVersion,
    'modelId': manifest.id,
    'version': manifest.version,
    'archiveSha256': manifest.archiveSha256,
    'artifacts': [
      for (final artifact in manifest.artifacts)
        {
          'id': artifact.id,
          'byteCount': artifact.byteCount,
          'sha256': artifact.sha256,
        },
    ],
    'installedAt': DateTime.now().toUtc().toIso8601String(),
    'files': [
      for (final file in manifest.files)
        {
          'path': file.archivePath,
          'byteCount': file.byteCount,
          'sha256': file.sha256,
        },
    ],
  });

  Future<bool> _hasValidInstallMarker(
    Directory root,
    LocalModelManifest manifest,
  ) => _verifyDirectoryMarker(_installationDirectory(root, manifest), manifest);

  Future<bool> _verifyDirectoryMarker(
    Directory directory,
    LocalModelManifest manifest,
  ) async {
    if (!await directory.exists()) return false;
    final marker = File('${directory.path}/install.json');
    if (!await marker.exists()) return false;
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map) return false;
      if (decoded['schemaVersion'] != 1 ||
          decoded['modelId'] != manifest.id ||
          decoded['version'] != manifest.version) {
        return false;
      }
      if (manifest.downloadArtifacts.isEmpty) {
        if (decoded['archiveSha256'] != manifest.archiveSha256) return false;
      } else if (!_markerArtifactsMatch(decoded['artifacts'], manifest)) {
        return false;
      }
      await _verifyFilesInDirectory(directory, manifest, fullHash: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _verifyInstalledFiles(
    Directory root,
    LocalModelManifest manifest, {
    required bool fullHash,
  }) async {
    final directory = _installationDirectory(root, manifest);
    if (!await _verifyDirectoryMarker(directory, manifest)) {
      throw LocalModelOperationException(
        l10n.isNotFullyInstalled((manifest.name).toString()),
      );
    }
    await _verifyFilesInDirectory(directory, manifest, fullHash: fullHash);
  }

  Future<void> _verifyFilesInDirectory(
    Directory directory,
    LocalModelManifest manifest, {
    required bool fullHash,
  }) async {
    for (final expected in manifest.files) {
      final file = File('${directory.path}/${expected.archivePath}');
      if (!await file.exists() || await file.length() != expected.byteCount) {
        throw LocalModelIntegrityException(
          l10n.modelFileIsMissingOrHasAn((expected.archivePath).toString()),
        );
      }
      if (fullHash && await _fileSha256(file) != expected.sha256) {
        throw LocalModelIntegrityException(
          l10n.modelFileFailedShaVerification(
            (expected.archivePath).toString(),
          ),
        );
      }
    }
  }

  Future<void> _ensureStorage(
    LocalModelManifest manifest,
    int downloadedBytes,
  ) async {
    int? available;
    try {
      available = await _storageProbe.availableBytes(_root!.path);
    } catch (_) {
      throw LocalModelOperationException(
        l10n.couldNotCheckAvailableStorageDownloadStopped,
      );
    }
    if (available == null) return;
    final remainingDownload = manifest.downloadByteCount - downloadedBytes;
    final extractionReserve = manifest.installedByteCount * 2;
    const safetyReserve = 64 * 1024 * 1024;
    final required = remainingDownload + extractionReserve + safetyReserve;
    if (available < required) {
      throw LocalModelOperationException(
        l10n.notEnoughStorageAtLeastOfFree((_formatBytes(required)).toString()),
      );
    }
  }

  void _ensureResourcesIdle() {
    if (_resourceBusy()) {
      throw LocalModelOperationException(
        l10n.recordingTranscriptionRecoveryOrRefinementIsIn,
      );
    }
  }

  Future<bool> _restoreActiveSelection(Directory root) async {
    final pointer = File('${root.path}/active_realtime_v1.json');
    if (!await pointer.exists()) return false;
    try {
      final decoded = jsonDecode(await pointer.readAsString());
      if (decoded is! Map) return false;
      final modelId = decoded['modelId']?.toString();
      if (modelId == null) return false;
      final manifest = _manifest(modelId);
      if (manifest.kind != LocalModelKind.realtime ||
          !await _hasValidInstallMarker(root, manifest)) {
        return false;
      }
      _activeRealtimeModelId = modelId;
      return true;
    } catch (_) {
      _activeRealtimeModelId = lightweightRealtimeModelId;
      return false;
    }
  }

  Future<void> _persistActiveSelection(
    Directory root,
    LocalModelManifest manifest,
  ) => _writeJsonAtomically(File('${root.path}/active_realtime_v1.json'), {
    'schemaVersion': 1,
    'modelId': manifest.id,
    'version': manifest.version,
    'installationName': manifest.installationName,
  });

  Future<bool> _readRefinementSuggestion(Directory root) async {
    final file = File('${root.path}/$_refinementSuggestionFileName');
    if (!await file.exists()) return false;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map &&
          decoded['schemaVersion'] == _refinementSuggestionSchemaVersion &&
          decoded['dismissed'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeJsonAtomically(
    File destination,
    Map<String, Object?> value,
  ) async {
    final temporary = File('${destination.path}.part');
    await temporary.parent.create(recursive: true);
    await temporary.writeAsString('${jsonEncode(value)}\n', flush: true);
    try {
      await temporary.rename(destination.path);
    } on FileSystemException {
      final backup = File('${destination.path}.previous');
      if (await backup.exists()) await backup.delete();
      if (await destination.exists()) await destination.rename(backup.path);
      try {
        await temporary.rename(destination.path);
        if (await backup.exists()) await backup.delete();
      } catch (_) {
        if (!await destination.exists() && await backup.exists()) {
          await backup.rename(destination.path);
        }
        rethrow;
      }
    }
  }

  void _refreshActivePhases() {
    for (final entry in _states.entries.toList()) {
      final state = entry.value;
      if (state.busy || state.phase == LocalModelInstallPhase.failed) continue;
      if (entry.key == _activeRealtimeModelId) {
        _states[entry.key] = state.copyWith(
          phase: LocalModelInstallPhase.active,
        );
      } else if (state.installed) {
        _states[entry.key] = state.copyWith(
          phase: state.manifest.bundled
              ? LocalModelInstallPhase.bundled
              : LocalModelInstallPhase.installed,
        );
      }
    }
  }

  void _setState(
    String modelId,
    LocalModelInstallPhase phase, {
    int? downloadedBytes,
    int? resumedFromBytes,
    double? bytesPerSecond,
    String? message,
    bool clearMessage = false,
    bool clearTransferMetrics = false,
  }) {
    final current =
        _states[modelId] ??
        LocalModelInstallState(
          manifest: _manifest(modelId),
          phase: LocalModelInstallPhase.unavailable,
        );
    _states[modelId] = current.copyWith(
      phase: phase,
      downloadedBytes: downloadedBytes,
      resumedFromBytes: resumedFromBytes,
      bytesPerSecond: bytesPerSecond,
      message: message,
      clearMessage: clearMessage,
      clearTransferMetrics: clearTransferMetrics,
    );
    notifyListeners();
  }

  LocalModelManifest _manifest(String modelId) {
    for (final manifest in catalog) {
      if (manifest.id == modelId) return manifest;
    }
    throw LocalModelOperationException(l10n.unknownModel((modelId).toString()));
  }

  File _downloadFile(
    Directory root,
    LocalModelManifest manifest,
    LocalModelDownloadArtifact artifact,
  ) {
    final name = manifest.downloadArtifacts.isEmpty
        ? artifact.fileName
        : '${manifest.id}-${manifest.version}-${artifact.id}-${artifact.fileName}';
    return File('${root.path}/downloads/$name.part');
  }

  Future<int> _downloadedBytes(
    Directory root,
    LocalModelManifest manifest,
  ) async {
    var total = 0;
    for (final artifact in manifest.artifacts) {
      final part = _downloadFile(root, manifest, artifact);
      if (!await part.exists()) continue;
      final length = await part.length();
      if (length <= artifact.byteCount) total += length;
    }
    return total;
  }

  Future<void> _deleteDownloads(
    Directory root,
    LocalModelManifest manifest,
  ) async {
    for (final artifact in manifest.artifacts) {
      final part = _downloadFile(root, manifest, artifact);
      if (await part.exists()) await part.delete();
    }
  }

  Directory _installationDirectory(
    Directory root,
    LocalModelManifest manifest,
  ) => Directory(
    '${root.path}/installed/${manifest.id}/${manifest.installationName}',
  );

  static Future<Directory> _defaultRootResolver() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/MomentAI/Models');
  }

  static bool _neverBusy() => false;
}

bool _isSafeRelativePath(String value) =>
    value.isNotEmpty &&
    !value.startsWith('/') &&
    !value.contains('\\') &&
    !value.split('/').any((part) => part.isEmpty || part == '..');

bool _markerArtifactsMatch(Object? value, LocalModelManifest manifest) {
  if (value is! List || value.length != manifest.artifacts.length) return false;
  final actual = <String, Map<Object?, Object?>>{};
  for (final item in value) {
    if (item is! Map) return false;
    final id = item['id']?.toString();
    if (id == null || actual.containsKey(id)) return false;
    actual[id] = item;
  }
  for (final artifact in manifest.artifacts) {
    final item = actual[artifact.id];
    if (item == null ||
        item['byteCount'] != artifact.byteCount ||
        item['sha256'] != artifact.sha256) {
      return false;
    }
  }
  return true;
}

Future<String> _fileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

bool _isIntegrityFailure(Object error) => error is LocalModelIntegrityException;

String _message(Object error) => switch (error) {
  LocalModelOperationException value => value.message,
  _ => '$error',
};

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  return '${(bytes / (1024 * 1024)).ceil()} MB';
}

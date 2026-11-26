import 'package:flutter/services.dart';
import 'package:momentai/l10n/app_localization.dart';

enum ProductPermissionStatus {
  notDetermined,
  notGranted,
  authorized,
  denied,
  restricted,
  unavailable,
  unknown;

  factory ProductPermissionStatus.fromWireValue(String value) =>
      switch (value) {
        'not_determined' => notDetermined,
        'not_granted' => notGranted,
        'authorized' => authorized,
        'denied' => denied,
        'restricted' => restricted,
        'unavailable' => unavailable,
        _ => unknown,
      };

  bool get requiresSettings => this == denied || this == restricted;

  bool get canRequest => this == notGranted || this == notDetermined;
}

enum ProductPermission { microphone, camera }

class ProductPermissionException implements Exception {
  const ProductPermissionException(this.permission, this.status);

  final ProductPermission permission;
  final ProductPermissionStatus status;

  String get message {
    final name = permission == ProductPermission.microphone
        ? l10n.microphone
        : l10n.camera;
    if (status.requiresSettings) {
      return l10n.accessIsNotAllowedEnableItIn((name).toString());
    }
    if (status == ProductPermissionStatus.unavailable) {
      return l10n.isNotAvailableOnThisDevice((name).toString());
    }
    if (status == ProductPermissionStatus.unknown) {
      return l10n.couldNotReadPermissionsTryAgain((name).toString());
    }
    return l10n.permissionWasNotGrantedYouCanRequest((name).toString());
  }

  @override
  String toString() => message;
}

class ProductSystemOverview {
  const ProductSystemOverview({
    required this.microphonePermission,
    required this.cameraPermission,
    required this.appVersion,
    required this.buildNumber,
    required this.modelId,
  });

  const ProductSystemOverview.empty()
    : microphonePermission = ProductPermissionStatus.unknown,
      cameraPermission = ProductPermissionStatus.unknown,
      appVersion = '',
      buildNumber = '',
      modelId = '';

  factory ProductSystemOverview.fromMap(Map<Object?, Object?> map) =>
      ProductSystemOverview(
        microphonePermission: ProductPermissionStatus.fromWireValue(
          map['microphonePermission']?.toString() ?? '',
        ),
        cameraPermission: ProductPermissionStatus.fromWireValue(
          map['cameraPermission']?.toString() ?? '',
        ),
        appVersion: map['appVersion']?.toString() ?? '',
        buildNumber: map['buildNumber']?.toString() ?? '',
        modelId: map['modelId']?.toString() ?? '',
      );

  final ProductPermissionStatus microphonePermission;
  final ProductPermissionStatus cameraPermission;
  final String appVersion;
  final String buildNumber;
  final String modelId;
}

abstract interface class ProductSystemGateway {
  Future<ProductSystemOverview> overview();
  Future<void> openSystemSettings();
  Future<void> requestPermission(ProductPermission permission);
}

class NativeProductSystemGateway implements ProductSystemGateway {
  static const _channel = MethodChannel(
    'org.hohu.momentai.product/session_repository',
  );

  @override
  Future<ProductSystemOverview> overview() async {
    return ProductSystemOverview.fromMap(
      _map(await _channel.invokeMethod<Object?>('systemOverview')),
    );
  }

  @override
  Future<void> openSystemSettings() async {
    await _channel.invokeMethod<Object?>('openSystemSettings');
  }

  @override
  Future<void> requestPermission(ProductPermission permission) async {
    await _channel.invokeMethod<Object?>('requestPermission', {
      'permission': permission.name,
    });
  }
}

Map<Object?, Object?> _map(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  if (value is Map) return Map<Object?, Object?>.from(value);
  return const {};
}

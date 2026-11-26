import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/system/product_system_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.hohu.momentai.product/session_repository');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reads native permission states and opens app settings', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'openSystemSettings') return null;
      return {
        'microphonePermission': 'not_granted',
        'cameraPermission': 'authorized',
        'appVersion': '1.0.0',
        'buildNumber': '1',
        'modelId': '',
      };
    });
    final gateway = NativeProductSystemGateway();
    final overview = await gateway.overview();
    expect(overview.microphonePermission, ProductPermissionStatus.notGranted);
    expect(overview.microphonePermission.requiresSettings, isFalse);
    expect(overview.microphonePermission.canRequest, isTrue);
    expect(overview.cameraPermission, ProductPermissionStatus.authorized);
    expect(overview.appVersion, '1.0.0');
    await gateway.openSystemSettings();
    expect(calls, ['systemOverview', 'openSystemSettings']);
  });

  test(
    'requests only the chosen permission and awaits the native callback',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final gateway = NativeProductSystemGateway();
      await gateway.requestPermission(ProductPermission.microphone);
      await gateway.requestPermission(ProductPermission.camera);
      expect(calls.map((call) => call.method), [
        'requestPermission',
        'requestPermission',
      ]);
      expect(calls.map((call) => call.arguments), [
        {'permission': 'microphone'},
        {'permission': 'camera'},
      ]);
    },
  );

  test('propagates native read failures for the page to display', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'system_failed');
    });
    await expectLater(
      NativeProductSystemGateway().overview(),
      throwsA(isA<PlatformException>()),
    );
  });
}

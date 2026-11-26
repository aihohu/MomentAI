import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/core/session/session_transfer_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.hohu.momentai.product/transfer');
  const gateway = NativeSessionTransferGateway();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('copy and TXT pass the same reading layout to native export', () async {
    const reading = '第一段。\n\n第二段。';
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'readSessionText' ? reading : null;
    });
    await gateway.readSessionText('session_selected', readingText: reading);
    await gateway.shareSession(
      'session_selected',
      SessionShareFormat.text,
      readingText: reading,
    );
    expect(calls.map((call) => (call.arguments as Map)['readingText']), [
      reading,
      reading,
    ]);
  });

  test(
    'reads canonical share text for the requested session without sharing',
    () async {
      final calls = <MethodCall>[];
      const text = '标题\n文字来源：精修\n⚠️ 缺口\n全文 🎙️\n随想';
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return text;
      });
      expect(await gateway.readSessionText('session_selected'), text);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'readSessionText');
      expect(calls.single.arguments, {'sessionId': 'session_selected'});
    },
  );

  test(
    'missing native text is a failure, never a successful empty copy',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      await expectLater(
        gateway.readSessionText('session_selected'),
        throwsStateError,
      );
    },
  );

  test('native text preparation error is preserved', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'SessionTransferError',
        message: '请先安全结束当前录音。',
      );
    });
    await expectLater(
      gateway.readSessionText('session_selected'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.message,
          'message',
          '请先安全结束当前录音。',
        ),
      ),
    );
  });
}

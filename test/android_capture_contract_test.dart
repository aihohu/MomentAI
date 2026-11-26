import 'package:flutter_test/flutter_test.dart';
import 'package:momentai/poc/poc_bridge.dart';

void main() {
  test('recovery retains an upper bound separately from exact loss', () {
    final measured = RecoveryOutcome.fromMap({
      'state': 'completed_with_gaps',
      'rpoMs': 363,
      'rpoKnown': true,
      'rpoIsUpperBound': true,
      'rpoPass': true,
    });
    expect(measured.rpoIsUpperBound, isTrue);
    expect(measured.rpoKnown, isTrue);
    expect(measured.rpoMs, 363);
    expect(RecoveryOutcome.fromMap({'rpoKnown': false}).rpoKnown, isFalse);
  });
  test('manual interruption recovery is enabled only by native capability', () {
    final ios = PoCSnapshot.fromMap({'state': 'interrupted'});
    final android = PoCSnapshot.fromMap({
      'state': 'interrupted',
      'canResumeAfterInterruption': true,
    });
    expect(ios.canResume, isFalse);
    expect(android.canResume, isTrue);
    expect(android.canPause, isFalse);
    expect(android.canStop, isTrue);
    expect(PoCSnapshot.fromMap({'state': 'paused'}).canResume, isTrue);
  });

  test('missing receipt remains unknown instead of implying zero loss', () {
    final candidate = RecoveryCandidate.fromMap({
      'state': 'recording',
      'lastCommittedSample': 16000,
      'observedSamples': 16000,
      'rpoMs': 0,
      'rpoKnown': false,
      'rpoPass': false,
    });
    expect(candidate.committedMs, 1000);
    expect(candidate.rpoKnown, isFalse);
    expect(candidate.rpoPass, isFalse);
    expect(RecoveryCandidate.fromMap({'rpoMs': 500}).rpoKnown, isTrue);
  });
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures `SystemChannels.platform` calls so a test can assert what was put
/// on the clipboard without touching a real pasteboard.
///
/// Returns the growing list of calls; read `Clipboard.setData`'s
/// `arguments['text']` from it. The mock handler is cleared at teardown, so
/// call this from inside a test body rather than a bare `setUp`.
List<MethodCall> recordClipboardCalls() {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}

/// The text handed to `Clipboard.setData`, or null if it was never called.
String? copiedText(List<MethodCall> calls) {
  for (final call in calls.reversed) {
    if (call.method == 'Clipboard.setData') {
      return (call.arguments as Map)['text'] as String?;
    }
  }
  return null;
}

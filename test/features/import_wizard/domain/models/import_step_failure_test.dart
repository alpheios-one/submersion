import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/import_wizard/domain/models/import_step_failure.dart';

void main() {
  test('reads as its message, not as an Instance of', () {
    // The wizard shows `message` directly, but anything that stringifies the
    // exception -- a log line, an unhandled-error report -- gets the default
    // "Instance of 'ImportStepFailure'" without this, which is exactly the
    // uninformative failure this PR set out to remove.
    const failure = ImportStepFailure('No data could be parsed from the file');

    expect(failure.message, 'No data could be parsed from the file');
    expect('$failure', 'No data could be parsed from the file');
    expect(failure, isA<Exception>());
  });
}

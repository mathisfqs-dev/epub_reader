// Entry point with the Flutter Driver extension, used to drive the app
// from tooling: flutter run -d macos -t test_driver/app.dart
import 'package:epub_reader/main.dart' as app;
import 'package:flutter_driver/driver_extension.dart';

Future<void> main() async {
  enableFlutterDriverExtension();
  await app.main();
}

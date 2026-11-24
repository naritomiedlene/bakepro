import 'package:bakepro/utils/picked_file_bytes.dart';

/// True when running on a platform where `dart:html` is available.
const bool webFileInputAvailable = false;

/// Web-only file picker. On non-web platforms this returns null.
Future<PickedFileBytes?> pickWebFileBytes({required String accept, bool captureFromCamera = false}) async => null;

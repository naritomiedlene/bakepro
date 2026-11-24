// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:async';
import 'dart:typed_data';

import 'package:bakepro/utils/picked_file_bytes.dart';

/// True when running on a platform where `dart:html` is available.
const bool webFileInputAvailable = true;

Future<PickedFileBytes?> pickWebFileBytes({required String accept, bool captureFromCamera = false}) async {
  // Some browsers (notably Safari/WebKit) can block `input.click()` when the
  // element is not attached to the DOM. Attach it temporarily to be safe.
  final input = html.FileUploadInputElement();
  input.accept = accept;
  input.style.display = 'none';
  if (captureFromCamera) input.setAttribute('capture', 'environment');

  html.document.body?.append(input);

  final completer = Completer<PickedFileBytes?>();

  void cleanup() {
    input.value = '';
    input.remove();
  }

  input.onChange.first.then((_) async {
    try {
      final files = input.files;
      if (files == null || files.isEmpty) {
        cleanup();
        completer.complete(null);
        return;
      }

      final file = files.first;
      final reader = html.FileReader();
      reader.onError.first.then((_) {
        try {
          final err = reader.error;
          html.window.console.warn('pickWebFileBytes: FileReader error: $err');
        } catch (_) {}
      });
      reader.readAsArrayBuffer(file);
      await reader.onLoadEnd.first;
      final result = reader.result;

      Uint8List? bytes;
      if (result is ByteBuffer) {
        bytes = Uint8List.view(result);
      } else if (result is Uint8List) {
        bytes = result;
      } else if (result is List<int>) {
        bytes = Uint8List.fromList(result);
      }

      if (bytes == null || bytes.isEmpty) {
        html.window.console.warn('pickWebFileBytes: Unexpected FileReader.result type=${result.runtimeType}');
        cleanup();
        completer.complete(null);
        return;
      }

      cleanup();
      completer.complete(
        PickedFileBytes(
          bytes: bytes,
          name: file.name,
          mimeType: file.type.isEmpty ? null : file.type,
        ),
      );
    } catch (_) {
      cleanup();
      completer.complete(null);
    }
  });

  try {
    input.click();
  } catch (_) {
    cleanup();
    return null;
  }

  return completer.future;
}

import 'dart:typed_data';

/// Simple cross-platform container for picked file bytes.
class PickedFileBytes {
  const PickedFileBytes({required this.bytes, required this.name, this.mimeType});

  final Uint8List bytes;
  final String name;
  final String? mimeType;
}

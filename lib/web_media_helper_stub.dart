import 'dart:typed_data';

/// Stub implementation of WebMediaHelper for non-web platforms.
class WebMediaHelper {
  static String? createBlobUrl(Uint8List bytes, String mimeType) => null;
  static void revokeBlobUrl(String url) {}
  static dynamic createAudioPlayer(Uint8List audioBytes) => null;
  static void playAudio(dynamic player) {}
  static void pauseAudio(dynamic player) {}
  static void seekAudio(dynamic player, Duration position) {}
  static void syncAudio(dynamic player, Duration position, bool isPlaying) {}
  static void disposeAudio(dynamic player) {}
  static void downloadBytes(Uint8List bytes, String filename) {}
}

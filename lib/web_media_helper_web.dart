// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

/// Browser implementation of WebMediaHelper using HTML5 APIs.
class WebMediaHelper {
  static String? createBlobUrl(Uint8List bytes, String mimeType) {
    try {
      final blob = html.Blob([bytes], mimeType);
      return html.Url.createObjectUrlFromBlob(blob);
    } catch (_) {
      return null;
    }
  }

  static void revokeBlobUrl(String url) {
    try {
      html.Url.revokeObjectUrl(url);
    } catch (_) {}
  }

  static dynamic createAudioPlayer(Uint8List audioBytes) {
    try {
      final blob = html.Blob([audioBytes], 'audio/wav');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final audio = html.AudioElement(url)
        ..preload = 'auto'
        ..autoplay = false;
      return audio;
    } catch (_) {
      return null;
    }
  }

  static void playAudio(dynamic player) {
    if (player is html.AudioElement) {
      player.play();
    }
  }

  static void pauseAudio(dynamic player) {
    if (player is html.AudioElement) {
      player.pause();
    }
  }

  static void seekAudio(dynamic player, Duration position) {
    if (player is html.AudioElement) {
      player.currentTime = position.inMilliseconds / 1000.0;
    }
  }

  static void syncAudio(dynamic player, Duration position, bool isPlaying) {
    if (player is html.AudioElement) {
      final targetSeconds = position.inMilliseconds / 1000.0;
      final currentSeconds = player.currentTime;
      if ((currentSeconds - targetSeconds).abs() > 0.25) {
        player.currentTime = targetSeconds;
      }
      if (isPlaying && player.paused) {
        player.play();
      } else if (!isPlaying && !player.paused) {
        player.pause();
      }
    }
  }

  static void disposeAudio(dynamic player) {
    if (player is html.AudioElement) {
      player.pause();
      if (player.src.isNotEmpty) {
        html.Url.revokeObjectUrl(player.src);
      }
    }
  }

  static void downloadBytes(Uint8List bytes, String filename) {
    try {
      final blob = html.Blob([bytes]);
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement(href: url);
      anchor.setAttribute('download', filename);
      anchor.click();
      html.Url.revokeObjectUrl(url);
    } catch (_) {}
  }
}

import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

// Native-only imports — guarded at runtime via kIsWeb
import 'dart:io' show File;

// FFmpeg & Gal are native-only; imported but only called when !kIsWeb
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:gal/gal.dart';

// Web helpers
import 'web_media_helper.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  DESIGN TOKENS — "Dubverse Glow" dark minimal system
// ─────────────────────────────────────────────────────────────────────────────
class DV {
  static const yellow = Color(0xFFFFD60A);
  static const amber = Color(0xFFFFB000);
  static const orange = Color(0xFFFF7A1A);
  static const green = Color(0xFF32D74B);
  static const red = Color(0xFFFF453A);
  static const blue = Color(0xFF64D2FF);

  static TextStyle head(
    double size, {
    Color color = Colors.white,
    FontWeight weight = FontWeight.w600,
    double? spacing,
  }) {
    return GoogleFonts.outfit(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: spacing ?? -size * 0.025,
      height: 1.05,
    );
  }

  static TextStyle body(
    double size, {
    Color color = Colors.white,
    FontWeight weight = FontWeight.w500,
    double height = 1.4,
  }) {
    return GoogleFonts.inter(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
    );
  }
}

/// Theme palette (dark is the hero look, light is a warm paper variant)
class Pal {
  final bool dark;
  const Pal(this.dark);

  Color get bg => dark ? Colors.black : const Color(0xFFFBF8F0);
  Color get surface => dark ? const Color(0xFF0C0C0E) : Colors.white;
  Color get surface2 =>
      dark ? const Color(0xFF17171A) : const Color(0xFFF1EDE2);
  Color get stroke => dark
      ? Colors.white.withValues(alpha: 0.13)
      : Colors.black.withValues(alpha: 0.12);
  Color get text => dark ? Colors.white : const Color(0xFF111111);
  Color get sub => dark ? const Color(0xFF9B9BA5) : const Color(0xFF6B6B74);
  Color get grid => dark
      ? Colors.white.withValues(alpha: 0.055)
      : Colors.black.withValues(alpha: 0.05);
}

// ─────────────────────────────────────────────────────────────────────────────
//  APP ENTRY
// ─────────────────────────────────────────────────────────────────────────────
void main() => runApp(const PolyglotApp());

class PolyglotApp extends StatelessWidget {
  const PolyglotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dubverse AI — Say it everywhere',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: DV.yellow,
          secondary: DV.orange,
        ),
      ),
      home: const DubbingScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  WEB NAVIGATION PAGES
// ─────────────────────────────────────────────────────────────────────────────
enum WebNavPage { landing, studio, mobileDemo }

// ─────────────────────────────────────────────────────────────────────────────
//  APP STATE ENUM
// ─────────────────────────────────────────────────────────────────────────────
enum AppState {
  idle,
  picking,
  uploading,
  processing,
  downloading,
  merging,
  done,
  error,
}

// ─────────────────────────────────────────────────────────────────────────────
//  MAIN SCREEN (all pipeline logic lives here — unchanged behaviour)
// ─────────────────────────────────────────────────────────────────────────────
class DubbingScreen extends StatefulWidget {
  const DubbingScreen({super.key});

  @override
  State<DubbingScreen> createState() => _DubbingScreenState();
}

class _DubbingScreenState extends State<DubbingScreen>
    with SingleTickerProviderStateMixin {
  AppState _state = AppState.idle;
  String _status = 'READY — SELECT A VIDEO TO BEGIN';
  String _lang = 'Hindi';

  // Mascot / glow animation
  late final AnimationController _anim;

  // Web navigation state
  WebNavPage _webPage = WebNavPage.landing;

  // Theme (dark is default, matches the hero look)
  bool _isDark = true;
  bool get isDark => _isDark;
  Pal get pal => Pal(_isDark);

  void toggleTheme() => setState(() => _isDark = !_isDark);

  // Native path (mobile / desktop)
  File? _originalVideo;

  // Web bytes upload
  Uint8List? _videoBytes;
  String? _videoFileName;

  // Result
  File? _finalVideo;
  Uint8List? _finalAudioBytes;
  VideoPlayerController? _videoCtrl;

  // Web playback & audio synchronization (dual playback: muted video + dubbed audio)
  String? _videoBlobUrl;
  dynamic _webAudioPlayer;
  bool _hasDubbedAudio = false;

  final List<String> _languages = [
    'Hindi',
    'English',
    'Spanish',
    'French',
    'Japanese',
    'Bhojpuri',
    'Marathi',
    'Tamil',
    'Telugu',
    'Urdu',
    'Kannada',
    'Gujarati',
    'Punjabi',
    'Bengali',
  ];

  final String _baseUrl = 'https://polyglot-backend-v1.onrender.com';

  bool get _hasVideo => kIsWeb ? _videoBytes != null : _originalVideo != null;

  bool get _isBusy =>
      _state != AppState.idle &&
      _state != AppState.done &&
      _state != AppState.error;

  String get _fileLabel {
    if (!_hasVideo) return '';
    if (kIsWeb) return _videoFileName ?? 'video.mp4';
    return _originalVideo!.path.split('/').last.split('\\').last;
  }

  Color get _statusColor {
    switch (_state) {
      case AppState.done:
        return DV.green;
      case AppState.error:
        return DV.red;
      case AppState.idle:
        return DV.blue;
      default:
        return DV.yellow;
    }
  }

  void update(VoidCallback fn) => setState(fn);

  void navigateWeb(WebNavPage page) => setState(() => _webPage = page);

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();
  }

  void togglePlayPause() {
    if (_videoCtrl == null) return;
    update(() {
      if (_videoCtrl!.value.isPlaying) {
        _videoCtrl!.pause();
        if (kIsWeb && _hasDubbedAudio && _webAudioPlayer != null) {
          WebMediaHelper.pauseAudio(_webAudioPlayer);
        }
      } else {
        _videoCtrl!.play();
        if (kIsWeb && _hasDubbedAudio && _webAudioPlayer != null) {
          WebMediaHelper.syncAudio(
            _webAudioPlayer,
            _videoCtrl!.value.position,
            true,
          );
        }
      }
    });
  }

  void _onVideoTick() {
    if (kIsWeb &&
        _hasDubbedAudio &&
        _webAudioPlayer != null &&
        _videoCtrl != null) {
      final isPlaying = _videoCtrl!.value.isPlaying;
      final pos = _videoCtrl!.value.position;
      WebMediaHelper.syncAudio(_webAudioPlayer, pos, isPlaying);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _videoCtrl?.removeListener(_onVideoTick);
    _videoCtrl?.dispose();
    if (_webAudioPlayer != null) {
      WebMediaHelper.disposeAudio(_webAudioPlayer);
    }
    if (_videoBlobUrl != null) {
      WebMediaHelper.revokeBlobUrl(_videoBlobUrl!);
    }
    super.dispose();
  }

  // ── PICK VIDEO ────────────────────────────────────────────────────────────
  Future<void> _pickVideo() async {
    _videoCtrl?.removeListener(_onVideoTick);
    _videoCtrl?.dispose();
    _videoCtrl = null;
    if (_webAudioPlayer != null) {
      WebMediaHelper.disposeAudio(_webAudioPlayer);
      _webAudioPlayer = null;
    }
    if (_videoBlobUrl != null) {
      WebMediaHelper.revokeBlobUrl(_videoBlobUrl!);
      _videoBlobUrl = null;
    }
    _hasDubbedAudio = false;
    _finalAudioBytes = null;
    _finalVideo = null;

    setState(() {
      _state = AppState.picking;
      _status = 'OPENING FILE SELECTOR...';
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        withData: kIsWeb,
      );

      if (result == null) {
        setState(() {
          _state = AppState.idle;
          _status = 'SELECTION CANCELLED';
        });
        return;
      }

      if (kIsWeb) {
        _videoBytes = result.files.single.bytes;
        _videoFileName = result.files.single.name;

        if (_videoBytes != null) {
          _videoBlobUrl = WebMediaHelper.createBlobUrl(
            _videoBytes!,
            'video/mp4',
          );
          if (_videoBlobUrl != null) {
            _videoCtrl =
                VideoPlayerController.networkUrl(Uri.parse(_videoBlobUrl!))
                  ..initialize().then((_) {
                    _videoCtrl?.addListener(_onVideoTick);
                    setState(() {});
                  });
          }
        }

        setState(() {
          _state = AppState.idle;
          _status = 'LOADED: ${_videoFileName?.toUpperCase() ?? 'VIDEO.MP4'}';
        });
      } else {
        if (result.files.single.path != null) {
          _originalVideo = File(result.files.single.path!);
          _videoCtrl = VideoPlayerController.file(_originalVideo!)
            ..initialize().then((_) {
              setState(() {});
            });
          setState(() {
            _state = AppState.idle;
            _status = 'LOADED: ${result.files.single.name.toUpperCase()}';
          });
        }
      }
    } catch (e) {
      setState(() {
        _state = AppState.error;
        _status = 'ERROR: $e';
      });
    }
  }

  // ── WEB: synchronized dual playback (muted video + dubbed audio) ──────────
  Future<void> _startSyncedPreview() async {
    if (_finalAudioBytes == null) return;
    if (_webAudioPlayer != null) {
      WebMediaHelper.disposeAudio(_webAudioPlayer);
      _webAudioPlayer = null;
    }
    _webAudioPlayer = WebMediaHelper.createAudioPlayer(_finalAudioBytes!);
    _hasDubbedAudio = true;

    if (_videoCtrl != null) {
      await _videoCtrl!.setVolume(0.0);
      await _videoCtrl!.seekTo(Duration.zero);
      WebMediaHelper.seekAudio(_webAudioPlayer, Duration.zero);
      await _videoCtrl!.play();
      WebMediaHelper.playAudio(_webAudioPlayer);
    }
  }

  // ── PROCESS VIDEO (Full Pipeline) ─────────────────────────────────────────
  Future<void> _processVideo() async {
    if (!_hasVideo) return;

    try {
      // 1. Upload
      setState(() {
        _state = AppState.uploading;
        _status = 'UPLOADING VIDEO TO SERVER...';
      });

      final uploadUri = Uri.parse('$_baseUrl/api/dubbing/upload');
      final request = http.MultipartRequest('POST', uploadUri);
      request.fields['targetLanguage'] = _lang;

      if (kIsWeb && _videoBytes != null) {
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            _videoBytes!,
            filename: _videoFileName ?? 'video.mp4',
          ),
        );
      } else {
        request.files.add(
          await http.MultipartFile.fromPath('file', _originalVideo!.path),
        );
      }

      final response = await request.send();
      String jobId = '';

      if (response.statusCode == 200 || response.statusCode == 202) {
        final body = await response.stream.bytesToString();
        final json = jsonDecode(body);
        jobId = json['jobId'] ?? json['job_id'] ?? '';
      } else {
        throw Exception('Upload failed: ${response.statusCode}');
      }

      // 2. Poll Status
      setState(() {
        _state = AppState.processing;
        _status = 'AI TRANSLATING VOICE ($jobId)...';
      });

      bool done = false;
      String downloadUrl = '';
      while (!done) {
        await Future.delayed(const Duration(seconds: 5));
        final statusRes = await http.get(
          Uri.parse('$_baseUrl/api/dubbing/status/$jobId'),
        );
        if (statusRes.statusCode == 200) {
          final sJson = jsonDecode(statusRes.body);
          if (sJson['status'] == 'COMPLETED') {
            done = true;
            downloadUrl = '$_baseUrl/api/dubbing/download/$jobId';
          } else {
            setState(() {
              _status =
                  'AI PROCESSING... STATUS: ${sJson['status'] ?? 'WORKING'}';
            });
          }
        }
      }

      // 3. Download Audio
      setState(() {
        _state = AppState.downloading;
        _status = 'DOWNLOADING DUBBED AUDIO...';
      });
      final dlRes = await http.get(Uri.parse(downloadUrl));
      if (dlRes.statusCode != 200) throw Exception('Download failed');

      if (kIsWeb) {
        _finalAudioBytes = dlRes.bodyBytes;
        // 4. Synchronized dual playback: muted video + dubbed audio blob
        await _startSyncedPreview();
        setState(() {
          _state = AppState.done;
          _status = 'DUBBING COMPLETE — PLAYING SYNCED VIDEO & AUDIO';
        });
        return;
      }

      // 4. Merge Audio + Video (native)
      setState(() {
        _state = AppState.merging;
        _status = 'MERGING AUDIO + VIDEO...';
      });

      final dir = await getApplicationDocumentsDirectory();
      final audioPath = '${dir.path}/dubbed_$jobId.wav';
      final outPath = '${dir.path}/final_dubbed_$jobId.mp4';

      await File(audioPath).writeAsBytes(dlRes.bodyBytes);

      final cmd =
          '-y -i "${_originalVideo!.path}" -i "$audioPath" -c:v copy -map 0:v:0 -map 1:a:0 -shortest "$outPath"';

      await FFmpegKit.execute(cmd).then((session) async {
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          _finalVideo = File(outPath);
          _videoCtrl = VideoPlayerController.file(_finalVideo!)
            ..initialize().then((_) {
              setState(() {});
              _videoCtrl!.play();
            });
        } else {
          final logs = await session.getLogsAsString();
          throw Exception('FFmpeg failed:\n$logs');
        }
      });

      setState(() {
        _state = AppState.done;
        _status = 'DUBBING COMPLETE — READY TO PLAY';
      });
    } catch (e) {
      setState(() {
        _state = AppState.error;
        _status = 'ERROR: ${e.toString().toUpperCase()}';
      });
    }
  }

  // ── SAVE TO GALLERY (native) ───────────────────────────────────────────────
  Future<void> _saveToGallery() async {
    if (_finalVideo == null) return;
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        await Gal.requestAccess(toAlbum: true);
      }
      await Gal.putVideo(_finalVideo!.path);
      if (!mounted) return;
      _showSnack('SAVED TO GALLERY!', DV.green);
    } catch (e) {
      if (!mounted) return;
      _showSnack('SAVE FAILED: $e', DV.red);
    }
  }

  // ── DOWNLOADS (web) ────────────────────────────────────────────────────────
  String get _baseName =>
      _videoFileName != null ? _videoFileName!.split('.').first : 'dubbed';

  void _downloadAudioWeb() {
    if (_finalAudioBytes != null) {
      final filename = '${_baseName}_${_lang.toLowerCase()}.wav';
      WebMediaHelper.downloadBytes(_finalAudioBytes!, filename);
      _showSnack('DOWNLOADING AUDIO ($filename)...', DV.green);
    }
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: DV.body(13, color: Colors.black, weight: FontWeight.w700),
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  // ── Hero helpers (web landing) ─────────────────────────────────────────────
  Future<void> heroPick() async {
    await _pickVideo();
    if (!mounted) return;
    if (_hasVideo) navigateWeb(WebNavPage.studio);
  }

  Future<void> heroGo() async {
    if (!_hasVideo) {
      await heroPick();
      return;
    }
    navigateWeb(WebNavPage.studio);
    _processVideo();
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final isDesktop = w >= 900;
    final p = pal;

    return Scaffold(
      backgroundColor: p.bg,
      body: _Backdrop(
        pal: p,
        child: isDesktop ? _WebScreen(state: this) : _MobileStudio(state: this),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  SHARED VISUAL PIECES
// ═════════════════════════════════════════════════════════════════════════════

/// Black canvas with a faint grid and a soft spotlight (like the reference)
class _Backdrop extends StatelessWidget {
  final Pal pal;
  final Widget child;
  const _Backdrop({required this.pal, required this.child});

  @override
  Widget build(BuildContext context) {
    final spot = pal.dark
        ? Colors.white.withValues(alpha: 0.10)
        : DV.yellow.withValues(alpha: 0.22);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: ColoredBox(color: pal.bg)),
        Positioned.fill(
          child: CustomPaint(painter: _GridPainter(pal.grid, 120)),
        ),
        Positioned(
          top: -140,
          right: -100,
          child: IgnorePointer(
            child: Container(
              width: 640,
              height: 440,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [spot, spot.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  final Color color;
  final double step;
  _GridPainter(this.color, this.step);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.color != color || old.step != step;
}

/// "Voice Hero" — a glowing studio microphone ringed by a live waveform,
/// with floating greeting bubbles in different languages.
/// Idle: gentle breathing. Talking (dubbing in progress): wave bars + rings go wild.
class _VoiceHero extends StatelessWidget {
  final Animation<double> anim;
  final double size;
  final bool talking;
  const _VoiceHero({
    required this.anim,
    required this.size,
    this.talking = false,
  });

  // text, x-fraction, y-fraction, phase, anchoredRight
  static const _bubbles = [
    ('Hello', 0.10, 0.17, 0.0, false),
    ('नमस्ते', 0.08, 0.16, 1.7, true),
    ('Hola', 0.05, 0.56, 3.1, false),
    ('こんにちは', 0.04, 0.50, 4.4, true),
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (_, __) {
        final cyc = anim.value * 2 * math.pi;
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CustomPaint(
                size: Size(size, size),
                painter: _VoiceHeroPainter(anim.value, talking),
              ),
              if (size >= 220)
                for (final b in _bubbles)
                  Positioned(
                    left: b.$5
                        ? null
                        : size * b.$2 + math.cos(cyc + b.$4) * size * 0.008,
                    right: b.$5
                        ? size * b.$2 - math.cos(cyc + b.$4) * size * 0.008
                        : null,
                    top: size * b.$3 + math.sin(cyc + b.$4) * size * 0.014,
                    child: _LangBubble(
                      text: b.$1,
                      fontSize: (size * 0.036).clamp(11.0, 16.0),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _LangBubble extends StatelessWidget {
  final String text;
  final double fontSize;
  const _LangBubble({required this.text, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: fontSize * 0.85,
        vertical: fontSize * 0.45,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(color: DV.yellow.withValues(alpha: 0.15), blurRadius: 16),
        ],
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _VoiceHeroPainter extends CustomPainter {
  final double t;
  final bool talking;
  _VoiceHeroPainter(this.t, this.talking);

  static const _dark = Color(0xFF16161A);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final cyc = t * 2 * math.pi;
    final c = Offset(s * 0.5, s * 0.44);

    canvas.save();
    canvas.translate(0, math.sin(cyc) * s * 0.008);

    // Soft glow behind everything
    canvas.drawCircle(
      c,
      s * 0.34,
      Paint()
        ..color = DV.yellow.withValues(
          alpha: (talking ? 0.42 : 0.30) + 0.08 * math.sin(cyc * 2),
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.13),
    );

    // Expanding sound rings
    final ringSpeed = talking ? 3 : 1;
    for (int i = 0; i < 3; i++) {
      final ph = (t * ringSpeed + i / 3) % 1.0;
      canvas.drawCircle(
        c,
        s * (0.20 + ph * 0.28),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.004
          ..color = DV.yellow.withValues(alpha: (1 - ph) * 0.38),
      );
    }

    // Radial waveform bars
    const n = 56;
    final r0 = s * 0.255;
    for (int i = 0; i < n; i++) {
      final a = 2 * math.pi * i / n - math.pi / 2;
      final base = 0.5 + 0.5 * math.sin(i * 0.9 + cyc * (talking ? 4 : 1));
      final amp = talking
          ? (0.25 + 0.75 * base * (0.5 + 0.5 * math.sin(i * 2.3 - cyc * 3)))
          : (0.15 + 0.35 * base);
      final len = s * (0.012 + 0.058 * amp);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        c + dir * r0,
        c + dir * (r0 + len),
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = s * 0.0085
          ..color = Color.lerp(
            DV.amber,
            Colors.white,
            amp * 0.6,
          )!.withValues(alpha: 0.55 + 0.4 * amp),
      );
    }

    // Microphone capsule (slight pulse while talking)
    final pulse = talking ? 1 + 0.012 * math.sin(cyc * 8) : 1.0;
    final capCenter = Offset(s * 0.5, s * 0.385);
    final cap = RRect.fromRectAndRadius(
      Rect.fromCenter(center: capCenter, width: s * 0.17, height: s * 0.30),
      Radius.circular(s * 0.085),
    );

    // Cradle (U-shaped shock mount) drawn behind the capsule
    final cradleRect = Rect.fromCenter(
      center: Offset(s * 0.5, s * 0.40),
      width: s * 0.25,
      height: s * 0.32,
    );
    final cradle = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * 0.02
      ..color = _dark;
    canvas.drawArc(cradleRect, 0, math.pi, false, cradle);
    canvas.drawLine(
      Offset(cradleRect.left, s * 0.40),
      Offset(cradleRect.left, s * 0.33),
      cradle,
    );
    canvas.drawLine(
      Offset(cradleRect.right, s * 0.40),
      Offset(cradleRect.right, s * 0.33),
      cradle,
    );
    canvas.drawArc(
      cradleRect,
      0,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.005
        ..color = Colors.white.withValues(alpha: 0.2),
    );

    // Stem + base
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(s * 0.486, s * 0.56, s * 0.514, s * 0.80),
        Radius.circular(s * 0.01),
      ),
      Paint()..color = _dark,
    );
    final base = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(s * 0.5, s * 0.815),
        width: s * 0.30,
        height: s * 0.03,
      ),
      Radius.circular(s * 0.015),
    );
    canvas.drawRRect(base, Paint()..color = _dark);
    canvas.drawRRect(
      base,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.18),
    );

    // Capsule body
    canvas.save();
    canvas.translate(capCenter.dx, capCenter.dy);
    canvas.scale(pulse);
    canvas.translate(-capCenter.dx, -capCenter.dy);

    canvas.drawRRect(
      cap.inflate(s * 0.01),
      Paint()
        ..color = DV.yellow.withValues(alpha: talking ? 0.55 : 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.03),
    );
    canvas.drawRRect(
      cap,
      Paint()
        ..shader = const LinearGradient(
          colors: [DV.amber, Color(0xFFFFF176), DV.yellow, DV.amber],
          stops: [0.0, 0.32, 0.65, 1.0],
        ).createShader(cap.outerRect),
    );

    // Grille lines
    canvas.save();
    canvas.clipRRect(cap);
    final grille = Paint()
      ..strokeWidth = s * 0.0032
      ..color = Colors.black.withValues(alpha: 0.17);
    final r = cap.outerRect;
    for (int j = 1; j < 11; j++) {
      final y = r.top + r.height * j / 11;
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), grille);
    }
    for (final dx in [-0.04, 0.0, 0.04]) {
      canvas.drawLine(
        Offset(capCenter.dx + s * dx, r.top),
        Offset(capCenter.dx + s * dx, r.bottom),
        grille,
      );
    }
    canvas.restore();

    // Highlight streak + outline
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          r.left + r.width * 0.16,
          r.top + r.height * 0.07,
          r.width * 0.1,
          r.height * 0.5,
        ),
        Radius.circular(s * 0.02),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.38),
    );
    canvas.drawRRect(
      cap,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.black.withValues(alpha: 0.28),
    );
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _VoiceHeroPainter old) =>
      old.t != t || old.talking != talking;
}

class _Label extends StatelessWidget {
  final String text;
  final Pal pal;
  const _Label(this.text, this.pal);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.3,
        color: pal.sub,
      ),
    );
  }
}

class _PillButton extends StatefulWidget {
  final String text;
  final IconData? icon;
  final bool primary;
  final bool enabled;
  final VoidCallback? onTap;
  final Pal pal;
  final double height;
  final Color? color;

  const _PillButton({
    required this.text,
    required this.pal,
    this.icon,
    this.primary = false,
    this.enabled = true,
    this.onTap,
    this.height = 54,
    this.color,
  });

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.pal;
    final solid = widget.primary || widget.color != null;
    final fill = widget.color ?? (widget.primary ? DV.yellow : p.surface2);
    final fg = solid ? Colors.black : p.text;

    return Opacity(
      opacity: widget.enabled ? 1 : 0.4,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedScale(
          scale: _down ? 0.97 : 1,
          duration: const Duration(milliseconds: 90),
          child: Container(
            height: widget.height,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(40),
              border: solid ? null : Border.all(color: p.stroke),
              boxShadow: widget.primary
                  ? [
                      BoxShadow(
                        color: DV.yellow.withValues(alpha: 0.35),
                        blurRadius: 28,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 20, color: fg),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DV.head(15, color: fg, spacing: 0),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;
  final double size;
  final Pal pal;

  const _RoundIconButton({
    required this.icon,
    required this.pal,
    this.onTap,
    this.filled = false,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? DV.yellow : Colors.transparent,
            border: filled ? null : Border.all(color: pal.stroke),
          ),
          child: Icon(
            icon,
            size: size * 0.48,
            color: filled ? Colors.black : pal.text,
          ),
        ),
      ),
    );
  }
}

/// Language dropdown pill (used inside the command bar)
class _LangMenu extends StatelessWidget {
  final _DubbingScreenState state;
  const _LangMenu({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    return PopupMenuButton<String>(
      enabled: !state._isBusy,
      tooltip: 'Target language',
      color: p.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: p.stroke),
      ),
      onSelected: (v) => state.update(() => state._lang = v),
      itemBuilder: (_) => state._languages
          .map(
            (l) => PopupMenuItem<String>(
              value: l,
              child: Row(
                children: [
                  Icon(
                    state._lang == l
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 16,
                    color: state._lang == l ? DV.yellow : p.sub,
                  ),
                  const SizedBox(width: 10),
                  Text(l, style: DV.body(14, color: p.text)),
                ],
              ),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: p.dark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: p.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate_rounded, size: 15, color: DV.yellow),
            const SizedBox(width: 6),
            Text(
              state._lang,
              style: DV.body(13, color: p.text, weight: FontWeight.w600),
            ),
            Icon(Icons.arrow_drop_down_rounded, size: 20, color: p.sub),
          ],
        ),
      ),
    );
  }
}

/// The "Ask anything…" pill — here it is the upload + language + go bar
class _CommandBar extends StatelessWidget {
  final _DubbingScreenState state;
  final VoidCallback onPlus;
  final VoidCallback onGo;
  final bool compact;

  const _CommandBar({
    required this.state,
    required this.onPlus,
    required this.onGo,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    final busy = state._isBusy;

    return Container(
      height: compact ? 58 : 66,
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: p.dark
              ? [
                  const Color(0xFF2B2B30).withValues(alpha: 0.94),
                  const Color(0xFF0E0E10).withValues(alpha: 0.94),
                ]
              : [Colors.white, const Color(0xFFF3EFE4)],
        ),
        border: Border.all(color: p.stroke),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: p.dark ? 0.55 : 0.12),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          _RoundIconButton(
            icon: Icons.add_rounded,
            pal: p,
            size: compact ? 38 : 42,
            onTap: busy ? null : onPlus,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              state._hasVideo ? state._fileLabel : 'Drop a video to dub…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DV.body(
                compact ? 14 : 15,
                color: state._hasVideo ? p.text : p.sub,
              ),
            ),
          ),
          _LangMenu(state: state),
          const SizedBox(width: 8),
          _RoundIconButton(
            icon: busy ? Icons.hourglass_top_rounded : Icons.north_east_rounded,
            pal: p,
            filled: true,
            size: compact ? 40 : 46,
            onTap: busy ? null : onGo,
          ),
        ],
      ),
    );
  }
}

/// Language chips (wrapping on web, horizontally scrolling on mobile)
class _LangChips extends StatelessWidget {
  final _DubbingScreenState state;
  final bool horizontal;
  const _LangChips({required this.state, this.horizontal = false});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    final chips = state._languages.map((l) {
      final selected = state._lang == l;
      return GestureDetector(
        onTap: state._isBusy ? null : () => state.update(() => state._lang = l),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? DV.yellow : p.surface,
            borderRadius: BorderRadius.circular(30),
            border: selected ? null : Border.all(color: p.stroke),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: DV.yellow.withValues(alpha: 0.3),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: Text(
            l,
            style: DV.body(
              13,
              color: selected ? Colors.black : p.text,
              weight: FontWeight.w600,
            ),
          ),
        ),
      );
    }).toList();

    if (horizontal) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (int i = 0; i < chips.length; i++) ...[
              chips[i],
              if (i < chips.length - 1) const SizedBox(width: 8),
            ],
          ],
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: chips,
    );
  }
}

/// Compact scrollable language list (shows ~3 rows, scroll for the rest)
class _LangList extends StatefulWidget {
  final _DubbingScreenState state;
  const _LangList({required this.state});

  @override
  State<_LangList> createState() => _LangListState();
}

class _LangListState extends State<_LangList> {
  final ScrollController _ctrl = ScrollController();
  static const double _rowH = 44;
  static const int _visible = 3;

  @override
  void initState() {
    super.initState();
    // Bring the currently selected language into view
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_ctrl.hasClients) return;
      final i = widget.state._languages.indexOf(widget.state._lang);
      if (i > _visible - 1) {
        _ctrl.jumpTo(
          (i * _rowH).clamp(0.0, _ctrl.position.maxScrollExtent).toDouble(),
        );
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final p = state.pal;
    final langs = state._languages;

    return Container(
      height: _rowH * _visible + 12,
      decoration: BoxDecoration(
        color: p.surface2,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: Scrollbar(
        controller: _ctrl,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _ctrl,
          padding: const EdgeInsets.all(6),
          itemExtent: _rowH,
          itemCount: langs.length,
          itemBuilder: (_, i) {
            final l = langs[i];
            final selected = state._lang == l;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: state._isBusy
                    ? null
                    : () => state.update(() => state._lang = l),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: selected ? DV.yellow : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l,
                          style: DV.body(
                            14,
                            color: selected ? Colors.black : p.text,
                            weight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 18,
                        color: selected ? Colors.black : p.sub,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final Pal pal;
  final IconData icon;
  final String title;
  final String sub;
  const _FeatureCard({
    required this.pal,
    required this.icon,
    required this.title,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: pal.dark ? Colors.black : Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: pal.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: pal.surface2,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: pal.stroke),
            ),
            child: Icon(icon, color: pal.text, size: 24),
          ),
          const SizedBox(height: 22),
          Text(title, style: DV.head(22, color: pal.text)),
          const SizedBox(height: 6),
          Text(sub, style: DV.body(14, color: pal.sub)),
        ],
      ),
    );
  }
}

class _FeatureData {
  static const items = [
    (
      Icons.auto_awesome_rounded,
      'Keep the emotion',
      'Tone, pauses and intensity carry over.',
    ),
    (
      Icons.sync_rounded,
      'Lip-sync timing',
      'Every line is fitted to its scene.',
    ),
    (
      Icons.translate_rounded,
      'Feels native',
      'Casual, natural dubs in 15+ languages.',
    ),
  ];
}

class _StatusCard extends StatelessWidget {
  final _DubbingScreenState state;
  const _StatusCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    final c = state._statusColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.stroke),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: c.withValues(alpha: 0.7), blurRadius: 10),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              state._status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: DV.body(12.5, color: p.text, weight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: c.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              state._state.name.toUpperCase(),
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
                color: c,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  final _DubbingScreenState state;
  const _SourceTile({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    final has = state._hasVideo;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface2,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.stroke),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: has ? DV.green.withValues(alpha: 0.18) : p.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              has ? Icons.check_rounded : Icons.file_upload_outlined,
              size: 20,
              color: has ? DV.green : p.sub,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              has ? state._fileLabel : 'No video selected yet',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DV.body(
                13,
                color: has ? p.text : p.sub,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressSteps extends StatelessWidget {
  final _DubbingScreenState state;
  const _ProgressSteps({required this.state});

  static const _steps = [
    AppState.uploading,
    AppState.processing,
    AppState.downloading,
    AppState.merging,
    AppState.done,
  ];
  static const _labels = ['UPLOAD', 'AI DUB', 'FETCH', 'MERGE', 'DONE'];

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    final cur = _steps.indexOf(state._state);
    return Row(
      children: List.generate(_steps.length, (i) {
        final active = cur >= 0 && i <= cur;
        final color = active
            ? (i == _steps.length - 1 ? DV.green : DV.yellow)
            : p.stroke;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < _steps.length - 1 ? 6 : 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: color.withValues(alpha: 0.5),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _labels[i],
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: active ? p.text : p.sub,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// Action buttons shared by web studio panel and mobile studio
class _ActionButtons extends StatelessWidget {
  final _DubbingScreenState state;
  const _ActionButtons({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    final ctrl = state._videoCtrl;
    final canPlay = ctrl != null && ctrl.value.isInitialized;
    final done = state._state == AppState.done;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PillButton(
          text: 'Select video',
          icon: Icons.video_library_outlined,
          pal: p,
          enabled: !state._isBusy,
          onTap: state._pickVideo,
        ),
        const SizedBox(height: 10),
        _PillButton(
          text: state._isBusy ? 'Dubbing in progress…' : 'Start dubbing',
          icon: state._isBusy
              ? Icons.hourglass_top_rounded
              : Icons.bolt_rounded,
          pal: p,
          primary: true,
          enabled: state._hasVideo && !state._isBusy,
          onTap: state._processVideo,
        ),
        if (canPlay) ...[
          const SizedBox(height: 10),
          _PillButton(
            text: ctrl.value.isPlaying ? 'Pause video' : 'Play video',
            icon: ctrl.value.isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            pal: p,
            onTap: state.togglePlayPause,
          ),
        ],
        if (done && !kIsWeb && state._finalVideo != null) ...[
          const SizedBox(height: 10),
          _PillButton(
            text: 'Save to gallery',
            icon: Icons.download_rounded,
            pal: p,
            color: DV.green,
            onTap: state._saveToGallery,
          ),
        ],
        if (done && kIsWeb && state._finalAudioBytes != null) ...[
          const SizedBox(height: 10),
          _PillButton(
            text: 'Download dubbed audio (WAV)',
            icon: Icons.graphic_eq_rounded,
            pal: p,
            onTap: state._downloadAudioWeb,
          ),
        ],
      ],
    );
  }
}

// ── Video monitor (preview, busy mascot, merged result) ──────────────────────
class _VideoMonitor extends StatelessWidget {
  final _DubbingScreenState state;
  const _VideoMonitor({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: p.stroke, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: DV.yellow.withValues(alpha: state._isBusy ? 0.20 : 0.07),
            blurRadius: 44,
            spreadRadius: 2,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: _content(),
    );
  }

  Widget _content() {
    final ctrl = state._videoCtrl;

    // 1. Video loaded (original preview or merged result)
    if (ctrl != null && ctrl.value.isInitialized) {
      final isPlaying = ctrl.value.isPlaying;
      final merged =
          state._state == AppState.done &&
          (state._finalVideo != null || (kIsWeb && state._hasDubbedAudio));
      final badge = !merged
          ? 'ORIGINAL PREVIEW'
          : kIsWeb
          ? 'DUBBED VIDEO (SYNCED)'
          : 'DUBBED VIDEO (MERGED)';

      return GestureDetector(
        onTap: state.togglePlayPause,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: ctrl.value.size.width,
                height: ctrl.value.size.height,
                child: VideoPlayer(ctrl),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: (merged ? DV.green : DV.yellow),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      merged ? Icons.auto_awesome : Icons.movie_outlined,
                      size: 13,
                      color: Colors.black,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      badge,
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!isPlaying)
              Center(
                child: Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    color: DV.yellow,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: DV.yellow.withValues(alpha: 0.5),
                        blurRadius: 30,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 36,
                    color: Colors.black,
                  ),
                ),
              ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.85),
                    ],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(14, 22, 14, 10),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: state.togglePlayPause,
                      child: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: VideoProgressIndicator(
                        ctrl,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: DV.yellow,
                          bufferedColor: Colors.white24,
                          backgroundColor: Colors.white10,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 2. Web done, audio only (no video controller available)
    if (state._state == AppState.done &&
        kIsWeb &&
        state._finalAudioBytes != null) {
      return Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: DV.green,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.audiotrack_rounded,
                  size: 34,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 14),
              Text('DUBBED AUDIO READY', style: DV.head(18)),
            ],
          ),
        ),
      );
    }

    // 3. Busy — the voice hero reacts while the AI works
    if (state._isBusy) {
      return Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _VoiceHero(anim: state._anim, size: 150, talking: true),
                const SizedBox(height: 4),
                Text(
                  state._state.name.toUpperCase(),
                  style: DV.head(16, spacing: 2),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Text(
                    state._status,
                    textAlign: TextAlign.center,
                    style: DV.body(12, color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 4. Idle
    return GestureDetector(
      onTap: state._pickVideo,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _VoiceHero(anim: state._anim, size: 150),
                const SizedBox(height: 2),
                Text(
                  state._hasVideo
                      ? 'READY — TAP START DUBBING'
                      : 'NO VIDEO LOADED',
                  style: DV.head(16, spacing: 1.5),
                ),
                const SizedBox(height: 6),
                Text(
                  state._hasVideo
                      ? 'Hit "Start dubbing" to begin'
                      : 'Tap here or use "Select video" to choose a file',
                  textAlign: TextAlign.center,
                  style: DV.body(12, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  WEB UI
// ═════════════════════════════════════════════════════════════════════════════
class _WebScreen extends StatelessWidget {
  final _DubbingScreenState state;
  const _WebScreen({required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _WebHeader(state: state),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: KeyedSubtree(
              key: ValueKey(state._webPage),
              child: state._webPage == WebNavPage.landing
                  ? _WebLanding(state: state)
                  : state._webPage == WebNavPage.studio
                  ? _WebStudio(state: state)
                  : _WebMobileDemo(state: state),
            ),
          ),
        ),
      ],
    );
  }
}

class _WebHeader extends StatelessWidget {
  final _DubbingScreenState state;
  const _WebHeader({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    return SizedBox(
      height: 78,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => state.navigateWeb(WebNavPage.landing),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: DV.yellow,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: DV.yellow.withValues(alpha: 0.5),
                              blurRadius: 16,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.graphic_eq_rounded,
                          size: 22,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text('Dubverse', style: DV.head(27, color: p.text)),
                    ],
                  ),
                ),
                const Spacer(),
                _RoundIconButton(
                  icon: p.dark
                      ? Icons.light_mode_rounded
                      : Icons.dark_mode_rounded,
                  pal: p,
                  size: 44,
                  onTap: state.toggleTheme,
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => state.navigateWeb(
                    state._webPage == WebNavPage.studio
                        ? WebNavPage.landing
                        : WebNavPage.studio,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: p.stroke),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          state._webPage == WebNavPage.studio
                              ? 'Home'
                              : 'Get started',
                          style: DV.body(
                            14,
                            color: p.text,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 16,
                          color: p.text,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _NavLink(
                  label: 'Overview',
                  active: state._webPage == WebNavPage.landing,
                  pal: p,
                  onTap: () => state.navigateWeb(WebNavPage.landing),
                ),
                _NavLink(
                  label: 'Studio',
                  active: state._webPage == WebNavPage.studio,
                  pal: p,
                  onTap: () => state.navigateWeb(WebNavPage.studio),
                ),
                _NavLink(
                  label: 'Mobile demo',
                  active: state._webPage == WebNavPage.mobileDemo,
                  pal: p,
                  onTap: () => state.navigateWeb(WebNavPage.mobileDemo),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NavLink extends StatelessWidget {
  final String label;
  final bool active;
  final Pal pal;
  final VoidCallback onTap;
  const _NavLink({
    required this.label,
    required this.active,
    required this.pal,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: active
              ? (pal.dark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.black.withValues(alpha: 0.07))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          label,
          style: DV.body(
            15,
            color: active ? pal.text : pal.sub,
            weight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _WebLanding extends StatelessWidget {
  final _DubbingScreenState state;
  const _WebLanding({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    final w = MediaQuery.of(context).size.width;
    final titleSize = w < 1100 ? 62.0 : 88.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(40, 20, 40, 70),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            children: [
              Text(
                'Say it everywhere.',
                textAlign: TextAlign.center,
                style: DV
                    .head(titleSize, color: p.text)
                    .copyWith(
                      shadows: p.dark
                          ? [
                              Shadow(
                                color: Colors.white.withValues(alpha: 0.22),
                                blurRadius: 40,
                              ),
                            ]
                          : null,
                    ),
              ),
              const SizedBox(height: 16),
              Text(
                'Your AI dubbing studio for videos, voices and 15+ languages.',
                textAlign: TextAlign.center,
                style: DV.body(20, color: p.text.withValues(alpha: 0.85)),
              ),
              const SizedBox(height: 28),

              // Hero: mascot + command bar overlapping its base
              SizedBox(
                width: 780,
                height: 470,
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 440,
                      child: ClipRect(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: _VoiceHero(
                            anim: state._anim,
                            size: 420,
                            talking: state._isBusy,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      top: 372,
                      child: _CommandBar(
                        state: state,
                        onPlus: state.heroPick,
                        onGo: state.heroGo,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: _LangChips(state: state),
              ),
              const SizedBox(height: 56),

              // Feature cards
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < _FeatureData.items.length; i++) ...[
                    Expanded(
                      child: _FeatureCard(
                        pal: p,
                        icon: _FeatureData.items[i].$1,
                        title: _FeatureData.items[i].$2,
                        sub: _FeatureData.items[i].$3,
                      ),
                    ),
                    if (i < _FeatureData.items.length - 1)
                      const SizedBox(width: 20),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WebStudio extends StatelessWidget {
  final _DubbingScreenState state;
  const _WebStudio({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 8, 40, 32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 6,
            child: Column(
              children: [
                Expanded(child: _VideoMonitor(state: state)),
                const SizedBox(height: 16),
                _StatusCard(state: state),
              ],
            ),
          ),
          const SizedBox(width: 28),
          SizedBox(
            width: 400,
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: p.stroke),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text('Studio', style: DV.head(26, color: p.text)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: DV.green.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  color: DV.green,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'ONLINE',
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1,
                                  color: DV.green,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        _Label('Target language', p),
                        const Spacer(),
                        Text(
                          state._lang,
                          style: DV.body(
                            12,
                            color: DV.yellow,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _LangList(state: state),
                    const SizedBox(height: 22),
                    _Label('Video source', p),
                    const SizedBox(height: 10),
                    _SourceTile(state: state),
                    const SizedBox(height: 22),
                    _Label('Pipeline progress', p),
                    const SizedBox(height: 12),
                    _ProgressSteps(state: state),
                    const SizedBox(height: 26),
                    _ActionButtons(state: state),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WebMobileDemo extends StatelessWidget {
  final _DubbingScreenState state;
  const _WebMobileDemo({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: DV.yellow,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                'MOBILE STUDIO PREVIEW',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: Colors.black,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: 390,
              height: 780,
              decoration: BoxDecoration(
                color: p.bg,
                borderRadius: BorderRadius.circular(44),
                border: Border.all(
                  color: p.dark ? const Color(0xFF2A2A2E) : Colors.black,
                  width: 8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: DV.yellow.withValues(alpha: 0.18),
                    blurRadius: 60,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: _Backdrop(
                pal: p,
                child: _MobileStudio(state: state),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  MOBILE STUDIO (single scrolling screen — hero look + full studio)
// ═════════════════════════════════════════════════════════════════════════════
class _MobileStudio extends StatelessWidget {
  final _DubbingScreenState state;
  const _MobileStudio({required this.state});

  @override
  Widget build(BuildContext context) {
    final p = state.pal;
    return SafeArea(
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: DV.yellow,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: DV.yellow.withValues(alpha: 0.5),
                        blurRadius: 14,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.graphic_eq_rounded,
                    size: 19,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(width: 10),
                Text('Dubverse', style: DV.head(23, color: p.text)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: state._statusColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    state._state.name.toUpperCase(),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      color: state._statusColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _RoundIconButton(
                  icon: p.dark
                      ? Icons.light_mode_rounded
                      : Icons.dark_mode_rounded,
                  pal: p,
                  size: 38,
                  onTap: state.toggleTheme,
                ),
              ],
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Say it\neverywhere.',
                    textAlign: TextAlign.center,
                    style: DV
                        .head(42, color: p.text)
                        .copyWith(
                          shadows: p.dark
                              ? [
                                  Shadow(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    blurRadius: 28,
                                  ),
                                ]
                              : null,
                        ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your AI dubbing studio for videos, voices and 15+ languages.',
                    textAlign: TextAlign.center,
                    style: DV.body(14.5, color: p.sub),
                  ),
                  const SizedBox(height: 14),

                  // Mascot + command bar
                  SizedBox(
                    height: 292,
                    child: Stack(
                      children: [
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: 262,
                          child: ClipRect(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: _VoiceHero(
                                anim: state._anim,
                                size: 250,
                                talking: state._isBusy,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 212,
                          child: _CommandBar(
                            state: state,
                            compact: true,
                            onPlus: state._pickVideo,
                            onGo: () {
                              if (state._hasVideo) {
                                state._processVideo();
                              } else {
                                state._pickVideo();
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 4),
                  _LangChips(state: state, horizontal: true),
                  const SizedBox(height: 22),

                  SizedBox(height: 230, child: _VideoMonitor(state: state)),
                  const SizedBox(height: 14),
                  _StatusCard(state: state),
                  const SizedBox(height: 18),

                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: p.surface,
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: p.stroke),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Label('Selected video', p),
                        const SizedBox(height: 10),
                        _SourceTile(state: state),
                        const SizedBox(height: 18),
                        _Label('Pipeline progress', p),
                        const SizedBox(height: 12),
                        _ProgressSteps(state: state),
                        const SizedBox(height: 20),
                        _ActionButtons(state: state),
                      ],
                    ),
                  ),

                  const SizedBox(height: 22),
                  for (final f in _FeatureData.items) ...[
                    _FeatureCard(pal: p, icon: f.$1, title: f.$2, sub: f.$3),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

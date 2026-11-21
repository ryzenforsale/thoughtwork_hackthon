import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;

import 'voice_phrase.dart';

/// Speaks turn-by-turn directions.
///
/// Audio comes from the Render-hosted ElevenLabs proxy so the API key never
/// ships inside the APK. If the proxy is unreachable (Render cold start, no
/// internet, quota exhausted) it silently falls back to the phone's built-in
/// TTS, so the demo never goes silent.
class VoiceGuideService {
  VoiceGuideService({String? apiBase}) : _apiBase = apiBase ?? defaultApiBase;

  /// Override at build time:
  ///   flutter build apk --dart-define=VOICE_API_BASE=https://xxx.onrender.com
  static const String defaultApiBase = String.fromEnvironment(
    'VOICE_API_BASE',
    defaultValue: 'https://meetme-voice.onrender.com',
  );

  final String _apiBase;

  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _tts = FlutterTts();
  final VoiceGate _gate = VoiceGate();

  bool _enabled = true;
  bool _initialized = false;
  bool _speaking = false;

  bool get enabled => _enabled;
  bool get isSpeaking => _speaking;

  set enabled(bool value) {
    _enabled = value;
    if (!value) {
      unawaited(stop());
    }
  }

  /// Warms up the local TTS engine and the Render service so the first
  /// announcement is not delayed by a cold start.
  Future<void> warmUp() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await _player.setReleaseMode(ReleaseMode.stop);
    } catch (error) {
      debugPrint('🔊 [VOICE] player init failed: $error');
    }

    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(false);
    } catch (error) {
      debugPrint('🔊 [VOICE] tts init failed: $error');
    }

    unawaited(_warmUpProxy());
  }

  Future<void> _warmUpProxy() async {
    if (_apiBase.isEmpty) return;
    try {
      await http
          .get(Uri.parse('$_apiBase/health'))
          .timeout(const Duration(seconds: 20));
    } catch (error) {
      debugPrint('🔊 [VOICE] proxy warm-up failed: $error');
    }
  }

  /// Called from the tracking screen on every refresh; the gate decides if
  /// anything is actually spoken.
  Future<void> update(VoiceContext context) async {
    if (!_enabled) return;

    final phrase = VoicePhraseBuilder.build(context);
    if (phrase == null) return;
    if (!_gate.shouldSpeak(phrase, DateTime.now())) return;

    await _speak(phrase);
  }

  Future<void> _speak(VoicePhrase phrase) async {
    _speaking = true;
    try {
      final audio = await _fetchAudio(phrase.text);
      if (audio != null && audio.isNotEmpty) {
        await _player.stop();
        await _player.play(
          BytesSource(audio, mimeType: 'audio/mpeg'),
          volume: 1.0,
        );
        return;
      }
    } catch (error) {
      debugPrint('🔊 [VOICE] cloud playback failed: $error');
    } finally {
      _speaking = false;
    }

    await _speakLocally(phrase.text);
  }

  Future<Uint8List?> _fetchAudio(String text) async {
    if (_apiBase.isEmpty) return null;

    try {
      final response = await http
          .post(
            Uri.parse('$_apiBase/speak'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'text': text}),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        return response.bodyBytes;
      }
      debugPrint(
        '🔊 [VOICE] proxy returned ${response.statusCode}: '
        '${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
      );
    } catch (error) {
      debugPrint('🔊 [VOICE] proxy request failed: $error');
    }
    return null;
  }

  Future<void> _speakLocally(String text) async {
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (error) {
      debugPrint('🔊 [VOICE] local tts failed: $error');
    }
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
  }

  void dispose() {
    unawaited(stop());
    _player.dispose();
    _gate.reset();
  }
}

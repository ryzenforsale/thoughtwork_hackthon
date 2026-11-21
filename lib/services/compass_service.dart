import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'arrow_engine.dart';

/// One accepted compass reading.
class HeadingSample {
  final double degrees;
  final double? accuracyDegrees;
  final bool isReliable;
  final DateTime at;

  const HeadingSample({
    required this.degrees,
    required this.accuracyDegrees,
    required this.isReliable,
    required this.at,
  });

  bool get needsCalibration =>
      accuracyDegrees != null && accuracyDegrees! > 20.0;
}

/// Single owner of the magnetometer / rotation-vector stream.
///
/// Responsibilities:
///  * reject invalid samples (null / negative headings),
///  * down-weight unreliable samples instead of throwing them away,
///  * time-based circular low-pass (no rate-dependent lag),
///  * seed from the first sample (no sweep in from north),
///  * apply an optional north-calibration offset + declination.
class CompassService {
  CompassService._();

  static const String _offsetKey = 'compass_north_offset_deg';
  static const double _tauSeconds = 0.15;
  static const Duration _emitInterval = Duration(milliseconds: 33);
  static const Duration _availabilityWindow = Duration(seconds: 3);

  static final ValueNotifier<HeadingSample?> heading =
      ValueNotifier<HeadingSample?>(null);

  static final CircularFilter _filter = CircularFilter();

  static StreamSubscription<CompassEvent>? _subscription;
  static DateTime? _lastSampleAt;
  static DateTime? _lastEmitAt;
  static double _northOffset = 0.0;
  static bool _started = false;

  /// Magnetic declination for the current location, in degrees (east positive).
  /// Most of India is close to zero, so this is opt-in.
  static double declinationDegrees = 0.0;

  static bool get isAvailable {
    final last = _lastSampleAt;
    return last != null &&
        DateTime.now().difference(last) < _availabilityWindow;
  }

  static double? get accuracyDegrees => heading.value?.accuracyDegrees;

  static bool get needsCalibration => heading.value?.needsCalibration ?? false;

  static double get northOffset => _northOffset;

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    await _loadOffset();

    final events = FlutterCompass.events;
    if (events == null) {
      debugPrint('⚠️ [COMPASS] No compass stream on this device');
      return;
    }

    _subscription = events.listen(
      _onEvent,
      onError: (Object error) {
        debugPrint('⚠️ [COMPASS] Stream error: $error');
      },
    );
  }

  static void _onEvent(CompassEvent event) {
    final raw = event.heading;
    // Some platforms emit -1 while the sensor is invalid.
    if (raw == null || raw < 0) return;

    final now = DateTime.now();
    final dt = _lastSampleAt == null
        ? 0.033
        : now.difference(_lastSampleAt!).inMicroseconds / 1000000.0;
    _lastSampleAt = now;

    final accuracy = event.accuracy;
    final reliability = _reliability(accuracy);
    final alpha =
        ArrowEngine.smoothingAlpha(
          dtSeconds: dt.clamp(0.005, 0.25),
          tauSeconds: _tauSeconds,
        ) *
        reliability;

    final smoothed = _filter.add(ArrowEngine.normalize360(raw), alpha);

    if (_lastEmitAt != null && now.difference(_lastEmitAt!) < _emitInterval) {
      return;
    }
    _lastEmitAt = now;

    heading.value = HeadingSample(
      degrees: ArrowEngine.normalize360(
        smoothed + _northOffset + declinationDegrees,
      ),
      accuracyDegrees: accuracy,
      isReliable: accuracy == null || accuracy <= 30.0,
      at: now,
    );
  }

  static double _reliability(double? accuracy) {
    // Android reports hard-coded 15/30/45 for high/medium/low, iOS reports an
    // actual error in degrees. null means "unknown/unreliable".
    if (accuracy == null) return 0.45;
    if (accuracy <= 20.0) return 1.0;
    if (accuracy <= 35.0) return 0.6;
    return 0.3;
  }

  /// Call while the user points the top of the phone at true north.
  ///
  /// Stores the correction so the arrow keeps pointing correctly afterwards.
  static Future<void> applyNorthCalibration(double trueNorthDegrees) async {
    final current = heading.value?.degrees;
    if (current == null) return;

    _northOffset += ArrowEngine.shortestDelta(current, trueNorthDegrees);
    _northOffset = ArrowEngine.normalize180(_northOffset);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_offsetKey, _northOffset);

    _filter.reset();
    heading.value = null;
    _lastSampleAt = null;
  }

  static Future<void> resetCalibration() async {
    _northOffset = 0.0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_offsetKey);
    _filter.reset();
    heading.value = null;
    _lastSampleAt = null;
  }

  static Future<void> _loadOffset() async {
    final prefs = await SharedPreferences.getInstance();
    _northOffset = prefs.getDouble(_offsetKey) ?? 0.0;
  }

  static void stop() {
    _subscription?.cancel();
    _subscription = null;
    _started = false;
    _lastSampleAt = null;
    _lastEmitAt = null;
    _filter.reset();
    heading.value = null;
  }
}

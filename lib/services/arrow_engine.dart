import 'dart:math' as math;

/// Pure, testable math for the direction arrow.
///
/// Everything here is deliberately free of Flutter/widget dependencies so it
/// can be unit-tested without a device.
class ArrowEngine {
  ArrowEngine._();

  static double _rad(double degrees) => degrees * math.pi / 180.0;
  static double _deg(double radians) => radians * 180.0 / math.pi;

  /// Wraps an angle into the range [0, 360).
  static double normalize360(double degrees) {
    final value = degrees % 360.0;
    return value < 0 ? value + 360.0 : value;
  }

  /// Wraps an angle into the range (-180, 180].
  static double normalize180(double degrees) {
    final value = normalize360(degrees);
    return value > 180.0 ? value - 360.0 : value;
  }

  /// Shortest signed rotation (degrees) that takes [from] to [to].
  static double shortestDelta(double fromDegrees, double toDegrees) =>
      normalize180(toDegrees - fromDegrees);

  /// Initial great-circle bearing from point 1 to point 2, true north = 0.
  static double bearingDegrees(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final dLon = _rad(lon2 - lon1);
    final y = math.sin(dLon) * math.cos(_rad(lat2));
    final x =
        math.cos(_rad(lat1)) * math.sin(_rad(lat2)) -
        math.sin(_rad(lat1)) * math.cos(_rad(lat2)) * math.cos(dLon);
    return normalize360(_deg(math.atan2(y, x)));
  }

  /// Bearing relative to where the phone is pointing (0 = straight ahead).
  static double relativeBearing(double bearingDegrees, double headingDegrees) =>
      normalize360(bearingDegrees - headingDegrees);

  /// Half-width of the arrow's uncertainty cone, in degrees.
  ///
  /// Combines the positional uncertainty (GPS accuracy of both phones over the
  /// separation) with the compass uncertainty. This is the honest number that
  /// makes the arrow trustworthy instead of pretending to be perfect.
  static double bearingUncertaintyDegrees({
    required double distanceMeters,
    required double myAccuracyMeters,
    required double friendAccuracyMeters,
    double headingAccuracyDegrees = 0,
  }) {
    final positionError = _deg(
      math.atan2(
        math.max(1.0, myAccuracyMeters + friendAccuracyMeters),
        math.max(1.0, distanceMeters),
      ),
    );
    final combined = math.sqrt(
      positionError * positionError +
          headingAccuracyDegrees * headingAccuracyDegrees,
    );
    return combined.clamp(2.0, 90.0).toDouble();
  }

  /// Exponential smoothing weight for a sample that arrived [dtSeconds] after
  /// the previous one. Time-based, so the smoothing behaves the same whether
  /// the sensor emits at 5 Hz or 50 Hz.
  static double smoothingAlpha({
    required double dtSeconds,
    required double tauSeconds,
  }) {
    if (dtSeconds <= 0 || tauSeconds <= 0) return 1.0;
    return (1.0 - math.exp(-dtSeconds / tauSeconds)).clamp(0.02, 1.0);
  }
}

/// Circular low-pass filter.
///
/// Averages the sine/cosine components instead of the raw degrees, so it never
/// produces the classic "spin the long way around" bug when crossing north.
class CircularFilter {
  double _sin = 0.0;
  double _cos = 0.0;
  bool _initialized = false;
  int _samples = 0;

  bool get hasValue => _initialized;
  int get sampleCount => _samples;

  double? get value {
    if (!_initialized) return null;
    return ArrowEngine.normalize360(math.atan2(_sin, _cos) * 180.0 / math.pi);
  }

  /// Adds a sample and returns the new smoothed angle.
  double add(double degrees, double alpha) {
    final weight = alpha.clamp(0.0, 1.0).toDouble();
    final radians = degrees * math.pi / 180.0;

    if (!_initialized) {
      _sin = math.sin(radians);
      _cos = math.cos(radians);
      _initialized = true;
      _samples = 1;
    } else {
      _sin = (1.0 - weight) * _sin + weight * math.sin(radians);
      _cos = (1.0 - weight) * _cos + weight * math.cos(radians);
      _samples++;
    }

    return value!;
  }

  void reset() {
    _sin = 0.0;
    _cos = 0.0;
    _initialized = false;
    _samples = 0;
  }
}

/// Keeps a *continuous* (unwrapped) rotation for the arrow painter.
///
/// Normalising the angle to 0-360 makes the arrow take the long way around at
/// the wrap point. Keeping the accumulated value avoids that entirely.
class AngleTracker {
  double _shown = 0.0;
  bool _hasValue = false;

  double get shown => _shown;
  bool get hasValue => _hasValue;

  /// Returns the new unwrapped angle, or `null` when the change is inside the
  /// deadband (which is what stops the arrow twitching while standing still).
  double? update(
    double targetDegrees, {
    double deadbandDegrees = 4.0,
    bool force = false,
  }) {
    if (!_hasValue) {
      _shown = ArrowEngine.normalize360(targetDegrees);
      _hasValue = true;
      return _shown;
    }

    final delta = ArrowEngine.shortestDelta(_shown, targetDegrees);
    if (!force && delta.abs() < deadbandDegrees) return null;

    _shown += delta;
    return _shown;
  }

  void reset() {
    _shown = 0.0;
    _hasValue = false;
  }
}

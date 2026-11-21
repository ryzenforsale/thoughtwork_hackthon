import 'dart:math' as math;

/// Where the currently displayed distance came from.
enum DistanceSource { gps, bluetooth, blended, none }

/// A single, honest distance reading.
///
/// GPS is the primary source. Bluetooth RSSI is only used for close-range
/// proximity (and as a fallback when GPS is unavailable) because RSSI distance
/// is easily off by 2-3x indoors - which is exactly how a 3 m separation used
/// to be displayed as "29 m".
class DistanceReading {
  final double? meters;
  final double uncertaintyMeters;
  final DistanceSource source;
  final bool isApproximate;
  final bool isVeryClose;
  final bool gpsAvailable;
  final bool bleAvailable;

  const DistanceReading({
    required this.meters,
    required this.uncertaintyMeters,
    required this.source,
    required this.isApproximate,
    required this.isVeryClose,
    required this.gpsAvailable,
    required this.bleAvailable,
  });

  static const DistanceReading none = DistanceReading(
    meters: null,
    uncertaintyMeters: 0,
    source: DistanceSource.none,
    isApproximate: false,
    isVeryClose: false,
    gpsAvailable: false,
    bleAvailable: false,
  );

  /// Main large number shown on screen.
  String get displayValue {
    if (meters == null) return '--';
    if (isVeryClose) return 'Very close';
    final formatted = DistanceEngine.formatMeters(meters);
    return isApproximate ? '≈$formatted' : formatted;
  }

  /// Small caption under the number.
  String get detail {
    switch (source) {
      case DistanceSource.gps:
        return 'GPS · ±${uncertaintyMeters.round()}m';
      case DistanceSource.blended:
        return 'GPS + Bluetooth · ±${uncertaintyMeters.round()}m';
      case DistanceSource.bluetooth:
        return 'Bluetooth · approximate';
      case DistanceSource.none:
        return 'Waiting for GPS';
    }
  }

  String get shortSource {
    switch (source) {
      case DistanceSource.gps:
        return 'GPS';
      case DistanceSource.blended:
        return 'GPS + BLE';
      case DistanceSource.bluetooth:
        return 'BLE';
      case DistanceSource.none:
        return '--';
    }
  }
}

class DistanceEngine {
  DistanceEngine._();

  /// Below this separation the UI switches to the "you are together" state.
  /// Beyond it the direction arrow takes over again.
  static const double veryCloseMeters = 1.0;

  /// A BLE reading older than this is ignored.
  static const double bleFreshSeconds = 4.0;

  /// Great-circle distance in metres.
  static double haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLon = (lon2 - lon1) * math.pi / 180.0;
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  static bool _isFreshBle(double? bleMeters, double? bleAgeSeconds) {
    return bleMeters != null &&
        bleMeters > 0 &&
        (bleAgeSeconds ?? double.infinity) <= bleFreshSeconds;
  }

  static DistanceReading evaluate({
    required double? myLat,
    required double? myLng,
    required double? myAccuracyMeters,
    required double? friendLat,
    required double? friendLng,
    required double? friendAccuracyMeters,
    double? bleDistanceMeters,
    double? bleAgeSeconds,
  }) {
    final hasGps =
        myLat != null &&
        myLng != null &&
        friendLat != null &&
        friendLng != null;
    final bleFresh = _isFreshBle(bleDistanceMeters, bleAgeSeconds);
    final myAccuracy = (myAccuracyMeters ?? 12).clamp(3.0, 100.0).toDouble();
    final friendAccuracy = (friendAccuracyMeters ?? 12)
        .clamp(3.0, 100.0)
        .toDouble();

    if (!hasGps) {
      if (bleFresh) {
        final ble = bleDistanceMeters!.clamp(0.3, 100.0).toDouble();
        return DistanceReading(
          meters: ble,
          uncertaintyMeters: ble * 0.6,
          source: DistanceSource.bluetooth,
          isApproximate: true,
          isVeryClose: ble <= veryCloseMeters,
          gpsAvailable: false,
          bleAvailable: true,
        );
      }
      return DistanceReading.none;
    }

    final gps = haversineMeters(myLat, myLng, friendLat, friendLng);
    final gpsUncertainty = math.sqrt(
      myAccuracy * myAccuracy + friendAccuracy * friendAccuracy,
    );

    // GPS wins above a metre. Bluetooth only gets a vote when it agrees that
    // the two phones are basically on top of each other.
    final ble = bleFresh
        ? bleDistanceMeters!.clamp(0.3, 100.0).toDouble()
        : null;
    final gpsSaysClose = gps <= veryCloseMeters;
    final bleAgreesClose = ble != null && ble <= 1.5 && gps <= 3.0;

    if (gpsSaysClose || bleAgreesClose) {
      return DistanceReading(
        meters: gps,
        uncertaintyMeters: gpsUncertainty,
        source: ble != null ? DistanceSource.blended : DistanceSource.gps,
        isApproximate: false,
        isVeryClose: true,
        gpsAvailable: true,
        bleAvailable: ble != null,
      );
    }

    return DistanceReading(
      meters: gps,
      uncertaintyMeters: gpsUncertainty,
      source: DistanceSource.gps,
      isApproximate: false,
      isVeryClose: false,
      gpsAvailable: true,
      bleAvailable: ble != null,
    );
  }

  static String formatMeters(double? meters) {
    if (meters == null) return '--';
    if (meters < 1) return '${(meters * 100).round()}cm';
    if (meters < 10) return '${meters.toStringAsFixed(1)}m';
    if (meters < 1000) return '${meters.round()}m';
    if (meters < 10000) return '${(meters / 1000).toStringAsFixed(1)}km';
    return '${(meters / 1000).round()}km';
  }

  /// Human readable compass sector for north-up mode.
  static String compassSector(double bearingDegrees) {
    const names = [
      'north',
      'north-east',
      'east',
      'south-east',
      'south',
      'south-west',
      'west',
      'north-west',
    ];
    final index = (((bearingDegrees % 360) + 22.5) / 45).floor() % names.length;
    return names[index];
  }
}

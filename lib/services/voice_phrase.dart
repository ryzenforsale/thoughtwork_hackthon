import 'arrow_engine.dart';
import 'distance_engine.dart';

/// Everything the voice guide needs to describe the current situation.
class VoiceContext {
  final String friendName;
  final double? distanceMeters;

  /// Direction relative to where the phone points (0 = straight ahead).
  final double? relativeBearingDegrees;

  /// Compass bearing to the friend (0 = north), used when the compass is not
  /// available and the app is in north-up mode.
  final double? absoluteBearingDegrees;

  final bool isVeryClose;
  final bool isStale;
  final int? friendAgeSeconds;

  const VoiceContext({
    required this.friendName,
    this.distanceMeters,
    this.relativeBearingDegrees,
    this.absoluteBearingDegrees,
    this.isVeryClose = false,
    this.isStale = false,
    this.friendAgeSeconds,
  });
}

/// One sentence to speak, plus a coarse key used to avoid repeating it.
class VoicePhrase {
  final String text;
  final String key;

  /// Urgent phrases (arrived / lost the friend) skip the normal cooldown.
  final bool urgent;

  const VoicePhrase(this.text, this.key, {this.urgent = false});
}

/// Builds short, natural navigation sentences such as
/// "Rahul is 12 metres away, ahead and to your right."
///
/// Pure Dart so it can be unit-tested without a device.
class VoicePhraseBuilder {
  VoicePhraseBuilder._();

  static VoicePhrase? build(VoiceContext context) {
    final name = context.friendName.trim().isEmpty
        ? 'Your friend'
        : context.friendName.trim();

    if (context.isVeryClose) {
      return VoicePhrase(
        "You're together. $name is right next to you.",
        'together',
        urgent: true,
      );
    }

    if (context.isStale) {
      final age = context.friendAgeSeconds;
      final when = age == null
          ? 'a moment ago'
          : age <= 1
          ? '1 second ago'
          : '$age seconds ago';
      return VoicePhrase(
        "Lost $name's location. Last seen $when.",
        'stale',
        urgent: true,
      );
    }

    final distance = context.distanceMeters;
    if (distance == null) return null;

    final distanceText = distancePhrase(distance);

    if (context.relativeBearingDegrees != null) {
      final direction = relativeDirection(context.relativeBearingDegrees!);
      return VoicePhrase(
        '$name is $distanceText, $direction.',
        'move|${distanceBucket(distance)}'
            '|rel${directionBucket(context.relativeBearingDegrees!)}',
      );
    }

    if (context.absoluteBearingDegrees != null) {
      final sector = DistanceEngine.compassSector(
        context.absoluteBearingDegrees!,
      );
      return VoicePhrase(
        '$name is $distanceText, to the $sector.',
        'move|${distanceBucket(distance)}'
            '|abs${sectorBucket(context.absoluteBearingDegrees!)}',
      );
    }

    return VoicePhrase(
      '$name is $distanceText.',
      'move|${distanceBucket(distance)}|nodir',
    );
  }

  /// "less than a metre away", "12 metres away", "1.4 kilometres away".
  static String distancePhrase(double meters) {
    if (meters < 1) return 'less than a metre away';
    if (meters < 2) return 'about a metre away';
    if (meters < 10) return '${meters.round()} metres away';
    if (meters < 100) return '${_roundTo(meters, 5)} metres away';
    if (meters < 1000) return '${_roundTo(meters, 50)} metres away';

    final km = meters / 1000;
    return km < 10
        ? '${km.toStringAsFixed(1)} kilometres away'
        : '${km.round()} kilometres away';
  }

  /// Direction relative to the phone, e.g. "ahead and to your right".
  static String relativeDirection(double degrees) {
    final delta = ArrowEngine.normalize180(degrees);
    final magnitude = delta.abs();
    final right = delta > 0;

    if (magnitude <= 20) return 'straight ahead';
    if (magnitude <= 60) {
      return right ? 'ahead and to your right' : 'ahead and to your left';
    }
    if (magnitude <= 120) return right ? 'to your right' : 'to your left';
    if (magnitude <= 155) {
      return right
          ? 'behind you and to your right'
          : 'behind you and to your left';
    }
    return 'behind you';
  }

  /// Coarse buckets keep the sentence stable while walking, so the voice does
  /// not repeat the same thing every second.
  static int directionBucket(double degrees) {
    final normalized = ArrowEngine.normalize360(degrees);
    return ((normalized + 22.5) ~/ 45) % 8;
  }

  static int sectorBucket(double degrees) {
    return directionBucket(degrees);
  }

  static int distanceBucket(double meters) {
    if (meters < 2) return 1;
    if (meters < 5) return 2;
    if (meters < 10) return meters.round();
    if (meters < 50) return (meters / 5).round() * 5;
    if (meters < 200) return (meters / 10).round() * 10;
    if (meters < 1000) return (meters / 50).round() * 50;
    return ((meters / 1000) * 10).round() * 10;
  }

  static int _roundTo(double value, int step) => (value / step).round() * step;
}

/// Decides whether a phrase should actually be spoken right now.
class VoiceGate {
  VoiceGate({
    this.minInterval = const Duration(seconds: 5),
    this.repeatInterval = const Duration(seconds: 20),
  });

  /// Minimum gap before a *different* phrase can be spoken.
  final Duration minInterval;

  /// Minimum gap before repeating the *same* phrase.
  final Duration repeatInterval;

  String? _lastKey;
  DateTime? _lastSpokenAt;

  bool shouldSpeak(VoicePhrase phrase, DateTime now) {
    final last = _lastSpokenAt;

    if (last == null) {
      _accept(phrase, now);
      return true;
    }

    final elapsed = now.difference(last);
    final samePhrase = phrase.key == _lastKey;

    if (samePhrase && elapsed < repeatInterval) return false;
    if (!samePhrase && elapsed < minInterval && !phrase.urgent) return false;

    _accept(phrase, now);
    return true;
  }

  void _accept(VoicePhrase phrase, DateTime now) {
    _lastKey = phrase.key;
    _lastSpokenAt = now;
  }

  void reset() {
    _lastKey = null;
    _lastSpokenAt = null;
  }
}

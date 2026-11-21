import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/tracking_session.dart';
import 'firebase_service.dart';
import 'location_service.dart';

enum PositionSource { gps, session, community, device }

/// A position fix with enough metadata to reason about freshness.
class PositionFix {
  final double lat;
  final double lng;
  final double accuracyMeters;
  final DateTime at;
  final PositionSource source;

  const PositionFix({
    required this.lat,
    required this.lng,
    required this.accuracyMeters,
    required this.at,
    required this.source,
  });

  double get ageSeconds =>
      DateTime.now().difference(at).inMilliseconds / 1000.0;

  bool get isStale => ageSeconds > 12;
  bool get isDead => ageSeconds > 30;
}

/// Single owner of *my* position.
///
/// The old screen ran a filtered stream, a raw stream and a 3 s poll that
/// overwrote the filtered latitude/longitude with raw values. This keeps one
/// filtered estimate and only uses the poll to nudge the same filter when the
/// stream goes quiet.
class MyPositionService {
  MyPositionService._();

  static final ValueNotifier<PositionFix?> fix = ValueNotifier<PositionFix?>(
    null,
  );

  static StreamSubscription<Position>? _subscription;
  static Timer? _fallbackTimer;
  static DateTime? _lastAcceptedAt;
  static bool _running = false;

  static Future<void> start() async {
    if (_running) return;
    _running = true;
    _lastAcceptedAt = null;
    fix.value = null;

    _subscription = LocationService.getPositionStream().listen(
      _accept,
      onError: (Object error) {
        debugPrint('🔴 [POSITION] stream error: $error');
      },
    );

    _fallbackTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _pollIfStale();
    });
  }

  static Future<void> _pollIfStale() async {
    if (!_running) return;
    final last = _lastAcceptedAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 3)) {
      return;
    }

    // getCurrentPosition() already runs through the same Kalman filter, so this
    // refreshes the estimate instead of replacing it with a raw reading.
    final position = await LocationService.getCurrentPosition();
    if (position != null) _accept(position);
  }

  static void _accept(Position position) {
    if (!_running) return;
    final now = DateTime.now();
    _lastAcceptedAt = now;

    fix.value = PositionFix(
      lat: position.latitude,
      lng: position.longitude,
      accuracyMeters: position.accuracy > 0 ? position.accuracy : 15.0,
      at: now,
      source: PositionSource.gps,
    );
  }

  static void stop() {
    _running = false;
    _subscription?.cancel();
    _subscription = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _lastAcceptedAt = null;
    fix.value = null;
  }
}

/// Merges the three possible Firebase sources for the other person into one
/// stable fix.
///
/// Priority when several sources are fresh:
///   tracking_sessions  >  community_members  >  devices
///
/// A stale high-priority source no longer wins over a fresh lower-priority one,
/// and out-of-order writes are ignored by timestamp.
class FriendPositionService {
  FriendPositionService._();

  static final ValueNotifier<PositionFix?> fix = ValueNotifier<PositionFix?>(
    null,
  );

  static final Map<PositionSource, PositionFix> _candidates = {};
  static final List<StreamSubscription<LocationData?>> _subscriptions = [];
  static String? _sessionId;
  static String? _friendId;

  static const Map<PositionSource, int> _priority = {
    PositionSource.session: 3,
    PositionSource.community: 2,
    PositionSource.device: 1,
  };

  static void watch(String sessionId, String friendId) {
    if (_sessionId == sessionId && _friendId == friendId) return;
    stop();
    _sessionId = sessionId;
    _friendId = friendId;

    _subscriptions.add(
      FirebaseService.listenToLocation(sessionId, friendId).listen(
        (data) => _ingest(PositionSource.session, data),
        onError: (Object error) {
          debugPrint('🔴 [FRIEND] session stream error: $error');
        },
      ),
    );

    _subscriptions.add(
      FirebaseService.listenToCommunityMemberLocation(friendId).listen(
        (data) => _ingest(PositionSource.community, data),
        onError: (Object error) {
          debugPrint('🔴 [FRIEND] community stream error: $error');
        },
      ),
    );

    _subscriptions.add(
      FirebaseService.listenToDeviceLocation(friendId).listen(
        (data) => _ingest(PositionSource.device, data),
        onError: (Object error) {
          debugPrint('🔴 [FRIEND] device stream error: $error');
        },
      ),
    );
  }

  static void _ingest(PositionSource source, LocationData? data) {
    if (data == null || (data.lat == 0 && data.lng == 0)) {
      _candidates.remove(source);
      _publish();
      return;
    }

    final at = data.timestamp > 0
        ? DateTime.fromMillisecondsSinceEpoch(data.timestamp)
        : DateTime.now();

    final existing = _candidates[source];
    if (existing != null && at.isBefore(existing.at)) {
      // Out-of-order write, ignore it.
      return;
    }

    _candidates[source] = PositionFix(
      lat: data.lat,
      lng: data.lng,
      accuracyMeters: data.accuracy > 0 ? data.accuracy : 15.0,
      at: at,
      source: source,
    );

    _publish();
  }

  static void _publish() {
    if (_candidates.isEmpty) {
      fix.value = null;
      return;
    }

    final now = DateTime.now();
    PositionFix? bestFresh;
    PositionFix? newest;

    for (final candidate in _candidates.values) {
      if (now.difference(candidate.at).inSeconds <= 12) {
        if (bestFresh == null ||
            _priority[candidate.source]! > _priority[bestFresh.source]!) {
          bestFresh = candidate;
        }
      }
      if (newest == null || candidate.at.isAfter(newest.at)) {
        newest = candidate;
      }
    }

    fix.value = bestFresh ?? newest;
  }

  static void stop() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _candidates.clear();
    _sessionId = null;
    _friendId = null;
    fix.value = null;
  }
}

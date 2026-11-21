import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/arrow_engine.dart';
import '../services/bluetooth_distance_service.dart';
import '../services/compass_service.dart';
import '../services/distance_engine.dart';
import '../services/firebase_service.dart';
import '../services/location_service.dart';
import '../services/position_service.dart';
import '../services/voice_guide_service.dart';
import '../services/voice_phrase.dart';
import '../widgets/rotating_arrow.dart';
import 'map_screen.dart';

class TrackingScreenA extends StatefulWidget {
  final String sessionId;
  final String friendId;
  final String friendName;
  final String myDeviceId;

  const TrackingScreenA({
    super.key,
    required this.sessionId,
    required this.friendId,
    required this.friendName,
    required this.myDeviceId,
  });

  @override
  State<TrackingScreenA> createState() => _TrackingScreenAState();
}

class _TrackingScreenAState extends State<TrackingScreenA> {
  final ValueNotifier<double> _arrowAngle = ValueNotifier<double>(0);
  final AngleTracker _angleTracker = AngleTracker();
  final CircularFilter _bearingFilter = CircularFilter();
  final VoiceGuideService _voice = VoiceGuideService();

  DistanceReading? _distance;
  ArrowMode _mode = ArrowMode.waiting;
  double _uncertaintyDeg = 90;
  int? _friendAgeSeconds;
  bool _needsCalibration = false;
  bool _permissionDenied = false;
  bool _voiceEnabled = true;

  StreamSubscription<Map<String, dynamic>>? _bleSubscription;
  double? _bleDistance;
  DateTime? _bleUpdatedAt;

  Timer? _ticker;
  DateTime? _lastBearingSampleAt;
  DateTime _lastFirebaseUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    _startTracking();
  }

  Future<void> _startTracking() async {
    final hasPermission = await LocationService.requestPermission();
    if (!hasPermission) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }

    LocationService.resetFilter();
    await MyPositionService.start();
    await CompassService.start();
    FriendPositionService.watch(widget.sessionId, widget.friendId);

    MyPositionService.fix.addListener(_onMyFix);
    FriendPositionService.fix.addListener(_onFriendFix);
    CompassService.heading.addListener(_onHeading);

    // Advertise too, so the other phone can use BLE proximity as well.
    unawaited(BluetoothDistanceService.startAdvertising(widget.myDeviceId));

    // Prime the local TTS + the Render/ElevenLabs proxy before the first
    // direction so the demo does not wait on a cold start.
    unawaited(_voice.warmUp());

    _bleSubscription = BluetoothDistanceService.scanForDevice(widget.friendId)
        .listen((result) {
          final value = result['distance'];
          if (value is num && value > 0) {
            _bleDistance = value.toDouble();
            _bleUpdatedAt = DateTime.now();
            _refresh();
          }
        });

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _refresh();
  }

  void _onMyFix() {
    _publishMyLocation();
    _refresh();
  }

  void _onFriendFix() {
    _refresh();
  }

  /// Runs at compass rate (~30 Hz) and only touches the arrow notifier, so the
  /// rest of the screen is not rebuilt.
  void _onHeading() {
    final heading = CompassService.heading.value;
    final bearing = _bearingFilter.value;
    if (heading == null || bearing == null) return;

    final target = CompassService.isAvailable
        ? ArrowEngine.relativeBearing(bearing, heading.degrees)
        : bearing;

    final next = _angleTracker.update(target, deadbandDegrees: 3);
    if (next != null) _arrowAngle.value = next;
  }

  void _refresh() {
    if (!mounted) return;

    final my = MyPositionService.fix.value;
    final friend = FriendPositionService.fix.value;
    final heading = CompassService.heading.value;
    final compassAvailable = CompassService.isAvailable && heading != null;

    final reading = DistanceEngine.evaluate(
      myLat: my?.lat,
      myLng: my?.lng,
      myAccuracyMeters: my?.accuracyMeters,
      friendLat: friend?.lat,
      friendLng: friend?.lng,
      friendAccuracyMeters: friend?.accuracyMeters,
      bleDistanceMeters: _bleDistance,
      bleAgeSeconds: _bleUpdatedAt == null
          ? null
          : DateTime.now().difference(_bleUpdatedAt!).inMilliseconds / 1000.0,
    );

    ArrowMode mode;
    double? rawBearing;

    if (my == null || friend == null || friend.isDead) {
      mode = ArrowMode.waiting;
    } else {
      rawBearing = ArrowEngine.bearingDegrees(
        my.lat,
        my.lng,
        friend.lat,
        friend.lng,
      );

      if (friend.isStale) {
        mode = ArrowMode.stale;
      } else {
        _smoothBearing(my, friend, rawBearing);

        if (reading.isVeryClose) {
          mode = ArrowMode.veryClose;
        } else if (!compassAvailable) {
          mode = ArrowMode.northUp;
        } else {
          mode = ArrowMode.normal;
        }
      }
    }

    final smoothedBearing = _bearingFilter.value ?? rawBearing;
    final headingDegrees = heading?.degrees;
    final relativeBearing =
        (smoothedBearing != null && compassAvailable && headingDegrees != null)
        ? ArrowEngine.relativeBearing(smoothedBearing, headingDegrees)
        : null;

    if (smoothedBearing != null) {
      final target = relativeBearing ?? smoothedBearing;
      final next = _angleTracker.update(target, deadbandDegrees: 4);
      if (next != null) _arrowAngle.value = next;
    }

    final uncertainty = (my != null && friend != null && reading.meters != null)
        ? ArrowEngine.bearingUncertaintyDegrees(
            distanceMeters: reading.meters!,
            myAccuracyMeters: my.accuracyMeters,
            friendAccuracyMeters: friend.accuracyMeters,
            headingAccuracyDegrees: heading?.accuracyDegrees ?? 20,
          )
        : 90.0;

    final age = friend == null
        ? null
        : DateTime.now().difference(friend.at).inSeconds;

    setState(() {
      _distance = reading;
      _mode = mode;
      _uncertaintyDeg = uncertainty;
      _friendAgeSeconds = age;
      _needsCalibration = compassAvailable && CompassService.needsCalibration;
    });

    unawaited(
      _voice.update(
        VoiceContext(
          friendName: widget.friendName,
          distanceMeters: reading.meters,
          relativeBearingDegrees: mode == ArrowMode.normal
              ? relativeBearing
              : null,
          absoluteBearingDegrees: smoothedBearing,
          isVeryClose: mode == ArrowMode.veryClose,
          isStale: mode == ArrowMode.stale,
          friendAgeSeconds: age,
        ),
      ),
    );
  }

  void _smoothBearing(PositionFix my, PositionFix friend, double rawBearing) {
    final lastSample = _lastBearingSampleAt;
    final isNewSample =
        lastSample == null || !friend.at.isAtSameMomentAs(lastSample);
    if (!isNewSample && _bearingFilter.hasValue) return;

    _lastBearingSampleAt = friend.at;
    final distance = DistanceEngine.haversineMeters(
      my.lat,
      my.lng,
      friend.lat,
      friend.lng,
    );
    _bearingFilter.add(rawBearing, _bearingAlpha(distance));
  }

  /// More smoothing close up (where GPS bearing is noisy) and less smoothing
  /// far away (where it is reliable and lag would be noticeable).
  double _bearingAlpha(double distanceMeters) {
    if (distanceMeters < 15) return 0.30;
    if (distanceMeters < 40) return 0.40;
    if (distanceMeters < 100) return 0.50;
    return 0.60;
  }

  void _publishMyLocation() {
    final my = MyPositionService.fix.value;
    if (my == null) return;

    final now = DateTime.now();
    if (now.difference(_lastFirebaseUpdate) <
        const Duration(milliseconds: 900)) {
      return;
    }
    _lastFirebaseUpdate = now;

    final heading = CompassService.heading.value?.degrees ?? 0.0;
    unawaited(
      FirebaseService.updateLocation(
        widget.sessionId,
        widget.myDeviceId,
        my.lat,
        my.lng,
        heading,
        accuracy: my.accuracyMeters,
      ),
    );
    unawaited(
      FirebaseService.updateDeviceLocation(
        widget.myDeviceId,
        my.lat,
        my.lng,
        heading,
        my.accuracyMeters,
      ),
    );
  }

  String _directionText() {
    switch (_mode) {
      case ArrowMode.waiting:
        return '';
      case ArrowMode.stale:
        return _friendAgeSeconds == null
            ? 'Last known position'
            : 'Last seen ${_friendAgeSeconds}s ago';
      case ArrowMode.northUp:
        final bearing = _bearingFilter.value;
        return bearing == null
            ? 'North-up'
            : 'North-up · ${DistanceEngine.compassSector(bearing)}';
      case ArrowMode.veryClose:
        return 'Look around — they are very close';
      case ArrowMode.normal:
        if (_uncertaintyDeg > 35) return 'Turn slowly…';
        return LocationService.getDirectionText(
          ArrowEngine.normalize360(_angleTracker.shown),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reading = _distance;
    final showArrow =
        _mode != ArrowMode.waiting && reading != null && reading.meters != null;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF00D4AA), Color(0xFF00A896)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: Center(
                  child: showArrow
                      ? _buildTrackingView(reading)
                      : _buildWaitingView(),
                ),
              ),
              _buildStopButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _stopTracking,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              shape: const CircleBorder(),
              fixedSize: const Size(44, 44),
            ),
          ),
          Expanded(
            child: Text(
              widget.friendName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _buildVoiceButton(),
          const SizedBox(width: 8),
          _buildMapButton(),
        ],
      ),
    );
  }

  Widget _buildVoiceButton() {
    return Material(
      color: _voiceEnabled
          ? Colors.white.withValues(alpha: 0.18)
          : Colors.black.withValues(alpha: 0.18),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _toggleVoice,
        child: Tooltip(
          message: _voiceEnabled
              ? 'Mute voice guidance'
              : 'Unmute voice guidance',
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              _voiceEnabled ? Icons.volume_up : Icons.volume_off,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }

  void _toggleVoice() {
    final next = !_voiceEnabled;
    setState(() => _voiceEnabled = next);
    _voice.enabled = next;
    if (next) {
      unawaited(_voice.warmUp());
    }
  }

  Widget _buildMapButton() {
    return Material(
      color: Colors.white.withValues(alpha: 0.18),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _openMap,
        child: const Tooltip(
          message: 'Open live map',
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.map_outlined, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  void _openMap() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapScreen(friendName: widget.friendName),
      ),
    );
  }

  Widget _buildWaitingView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
          const SizedBox(height: 24),
          Text(
            _permissionDenied
                ? 'Location permission denied'
                : "Finding ${widget.friendName}'s location...",
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackingView(DistanceReading reading) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ArrowDisplay(
          angle: _arrowAngle,
          uncertaintyDeg: _uncertaintyDeg,
          mode: _mode,
          friendName: widget.friendName,
          friendAgeSeconds: _friendAgeSeconds,
        ),
        const SizedBox(height: 36),
        Text(
          reading.displayValue,
          style: TextStyle(
            color: Colors.white,
            fontSize: reading.isVeryClose ? 42 : 56,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 10),
        _buildSourceChip(reading),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Text(
            _directionText(),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 22),
          ),
        ),
        if (_needsCalibration) ...[
          const SizedBox(height: 18),
          _buildCalibrationHint(),
        ],
      ],
    );
  }

  Widget _buildSourceChip(DistanceReading reading) {
    final icon = reading.source == DistanceSource.bluetooth
        ? Icons.bluetooth
        : Icons.gps_fixed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white70),
          const SizedBox(width: 6),
          Text(
            reading.detail,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalibrationHint() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 28),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.explore_off_outlined, size: 15, color: Colors.white70),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Compass accuracy is low — move your phone in a figure-8.',
              style: TextStyle(color: Colors.white70, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStopButton() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: ElevatedButton(
        onPressed: _stopTracking,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          elevation: 5,
        ),
        child: const Text(
          'Stop Tracking',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Future<void> _stopTracking() async {
    final shouldStop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End Session?'),
        content: const Text('Are you sure you want to stop tracking?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('End'),
          ),
        ],
      ),
    );

    if (shouldStop == true) {
      await FirebaseService.endTrackingSession(widget.sessionId);
      if (!mounted) return;
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _bleSubscription?.cancel();
    MyPositionService.fix.removeListener(_onMyFix);
    FriendPositionService.fix.removeListener(_onFriendFix);
    CompassService.heading.removeListener(_onHeading);
    FriendPositionService.stop();
    MyPositionService.stop();
    CompassService.stop();
    _voice.dispose();
    unawaited(BluetoothDistanceService.stopScanning());
    unawaited(BluetoothDistanceService.stopAdvertising());
    _arrowAngle.dispose();
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }
}

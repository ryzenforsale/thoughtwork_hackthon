import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/bluetooth_distance_service.dart';
import '../services/distance_engine.dart';
import '../services/firebase_service.dart';
import '../services/location_service.dart';
import '../services/position_service.dart';
import 'map_screen.dart';

class TrackingScreenB extends StatefulWidget {
  final String sessionId;
  final String friendId;
  final String friendName;
  final String myDeviceId;

  const TrackingScreenB({
    super.key,
    required this.sessionId,
    required this.friendId,
    required this.friendName,
    required this.myDeviceId,
  });

  @override
  State<TrackingScreenB> createState() => _TrackingScreenBState();
}

class _TrackingScreenBState extends State<TrackingScreenB>
    with SingleTickerProviderStateMixin {
  late AnimationController _iconController;

  DistanceReading? _distance;
  int? _friendAgeSeconds;
  bool _permissionDenied = false;

  StreamSubscription<Map<String, dynamic>>? _bleSubscription;
  double? _bleDistance;
  DateTime? _bleUpdatedAt;

  Timer? _ticker;
  DateTime _lastFirebaseUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    _setupAnimation();
    _startTracking();
  }

  void _setupAnimation() {
    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  Future<void> _startTracking() async {
    final hasPermission = await LocationService.requestPermission();
    if (!hasPermission) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }

    LocationService.resetFilter();
    await MyPositionService.start();
    FriendPositionService.watch(widget.sessionId, widget.friendId);

    MyPositionService.fix.addListener(_onMyFix);
    FriendPositionService.fix.addListener(_onFriendFix);

    await BluetoothDistanceService.startAdvertising(widget.myDeviceId);

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

  void _publishMyLocation() {
    final my = MyPositionService.fix.value;
    if (my == null) return;

    final now = DateTime.now();
    if (now.difference(_lastFirebaseUpdate) <
        const Duration(milliseconds: 900)) {
      return;
    }
    _lastFirebaseUpdate = now;

    unawaited(
      FirebaseService.updateLocation(
        widget.sessionId,
        widget.myDeviceId,
        my.lat,
        my.lng,
        0,
        accuracy: my.accuracyMeters,
      ),
    );
    unawaited(
      FirebaseService.updateDeviceLocation(
        widget.myDeviceId,
        my.lat,
        my.lng,
        0,
        my.accuracyMeters,
      ),
    );
  }

  void _refresh() {
    if (!mounted) return;

    final my = MyPositionService.fix.value;
    final friend = FriendPositionService.fix.value;

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

    setState(() {
      _distance = reading;
      _friendAgeSeconds = friend == null
          ? null
          : DateTime.now().difference(friend.at).inSeconds;
    });
  }

  @override
  Widget build(BuildContext context) {
    final reading = _distance;
    final ready = reading != null && reading.meters != null;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue.shade400, Colors.blue.shade700],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: Center(
                  child: ready
                      ? _buildSharingView(reading)
                      : _buildConnectingView(),
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
            onPressed: _stopSharing,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              shape: const CircleBorder(),
              fixedSize: const Size(44, 44),
            ),
          ),
          Expanded(
            child: Text(
              'Sharing with ${widget.friendName}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _buildMapButton(),
        ],
      ),
    );
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

  Widget _buildConnectingView() {
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
            _permissionDenied ? 'Location permission denied' : 'Connecting...',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildSharingView(DistanceReading reading) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedBuilder(
          animation: _iconController,
          builder: (context, child) {
            return Transform.scale(
              scale: 1 + (_iconController.value * 0.3),
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.3),
                ),
                child: const Icon(
                  Icons.location_on,
                  size: 60,
                  color: Colors.white,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 44),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            '${widget.friendName} is reaching you',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            'Please stand where you are',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
        ),
        const SizedBox(height: 40),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.2),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Column(
            children: [
              Text(
                reading.displayValue,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: reading.isVeryClose ? 36 : 48,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'away',
                style: TextStyle(color: Colors.white70, fontSize: 20),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildSourceChip(reading),
        if (reading.isVeryClose) ...[
          const SizedBox(height: 12),
          const Text(
            'They are right next to you',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ] else if (_friendAgeSeconds != null && _friendAgeSeconds! > 10) ...[
          const SizedBox(height: 12),
          Text(
            'Last update ${_friendAgeSeconds}s ago',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
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

  Widget _buildStopButton() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: ElevatedButton(
        onPressed: _stopSharing,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
        child: const Text('Stop Sharing', style: TextStyle(fontSize: 18)),
      ),
    );
  }

  Future<void> _stopSharing() async {
    await FirebaseService.endTrackingSession(widget.sessionId);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _bleSubscription?.cancel();
    MyPositionService.fix.removeListener(_onMyFix);
    FriendPositionService.fix.removeListener(_onFriendFix);
    FriendPositionService.stop();
    MyPositionService.stop();
    unawaited(BluetoothDistanceService.stopScanning());
    unawaited(BluetoothDistanceService.stopAdvertising());
    _iconController.dispose();
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }
}

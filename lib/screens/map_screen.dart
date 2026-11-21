import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/compass_service.dart';
import '../services/distance_engine.dart';
import '../services/position_service.dart';

/// Full-screen live map: where you are, where your friend is, and the
/// straight-line path between the two phones.
///
/// It deliberately does not own the position services - the tracking screen
/// keeps them running while this screen is pushed on top, so the map is always
/// fed by the same filtered fixes as the arrow.
class MapScreen extends StatefulWidget {
  final String friendName;

  const MapScreen({super.key, required this.friendName});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();

  bool _followMe = true;
  bool _mapReady = false;
  bool _tilesFailed = false;
  bool _didInitialFit = false;
  bool _didAutoFitFriend = false;

  LatLng? _lastCentered;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      body: ValueListenableBuilder<PositionFix?>(
        valueListenable: MyPositionService.fix,
        builder: (context, my, _) {
          return ValueListenableBuilder<PositionFix?>(
            valueListenable: FriendPositionService.fix,
            builder: (context, friend, _) {
              final myPoint = my == null ? null : LatLng(my.lat, my.lng);
              final friendPoint = friend == null
                  ? null
                  : LatLng(friend.lat, friend.lng);

              _scheduleCamera(myPoint, friendPoint);

              return Stack(
                children: [
                  _buildMap(my, friend, myPoint, friendPoint),
                  _buildTopBar(my, friend, myPoint, friendPoint),
                  if (_tilesFailed) _buildTileWarning(),
                  _buildControls(myPoint, friendPoint),
                  _buildBottomCard(my, friend, myPoint, friendPoint),
                ],
              );
            },
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- camera

  void _scheduleCamera(LatLng? myPoint, LatLng? friendPoint) {
    if (!_mapReady) return;

    if (!_didInitialFit && myPoint != null) {
      _didInitialFit = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _mapController.move(myPoint, 17);
      });
      return;
    }

    // Once both people are known, zoom out just enough to show both of them.
    if (!_didAutoFitFriend &&
        _didInitialFit &&
        myPoint != null &&
        friendPoint != null) {
      _didAutoFitFriend = true;
      final separation = DistanceEngine.haversineMeters(
        myPoint.latitude,
        myPoint.longitude,
        friendPoint.latitude,
        friendPoint.longitude,
      );
      if (separation > 40) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _fitBoth(myPoint, friendPoint);
        });
      }
    }

    if (_followMe && myPoint != null) {
      final last = _lastCentered;
      final moved = last == null
          ? double.infinity
          : DistanceEngine.haversineMeters(
              last.latitude,
              last.longitude,
              myPoint.latitude,
              myPoint.longitude,
            );
      if (moved > 2) {
        _lastCentered = myPoint;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _mapController.move(myPoint, _mapController.camera.zoom);
        });
      }
    }
  }

  void _fitBoth(LatLng myPoint, LatLng friendPoint) {
    if (!_mapReady) return;
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints([myPoint, friendPoint]),
        padding: const EdgeInsets.fromLTRB(60, 160, 60, 260),
        maxZoom: 17,
      ),
    );
  }

  // ------------------------------------------------------------------- map

  Widget _buildMap(
    PositionFix? my,
    PositionFix? friend,
    LatLng? myPoint,
    LatLng? friendPoint,
  ) {
    final center = myPoint ?? const LatLng(20.5937, 78.9629); // India
    final zoom = myPoint == null ? 4.2 : 17.0;

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        minZoom: 3,
        maxZoom: 19,
        backgroundColor: const Color(0xFF10202A),
        onMapReady: () {
          _mapReady = true;
          final my = MyPositionService.fix.value;
          if (my != null && !_didInitialFit) {
            _didInitialFit = true;
            _mapController.move(LatLng(my.lat, my.lng), 17);
          }
        },
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture && _followMe) {
            setState(() => _followMe = false);
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.meet_me',
          maxZoom: 19,
          errorTileCallback: (tile, error, stackTrace) {
            if (!_tilesFailed && mounted) {
              setState(() => _tilesFailed = true);
            }
          },
        ),
        if (myPoint != null && my != null && my.accuracyMeters > 0)
          CircleLayer(
            circles: [
              CircleMarker(
                point: myPoint,
                radius: my.accuracyMeters.clamp(5, 200).toDouble(),
                useRadiusInMeter: true,
                color: const Color(0xFF2196F3).withValues(alpha: 0.14),
                borderColor: const Color(0xFF2196F3).withValues(alpha: 0.55),
                borderStrokeWidth: 1.5,
              ),
            ],
          ),
        if (myPoint != null && friendPoint != null)
          PolylineLayer(
            polylines: [
              Polyline(
                points: [myPoint, friendPoint],
                strokeWidth: 3,
                color: Colors.white.withValues(alpha: 0.9),
                borderStrokeWidth: 2,
                borderColor: Colors.black.withValues(alpha: 0.25),
                isDotted: true,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            if (myPoint != null) _meMarker(myPoint),
            if (friendPoint != null)
              _friendMarker(friendPoint, friend, friendName: widget.friendName),
          ],
        ),
      ],
    );
  }

  Marker _meMarker(LatLng point) {
    return Marker(
      point: point,
      width: 84,
      height: 84,
      child: ValueListenableBuilder<HeadingSample?>(
        valueListenable: CompassService.heading,
        builder: (context, heading, _) {
          final degrees = heading?.degrees ?? 0;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (heading != null)
                Transform.rotate(
                  angle: degrees * math.pi / 180.0,
                  child: CustomPaint(
                    size: const Size(84, 84),
                    painter: _HeadingConePainter(),
                  ),
                ),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF2196F3),
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Marker _friendMarker(
    LatLng point,
    PositionFix? friend, {
    required String friendName,
  }) {
    final stale = friend?.isStale ?? false;

    return Marker(
      point: point,
      width: 140,
      height: 92,
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 6,
                ),
              ],
            ),
            child: Text(
              friendName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0B141A),
              ),
            ),
          ),
          Icon(
            Icons.location_on,
            size: 42,
            color: stale ? Colors.grey.shade500 : const Color(0xFF00B894),
            shadows: const [
              Shadow(
                color: Colors.black26,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- chrome

  Widget _buildTopBar(
    PositionFix? my,
    PositionFix? friend,
    LatLng? myPoint,
    LatLng? friendPoint,
  ) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              _roundButton(
                icon: Icons.arrow_back,
                onTap: () => Navigator.pop(context),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC0B141A),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Live map',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _statusLine(friend),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _roundButton(
                icon: Icons.navigation,
                tooltip: 'Centre on me',
                active: _followMe,
                onTap: () {
                  setState(() => _followMe = true);
                  if (myPoint != null && _mapReady) {
                    _mapController.move(myPoint, 17.5);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(LatLng? myPoint, LatLng? friendPoint) {
    return Positioned(
      right: 12,
      bottom: 190,
      child: Column(
        children: [
          _roundButton(
            icon: Icons.zoom_out_map,
            tooltip: 'Show both',
            onTap: () {
              if (!_mapReady) return;
              if (myPoint != null && friendPoint != null) {
                setState(() => _followMe = false);
                _fitBoth(myPoint, friendPoint);
              } else if (myPoint != null) {
                _mapController.move(myPoint, 17);
              }
            },
          ),
          const SizedBox(height: 10),
          _roundButton(
            icon: Icons.add,
            tooltip: 'Zoom in',
            onTap: () {
              if (!_mapReady) return;
              _mapController.move(
                _mapController.camera.center,
                (_mapController.camera.zoom + 1).clamp(3.0, 19.0),
              );
            },
          ),
          const SizedBox(height: 10),
          _roundButton(
            icon: Icons.remove,
            tooltip: 'Zoom out',
            onTap: () {
              if (!_mapReady) return;
              _mapController.move(
                _mapController.camera.center,
                (_mapController.camera.zoom - 1).clamp(3.0, 19.0),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBottomCard(
    PositionFix? my,
    PositionFix? friend,
    LatLng? myPoint,
    LatLng? friendPoint,
  ) {
    final meters = (myPoint != null && friendPoint != null)
        ? DistanceEngine.haversineMeters(
            myPoint.latitude,
            myPoint.longitude,
            friendPoint.latitude,
            friendPoint.longitude,
          )
        : null;

    final accuracy = (my != null && friend != null)
        ? math.sqrt(
            my.accuracyMeters * my.accuracyMeters +
                friend.accuracyMeters * friend.accuracyMeters,
          )
        : null;

    return Positioned(
      left: 12,
      right: 12,
      bottom: 16,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            color: const Color(0xF20B141A),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      meters == null
                          ? 'Locating…'
                          : DistanceEngine.formatMeters(meters),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _distanceDetail(friend, accuracy),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF00B894).withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.straighten,
                      size: 14,
                      color: Color(0xFF4DE3C1),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Straight line',
                      style: TextStyle(
                        color: const Color(0xFF4DE3C1).withValues(alpha: 0.95),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTileWarning() {
    return Positioned(
      top: 96,
      left: 12,
      right: 12,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xE6B45309),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            children: [
              Icon(Icons.cloud_off, size: 14, color: Colors.white),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Map tiles unavailable — check your internet. '
                  'Your positions are still shown.',
                  style: TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    bool active = false,
  }) {
    final button = Material(
      color: active ? const Color(0xFF00B894) : const Color(0xE60B141A),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 21, color: Colors.white),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }

  String _statusLine(PositionFix? friend) {
    if (friend == null) return 'Waiting for ${widget.friendName}…';
    if (friend.isStale) {
      return '${widget.friendName} · last seen ${friend.ageSeconds.round()}s ago';
    }
    return '${widget.friendName} · updated ${friend.ageSeconds.round()}s ago';
  }

  String _distanceDetail(PositionFix? friend, double? accuracy) {
    if (friend == null) return 'Waiting for your friend to share location';
    if (friend.isStale) {
      return 'Last known position · ${friend.ageSeconds.round()}s old';
    }
    if (accuracy == null) return 'GPS';
    return 'GPS · ±${accuracy.round()}m';
  }
}

/// A soft cone showing which way the top of the phone is pointing.
class _HeadingConePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width * 0.47;
    const half = 30 * math.pi / 180;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final start = -math.pi / 2 - half;

    final paint = Paint()
      ..shader = SweepGradient(
        startAngle: start,
        endAngle: start + half * 2,
        colors: [
          const Color(0xFF2196F3).withValues(alpha: 0.0),
          const Color(0xFF2196F3).withValues(alpha: 0.45),
          const Color(0xFF2196F3).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rect);

    canvas.drawArc(rect, start, half * 2, true, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

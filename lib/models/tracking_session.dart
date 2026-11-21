class LocationData {
  final double lat;
  final double lng;
  final double heading;
  final int timestamp;
  final double accuracy;

  LocationData({
    required this.lat,
    required this.lng,
    required this.heading,
    required this.timestamp,
    this.accuracy = 0,
  });

  factory LocationData.fromMap(Map<dynamic, dynamic> map) {
    return LocationData(
      lat: _asDouble(map['lat']),
      lng: _asDouble(map['lng']),
      heading: _asDouble(map['heading']),
      // Sessions use `timestamp`, devices/community use `locationUpdatedAt`
      // (falling back to `lastSeen` for older clients).
      timestamp: _asInt(
        map['timestamp'] ?? map['locationUpdatedAt'] ?? map['lastSeen'],
      ),
      accuracy: _asDouble(map['accuracy']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'lat': lat,
      'lng': lng,
      'heading': heading,
      'timestamp': timestamp,
      'accuracy': accuracy,
    };
  }

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  static int _asInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

class TrackingSession {
  final String id;
  final String deviceAId;
  final String deviceBId;
  final bool active;
  final LocationData? locationA;
  final LocationData? locationB;

  TrackingSession({
    required this.id,
    required this.deviceAId,
    required this.deviceBId,
    required this.active,
    this.locationA,
    this.locationB,
  });
}

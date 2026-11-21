import 'dart:convert';

import 'package:http/http.dart' as http;

class TinyFishPlace {
  final String title;
  final String snippet;
  final String url;
  final String siteName;

  const TinyFishPlace({
    required this.title,
    required this.snippet,
    required this.url,
    required this.siteName,
  });

  factory TinyFishPlace.fromJson(Map<String, dynamic> json) {
    return TinyFishPlace(
      title: json['title'] as String? ?? 'Hospital',
      snippet: json['snippet'] as String? ?? '',
      url: json['url'] as String? ?? '',
      siteName: json['site_name'] as String? ?? '',
    );
  }
}

class TinyFishPlacesService {
  static const String _apiKey = String.fromEnvironment('TINYFISH_API_KEY');
  static const String _searchLocation = String.fromEnvironment(
    'TINYFISH_SEARCH_LOCATION',
    defaultValue: 'IN',
  );

  static Future<List<TinyFishPlace>> searchNearbyHospitals({
    required double latitude,
    required double longitude,
  }) async {
    if (_apiKey.isEmpty) {
      throw StateError(
        'TinyFish API key is missing. Run with --dart-define=TINYFISH_API_KEY=your_key',
      );
    }

    final query = Uri.encodeComponent(
      'hospitals near latitude $latitude, longitude $longitude, '
      'including hospital name, address, phone number, and distance',
    );
    final uri = Uri.parse(
      'https://api.search.tinyfish.ai/?query=$query'
      '&purpose=Find nearby hospitals for the user at these exact GPS coordinates'
      '&location=$_searchLocation&language=en&page=0',
    );

    final response = await http.get(
      uri,
      headers: {'X-API-Key': _apiKey, 'Accept': 'application/json'},
    );

    if (response.statusCode != 200) {
      throw Exception('TinyFish search failed (${response.statusCode})');
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final results = payload['results'];
    if (results is! List) return const [];

    return results
        .whereType<Map<String, dynamic>>()
        .map(TinyFishPlace.fromJson)
        .take(8)
        .toList(growable: false);
  }
}

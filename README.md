# meet_me

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## TinyFish Nearby Hospitals

The Community radar includes a `Near You` filter. It sends the current GPS
coordinates to the TinyFish Search API and displays hospital search results.

1. Create an API key at https://agent.tinyfish.ai/api-keys.
2. Run the app without committing the key:

```bash
flutter run --dart-define=TINYFISH_API_KEY=sk-tinyfish-your-key
```

The default search country is India. Override it when needed:

```bash
flutter run --dart-define=TINYFISH_API_KEY=sk-tinyfish-your-key --dart-define=TINYFISH_SEARCH_LOCATION=US
```

Do not place the key directly in Dart source or commit it to version control.

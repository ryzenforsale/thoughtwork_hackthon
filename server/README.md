# MeetMe voice proxy (Render + ElevenLabs)

A ~100-line Node service that turns text into speech with ElevenLabs and hands
the MP3 back to the Flutter app. The API key stays here, never in the APK.

## 1. Get an ElevenLabs key + voice id

1. Sign in at <https://elevenlabs.io> → **Profile → API Keys** → create a key.
2. Pick a voice at <https://elevenlabs.io/app/voice-lab> and copy its **Voice ID**
   (or list them later with `GET /voices`).

## 2. Deploy on Render

### Option A — Blueprint (recommended)

1. Push this project to GitHub (or just the repo containing `server/` + `render.yaml`).
2. Render dashboard → **New → Blueprint** → select the repo.
3. Render reads `render.yaml`, creates the `meetme-voice` web service.
4. When prompted, set:
   - `ELEVENLABS_API_KEY` = your key
   - `ELEVENLABS_VOICE_ID` = the voice id you copied
5. Deploy. Your URL will look like `https://meetme-voice-xxxx.onrender.com`.

### Option B — Manual web service

1. Render → **New → Web Service** → connect the repo.
2. **Root Directory**: `server`
3. **Build Command**: `npm install`
4. **Start Command**: `npm start`
5. **Environment variables**: `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`,
   `ELEVENLABS_MODEL_ID=eleven_turbo_v2_5`
6. Deploy.

## 3. Point the app at it

The app reads the base URL at build time:

```powershell
flutter build apk --debug --dart-define=VOICE_API_BASE=https://meetme-voice-xxxx.onrender.com
```

Or edit the default in `lib/services/voice_guide_service.dart`
(`defaultApiBase`).

## 4. Test the service

```powershell
curl -X POST https://meetme-voice-xxxx.onrender.com/speak `
  -H "content-type: application/json" `
  -d '{\"text\":\"Rahul is twelve metres away, straight ahead\"}' --output test.mp3
```

Open `test.mp3` — if you hear the voice, the app will too.

`GET /health` → `{ "ok": true, "configured": true }`
`GET /voices` → your account's voices (id + name)

## Notes for the demo

- **Free tier sleeps after ~15 minutes of inactivity** and takes ~30-60 s to wake.
  Before presenting, open `/health` once (or keep a 10-minute uptime ping) so the
  first announcement is instant.
- The service caches identical phrases, so repeated directions cost no extra quota.
- If Render is asleep/unreachable, the app automatically falls back to the
  phone's built-in TTS, so the demo never goes silent.

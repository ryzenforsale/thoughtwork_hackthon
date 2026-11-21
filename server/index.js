import crypto from 'node:crypto';
import express from 'express';

/**
 * MeetMe voice proxy.
 *
 * The Flutter app POSTs { "text": "Rahul is 12 metres away, straight ahead" }
 * and gets back an MP3 rendered by ElevenLabs. The ElevenLabs API key lives
 * only in this server's environment variables, never in the APK.
 */

const app = express();
app.use(express.json({ limit: '8kb' }));

const PORT = process.env.PORT || 8080;
const API_KEY = process.env.ELEVENLABS_API_KEY || '';
const VOICE_ID = process.env.ELEVENLABS_VOICE_ID || '21m00Tcm4TlvDq8ikWAM';
const MODEL_ID = process.env.ELEVENLABS_MODEL_ID || 'eleven_turbo_v2_5';
const MAX_CHARS = 300;

// Tiny in-memory cache: the same direction phrase is requested repeatedly while
// walking, so this saves both latency and ElevenLabs quota.
const cache = new Map();
const CACHE_LIMIT = 150;

// Very small per-IP rate limiter so a stuck app cannot burn the quota.
const hits = new Map();
const RATE_LIMIT = 40; // requests
const RATE_WINDOW_MS = 60_000;

app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'content-type');
  res.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

app.get('/', (_req, res) => {
  res.json({
    ok: true,
    service: 'meetme-voice',
    configured: Boolean(API_KEY),
    voiceId: VOICE_ID,
    model: MODEL_ID,
  });
});

app.get('/health', (_req, res) => {
  res.json({ ok: true, configured: Boolean(API_KEY) });
});

// Lists the voices available on the configured ElevenLabs account, so you can
// copy the id you like into ELEVENLABS_VOICE_ID.
app.get('/voices', async (_req, res) => {
  if (!API_KEY) return res.status(500).json({ error: 'missing ELEVENLABS_API_KEY' });
  try {
    const upstream = await fetch('https://api.elevenlabs.io/v1/voices', {
      headers: { 'xi-api-key': API_KEY },
    });
    const data = await upstream.json();
    if (!upstream.ok) return res.status(upstream.status).json(data);
    res.json(
      (data.voices || []).map((v) => ({
        id: v.voice_id,
        name: v.name,
        category: v.category,
        labels: v.labels,
      })),
    );
  } catch (error) {
    res.status(502).json({ error: 'voices request failed', detail: String(error) });
  }
});

app.post('/speak', async (req, res) => {
  const text = String(req.body?.text ?? '').trim();

  if (!text) return res.status(400).json({ error: 'text is required' });
  if (text.length > MAX_CHARS) {
    return res.status(413).json({ error: `text too long (max ${MAX_CHARS})` });
  }
  if (!API_KEY) {
    return res.status(500).json({ error: 'server missing ELEVENLABS_API_KEY' });
  }

  const ip = req.headers['x-forwarded-for']?.toString().split(',')[0] || req.ip || 'unknown';
  if (!allowRequest(ip)) {
    return res.status(429).json({ error: 'too many requests' });
  }

  const key = crypto
    .createHash('sha1')
    .update(`${VOICE_ID}|${MODEL_ID}|${text}`)
    .digest('hex');

  const cached = cache.get(key);
  if (cached) {
    res.set('X-Cache', 'HIT');
    return sendAudio(res, cached);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);

  try {
    const upstream = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}?output_format=mp3_44100_128`,
      {
        method: 'POST',
        headers: {
          'xi-api-key': API_KEY,
          'content-type': 'application/json',
          accept: 'audio/mpeg',
        },
        body: JSON.stringify({
          text,
          model_id: MODEL_ID,
          voice_settings: {
            stability: 0.4,
            similarity_boost: 0.75,
            style: 0.0,
            use_speaker_boost: true,
          },
        }),
        signal: controller.signal,
      },
    );

    if (!upstream.ok) {
      const detail = await upstream.text();
      console.error('ElevenLabs error', upstream.status, detail.slice(0, 300));
      return res.status(upstream.status).json({
        error: 'elevenlabs request failed',
        detail: detail.slice(0, 500),
      });
    }

    const buffer = Buffer.from(await upstream.arrayBuffer());
    cache.set(key, buffer);
    if (cache.size > CACHE_LIMIT) {
      cache.delete(cache.keys().next().value);
    }

    res.set('X-Cache', 'MISS');
    return sendAudio(res, buffer);
  } catch (error) {
    const aborted = error?.name === 'AbortError';
    console.error('TTS failed', error);
    return res
      .status(aborted ? 504 : 502)
      .json({ error: aborted ? 'elevenlabs timeout' : 'elevenlabs unreachable' });
  } finally {
    clearTimeout(timeout);
  }
});

function sendAudio(res, buffer) {
  res.set({
    'Content-Type': 'audio/mpeg',
    'Content-Length': String(buffer.length),
    'Cache-Control': 'public, max-age=86400',
  });
  res.send(buffer);
}

function allowRequest(ip) {
  const now = Date.now();
  const entry = hits.get(ip);
  if (!entry || now - entry.start > RATE_WINDOW_MS) {
    hits.set(ip, { start: now, count: 1 });
    return true;
  }
  entry.count += 1;
  return entry.count <= RATE_LIMIT;
}

app.listen(PORT, '0.0.0.0', () => {
  console.log(`meetme-voice listening on :${PORT} (configured=${Boolean(API_KEY)})`);
});

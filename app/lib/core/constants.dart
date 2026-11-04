import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// Single source of truth for Texa's fixed values.
const double boardWidth = 1600;
const double boardHeight = 1200;
const Size boardSize = Size(boardWidth, boardHeight);
const String apiBaseUrl = 'https://api.meta.ai/v1';
const String ignoreTurnSentinel = '<[IGNORE_TURN]>';

/// Output by the model (exactly, alone) after a tool result when the
/// turn is complete and there is nothing relevant left to say or do -
/// the app ends the turn silently instead of speaking filler.
const String turnDoneSentinel = '<[TURN_DONE]>';
const int frameIntervalMs = 1000;
const int frameWidth = 720;
const int frameHeight = 540;
const int vadSilenceMs = 500;
const int sustainedSpeechMs = 250;
const int connectTimeoutSeconds = 60;
const int responseTimeoutSeconds = 180;

/// Maximum number of student turn-videos sent in one tutor request.
/// Meta AI allows 5 videos per request; Texa keeps one spare slot as a
/// safety margin. Older student turns are sent as transcripts instead.
const int maxVideoTurnsPerRequest = 4;

final isMobile = [
  TargetPlatform.iOS,
  TargetPlatform.android,
].contains(defaultTargetPlatform);

/// Base URL the individual Kokoro files (`model.onnx`, `voices.bin`, …)
/// are downloaded from; the file name is appended to it.
const String kokoroBaseUrl = String.fromEnvironment(
  'KOKORO_BASE_URL',
  defaultValue:
      'https://huggingface.co/sitatech/kokoro-multi-lang-v1_0/resolve/main/',
);

/// Base URL the individual Piper files (`model.onnx`, `tokens.txt`)
/// are downloaded from; the file name is appended to it. Piper reuses
/// Kokoro's lexicon, so it has no lexicon file of its own here.
/// Base URL of the Kokoro-82M ONNX repo used on WEB only (kokoro-js).
/// HF form ends in `/resolve/main/`; a local mirror ends at the repo
/// root (files directly inside). See texa-webspeech kokoro-source.js.
/// Dev example: --dart-define=KOKORO_WEB_BASE_URL=http://localhost:8765/sitatech/Kokoro-82M-v1.0-ONNX/
const String kokoroWebBaseUrl = String.fromEnvironment(
  'KOKORO_WEB_BASE_URL',
  defaultValue:
      'https://huggingface.co/sitatech/Kokoro-82M-v1.0-ONNX/resolve/main/',
);

const String piperBaseUrl = String.fromEnvironment(
  'PIPER_BASE_URL',
  defaultValue: 'https://huggingface.co/sitatech/vits-piper-en_US-amy-medium/resolve/main/',
);
const String sileroVadModelUrl = String.fromEnvironment(
  'SILERO_VAD_MODEL_URL',
  defaultValue: 'https://huggingface.co/sitatech/Smart-Turn-v3.2-ONNX/resolve/main/silero_vad.onnx',
);
const String smartTurnModelUrl = String.fromEnvironment(
  'SMART_TURN_MODEL_URL',
  defaultValue: 'https://huggingface.co/sitatech/Smart-Turn-v3.2-ONNX/resolve/main/smart-turn-v3.2-int8.onnx',
);

const wasmBaseUrl = String.fromEnvironment('WASM_BASE_URL');

Color colorFromName(String? name, Color fallback) {
  switch (name?.toLowerCase()) {
    case 'red':
      return const Color(0xFFEF6666);
    case 'green':
      return const Color(0xFF10B981);
    case 'yellow':
    case 'amber':
      return const Color(0xFFFBBF24);
    case 'blue':
      return const Color(0xFF3B82F6);
    case 'black':
      return const Color(0xFF1F2937);
    case 'purple':
      return const Color(0xFF8B5CF6);
    case 'orange':
      return const Color(0xFFF97316);
    default:
      return fallback;
  }
}

String colorToName(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';

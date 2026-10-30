import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// Single source of truth for Texa's fixed values.
const double boardWidth = 1600;
const double boardHeight = 1200;
const Size boardSize = Size(boardWidth, boardHeight);
const String apiBaseUrl = 'https://api.meta.ai/v1';
const String ignoreTurnSentinel = '<[IGNORE_TURN]>';
const int frameIntervalMs = 1000;
const int frameWidth = 720;
const int frameHeight = 540;
const int vadSilenceMs = 1000;
const int sustainedSpeechMs = 300;
const int connectTimeoutSeconds = 30;
const int responseTimeoutSeconds = 120;

final isMobile = [
  TargetPlatform.iOS,
  TargetPlatform.android,
].contains(defaultTargetPlatform);

/// Base URL the individual Kokoro files (`model.onnx`, `voices.bin`, …)
/// are downloaded from; the file name is appended to it.
const String kokoroBaseUrl = String.fromEnvironment(
  'KOKORO_BASE_URL',
  defaultValue:
      'https://huggingface.co/sitatech/kokoro-multi-lang-v1_1/resolve/main/',
);

/// Base URL the individual Piper files (`model.onnx`, `tokens.txt`)
/// are downloaded from; the file name is appended to it. Piper reuses
/// Kokoro's lexicon, so it has no lexicon file of its own here.
const String piperBaseUrl = String.fromEnvironment(
  'PIPER_BASE_URL',
  defaultValue: 'https://huggingface.co/sitatech/vits-piper-en_US-hfc_female-medium/resolve/main/',
);
const String sileroVadModelUrl = String.fromEnvironment(
  'SILERO_VAD_MODEL_URL',
  defaultValue: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
);
const String smartTurnModelUrl = String.fromEnvironment(
  'SMART_TURN_MODEL_URL',
  defaultValue: 'https://huggingface.co/soniqo/Smart-Turn-v3.2-ONNX/resolve/main/smart-turn-v3.2-int8.onnx',
);
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

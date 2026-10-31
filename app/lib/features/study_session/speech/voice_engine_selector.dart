import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/data/models.dart';
import '../../../generated/i18n/translations.g.dart';

/// Radio choice between the Kokoro and Piper TTS engines, with the
/// platform recommendation badged (Piper on mobile, Kokoro on desktop).
/// Shared by Setup (first launch, before anything is downloaded) and
/// Settings (switchable anytime afterwards).
class VoiceEngineSelector extends StatelessWidget {
  const VoiceEngineSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// Currently selected engine (callers pass the platform default
  /// until the user picks one explicitly).
  final TtsEngine value;
  final ValueChanged<TtsEngine?> onChanged;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<TtsEngine>(
      groupValue: value,
      onChanged: onChanged,
      child: Column(
        children: [
          RadioListTile<TtsEngine>(
            value: TtsEngine.kokoro,
            title: _title(
              context,
              tr.settings.voiceKokoro,
              recommended: !isMobile,
            ),
            subtitle: Text(tr.settings.voiceKokoroDescription),
          ),
          RadioListTile<TtsEngine>(
            value: TtsEngine.piper,
            title: _title(
              context,
              tr.settings.voicePiper,
              recommended: isMobile,
            ),
            subtitle: Text(tr.settings.voicePiperDescription),
          ),
        ],
      ),
    );
  }

  Widget _title(
    BuildContext context,
    String name, {
    required bool recommended,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name),
        if (recommended) ...[
          const SizedBox(width: 8),
          Container(
            padding: .symmetric(vertical: 2, horizontal: 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.7),
              ),
              borderRadius: .circular(7),
            ),
            child: Text(
              tr.settings.voiceRecommended,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }
}

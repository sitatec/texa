import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:texa/core/widgets/texa_app_bar.dart';

import '../../app_controller.dart';
import '../../core/data/models.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../generated/i18n/translations.g.dart';
import '../study_session/ai/ai_client.dart';
import '../study_session/speech/voice_engine_selector.dart';

/// Settings: API key, captions default, local logs and data wipe.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.app});
  final AppController app;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _key = TextEditingController(
    text: widget.app.settings.apiKey,
  );
  late final TextEditingController _memory = TextEditingController(
    text: widget.app.memoryText,
  );
  bool _testing = false;
  String? _message;
  String _logs = '';
  bool _voiceSwitching = false;
  double _voiceProgress = 0;
  String? _voiceProgressLabel;
  @override
  void initState() {
    super.initState();
    unawaited(_loadLogs());
  }

  Future<void> _loadLogs() async {
    final l = await widget.app.db.loadLogs();
    if (mounted) setState(() => _logs = l);
  }

  @override
  void dispose() {
    _key.dispose();
    _memory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: TexaAppBar(title: Text(tr.settings.title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: .start,
              children: [
                Text(
                  tr.settings.apiSection,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(tr.setup.privacyNote),
                const SizedBox(height: 12),
                TextField(
                  controller: _key,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: tr.setup.apiKeyLabel,
                    hintText: tr.setup.apiKeyHint,
                    helperText: tr.setup.apiKeySecureNote,
                    border: OutlineInputBorder(borderRadius: .circular(8)),
                  ),
                ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_message!),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: const Icon(Symbols.wifi_tethering),
                      label: Text(
                        _testing ? tr.setup.testing : tr.setup.testConnection,
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Symbols.save),
                      label: Text(tr.common.save),
                    ),
                  ],
                ),
                const Divider(height: 36),
                Text(
                  tr.settings.playbackSection,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SwitchListTile(
                  visualDensity: .compact,
                  dense: true,
                  value: widget.app.settings.captionsDefault,
                  title: Text(tr.settings.captionsDefault),
                  onChanged: (v) async {
                    await widget.app.saveSettings(
                      widget.app.settings.copyWith(captionsDefault: v),
                    );
                    setState(() {});
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  tr.settings.voiceSection,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                VoiceEngineSelector(
                  value: widget.app.settings.ttsEngineOrDefault,
                  onChanged: _voiceSwitching ? (_) {} : _changeVoice,
                ),
                if (_voiceSwitching) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _voiceProgress),
                  if (_voiceProgressLabel != null) ...[
                    const SizedBox(height: 6),
                    Text(_voiceProgressLabel!),
                  ],
                ],
                const Divider(height: 36),
                Text(
                  tr.settings.memorySection,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(tr.settings.memoryDescription),
                const SizedBox(height: 12),
                TextField(
                  controller: _memory,
                  minLines: 3,
                  maxLines: 8,
                  decoration: InputDecoration(
                    labelText: tr.settings.memoryLabel,
                    hintText: tr.settings.memoryHint,
                    border: OutlineInputBorder(borderRadius: .circular(8)),
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _saveMemory,
                    icon: const Icon(Symbols.save),
                    label: Text(tr.common.save),
                  ),
                ),
                const Divider(height: 36),
                Text(
                  tr.settings.dataSection,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: texaRed,
                    side: const BorderSide(color: texaRed),
                  ),
                  onPressed: _wipe,
                  icon: const Icon(Symbols.delete_forever),
                  label: Text(tr.settings.deleteAll),
                ),
                const Divider(height: 36),
                Row(
                  children: [
                    Text(
                      tr.settings.logs,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: tr.common.save,
                      icon: const Icon(Symbols.content_copy),
                      onPressed: _logs.isEmpty
                          ? null
                          : () => Clipboard.setData(ClipboardData(text: _logs)),
                    ),
                  ],
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 600),
                  child: SingleChildScrollView(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9FAFB),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SelectableText(
                        _logs.isEmpty ? '—' : _logs,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _message = null;
    });
    try {
      await AiClient(_key.text.trim()).testConnection();
      setState(() => _message = tr.setup.connectionOk);
    } on AppError catch (e) {
      setState(() => _message = e.message);
    } catch (_) {
      setState(() => _message = tr.setup.connectionFailed);
    }
    setState(() => _testing = false);
  }

  Future<void> _save() async {
    await widget.app.saveSettings(
      widget.app.settings.copyWith(
        apiKey: _key.text.trim(),
        setupComplete: _key.text.trim().isNotEmpty,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr.settings.saved)));
    }
  }

  Future<void> _saveMemory() async {
    await widget.app.saveMemory(_memory.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr.settings.saved)));
    }
  }

  Future<void> _changeVoice(TtsEngine? engine) async {
    if (engine == null ||
        _voiceSwitching ||
        engine == widget.app.settings.ttsEngineOrDefault) {
      return;
    }
    setState(() {
      _voiceSwitching = true;
      _voiceProgress = 0;
      _voiceProgressLabel = null;
    });
    try {
      await widget.app.changeTtsEngine(
        engine,
        onProgress: (label, f) {
          if (mounted) {
            setState(() {
              _voiceProgress = f;
              _voiceProgressLabel = tr.setup.downloading(
                name: label,
                percent: (f * 100).round().toString(),
              );
            });
          }
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr.settings.saved)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr.settings.voiceDownloadFailed)),
        );
      }
    }
    if (mounted) setState(() => _voiceSwitching = false);
  }

  Future<void> _wipe() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr.settings.deleteAllTitle),
        content: Text(tr.settings.deleteAllBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.common.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: texaRed),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.common.delete),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.app.wipeAll();
      if (mounted) Navigator.pop(context);
    }
  }
}

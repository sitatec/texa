import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app_controller.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../generated/i18n/translations.g.dart';
import '../study_session/ai/ai_client.dart';

/// First launch: API key, microphone permission, then speech provisioning.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.app, required this.onDone});
  final AppController app;
  final VoidCallback onDone;
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  int _step = 0;
  bool _testing = false;
  bool _keyOk = false;
  String? _error;
  bool _provisioning = false;
  double _progress = 0;
  String _progressLabel = '';
  final TextEditingController _key = TextEditingController();
  @override
  void initState() {
    super.initState();
    _key.text = widget.app.settings.apiKey;
    _keyOk = _key.text.isNotEmpty && widget.app.settings.setupComplete;
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Symbols.school, size: 64, color: texaBlue),
                  const SizedBox(height: 18),
                  Text(
                    tr.setup.welcomeTitle,
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(tr.setup.welcomeBody, textAlign: TextAlign.center),
                  const SizedBox(height: 14),
                  if (_step == 0) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          const Icon(Symbols.privacy_tip, color: texaBlue),
                          const SizedBox(width: 10),
                          Expanded(child: Text(tr.setup.privacyNote)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 26),
                    TextField(
                      controller: _key,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: tr.setup.apiKeyLabel,
                        hintText: tr.setup.apiKeyHint,
                        helperText: tr.setup.apiKeySecureNote,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() => _keyOk = false),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: texaRed),
                        ),
                      ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: _testing || _key.text.trim().isEmpty
                          ? null
                          : _test,
                      icon: const Icon(Symbols.wifi_tethering),
                      label: Text(
                        _testing ? tr.setup.testing : tr.setup.testConnection,
                      ),
                    ),
                    if (_keyOk)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          tr.setup.connectionOk,
                          style: const TextStyle(
                            color: texaGreen,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: _keyOk
                          ? () {
                              setState(() => _step = 1);
                              unawaited(_provision());
                            }
                          : null,
                      child: Text(tr.common.kContinue),
                    ),
                  ] else ...[
                    const SizedBox(height: 24),
                    Text(
                      tr.setup.modelsTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(tr.setup.modelsBody, textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    if (_provisioning) ...[
                      LinearProgressIndicator(
                        value: _progress == 0 ? null : _progress,
                      ),
                      const SizedBox(height: 10),
                      Text(_progressLabel, textAlign: TextAlign.center),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: texaRed),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (!_provisioning && _error != null) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => unawaited(_provision()),
                        icon: const Icon(Symbols.refresh),
                        label: Text(tr.common.retry),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      await AiClient(_key.text.trim()).testConnection();
      await widget.app.saveSettings(
        widget.app.settings.copyWith(apiKey: _key.text.trim()),
      );
      setState(() => _keyOk = true);
    } on AppError catch (e) {
      debugPrint(e.cause?.toString());
      setState(() => _error = e.message);
    } catch (e, s) {
      debugPrint('$e\n$s');
      setState(() => _error = tr.setup.connectionFailed);
    }
    setState(() => _testing = false);
  }

  Future<void> _provision() async {
    setState(() {
      _provisioning = true;
      _error = null;
      _progress = 0;
    });
    try {
      await widget.app.provisioning.provision((label, f) {
        if (mounted) {
          setState(() {
            _progress = f;
            _progressLabel = tr.setup.downloading(
              name: label,
              percent: (f * 100).round().toString(),
            );
          });
        }
      }, engine: widget.app.settings.ttsEngineOrDefault);
      final vadOk = await widget.app.speech.verifyVad(
        await widget.app.provisioning.vadPath,
        smartTurnPath: await widget.app.provisioning.smartTurnPath,
      );
      final ttsOk = await widget.app.tryInitSpeech();
      if (!vadOk || !ttsOk) {
        throw StateError(
          'Speech models downloaded but did not initialise on this device.',
        );
      }
      await widget.app.saveSettings(
        widget.app.settings.copyWith(setupComplete: true),
      );
      widget.onDone();
    } catch (e) {
      if (mounted) {
        setState(() {
          _provisioning = false;
          _error = '${tr.setup.modelsFailed} $e';
        });
      }
    }
  }
}

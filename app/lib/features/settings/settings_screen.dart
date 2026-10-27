import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_controller.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../generated/i18n/translations.g.dart';
import '../ai/ai_client.dart';

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
  bool _testing = false;
  String? _message;
  String _logs = '';
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr.settings.title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
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
              border: const OutlineInputBorder(),
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
                icon: const Icon(Icons.wifi_tethering),
                label: Text(
                  _testing ? tr.setup.testing : tr.setup.testConnection,
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
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
            value: widget.app.settings.captionsDefault,
            title: Text(tr.settings.captionsDefault),
            onChanged: (v) async {
              await widget.app.saveSettings(
                widget.app.settings.copyWith(captionsDefault: v),
              );
              setState(() {});
            },
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
            icon: const Icon(Icons.delete_forever_outlined),
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
                icon: const Icon(Icons.copy_outlined),
                onPressed: _logs.isEmpty
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: _logs)),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              _logs.isEmpty ? '—' : _logs,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app_controller.dart';
import '../../core/theme.dart';
import '../../core/data/models.dart';
import '../../generated/i18n/translations.g.dart';
import '../study_session/session_controller.dart';
import '../study_session/session_screen.dart';
import '../settings/settings_screen.dart';

/// Home: session history plus the single New Session action.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(tr.home.title),
          actions: [
            IconButton(
              tooltip: tr.home.settings,
              icon: const Icon(Symbols.settings),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SettingsScreen(app: app)),
                );
              },
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          onPressed: () => _newSession(context),
          icon: const Icon(Symbols.add),
          label: Text(tr.home.newSession),
        ),
        body: app.sessions.isEmpty
            ? Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 900),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Symbols.school, size: 72, color: texaBlue),
                        const SizedBox(height: 20),
                        Text(
                          tr.home.emptyTitle,
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Text(tr.home.emptyBody, textAlign: TextAlign.center),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: () => _newSession(context),
                          icon: const Icon(Symbols.add),
                          label: Text(tr.home.newSession),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 900),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    itemCount: app.sessions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, i) {
                      final s = app.sessions[i];
                      return Card(
                        child: ListTile(
                          leading: s.thumbnailBase64 == null
                              ? const CircleAvatar(child: Icon(Symbols.draw))
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.memory(
                                    base64Decode(s.thumbnailBase64!),
                                    width: 52,
                                    height: 68,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const CircleAvatar(
                                          child: Icon(Symbols.draw),
                                        ),
                                  ),
                                ),
                          title: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Chip(
                                label: Text(
                                  s.model,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                              if (s.reasoningEffort != null)
                                Chip(
                                  label: Text(
                                    tr.home.reasoningChip(
                                      effort: s.reasoningEffort!,
                                    ),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              Text(relativeTime(s.updatedAt)),
                            ],
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'rename') {
                                _rename(context, s);
                              } else if (v == 'delete') {
                                _delete(context, s);
                              }
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text(tr.common.rename),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(tr.common.delete),
                              ),
                            ],
                          ),
                          onTap: () => unawaited(_open(context, s)),
                        ),
                      );
                    },
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _open(BuildContext context, Session s) async {
    final controller = SessionController(
      db: app.db,
      session: s,
      settings: app.settings,
      speech: app.speech,
      vadPath: await app.sileroVadPath(),
    );
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SessionScreen(controller: controller)),
    );
    await app.refreshSessions();
  }

  Future<void> _rename(BuildContext context, Session s) async {
    final ctrl = TextEditingController(text: s.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr.home.renameTitle),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(labelText: tr.home.sessionName),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.common.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.common.save),
          ),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      await app.renameSession(s, ctrl.text.trim());
    }
  }

  Future<void> _delete(BuildContext context, Session s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr.home.deleteSessionTitle),
        content: Text(tr.home.deleteSessionBody),
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
    if (ok == true) await app.deleteSession(s);
  }

  Future<void> _newSession(BuildContext context) async {
    final modelCtrl = TextEditingController();
    // Curated chat models, plus Custom for anything else. The full
    // /models list also contains non-chat models, so it is not offered.
    const customModel = '__custom';
    const modelOptions = [
      'muse-wonder-1.0',
      'muse-spark-1.3',
      'muse-spark-1.3-contributor',
      customModel,
    ];
    var selection = modelOptions.first;
    var reasoning = 'medium';
    final created = await showDialog<Session>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr.home.chooseModel),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr.home.chooseModelBody),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: selection,
                  decoration: InputDecoration(
                    labelText: tr.home.modelNameLabel,
                  ),
                  items: modelOptions
                      .map(
                        (m) => DropdownMenuItem(
                          value: m,
                          child: Text(
                            m == customModel ? tr.home.customModel : m,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) =>
                      setState(() => selection = v ?? modelOptions.first),
                ),
                if (selection == customModel) ...[
                  const SizedBox(height: 14),
                  TextField(
                    controller: modelCtrl,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: tr.home.modelNameLabel,
                      hintText: 'e.g. meta-ai-model',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: reasoning,
                  decoration: InputDecoration(
                    labelText: tr.home.reasoningLabel,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'none',
                      child: Text(tr.home.reasoningNone),
                    ),
                    DropdownMenuItem(
                      value: 'minimal',
                      child: Text(tr.home.reasoningMinimal),
                    ),
                    DropdownMenuItem(
                      value: 'low',
                      child: Text(tr.home.reasoningLow),
                    ),
                    DropdownMenuItem(
                      value: 'medium',
                      child: Text(tr.home.reasoningMedium),
                    ),
                    DropdownMenuItem(
                      value: 'high',
                      child: Text(tr.home.reasoningHigh),
                    ),
                    DropdownMenuItem(
                      value: 'xhigh',
                      child: Text(tr.home.reasoningXHigh),
                    ),
                  ],
                  onChanged: (v) => setState(() => reasoning = v ?? 'none'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.common.cancel),
            ),
            FilledButton(
              onPressed:
                  selection == customModel && modelCtrl.text.trim().isEmpty
                  ? null
                  : () async {
                      final s = await app.createSession(
                        selection == customModel
                            ? modelCtrl.text.trim()
                            : selection,
                        reasoningEffort: reasoning == 'none' ? null : reasoning,
                      );
                      if (context.mounted) Navigator.pop(context, s);
                    },
              child: Text(tr.home.createSession),
            ),
          ],
        ),
      ),
    );
    if (created != null && context.mounted) {
      unawaited(_open(context, created));
    }
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../generated/i18n/translations.g.dart';
import '../ai/ai_client.dart';
import '../session/session_controller.dart';
import '../session/session_screen.dart';
import '../settings/settings_screen.dart';

/// Home: session history plus the single New Session action.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(tr.home.title),
          actions: [
            IconButton(
              tooltip: tr.home.settings,
              icon: const Icon(Icons.settings_outlined),
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
          onPressed: () => _newSession(context),
          icon: const Icon(Icons.add),
          label: Text(tr.home.newSession),
        ),
        body: app.sessions.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.school_outlined,
                        size: 72,
                        color: texaBlue,
                      ),
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
                        icon: const Icon(Icons.add),
                        label: Text(tr.home.newSession),
                      ),
                    ],
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: app.sessions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final s = app.sessions[i];
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(14),
                      leading: s.thumbnailBase64 == null
                          ? const CircleAvatar(child: Icon(Icons.draw_outlined))
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.memory(
                                base64Decode(s.thumbnailBase64!),
                                width: 52,
                                height: 68,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const CircleAvatar(
                                  child: Icon(Icons.draw_outlined),
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
                          if (s.subject != null)
                            Chip(
                              label: Text(
                                s.subject!,
                                style: const TextStyle(fontSize: 11),
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          Chip(
                            label: Text(
                              s.model,
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
    List<String> models = [];
    String? selected;
    String? loadError;
    bool loading = false;
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
                if (models.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: selected,
                    decoration: InputDecoration(
                      labelText: tr.home.modelNameLabel,
                    ),
                    items: models
                        .map(
                          (m) => DropdownMenuItem(
                            value: m,
                            child: Text(m, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() {
                      selected = v;
                      modelCtrl.text = v ?? '';
                    }),
                  ),
                TextField(
                  controller: modelCtrl,
                  decoration: InputDecoration(
                    labelText: tr.home.modelNameLabel,
                    hintText: 'e.g. meta-ai-model',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (loadError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      loadError!,
                      style: const TextStyle(color: texaRed),
                    ),
                  ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: loading
                      ? null
                      : () async {
                          setState(() {
                            loading = true;
                            loadError = null;
                          });
                          try {
                            models = await AiClient(app.settings.apiKey)
                                .listModels();
                            selected = models.isEmpty ? null : models.first;
                            modelCtrl.text = selected ?? '';
                          } on AppError catch (e) {
                            loadError = e.message;
                          } catch (e) {
                            loadError = e.toString();
                          }
                          setState(() => loading = false);
                        },
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: Text(loading ? tr.setup.testing : tr.home.loadModels),
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
              onPressed: modelCtrl.text.trim().isEmpty
                  ? null
                  : () async {
                      final s = await app.createSession(modelCtrl.text.trim());
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

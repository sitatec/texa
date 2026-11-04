import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:texa/core/utils/context_utils.dart';
import 'package:texa/core/widgets/texa_app_bar.dart';

import '../../app_controller.dart';
import '../../core/theme.dart';
import '../../core/data/models.dart';
import '../../generated/i18n/translations.g.dart';
import '../study_session/session_controller.dart';
import '../study_session/session_screen.dart';
import '../study_session/board/board_widget.dart';
import '../settings/settings_screen.dart';

/// Home: session history plus the single New Session action.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});
  final AppController app;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppController get app => widget.app;

  /// Whether this Home instance has already claimed its chance to
  /// present the one-time welcome dialog. The persisted
  /// [AppSettings.homeWelcomeSeen] flag is the real guard across app
  /// runs; this only stops a rebuild of the same Home instance from
  /// queuing a second attempt.
  bool _welcomeHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_maybeShowWelcome()),
    );
  }

  /// Presents the welcome dialog the first time Home renders, and
  /// never again. The seen flag is persisted *before* the dialog
  /// opens, so it cannot reappear - not on a Home rebuild, and not
  /// even if the app is closed while the dialog is on screen.
  Future<void> _maybeShowWelcome() async {
    if (_welcomeHandled || app.settings.homeWelcomeSeen) return;
    _welcomeHandled = true;
    await app.markHomeWelcomeSeen();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      // The only way out is the dialog's own call to action, which
      // stays disabled for a few seconds so the message is read.
      barrierDismissible: false,
      builder: (_) => const _WelcomeDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSmallScreen = context.isSmallScreen;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        appBar: TexaAppBar(
          automaticallyImplyLeading: false,
          maxWidth: 880,
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
                      final boardPreview = app.boardPreviews[s.id];
                      return Card(
                        child: ListTile(
                          dense: isSmallScreen,
                          visualDensity: isSmallScreen ? .compact : null,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: isSmallScreen ? 4 : 16,
                          ),
                          horizontalTitleGap: isSmallScreen ? 4 : 16,
                          // The preview is rendered live from the
                          // board snapshot saved when the session was
                          // closed, so it shows the board exactly as
                          // it was left. Sessions saved before board
                          // snapshots existed fall back to their
                          // raster thumbnail, then to the placeholder.
                          leading: boardPreview != null
                              ? boardPreview.elements.isEmpty
                                    ? const CircleAvatar(
                                        child: Icon(Symbols.draw),
                                      )
                                    : Card(
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        clipBehavior: .antiAlias,
                                        margin: .zero,
                                        child: SizedBox(
                                          width: 68,
                                          height: 52,
                                          child: BoardPreview(
                                            snapshot: boardPreview,
                                          ),
                                        ),
                                      )
                              : s.thumbnailBase64 == null
                              ? const CircleAvatar(child: Icon(Symbols.draw))
                              : Card(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  clipBehavior: .antiAlias,
                                  margin: .zero,
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
                          subtitle: Padding(
                            padding: EdgeInsets.only(
                              top: isSmallScreen ? 2 : 4,
                            ),
                            child: Wrap(
                              spacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _Chip(s.model),
                                if (s.reasoningEffort != null)
                                  _Chip(
                                    tr.home.reasoningChip(
                                      effort: s.reasoningEffort!,
                                    ),
                                  ),
                                Text(relativeTime(s.updatedAt)),
                              ],
                            ),
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
      smartTurnPath: await app.smartTurnPath(),
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
    final created = await showDialog<Session>(
      context: context,
      builder: (_) => _NewSessionDialog(app: app),
    );
    if (created != null && context.mounted) {
      unawaited(_open(context, created));
    }
  }
}

/// The New Session dialog. Its text controllers are owned by this
/// widget's state and disposed from [State.dispose] - i.e. only once
/// the dialog has actually left the tree. Disposing them when the
/// dialog's route future completes is too early: the dialog is still
/// animating out then, and a rebuild of its fields (triggered by the
/// session route being pushed on top) hits the disposed controllers.
class _NewSessionDialog extends StatefulWidget {
  const _NewSessionDialog({required this.app});
  final AppController app;

  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  // Curated chat models, plus Custom for anything else. The full
  // /models list also contains non-chat models, so it is not offered.
  static const _customModel = '__custom';
  static const _modelOptions = [
    'muse-wonder-1.0',
    'muse-spark-1.3',
    'muse-spark-1.3-contributor',
    _customModel,
  ];

  final _modelCtrl = TextEditingController();
  final _titleCtrl = TextEditingController(
    text: defaultSessionTitle(DateTime.now()),
  );
  String _selection = _modelOptions.first;
  String _reasoning = 'low';

  @override
  void dispose() {
    _modelCtrl.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr.home.chooseModel),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr.home.chooseModelBody),
            const SizedBox(height: 14),
            TextField(
              controller: _titleCtrl,
              decoration: InputDecoration(
                labelText: tr.home.sessionName,
                border: OutlineInputBorder(borderRadius: .circular(8)),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _selection,
              decoration: InputDecoration(labelText: tr.home.modelNameLabel),
              items: _modelOptions
                  .map(
                    (m) => DropdownMenuItem(
                      value: m,
                      child: Text(
                        m == _customModel ? tr.home.customModel : m,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) =>
                  setState(() => _selection = v ?? _modelOptions.first),
            ),
            if (_selection == _customModel) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _modelCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr.home.modelNameLabel,
                  hintText: 'e.g. meta-ai-model',
                  border: OutlineInputBorder(borderRadius: .circular(8)),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _reasoning,
              decoration: InputDecoration(labelText: tr.home.reasoningLabel),
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
              onChanged: (v) => setState(() => _reasoning = v ?? 'none'),
            ),
            const SizedBox(height: 4),
            Text(
              tr.home.reasoningDescription,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
              ),
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
              _titleCtrl.text.trim().isEmpty ||
                  (_selection == _customModel && _modelCtrl.text.trim().isEmpty)
              ? null
              : () async {
                  final navigator = Navigator.of(context);
                  final s = await widget.app.createSession(
                    _selection == _customModel
                        ? _modelCtrl.text.trim()
                        : _selection,
                    title: _titleCtrl.text.trim(),
                    reasoningEffort: _reasoning == 'none' ? null : _reasoning,
                  );
                  if (mounted) navigator.pop(s);
                },
          child: Text(tr.home.createSession),
        ),
      ],
    );
  }
}

/// The one-time welcome dialog: what Texa is (a guiding tutor, not
/// an answer machine) and what it needs (a quiet room).
class _WelcomeDialog extends StatefulWidget {
  const _WelcomeDialog();

  @override
  State<_WelcomeDialog> createState() => _WelcomeDialogState();
}

class _WelcomeDialogState extends State<_WelcomeDialog> {
  /// Seconds the student must spend with the dialog before its
  /// single call to action becomes clickable, counted down visibly
  /// on the button itself.
  static const int _countdownSeconds = 5;
  int _secondsLeft = _countdownSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 520),
      title: Text(tr.home.welcomeTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _WelcomeSection(
              icon: Symbols.lightbulb,
              title: tr.home.welcomeGuideTitle,
              body: tr.home.welcomeGuideBody,
            ),
            const SizedBox(height: 20),
            _WelcomeSection(
              icon: Symbols.volume_off,
              title: tr.home.welcomeQuietTitle,
              body: tr.home.welcomeQuietBody,
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _secondsLeft > 0 ? null : () => Navigator.pop(context),
          child: Text(
            _secondsLeft > 0
                ? '${tr.common.gotIt} ($_secondsLeft)'
                : tr.common.gotIt,
          ),
        ),
      ],
    );
  }
}

class _WelcomeSection extends StatelessWidget {
  const _WelcomeSection({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: theme.colorScheme.primary, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  const _Chip(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: .symmetric(vertical: 2, horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(
          width: 0.6,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
        borderRadius: .circular(7),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11)),
    );
  }
}

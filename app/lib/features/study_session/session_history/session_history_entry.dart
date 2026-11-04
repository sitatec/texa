import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../core/data/models.dart';
import '../../../core/theme.dart';
import '../../../generated/i18n/translations.g.dart';
import '../board/board_models.dart';
import '../board/board_widget.dart';
import '../ai/ai_client.dart';
import '../board/plot_preview.dart';
import '../file_attachment/input_file_widget.dart';
import 'turn_video_player.dart';

/// Present-tense status label for a tool while it is being performed
/// ("Writing math expression…"), or null for tools with no specific
/// status wording (the generic Working… is used instead).
String? actionStatusLabel(String tool) => switch (tool) {
  'write_text' => tr.session.writingText,
  'write_math' => tr.session.writingMath,
  'plot_function' => tr.session.plottingFunction,
  'draw_svg' => tr.session.drawingDiagram,
  'mark_landmarks' => tr.session.markingLandmarks,
  'edit_element' => tr.session.editingElement,
  'remove_element' => tr.session.removingElement,
  'point_at' => tr.session.pointing,
  'focus_viewport' => tr.session.movingView,
  'update_session_observation' || 'update_memory' => tr.session.takingNotes,
  'search_session_observations' => tr.session.searchingSessions,
  _ => null,
};

/// Past-tense history label for a performed tool call ("Wrote text").
String actionHistoryLabel(String tool) => switch (tool) {
  'write_text' => tr.session.wroteText,
  'write_math' => tr.session.wroteMath,
  'plot_function' => tr.session.plottedFunction,
  'draw_svg' => tr.session.drewDiagram,
  'mark_landmarks' => tr.session.markedLandmarks,
  'edit_element' => tr.session.editedElement,
  'remove_element' => tr.session.removedElement,
  'point_at' => tr.session.pointedAt,
  'focus_viewport' => tr.session.movedView,
  _ => tool,
};

/// Tools that happen off-board (quiet notebooks, searches, resuming):
/// performed, but not board actions to itemise in the history.
const _internalTools = {
  'update_session_observation',
  'update_memory',
  'search_session_observations',
  'resume_explanation',
};

/// One conversation entry in the session history sheet: the student
/// turn's video for student messages, and for AI messages the spoken
/// text plus every board action, rendered - text as text, math as
/// typeset math, diagrams as SVG, and plots as a re-rendered curve that
/// can be tapped to enlarge.
class SessionHistoryEntry extends StatelessWidget {
  const SessionHistoryEntry({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final isAi = m.role == 'ai';
    final text = m.payload['text'] as String? ?? '';
    final video = isAi ? null : m.payload['videoBase64'] as String?;
    final uploads = isAi ? const <AiUpload>[] : AiClient.uploadsOf(m);
    final calls = m.payload['toolCalls'];
    // Ordered turn pieces (text before/between/after tool calls),
    // when persisted: text that follows a call refers to what that
    // call put on the board, so pieces must render in turn order -
    // never as one merged text block followed by every action.
    final rawItems = m.payload['items'];
    final orderedItems = isAi && rawItems is List && rawItems.isNotEmpty
        ? rawItems
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList()
        : null;
    return ListTile(
      leading: Icon(isAi ? Symbols.auto_awesome : Symbols.person_outline),
      titleAlignment: .top,
      title: Text(isAi ? 'Texa' : 'You'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (orderedItems != null)
            for (final item in orderedItems) ...[
              if (item['kind'] == 'text' &&
                  (item['text'] as String? ?? '').trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text((item['text'] as String).trim()),
                ),
              if (item['kind'] == 'toolCall' &&
                  !_internalTools.contains(item['name']))
                _ActionEntry(call: item),
            ]
          else ...[
            if (text.isNotEmpty) Text(text),
            if (calls is List)
              for (final call in calls)
                if (call is Map && !_internalTools.contains(call['name']))
                  _ActionEntry(call: call.cast<String, dynamic>()),
          ],
          if (uploads.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final upload in uploads)
                  TexaUploadedFilePreview(upload: upload),
              ],
            ),
          ],
          if (video != null && video.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 250,
              child: TurnVideoPlayer(
                key: ValueKey('history-video-${m.id}'),
                base64Video: video,
                messageId: m.id,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One performed action: its label plus what it actually put on the
/// board, re-rendered from the saved arguments.
class _ActionEntry extends StatelessWidget {
  const _ActionEntry({required this.call});

  final Map<String, dynamic> call;

  String get _tool => call['name'] as String? ?? '';
  Map<String, dynamic> get _args =>
      (call['args'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool get _failed => call['status'] == 'error';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _failed ? Symbols.error_outline : Symbols.check_circle,
                size: 15,
                color: _failed ? texaRed : texaGreen,
              ),
              const SizedBox(width: 5),
              Text(
                actionHistoryLabel(_tool),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              if (_args['element_id'] is String) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _args['element_id'] as String,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
              ],
            ],
          ),
          // What Texa said while performing this action, shown above
          // the element it produced - in the session it was heard
          // alongside the drawing, so in history it belongs with (and
          // before) that element, not merged into the turn's text.
          if ((_args['explanation_speech'] as String? ?? '')
              .trim()
              .isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Symbols.text_to_speech,
                  size: 14,
                  color: Colors.black45,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    (_args['explanation_speech'] as String).trim(),
                    style: const TextStyle(
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                      color: Colors.black54,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          _content(context),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    switch (_tool) {
      case 'write_text':
        final text = _args['text'] as String? ?? '';
        return Text(text, style: const TextStyle(fontSize: 15));
      case 'write_math':
        final latex = _args['latex'] as String? ?? '';
        return Math.tex(
          latex,
          mathStyle: MathStyle.display,
          textStyle: const TextStyle(fontSize: 18),
          onErrorFallback: (_) =>
              Text(latex, style: const TextStyle(color: texaRed, fontSize: 14)),
        );
      case 'plot_function':
        final element = plotElementFromArgs(_args);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (element.plotSeries.isNotEmpty)
              Text(
                _plotCaption(element),
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
            const SizedBox(height: 4),
            InkWell(
              onTap: () => _enlargePlot(context, element),
              child: Container(
                height: 200,
                width: 400,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: PlotView(element: element),
              ),
            ),
          ],
        );
      case 'draw_svg':
        final svg = _args['svg'] as String? ?? '';
        if (svg.isEmpty) return const SizedBox.shrink();
        return Container(
          height: 160,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.black12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SvgStringWidget(svg: svg),
        );
      case 'mark_landmarks':
        final names = (_args['landmarks'] as List?)?.join(', ') ?? '';
        return Text(names, style: const TextStyle(fontSize: 13));
      default:
        return const SizedBox.shrink();
    }
  }

  /// Human caption for a plot's functions, e.g. `f(x) = x^2` for a
  /// single unlabelled curve, or `f(x) = x^2  ·  g(x) = 2*x+1` when
  /// several labelled curves share the plot.
  String _plotCaption(BoardElement element) => element.plotSeries
      .map(
        (s) => (s.label != null && s.label!.trim().isNotEmpty)
            ? '${s.label!.trim()}(x) = ${s.expression}'
            : element.plotSeries.length == 1
            ? 'f(x) = ${s.expression}'
            : s.expression,
      )
      .join('  ·  ');

  void _enlargePlot(BuildContext context, BoardElement element) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      element.plotSeries.isNotEmpty
                          ? _plotCaption(element)
                          : tr.session.plottedFunction,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Symbols.close),
                    onPressed: () => Navigator.pop(dialogContext),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 360,
                width: 560,
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Container(
                    color: Colors.white,
                    child: PlotView(element: element),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/core/data/models.dart';
import 'package:texa/features/study_session/board/plot_preview.dart';
import 'package:texa/features/study_session/session_history/session_history_entry.dart';
import 'package:texa/generated/i18n/translations.g.dart';

ChatMessage _aiMessage(Map<String, dynamic> payload) => ChatMessage(
  id: 'm1',
  sessionId: 's1',
  role: 'ai',
  kind: 'actions',
  payloadJson: jsonEncode(payload),
  createdAt: DateTime(2026),
);

void main() {
  testWidgets('shows labelled actions with their rendered content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SessionHistoryEntry(
              message: _aiMessage({
                'text': 'Let me show you.',
                'toolCalls': [
                  {
                    'id': 'call_1',
                    'name': 'write_text',
                    'args': {'element_id': 'title', 'text': 'Quadratic'},
                    'status': 'success',
                  },
                  {
                    'id': 'call_2',
                    'name': 'write_math',
                    'args': {'element_id': 'eq', 'latex': 'x^2+2x+1'},
                    'status': 'success',
                  },
                  {
                    'id': 'call_3',
                    'name': 'plot_function',
                    'args': {
                      'element_id': 'curve',
                      'expression': 'x^2',
                      'x_min': -5,
                      'x_max': 5,
                    },
                    'status': 'success',
                  },
                  {
                    'id': 'call_4',
                    'name': 'update_memory',
                    'args': {'edits': []},
                    'status': 'success',
                  },
                ],
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Wrote text'), findsOneWidget);
    expect(find.text('Quadratic'), findsOneWidget);
    expect(find.text('Wrote math expression'), findsOneWidget);
    expect(find.text('Plotted function'), findsOneWidget);
    expect(find.text('f(x) = x^2'), findsOneWidget);
    // Quiet internal tools are not itemised as board actions.
    expect(find.text('update_memory'), findsNothing);

    // The plot enlarges on tap.
    await tester.tap(find.byType(PlotView).first);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('f(x) = x^2'), findsNWidgets(2));
  });
}

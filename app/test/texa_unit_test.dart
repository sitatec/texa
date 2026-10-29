import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/ai/ai_actions.dart';
import 'package:texa/features/study_session/board/board_models.dart';
import 'package:flutter/material.dart';
import 'package:texa/features/study_session/board/plotter.dart';
import 'package:texa/features/study_session/playback/playback_engine.dart';
import 'package:texa/features/study_session/playback/speech_chunker.dart';
import 'package:texa/features/study_session/playback/wav_builder.dart';
import 'package:texa/core/data/db.dart';
import 'package:texa/core/data/models.dart';
import 'package:texa/features/study_session/ai/utils/file_edit.dart';

void main() {
  test('streaming splitter emits only at sentence endpoints', () {
    final s = StreamingSpeechSplitter();
    expect(s.add('Hello there'), isEmpty);
    expect(s.add('. How are'), ['Hello there.']);
    expect(s.add(' you? Yes'), ['How are you?']);
    expect(s.flush(), ['Yes']);
  });
  test('splitSpeech handles terminators and no terminator', () {
    expect(splitSpeech('One. Two! Three?'), ['One.', 'Two!', 'Three?']);
    expect(splitSpeech('Just one thought'), ['Just one thought']);
    expect(splitSpeech('  '), isEmpty);
  });
  test('wav builder writes a RIFF header', () {
    final wav = buildWav(Float32List.fromList([0, 0.5, -0.5]), 16000);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(wav.length, 44 + 6);
  });
  test('sentinel parsing', () {
    expect(parseReply('<[IGNORE_TURN]>', []).kind, 'ignore');
    expect(parseReply('Hello <[IGNORE_TURN]>', []).kind, 'invalidSentinel');
    expect(parseReply('Hello.', []).kind, 'normal');
  });
  test('plotter samples a parabola and breaks nothing', () {
    final r = samplePlot('x^2', -2, 2, null, null);
    expect(r.points.length, greaterThan(100));
    expect(r.yMax, greaterThan(3));
  });
  test('playback queue suspend keeps remaining plus interrupted chunk', () {
    final q = PlaybackQueue()..addAll([TextItem('One.'), TextItem('Two.')]);
    q.next();
    final s = q.suspend('One.');
    expect(s.remaining.length, 2);
    expect(s.toContext()['suspendedStepsRemaining'], 2);
  });
  test('board snapshot round-trips the AI registry', () {
    final el = BoardElement(
      id: 'eq_main',
      kind: BoardElementKind.math,
      owner: BoardOwner.ai,
      x: 10,
      y: 20,
      width: 200,
      height: 60,
      latex: r'x^2',
    );
    final snap = BoardSnapshot(
      elements: [el],
      viewport: const [1, 0, 0],
      registry: {
        'eq_main': const AiElementInfo(
          id: 'eq_main',
          kind: 'math',
          rect: Rect.fromLTWH(10, 20, 200, 60),
        ),
      },
    );
    final back = BoardSnapshot.decode(snap.encode());
    expect(back.registry.keys, contains('eq_main'));
    expect(back.elements.single.latex, r'x^2');
  });

  test('notebook edits seed a blank notebook and apply later edits', () {
    final seeded = applyNotebookEdits('', [
      Edit(oldText: '', newText: 'Struggles with fractions.'),
    ]);
    expect(seeded, 'Struggles with fractions.');
    final updated = applyNotebookEdits(seeded, [
      Edit(oldText: 'fractions', newText: 'fraction addition'),
    ]);
    expect(updated, 'Struggles with fraction addition.');
  });
  test('observation is clamped to two paragraphs', () {
    expect(clampToTwoParagraphs('One.\n\nTwo.\n\nThree.'), 'One.\n\nTwo.');
    expect(clampToTwoParagraphs('Only one.'), 'Only one.');
  });
  test('observation search filters by content, date and both', () {
    final all = [
      SessionObservation(
        sessionId: 'a',
        date: DateTime(2026, 1, 5),
        content: 'Confident with Fractions now',
      ),
      SessionObservation(
        sessionId: 'b',
        date: DateTime(2026, 2, 10),
        content: 'Quiet when unsure',
      ),
      SessionObservation(
        sessionId: 'c',
        date: DateTime(2026, 3, 15),
        content: 'fractions clicked after drawing',
      ),
    ];
    final db = AppDb.memory();
    expect(db.searchObservations(all, query: 'FRACTIONS').length, 2);
    expect(db.searchObservations(all, from: DateTime(2026, 2, 1)).length, 2);
    expect(
      db
          .searchObservations(
            all,
            query: 'fractions',
            from: DateTime(2026, 2, 1),
            to: DateTime(2026, 12, 31),
          )
          .single
          .sessionId,
      'c',
    );
    expect(db.searchObservations(all, query: 'nothing').isEmpty, isTrue);
  });

  test(
    'table-backed store round-trips sessions, messages, observations',
    () async {
      final db = AppDb.memory();
      final session = Session(
        id: 's1',
        title: 'Fractions',
        model: 'm1',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
      );
      await db.saveSessions([session]);
      expect((await db.loadSessions()).single.title, 'Fractions');
      await db.saveBoard('s1', '{"elements":[]}');
      expect(await db.loadBoard('s1'), '{"elements":[]}');
      await db.saveMessages('s1', [
        ChatMessage(
          id: 'msg1',
          sessionId: 's1',
          role: 'ai',
          kind: 'text',
          payloadJson: '{"text":"hi"}',
          createdAt: DateTime(2026, 1, 2),
        ),
      ]);
      expect((await db.loadMessages('s1')).single.payload['text'], 'hi');
      await db.saveObservation('s1', 'Getting confident.');
      expect(
        (await db.loadObservations()).single.content,
        'Getting confident.',
      );
      await db.saveSettings(
        const AppSettings(apiKey: 'secret', captionsDefault: false),
      );
      final settings = await db.loadSettings();
      expect(settings.apiKey, 'secret');
      expect(settings.captionsDefault, isFalse);
      await db.deleteSession('s1');
      expect(await db.loadSessions(), isEmpty);
      expect(await db.loadBoard('s1'), isNull);
    },
  );
}

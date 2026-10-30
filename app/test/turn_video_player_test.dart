import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/session_history/turn_video_player.dart';

void main() {
  testWidgets('undecodable turn video degrades to a placeholder icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TurnVideoPlayer(
            base64Video: '!!!not-base64!!!',
            messageId: 'm1',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
  });
}

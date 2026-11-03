import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/ai/ai_client.dart';
import 'package:texa/features/study_session/file_attachment/input_file_widget.dart';
import 'package:texa/generated/i18n/translations.g.dart';

void main() {
  testWidgets('upload modal shows uploaded files below the selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: Scaffold(
            body: TexaInputFileWidget(
              uploadedFiles: [
                AiUpload(
                  name: 'diagram.png',
                  mimeType: 'image/png',
                  base64: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
                ),
                AiUpload(
                  name: 'worksheet.pdf',
                  mimeType: 'application/pdf',
                  base64: 'PDF',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Add files'));
    await tester.pumpAndSettle();

    expect(find.text('Selected files'), findsOneWidget);
    expect(
      find.text('No files selected yet. Choose an option above to add some.'),
      findsOneWidget,
    );
    expect(find.text('Uploaded Files'), findsOneWidget);
    expect(find.text('diagram.png'), findsOneWidget);
    expect(find.text('worksheet.pdf'), findsOneWidget);
    // Uploaded files are read-only history: only selected files get a
    // remove button, and there are none selected here.
    expect(find.byTooltip('Remove file'), findsNothing);
  });
}

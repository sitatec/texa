import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:texa/features/study_session/turn_video_encoder/pcm_second_buffer.dart';

void main() {
  test('hands out exact seconds assembled from small chunks, in order', () {
    final buffer = PcmSecondBuffer(secondBytes: 8);
    buffer.add(Uint8List.fromList([1, 2, 3]));
    expect(buffer.hasFullSecond, isFalse);
    buffer.add(Uint8List.fromList([4, 5, 6, 7, 8, 9]));
    expect(buffer.hasFullSecond, isTrue);
    expect(buffer.takeSecond(), [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(buffer.bufferedBytes, 1);
    expect(buffer.totalReceived, 9);
  });

  test('splits a chunk that straddles a second boundary', () {
    final buffer = PcmSecondBuffer(secondBytes: 4);
    buffer.add(Uint8List.fromList([1, 2, 3, 4, 5, 6]));
    expect(buffer.takeSecond(), [1, 2, 3, 4]);
    expect(buffer.takeSecond(), [5, 6, 0, 0]);
  });

  test('silence-pads the final partial second', () {
    final buffer = PcmSecondBuffer(secondBytes: 6);
    buffer.add(Uint8List.fromList([9, 9]));
    expect(buffer.takeSecond(), [9, 9, 0, 0, 0, 0]);
    expect(buffer.bufferedBytes, 0);
  });

  test('clear resets counters for the next turn', () {
    final buffer = PcmSecondBuffer(secondBytes: 4);
    buffer.add(Uint8List.fromList([1, 2, 3]));
    buffer.clear();
    expect(buffer.totalReceived, 0);
    expect(buffer.hasFullSecond, isFalse);
  });
}

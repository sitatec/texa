import 'dart:convert';

import '../../../core/constants.dart';

/// One ordered playback item parsed from an AI reply.
sealed class PlaybackItem {
  String? get speech;
}

class TextItem extends PlaybackItem {
  TextItem(this.text);
  final String text;
  @override
  String? get speech => text;
}

class ActionItem extends PlaybackItem {
  ActionItem(this.tool, this.args);
  final String tool;
  final Map<String, dynamic> args;
  @override
  String? get speech => args['accompanying_speech'] as String?;
  String? get elementId => args['element_id'] as String?;
}

class ResumeItem extends PlaybackItem {
  @override
  String? get speech => null;
}

/// Result of parsing a raw AI reply before any playback.
class ParsedReply {
  const ParsedReply({
    required this.kind,
    this.items = const [],
    this.text = '',
  });
  final String kind;
  final List<PlaybackItem> items;
  final String text;
}

ParsedReply parseReply(
  String? content,
  List<({String name, Map<String, dynamic> args})> toolCalls,
) {
  final text = (content ?? '').trim();
  if (toolCalls.isEmpty && text == ignoreTurnSentinel) {
    return const ParsedReply(kind: 'ignore');
  }
  if (text.contains(ignoreTurnSentinel)) {
    return const ParsedReply(kind: 'invalidSentinel');
  }
  final items = <PlaybackItem>[];
  if (text.isNotEmpty) items.add(TextItem(text));
  for (final call in toolCalls) {
    if (call.name == 'resume_explanation') {
      items.add(ResumeItem());
    } else {
      items.add(ActionItem(call.name, call.args));
    }
  }
  return ParsedReply(kind: 'normal', items: items, text: text);
}

Map<String, dynamic> decodeArgs(String raw) {
  try {
    final v = jsonDecode(raw);
    return v is Map<String, dynamic> ? v : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

/// Responses API tool schemas (flat `type`/`name`/`description`/
/// `parameters` shape), sent with every request (single source).
List<Map<String, dynamic>> toolSchemas() {
  Map<String, dynamic> props(List<String> req, Map<String, dynamic> p) => {
    'type': 'object',
    'properties': p,
    'required': req,
    'additionalProperties': false,
  };
  final speech = {
    'type': 'string',
    'description': 'Spoken aloud while this step draws.',
  };
  final id = {
    'type': 'string',
    'description': 'Short unique snake_case id for this element.',
  };
  final num = {'type': 'number'};
  final str = {'type': 'string'};
  Map<String, dynamic> tool(
    String name,
    String desc,
    Map<String, dynamic> params,
  ) => {
    'type': 'function',
    'name': name,
    'description': desc,
    'parameters': params,
  };
  return [
    tool(
      'write_text',
      'Write short plain text on the board.',
      props(
        ['element_id', 'x', 'y', 'text'],
        {
          'element_id': id,
          'x': num,
          'y': num,
          'text': str,
          'size': num,
          'color': str,
          'accompanying_speech': speech,
        },
      ),
    ),
    tool(
      'write_math',
      'Write LaTeX maths on the board.',
      props(
        ['element_id', 'x', 'y', 'latex'],
        {
          'element_id': id,
          'x': num,
          'y': num,
          'latex': str,
          'size': num,
          'color': str,
          'accompanying_speech': speech,
        },
      ),
    ),
    tool(
      'draw_svg',
      'Draw an SVG diagram inside a board rect.',
      props(
        ['element_id', 'x', 'y', 'width', 'height', 'svg'],
        {
          'element_id': id,
          'x': num,
          'y': num,
          'width': num,
          'height': num,
          'svg': str,
          'accompanying_speech': speech,
        },
      ),
    ),
    tool(
      'plot_function',
      'Plot an analytic function of x on-device.',
      props(
        [
          'element_id',
          'x',
          'y',
          'width',
          'height',
          'expression',
          'x_min',
          'x_max',
        ],
        {
          'element_id': id,
          'x': num,
          'y': num,
          'width': num,
          'height': num,
          'expression': str,
          'x_min': num,
          'x_max': num,
          'y_min': num,
          'y_max': num,
          'color': str,
          'accompanying_speech': speech,
        },
      ),
    ),
    tool(
      'mark_landmarks',
      'Mark exact landmark points on one of your existing elements. You supply only the element_id and landmark NAMES; the app computes the coordinates from the element itself and draws labelled markers. Never compute landmark coordinates yourself. Supported names: for plot_function: vertex (alias turning_point), root/roots, y_intercept, maximum, minimum; for SVG shapes: vertex/vertices, centroid, circumcenter, incenter, orthocenter, midpoint/midpoints; for any element: center, top_left, top_right, bottom_left, bottom_right.',
      props(
        ['element_id', 'landmarks'],
        {
          'element_id': id,
          'landmarks': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Landmark names to compute and mark, e.g. ["vertex"], ["circumcenter", "centroid"], ["roots", "y_intercept"].',
          },
          'color': str,
          'accompanying_speech': speech,
        },
      ),
    ),
    tool(
      'edit_element',
      'Move, resize or replace one of your own elements by element_id.',
      props(
        ['element_id'],
        {
          'element_id': id,
          'x': num,
          'y': num,
          'width': num,
          'height': num,
          'text': str,
          'latex': str,
          'svg': str,
          'expression': str,
          'accompanying_speech': speech,
        },
      ),
    ),
    tool(
      'remove_element',
      'Remove one of your own elements by element_id.',
      props(['element_id'], {'element_id': id, 'accompanying_speech': speech}),
    ),
    tool(
      'point_at',
      'Point at a board point or one of your elements. Transient.',
      props([], {
        'x': num,
        'y': num,
        'element_id': id,
        'label': str,
        'accompanying_speech': speech,
      }),
    ),
    tool(
      'focus_viewport',
      'Move the camera to a board rect or one of your elements, drawing nothing.',
      props([], {
        'x': num,
        'y': num,
        'width': num,
        'height': num,
        'zoom': num,
        'element_id': id,
        'accompanying_speech': speech,
      }),
    ),
    tool(
      'resume_explanation',
      'Resume a suspended explanation after answering an interruption.',
      props([], {}),
    ),
  ];
}

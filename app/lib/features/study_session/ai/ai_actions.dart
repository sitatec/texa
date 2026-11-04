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
  String? get speech => args['explanation_speech'] as String?;
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
  // <[TURN_DONE]> is the model closing the turn after tool results:
  // when it is all that remains of the text the reply is 'turnDone'
  // (its tool calls still count - they were performed). Stray
  // occurrences next to real speech are stripped and the speech is
  // kept, so the sentinel is never spoken or displayed.
  if (text.contains(turnDoneSentinel)) {
    final spoken = text.replaceAll(turnDoneSentinel, '').trim();
    if (spoken.isEmpty) return const ParsedReply(kind: 'turnDone');
    final items = <PlaybackItem>[
      TextItem(spoken),
      for (final call in toolCalls)
        if (call.name == 'resume_explanation')
          ResumeItem()
        else
          ActionItem(call.name, call.args),
    ];
    return ParsedReply(kind: 'normal', items: items, text: spoken);
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
    {"type": "web_search", "search_context_size": "low"},
    tool(
      'write_text',
      'Write SHORT plain text on the board: a label, a heading, or a few short lines. Never write sentences or paragraphs on the board - say those in explanation_speech instead. If the content needs more than one line, put line breaks directly in the text of a SINGLE write_text call ("line1\\nline2\\nline3") - never make separate write_text calls just to stack lines; that wastes calls and adds latency. The app measures the text (line breaks included) and wraps it at the board edge, so you do not need to supply width or height.',
      props(
        ['element_id', 'x', 'y', 'text'],
        {
          'element_id': id,
          'x': num,
          'y': num,
          'text': {
            'type': 'string',
            'description': 'The text itself. Keep it brief - a few words, or a few short lines separated by \\n inside this one string.',
          },
          'size': num,
          'color': str,
          'explanation_speech': speech,
        },
      ),
    ),
    tool(
      'write_math',
      'Write one LaTeX maths expression or one short step on the board. Formulas cannot wrap, so keep each call to a single short line and use a separate call for the next step. If a formula is too wide for its board area the app shrinks its font to fit rather than enlarging the element, so splitting long workings into steps keeps them legible.',
      props(
        ['element_id', 'x', 'y', 'latex'],
        {
          'element_id': id,
          'x': num,
          'y': num,
          'latex': str,
          'size': num,
          'color': str,
          'explanation_speech': speech,
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
          'explanation_speech': speech,
        },
      ),
    ),
    tool(
      'plot_function',
      'Plot one or more analytic functions of x on-device, on shared axes. Always pass the function(s) in expressions: a single function is a one-item array, and several functions to compare or show intersecting go in the SAME call as multiple items - never make separate plot_function calls at the same position for that, as each separate plot gets its own axes and auto-scaled y-range so the curves would not be comparable. All functions in expressions share the same x/y ranges. Give each a distinct color and a short label for the legend (e.g. f, g), then use mark_landmarks with "intersections" on this element to mark exactly where they cross.',
      props(
        [
          'element_id',
          'x',
          'y',
          'width',
          'height',
          'x_min',
          'x_max',
          'expressions',
        ],
        {
          'element_id': id,
          'x': num,
          'y': num,
          'width': num,
          'height': num,
          'expressions': {
            'type': 'array',
            'description': 'The function(s) of x to draw on this plot: one item for a single function, multiple items for functions drawn together on shared axes. Prefer objects so each curve has its own colour and legend label.',
            'items': {
              'type': 'object',
              'properties': {
                'expression': {
                  'type': 'string',
                  'description': 'Function of x, e.g. "x^2-4".',
                },
                'color': str,
                'label': {
                  'type': 'string',
                  'description': 'Short legend label, e.g. "f" or "g".',
                },
              },
              'required': ['expression'],
              'additionalProperties': false,
            },
          },
          'x_min': num,
          'x_max': num,
          'y_min': num,
          'y_max': num,
          'explanation_speech': speech,
        },
      ),
    ),
    tool(
      'mark_landmarks',
      'Mark exact landmark points on one of your existing elements. You supply only the element_id and landmark NAMES; the app computes the coordinates from the element itself and draws labelled markers. Never compute landmark coordinates yourself. Supported names: for plot_function: vertex (alias turning_point), root/roots, y_intercept, maximum, minimum, and intersection/intersections (where the functions of a multi-function plot cross each other; other plot landmarks refer to the first function); for SVG shapes: vertex/vertices, centroid, circumcenter, incenter, orthocenter, midpoint/midpoints; for any element: center, top_left, top_right, bottom_left, bottom_right.',
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
          'explanation_speech': speech,
        },
      ),
    ),
    tool(
      'edit_element',
      'Move, resize, edit or replace one of the elements you have already written/drawn by element_id. Use the right parameter(s) based on the type of element.',
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
          'expressions': {
            'type': 'array',
            'description': 'For a plot element: replacement functions of x to draw together on it, replacing its current functions. Items are objects with expression plus optional color/label, as in plot_function.',
            'items': {
              'type': 'object',
              'properties': {'expression': str, 'color': str, 'label': str},
              'required': ['expression'],
              'additionalProperties': false,
            },
          },
          'explanation_speech': speech,
        },
      ),
    ),
    tool(
      'remove_element',
      'Remove one of your own elements by element_id.',
      props(['element_id'], {'element_id': id, 'explanation_speech': speech}),
    ),
    tool(
      'point_at',
      'Point at a board point or one of your elements. Transient.',
      props([], {
        'x': num,
        'y': num,
        'element_id': id,
        'label': str,
        'explanation_speech': speech,
      }),
    ),
    tool(
      'focus_viewport',
      'Move the camera to a board rect or to one or more of your elements, drawing nothing. When the student needs to see multiple related elements at once (e.g. a problem statement together with its equation, or similar cases), pass all of their element_ids together in one call so they are framed together in a single view, but you can also pass a single element id to focus only tha one.',
      props([], {
        'x': num,
        'y': num,
        'width': num,
        'height': num,
        'zoom': num,
        'element_ids': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Element ids to frame together: the camera fits the area covering all of them at once. Prefer this over element_id whenever related elements should be seen together.',
        },
        'explanation_speech': speech,
      }),
    ),
    tool(
      'resume_explanation',
      'Resume a suspended explanation after answering an interruption. You should let the user know that you are continue explanation instead of just jumping which could be confusing.',
      props([], {}),
    ),
  ];
}

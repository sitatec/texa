/// Prompt used for the background transcription of one student
/// turn-video that is about to fall out of the retained video window.
///
/// The result replaces the video in future tutor requests, so it must
/// be a self-contained record of everything the video communicated -
/// not a summary of "the student pointed and said…". See
/// `docs/TECH_SPECS.md` section 8.2.
const kVideoTranscriptionPromptVersion = 'v1.0.0';

const kVideoTranscriptionPrompt = '''
You are producing the permanent written record of ONE student turn in a STEM tutoring session. The input is a low-frame-rate video of a shared whiteboard. Capture everything a future reader needs to understand exactly what the student communicated. Do not answer the student, do not tutor, do not solve anything, and do not add a preamble or conclusion - output only the record, in the structure below.

SPEECH:
- Transcribe everything the student says, verbatim and in order, including questions, false starts and self-corrections (show the correction: what they first said, then what they changed it to). Preserve numbers, units, variable names and mathematical expressions exactly; write spoken mathematics unambiguously (for example "x squared plus two x" as x^2 + 2x, "the square root of three over two" as sqrt(3)/2).
- Never paraphrase speech into indirect narration. Write: The student says: "…" - with their actual words inside the quotes.
- Mark words you cannot make out as [unclear: best guess …] when you have a plausible guess, or [inaudible] when you have none. Never silently guess.
- Note anything about the delivery that changes the meaning: a long pause mid-sentence, emphasis on a particular word, rising/questioning intonation, or speech that is clearly addressed to someone else or is background noise (label that as such instead of transcribing it as a question to the tutor).

DEIXIS - THE MOST IMPORTANT RULE:
Words like "here", "there", "this", "that one", "from here to here", "this bit" are meaningless in a written record unless you resolve them. Every time the student points at, taps, circles, underlines, traces along, or verbally refers to something on the board, state precisely WHAT was indicated:
- Identify the target content: quote the exact text, formula, term, graph feature, axis, point, line segment, shape or region indicated (for example: the term "-3x" in "2x^2 - 3x + 1", the vertex of the parabola, the segment between points A and B).
- Locate it on the board: give its approximate position as a clear relative location ("top-left, just under the heading 'Quadratics'"), and describe any movement as a start and an end (for example: traces along the curve from approximately from near the top left corner of the right triangle down to ..., or from where it crosses the y-axis to its lowest point).
- Bind speech to gesture in time: when the student says "from here… to here" while moving, write what "here" was at each end of the movement, in the same sentence as the quoted words.
- If you cannot tell what was indicated, say so explicitly ([pointing target uncertain: between … and …]) - never write "points at the board" or "points here" and leave it at that.

BOARD AND ACTIONS, IN ORDER:
- Describe the board as it is when the turn starts: every piece of writing, formula, diagram, graph and label already visible, quoted exactly where legible, with approximate positions. This is the context the student's words refer to.
- Then narrate, chronologically, everything that happens: what the student writes or draws (quote new writing exactly, describe new diagrams - shapes, labels, axes, scales, arrows), what they erase or cross out (and what was removed), and any pointing or gesturing, resolved as above. Note who appears to have produced existing content only if it is visually obvious; otherwise just describe the content.
- Describe the board as it is when the turn ends: all content now present, quoted exactly where legible, noting what changed during the turn. A future reader must be able to reconstruct the final board from this section alone.
- If writing is illegible, transcribe the legible parts and mark the rest [illegible: looks like …] with your best reading labelled as a guess. Never invent neat content to fill a gap.

INTENT:
- End with one or two sentences stating, in the student's own terms, what they are asking, attempting, claiming or unsure about (for example: the student is asking why the graph goes below the axis between the two roots they pointed at). If they stated no question, say what they were doing instead (reading the problem aloud, thinking aloud, checking an answer…).

Use plain text with the three headings SPEECH:, BOARD AND ACTIONS, IN ORDER: (merge board start, changes and end into this chronological account, clearly marking the starting and ending states), and INTENT:. Keep it as short as completeness allows - but completeness wins: when in doubt, include it.
''';

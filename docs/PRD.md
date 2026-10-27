# Texa — Product Requirements Document (PRD)

| Field | Detail |
|---|---|
| Product | Texa — AI STEM Tutor |
| Tagline | The personal AI tutor for everyone |
| Document version | 1.5 |
| Version history | v1.1: fixed Meta AI base URL, per-session immutable model, confirmed 1200×1600 board, no mid-turn recovery. v1.2: voice barge-in, natural turn judgement, whiteboard etiquette. v1.3: `<[IGNORE_TURN]>` sentinel (not a tool), AI element identifiers + edit/remove of own elements, first-launch model downloads, platform-setup requirements, slang (English-only) and code-quality standards (Tech Specs §16–§19). v1.4: corrected Kokoro model to v1_1, supported platforms are Android/iOS/macOS/Web with Windows planned. v1.5 (27 Oct 2026): model files moved out of Flutter assets to `app/models/` and served in development by `app/startserver.sh`; model URLs are dart-defines defaulting to the production URLs, set for local development in `.vscode/launch.json` |
| Status | Draft for prototype (MVP) |
| Date | 27 October 2026 |
| Platform | Flutter — Android, iOS, macOS, and Web (mobile is the primary target). Windows is planned but not a supported/tested platform in this version |
| Audience for this document | Product, design, engineering |
| Companion document | [Technical Specifications](TECH_SPECS.md) |

---

## 1. Executive Summary

Texa is an interactive, AI-powered STEM tutor for middle- and high-school students (Maths, Physics, Chemistry). Unlike chat-based tutors, Texa's core experience is a **shared interactive digital whiteboard combined with a voice conversation**. The student draws and speaks; the AI tutor explains conversationally while progressively writing formulas, drawing diagrams, plotting functions, and pointing at elements on the same board — just as a human tutor would across a desk.

This PRD defines the prototype (MVP). The prototype has no custom backend: the Flutter app connects directly to the Meta AI API (fixed base URL `https://api.meta.ai/v1`) using a user-supplied API key, runs speech models on-device, and stores all sessions locally. The endpoint accepts video with embedded audio.

## 2. Problem & Opportunity

- Text chat forces students to translate drawings, geometry, graphs, and "this part here" into words. Most STEM confusion is spatial and gestural, so chat loses the actual question.
- A single photo/snapshot of finished work loses *how* the student got there — the sequence of steps where the misconception occurred.
- Video-call human tutoring solves this but is expensive, scheduled, and scarce.

**Opportunity:** a tutor that *sees the work unfold, hears the student think aloud, and responds by drawing on the same surface* — available instantly, at marginal cost.

## 3. Vision, Goals & Non-Goals

### 3.1 Vision
A patient, perceptive personal tutor that works *with* the student on a shared board, not *at* them through a chat box.

### 3.2 Prototype Goals
1. Validate the core loop: **draw + talk → AI understands → AI explains by drawing + talking back.**
2. Validate that low-framerate (1 FPS) board video + audio gives the model enough temporal context to answer deictic questions ("from here… why does it go negative down here?").
3. Validate that step-by-step AI drawing synchronised with speech feels like tutoring, not like watching a slideshow.
4. Ship a beautiful, minimal experience a student can start using within 60 seconds of first launch (excluding model/key setup).

### 3.3 Non-Goals (Prototype)
- No user accounts, authentication, cloud sync, or custom backend.
- No curriculum engine, syllabus tracking, quizzes, grading, gamification, or progress analytics.
- No parent/teacher dashboards, payments, or subscriptions.
- No handwriting recognition/OCR as a separate pipeline (the multimodal model interprets the board video directly).
- No complex AI-output schema validation/repair pipeline (see §13 — explicitly deferred; noted here so it is not lost).
- No Smart Turn detection (deferred — requires a custom `sherpa-onnx` build; VAD only for the prototype).
- No multi-student / collaborative sessions.

## 4. Target Users & Personas

| Persona | Description | Key need |
|---|---|---|
| **Primary: Student (11–18)** | Middle/high school, stuck on homework or revising; thinks by scribbling | "Show me *on my work* where I went wrong, step by step." |
| **Secondary: Self-learner / parent-assisted learner** | Uses Texa at home, owns the device and API key | Quick setup, trustworthy behaviour, no account friction |

Prototype assumption: the person configuring the API key may be a parent/older student, but the person *using* a session is the student. Language and tone must suit the student.

## 5. Product Principles

1. **The board is the conversation.** Chat is a fallback, never the centre. If it can be shown, draw it.
2. **Show, step by step.** The AI never dumps a finished solution; it builds it progressively, narrating as it goes.
3. **Nothing on the board is sacred.** AI content is ordinary board content: the student can erase it, draw over it, circle it.
4. **Minimal first, depth on demand.** Screens show only what is needed now; controls recede (mobile "More" pattern, overlays, progressive disclosure).
5. **The student stays in control.** Mic can be muted, captions toggled, AI playback interrupted, camera moved manually at any time.
6. **Behave like a present tutor, not a answering machine.** The mic is live whenever unmuted, so the AI must judge every captured turn before acting: it may have caught a cough, background noise, or the student talking to someone else. When a turn is unclear, ambiguous, or not addressed to the tutor, the correct behaviour is to ask a specific clarifying question, briefly redirect, or stay silent — never to guess and answer a question that was not asked.
6. **Fast to first value.** No sign-up. API-key setup is a one-time, clearly explained step.

## 6. Scope

### 6.1 In Scope (MVP)
- First-launch setup: API key configuration (base URL is fixed, not user-entered), microphone permission.
- Model selection per session at creation time; a session's model cannot be changed afterwards.
- Home/dashboard: session history, resume a session, create a new session, rename/delete sessions.
- Session screen: unified whiteboard (fixed logical size), pen/eraser/undo/redo, voice turn capture (VAD), AI replies as plain text (spoken) and/or board tool actions (SVG, LaTeX, text, function plots, pointers/highlights, viewport focus).
- On-device VAD (Silero via `sherpa-onnx`) and TTS (Kokoro via `sherpa-onnx`), sentence-chunked speech, optional live captions of the chunk currently playing. Speech models are downloaded on first launch from URLs supplied via dart-defines defaulting to the production URLs (a local model server overrides them in development — Tech Specs §16).
- Session overlays: mic mute/unmute, captions on/off, fullscreen enter/exit; collapsed under a **More** button on mobile.
- Portrait-locked session screen on mobile; local persistence of sessions and board state (`tostore`).
- Settings: API key, captions default, clear-all-data.

### 6.2 Deferred / Future (explicit backlog, not MVP)
| Item | Why deferred |
|---|---|
| Smart Turn end-of-turn detection | Requires a custom `sherpa-onnx` build |
| AI output schema validation, auto-repair & retry loop | "Make it work first, then harden" — see Tech Specs §12 |
| Semantic element registry (stable IDs/bounding boxes so the AI can reference "the denominator you circled") | MVP uses board coordinates |
| Secure credential storage (Keychain/Keystore) replacing plain local storage | Prototype only |
| Accounts, cloud sync, backend proxy for API keys | Out of prototype scope |
| Curriculum, exercises, progress tracking, multi-language UI | Post-validation |

## 7. Information Architecture

```
App
├── Setup (first launch only, re-accessible from Settings)
│   ├── Welcome
│   ├── API configuration (key only — base URL is fixed)
│   └── Microphone permission
├── Home / Dashboard
│   ├── Session list (history)
│   ├── New Session action
│   └── Settings (entry point)
├── Session
│   ├── Whiteboard (primary surface)
│   ├── Board toolbar (pen, eraser, undo, redo, clear)
│   └── Overlay controls (mic, captions, fullscreen / More on mobile)
└── Settings
    ├── API configuration
    ├── Playback (captions on/off default)
    └── Data (delete all sessions, remove API key)
```

## 8. User Flows

### F-01 — First launch & setup
1. App opens to a short welcome explaining Texa in one screen ("Your AI tutor that draws with you").
2. User enters their API key. The base URL is fixed at `https://api.meta.ai/v1` and is never asked for. A **Test connection** action confirms the key works before proceeding; failure shows a plain-language error with retry.
3. App requests microphone permission, explaining it is used so the student can talk while drawing. Denial does not block entry — the app continues with mic disabled and explains voice is off (see F-09).
4. On-device speech models are provisioned (Tech Specs §16): downloaded on first launch from the dart-define model URLs (production URLs by default; the local `startserver.sh` server in development); setup does not complete until Kokoro and Silero VAD initialise successfully.
5. User lands on Home. **Success:** user reaches Home with a working configuration.

### F-02 — Home / dashboard
1. Home lists previous sessions as cards: title, subject (if set), model, last-updated time, and the stored board thumbnail.
2. Empty state (no sessions): friendly illustration/copy and one primary action — **New session**.
3. Tapping a session resumes it exactly where it left off (board contents, scroll/zoom position, conversation state).
4. Secondary actions per session (long-press / overflow menu): **Rename**, **Delete** (with confirmation).
5. **New session** first asks the user to select the AI model for the session (model picker shown at creation). The choice is stored on the session and **cannot be changed afterwards** — there is no model editor in an existing session. The app then creates the session and navigates straight to the board. Title is auto-generated (e.g. date/time) and editable.

### F-03 — Starting a session & setting the problem
1. Student lands on an empty board (or says/draws the problem immediately).
2. Optional, non-blocking subject selector (Maths / Physics / Chemistry) sets tutoring context; the student can ignore it entirely.
3. Student writes/draws the problem and starts talking. No "send" button is required.

### F-04 — Student turn (draw + talk) — core loop
1. With mic unmuted, on-device VAD detects speech start → turn capture begins: board frames are recorded at **1 FPS** and microphone audio is recorded in sync.
2. The student draws and speaks freely, pointing with the pen and referring to "here/there/this one".
3. VAD detects ~1 second of silence → the turn is finalised automatically. A subtle state indicator shows the turn was captured and is being sent ("Thinking…").
4. The student never manages files, buttons, or recording controls.

### F-05 — AI turn (talk, draw, or both)
1. The AI may reply **in plain text only** when it just wants to talk (answer a question, ask a clarifying question, encourage). The text is spoken via TTS and, if captions are on, shown chunk-by-chunk as it plays.
2. Or the AI replies with a sequence of board actions — write text, write LaTeX maths, draw SVG shapes/diagrams, plot a function, point/highlight — each optionally carrying `accompanying_speech`.
3. Actions play back as one timeline: the camera smoothly frames new content, the drawing animates in, and the accompanying speech for that step plays at the same time. Steps proceed in order until the sequence completes.
4. When finished, the app returns to listening (mic live, idle state). The board now holds everything the AI drew as ordinary, erasable content.

### F-06 — Follow-up & iteration
1. Student responds — circling part of the AI's working, erasing a term, adding their own step — and talks. Next turn begins (F-04).
2. The AI can reference existing board areas using coordinates, point at them, and call `focus_viewport` to bring them into view before/without drawing.

### F-06b — Interrupting the AI & natural turn judgement
1. **Interruption (barge-in):** while the AI is speaking/drawing, the student can simply start talking (or start drawing, or tap Stop). Playback halts almost immediately — speech stops, drawing/camera freeze, already-drawn content stays on the board — and the app listens. The student's words become the next turn, with context that the AI was interrupted mid-step.
2. **Resuming:** if the interruption was a quick question, the AI answers it and can then pick the explanation back up from the step where it stopped (without redrawing what is already on the board). If the interruption changes topic, the old explanation is abandoned cleanly.
3. **False alarms:** a cough, a bump, or a half-second of background noise that trips the mic does not kill the explanation — playback resumes from the start of the sentence chunk that was interrupted.
4. **Not every captured turn deserves an answer.** Because the mic is live until muted, the AI must first judge each turn:
   - *Clear question/instruction to the tutor* → answer normally.
   - *Unclear audio or ambiguous reference* ("this one" with several candidates) → **ask, don't guess**: say what was understood, point at the candidate area(s) on the board, and ask a specific clarifying question. No solution content is drawn.
   - *Noise, or speech clearly addressed to someone else in the room* → stay silent, keep listening (and resume the interrupted explanation if there was one).
   - *Irrelevant/off-topic* → one brief, kind spoken redirect; no board changes.
   - *Incomplete thought / thinking aloud* → a short encouragement to continue ("Go on — what were you thinking here?"), optionally pointing where the student left off.

### F-07 — Overlay controls (session screen)
| Control | Behaviour |
|---|---|
| Mic mute/unmute | Muted: VAD/capture fully stopped, clear muted affordance. Unmuting resumes listening. Muting mid-turn finalises/discards per FR-SE-04. |
| Captions on/off | When on, displays the exact text chunk currently being spoken by TTS (the current sentence chunk). When off, no text is shown. |
| Fullscreen enter/exit | Hides system UI/app chrome for maximum board area; exit restores. |
| More (mobile only) | On compact/mobile layouts the three controls collapse under a single **More** button; tapping expands them, tapping elsewhere/again collapses. |

### F-08 — Leaving, resuming, and session management
1. Leaving a session (back) autosaves board + history continuously — there is no save button and no data loss on app kill (FR-DA-02).
2. From Home the student can resume, rename, or delete any session. Delete is permanent (local data) and confirmed.

### F-09 — Edge & failure flows
| Case | Required behaviour |
|---|---|
| No/invalid API key, test connection fails | Plain-language error, stay in setup/settings, never enter a broken session silently |
| Network offline / request timeout / rate limit (429) / server error | Non-destructive banner in session, board untouched, one-tap **Retry turn**; student work is never lost |
| Mic permission denied | Session works in "draw only" degraded mode; persistent but dismissible hint; re-enable path via Settings |
| Student says/draws nothing (empty turn) | Turn is discarded silently; app returns to listening |
| AI returns unusable output (bad SVG/LaTeX/tool args) | Skip the broken action, continue the rest of the sequence, keep speech coherent; log locally. (Hardening/repair: deferred, §6.2) |
| AI draws off-board or overlaps existing work | Clamp to board bounds; camera framing still succeeds |
| Student pans/zooms away while AI is drawing | Auto-framing applies per new action, but a manual interaction during playback pauses camera auto-tracking for that turn |
| Student wants the AI to stop | Starting to speak, starting to draw, or the interrupt control halts playback immediately; already-drawn content stays; app returns to listening (F-06b) |
| Mic picks up noise / side conversation | AI stays silent (no speech, no drawing) and keeps listening; a suspended explanation resumes (F-06b) |
| AI cannot understand the student | AI asks a specific clarifying question, pointing at candidate areas; it does not guess an answer (F-06b) |
| App backgrounded/killed | No special recovery flow in this version. Messages are saved to the local DB as they are sent and received, and board state is autosaved, so history and board are intact on relaunch |
| Very long session | Board/history remain performant; oldest turn media pruned per retention policy (FR-DA-03) |

## 9. Functional Requirements

Format: **ID — Requirement** *(acceptance criteria in italics)*.

### 9.1 Setup & Settings
- **FR-SU-01** — The app shall require an API key before first use, with a Test Connection action. The base URL is fixed (`https://api.meta.ai/v1`) and shall never be presented as an editable field. *An API key that fails Test Connection cannot be saved as "ready".*
- **FR-SU-02** — Configuration shall persist locally across launches and be editable in Settings.
- **FR-SU-03** — Microphone permission shall be requested with an explanation; denial degrades gracefully (F-09).

### 9.2 Home & Sessions
- **FR-HO-01** — Home shall list all sessions, most recently updated first, with title and last-updated time. *Tapping resumes the session with board and viewport restored.*
- **FR-HO-02** — Creating a new session shall require selecting the session's AI model in the creation flow, then land directly on its board.
- **FR-HO-05** — A session's model is fixed at creation and shall not be changeable from the session screen, session menu, or Settings. The model is displayed on the session card/info for reference.
- **FR-HO-03** — The user shall be able to rename and delete (with confirmation) a session.
- **FR-HO-04** — An empty state shall present a single clear New Session action.

### 9.3 Whiteboard
- **FR-WB-01** — The board shall have a **fixed logical size** (Tech Specs §5), shared identically by student ink, AI content, capture, and AI coordinates.
- **FR-WB-02** — The student shall be able to draw freehand (pen/finger/stylus), erase (including erasing parts of AI content), undo, redo, and clear (with confirmation).
- **FR-WB-03** — AI-generated SVG, LaTeX renders, text, and plots shall be baked onto the same canvas layer so they zoom, pan, layer, and erase identically to student ink.
- **FR-WB-04** — Board state shall autosave continuously and restore on resume/relaunch.
- **FR-WB-05** — On mobile, the session screen shall be locked to **portrait** orientation.

### 9.4 Student Turn Capture
- **FR-ST-01** — While unmuted, on-device VAD (Silero) shall detect speech start/end; a turn finalises after ~1s of trailing silence (configurable constant).
- **FR-ST-02** — During a turn, the app shall capture board frames at **1 FPS** and synchronised mic audio, encoded into a lightweight video turn payload (Tech Specs §7).
- **FR-ST-03** — Turn state (listening / capturing / sending / thinking) shall always be visible via a subtle status affordance without covering the board.
- **FR-ST-04** — If the mic is muted, no capture shall occur and the muted state shall be unmistakable.

### 9.5 AI Turns & Playback
- **FR-AI-01** — The AI shall be able to reply with plain text only (conversation/answers), which is spoken and optionally captioned.
- **FR-AI-02** — The AI shall be able to emit ordered board actions: write text, write LaTeX, draw SVG, plot function, point/highlight, focus viewport — each with optional `accompanying_speech`.
- **FR-AI-11** — Every element the AI draws shall carry an AI-chosen identifier (`element_id`, supplied as a tool parameter). The AI shall be able to later reference that ID to point at, edit (move/resize/replace content), or remove **its own** elements. Student-drawn elements have no AI-visible identifier and cannot be edited or removed by the AI.
- **FR-AI-03** — Function plots shall be evaluated by the on-device plotting engine from an analytic expression; the AI shall never supply plotted coordinates.
- **FR-AI-04** — Playback shall be a single ordered timeline: camera framing → action animation → that action's speech, sequenced per action.
- **FR-AI-05** — New AI content shall trigger smooth automatic viewport framing; `focus_viewport` shall move the camera without drawing.
- **FR-AI-06** — A broken individual action shall be skipped without failing the whole AI turn (F-09).
- **FR-AI-07** — The AI shall never erase or overwrite the student's own work. Corrections are drawn beside/around student work (circling, pointing, adjacent working); only the student erases.
- **FR-AI-08** — Before answering, the AI shall judge each captured turn (clear / unclear / not addressed to the tutor / off-topic / incomplete) and respond per F-06b: clarify, redirect briefly, prompt to continue, or stay silent. It shall never fabricate an interpretation of audio it did not understand.
- **FR-AI-09** — When explaining on the board, the AI shall anchor before it draws: focus/point at the relevant existing element first, draw one step at a time in empty space near (not on top of) the relevant work, narrate while drawing, and periodically check understanding before continuing.
- **FR-AI-10** — After an interruption, the AI shall either resume the suspended explanation from the interrupted step (without redrawing completed steps), answer the interrupting question and then offer/resume, or abandon it if the student changed topic. It shall not restart the whole explanation unprompted.

### 9.6 Speech Output & Captions
- **FR-SP-01** — All spoken text (plain replies and every `accompanying_speech`) shall be split into chunks at **full-stop sentence punctuation** (`.`, `!`, `?`) and synthesised chunk-by-chunk with Kokoro TTS (Tech Specs §9).
- **FR-SP-02** — Chunks shall play sequentially without overlap; the next chunk is synthesised while the current chunk plays (prefetch depth 1).
- **FR-SP-03** — When captions are enabled, the caption area shall show exactly the chunk currently playing — no more, no less.
- **FR-SP-04** — The student shall be able to interrupt AI playback at any time by speaking (barge-in), drawing, or the interrupt control. Speech audio shall stop within ~200 ms of detected speech onset. Brief non-speech triggers (< ~300 ms) shall resume playback from the start of the interrupted chunk instead of cancelling the turn (F-06b).

### 9.7 Session Overlays & Fullscreen
- **FR-SE-01** — The session screen shall expose mic mute/unmute, captions toggle, and fullscreen toggle as small, unobtrusive overlays that never permanently cover board content.
- **FR-SE-02** — On mobile/compact widths, those overlays shall collapse under a **More** button and expand on tap.
- **FR-SE-03** — Fullscreen shall hide system chrome and exit cleanly, restoring prior state.
- **FR-SE-04** — Muting mid-capture finalises the current turn if speech exists, otherwise discards it.
- **FR-SE-05** — An always-available interrupt/stop affordance shall appear while the AI is speaking/drawing.

### 9.8 Data
- **FR-DA-01** — Sessions (including their fixed model), board state, messages, and settings shall persist in the on-device `tostore` database only.
- **FR-DA-02** — No student work shall be lost on app kill, crash, or leaving a session (continuous autosave).
- **FR-DA-03** — Each message shall be saved to the local DB as it is sent (student turn) and as it is received (AI reply, before playback). Captured turn video files are deleted after the turn completes; board state and saved messages persist.

## 10. UX & Visual Design Requirements

- **Style:** modern, minimal, calm. Structured surfaces, generous whitespace, one primary action per screen, progressive disclosure. Brand: Google Sans Flex, primary blue `#3B82F6` with red `#EF6666`, green `#10B981`, yellow `#FBBF24` accents (per existing theme/logo). Light theme primary for the board experience; dark theme supported per existing theme definitions.
- **Home:** clean session cards (title, subject chip if present, relative time — e.g. "2h ago"), single prominent New Session button/FAB. No dense metadata.
- **Board screen:** the board is ≥90% of the visual field. Toolbar and overlays are compact, translucent/floating, and recede. Status (Listening…/Thinking…/Speaking…) is a small pill, never a blocking spinner.
- **Captions:** bottom-anchored, high-contrast, at most ~2 lines, showing only the current spoken chunk.
- **Motion:** camera moves and drawing animations are smooth (300–500ms ease); no jarring cuts. AI drawing should visibly *draw in*, not pop.
- **Touch targets:** ≥44pt, overlays reachable one-handed on mobile within the More pattern.
- **Accessibility (prototype baseline):** captions serve hearing-impaired users; controls have semantic labels; text scales with system settings outside the board surface.
- **Portrait on mobile:** session screen forced portrait; board letterboxed/centred within it, camera pan/zoom used to work across the full fixed board.

## 11. Content & Tutor Behaviour (Product Level)

- **Tone:** warm, patient, encouraging; addresses the student directly; never condescending. Age-appropriate for 11–18.
- **Pedagogy:** guide before telling — ask a leading question or show one step, then check understanding. Never emit a full worked solution in one turn unless the student explicitly asks.
- **Modality discipline:** if a step is spatial (diagram, graph, molecule, circuit), it must be drawn; formulas must be written as LaTeX, not described in prose.
- **Length:** spoken turns should be short (target ≤ ~45 seconds of speech per AI turn); prefer more, smaller exchanges.
- Detailed prompt/system-instruction design is specified in Tech Specs §8.4.

## 12. Privacy, Safety & Trust

- **Prototype posture:** no accounts, no Texa servers; board video/audio go only to the Meta AI API. This must be stated plainly in setup/Settings ("Your board and voice are sent to Meta AI").
- API keys are stored locally only (prototype: `tostore`; secure storage is a deferred hardening item, §6.2).
- The AI must stay on-topic (STEM tutoring), decline non-tutoring requests briefly and kindly, and never request personal information from the student.
- All data can be wiped in Settings (delete all sessions + remove key).

## 13. Success Metrics (Prototype Validation)

| Question | Signal |
|---|---|
| Does the model understand deictic speech + drawing? | In moderated tests, ≥70% of "here/there" questions answered about the correct board region |
| Does step-by-step drawing help? | Students can state the next step / spot their error after an AI turn (observed task success) |
| Is the loop fast enough? | Median turn round-trip (silence → first AI speech/drawing) target ≤ 8s on broadband |
| Is it delightful, not frustrating? | Students voluntarily continue a session beyond the set problem; qualitative SUS ≥ 70 |

## 14. Risks & Assumptions

| Risk/Assumption | Mitigation |
|---|---|
| AI emits malformed SVG/LaTeX/tool arguments | MVP: skip-and-continue (FR-AI-06); validation/repair deferred (§6.2) |
| Latency breaks conversational feel | 1 FPS/540p payload, chunked TTS prefetch, progressive playback (start speaking before all chunks ready) |
| VAD false triggers (TV, siblings, classroom noise) | Mic mute is prominent; silence threshold tunable; degraded modes defined |
| Fixed board too small for large problems | Fixed 1200×1600 size + camera pan/zoom (Tech Specs §5) |
| API cost per turn surprises the key owner | Payload is deliberately tiny; each session displays its (fixed) model on its Home card (cost dashboard: future) |

## 15. Open Questions

1. Should New Session also prompt for subject/title, or stay zero-friction with auto-title beyond the required model selection? (PRD defaults to zero-friction.)
2. (Resolved in v1.2: voice barge-in is required — see F-06b.)

## 16. Milestones (Prototype)

| Milestone | Contents |
|---|---|
| M0 — Foundations | sherpa-onnx VAD+Kokoro verified on target devices; canvas bake-in of SVG/LaTeX verified (Tech Specs §14 checks) |
| M1 — Board & Home | Home/session CRUD, fixed board, drawing tools, autosave/resume, overlays + More, portrait lock, fullscreen |
| M2 — Student Turn | Mic capture, Silero VAD turn finalisation, 1 FPS video encoding, send turn |
| M3 — AI Turn | Tool-call handling, SVG/LaTeX/plot rendering, playback timeline, camera framing, chunked TTS + captions |
| M4 — Polish & Validation | Empty/error states, Settings, moderated student tests, metrics in §13 |


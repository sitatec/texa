# Texa — Product Requirements Document (PRD)

| Field | Detail |
|---|---|
| Product | Texa — AI STEM Tutor |
| Tagline | The personal AI tutor for everyone |
| Document version | 1.10 |
| Version history | v1.1: fixed Meta AI base URL, per-session immutable model, confirmed 1600×1200 landscape board, no mid-turn recovery. v1.2: voice barge-in, natural turn judgement, whiteboard etiquette. v1.3: `<[IGNORE_TURN]>` sentinel (not a tool), AI element identifiers + edit/remove of own elements, first-launch model downloads, platform-setup requirements, slang (English-only) and code-quality standards (Tech Specs §16–§19). v1.4: corrected Kokoro model to v1_1, supported platforms are Android/iOS/macOS/Web with Windows planned. v1.6 (27 Oct 2026): file uploads (modal picker with preview grid), attempt-first pedagogy, per-session Session Observation, cross-session student Memory and observation search. v1.8 (28 Oct 2026): mark_landmarks tool (model supplies landmark names only, app computes coordinates), optional per-session reasoning effort at creation, landscape eraser/line-tool fixes. v1.7 (28 Oct 2026): landscape 1600×1200 board, custom high-performance board engine, API key in secure storage, tostore table engine for collections, subject selector removed, no text composer (voice + drawing + file uploads only), single pen-colour picker. v1.5 (27 Oct 2026): model files moved out of Flutter assets to `app/models/` and served in development by `app/startserver.sh`; model URLs are dart-defines defaulting to the production URLs, set for local development in `.vscode/launch.json`. v1.9 (2 Nov 2026): long sessions past Meta AI's 5-videos-per-request limit - only the 4 newest student turns are sent as video, older turns are transcribed in the background (same model, in parallel with the tutor's reply) and sent as persisted transcripts. v1.10 (4 Nov 2026): hallucination posture — initial version recommends problems the student already has a solution to, so guidance can be verified against it; added future plans for stronger grounding and a teacher-partnership mode (§6.2, §12, §14) |
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
- On-device speech behind one interface: Silero VAD + Smart Turn end-of-turn detection, and Kokoro or Piper TTS (one engine at a time), sentence-chunked with optional live captions of the chunk currently playing. Native uses `sherpa-onnx`; web uses the first-party `texa-webspeech` workers (Sherpa's web Kokoro has no WebGPU/threaded-WASM path and is too slow). Speech models are downloaded on first launch from URLs supplied via dart-defines defaulting to the production URLs (a local model server overrides them in development — Tech Specs §16).
- Session overlays: mic mute/unmute, captions on/off, fullscreen enter/exit; collapsed under a **More** button on mobile.
- Landscape-locked session screen; local persistence of sessions and board state (`tostore`).
- Settings: API key, captions default, clear-all-data.

### 6.2 Deferred / Future (explicit backlog, not MVP)
| Item | Why deferred |
|---|---|
| AI output schema validation, auto-repair & retry loop | "Make it work first, then harden" — see Tech Specs §12 |
| Semantic element registry (stable IDs/bounding boxes so the AI can reference "the denominator you circled") | MVP uses board coordinates |
| Secure credential storage (Keychain/Keystore) replacing plain local storage | Prototype only |
| Accounts, cloud sync, backend proxy for API keys | Out of prototype scope |
| Curriculum, exercises, progress tracking, multi-language UI | Post-validation |
| Stronger grounding to reduce hallucination risk (e.g. verified solution/curriculum sources the tutor must stay consistent with, answer-checking against known solutions, and confidence/uncertainty handling) | Even frontier models that score perfectly on most middle/high-school STEM problems can still hallucinate; the risk is never zero. Grounding is the planned mitigation — see §12 and §14 |
| Teacher-partnership mode: teachers provide their programme/curriculum and pedagogy, the AI tutors students within that guidance, and reports back to the teacher with session recordings | Builds on grounding: teacher-supplied material anchors the tutoring to what is actually taught, and teacher oversight (including reviewing session recordings) catches errors a student could not. Requires accounts, consent/safeguarding and reporting infrastructure that are out of prototype scope (see §3.3) |

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
│   ├── Board toolbar (pen, line, eraser, undo, redo, clear)
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
4. On-device speech models are provisioned (Tech Specs §16): downloaded on first launch from the dart-define model URLs (production URLs by default; the local `startserver.sh` server in development); setup does not complete until the selected TTS engine and Silero VAD initialise successfully.
5. User lands on Home. **Success:** user reaches Home with a working configuration.

### F-02 — Home / dashboard
1. Home lists previous sessions as cards: title, model, last-updated time, and the stored board thumbnail.
2. Empty state (no sessions): friendly illustration/copy and one primary action — **New session**.
3. Tapping a session resumes it exactly where it left off (board contents, scroll/zoom position, conversation state).
4. Secondary actions per session (long-press / overflow menu): **Rename**, **Delete** (with confirmation).
5. **New session** first asks the user to select the AI model for the session (model picker shown at creation). The choice is stored on the session and **cannot be changed afterwards** — there is no model editor in an existing session. The app then creates the session and navigates straight to the board. Title is auto-generated (e.g. date/time) and editable.

### F-03 — Starting a session & setting the problem
1. Student lands on an empty board (or says/draws the problem immediately).
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
| Very long session | Board/history remain performant. Past 4 student video turns, older turns are sent to the tutor as transcripts instead of video (Meta AI allows at most 5 videos per request; Texa keeps a one-slot margin), so a session is never cut short by the video limit. Turn videos themselves are kept locally for history playback |


### F-10 — Uploading files to a session
1. Tapping the file control in the session composer opens a modal. The modal offers the upload sources that make sense on the current platform (e.g. photo gallery and camera on mobile, file picker on desktop/web, plus in-app audio recording when audio is supported) and, below them, a vertically scrollable, responsive grid of the files selected so far — each cell showing a preview (image thumbnail, audio player, or a type icon for video/documents) with its file name.
2. Files can be removed from the grid before sending. Limits (count and 45 MB per file) are enforced with plain-language errors.
3. Selected files are attached to the next turn the student sends: photos/documents are shared with the tutor as part of that turn so the student can say "this question here" about their own material.

### F-11 — Attempt-first tutoring
1. When a student presents a problem, Texa does **not** solve it for them. It first asks the student to try it, or asks how they think it should be approached ("What do you think the first step could be?").
2. Texa then assists only as needed: a hint, a pointed question, or one small step — escalating help only when the student is stuck, asks for more help, or has tried and missed.
3. A full worked solution is given only when the student has genuinely attempted the problem or explicitly asks to be shown after trying.

### F-12 — Session Observation
1. Every session has a **Session Observation**: a note that starts blank and that the tutor progressively updates during the session as it notices things worth remembering — how the student's understanding or behaviour changes in specific situations, misconceptions that surface or clear, strategies that work for them.
2. It contains only important observations (not a transcript or summary of everything said), is at most **two paragraphs**, and may legitimately stay empty when nothing noteworthy has been observed yet.
3. The observations from the **last 3 sessions** are always given to the tutor at the start of a session, and the tutor can search older observations (by date, by content, or both) when it needs more history.

### F-13 — Student Memory (cross-session)
1. Separate from any single session, Texa keeps a **Memory** of the student: their level, goals, preferences, learning patterns, what helps them understand, and what tends to confuse them.
2. Memory is concise and kept current — the tutor progressively revises it across sessions as things change, rather than appending endlessly.
3. Memory is given to the tutor in every session so help is personalised from the first minute.

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
- **FR-AI-09** — The AI shall be able to mark exact landmark points on its own elements via `mark_landmarks`, supplying only landmark names (e.g. vertex, circumcenter, roots); the app computes and draws the points.
- **FR-WB-02** — The student shall be able to draw freehand (pen/finger/stylus) with ink visible *while* drawing, draw straight lines (drag to preview, release to commit), erase (partially erasing a stroke splits it, leaving a gap; erasing also works on AI content), undo, redo, and clear (with confirmation).
- **FR-WB-03** — AI-generated SVG, LaTeX renders, text, and plots shall be baked onto the same canvas layer so they zoom, pan, layer, and erase identically to student ink.
- **FR-WB-04** — Board state shall autosave continuously and restore on resume/relaunch.
- **FR-WB-05** — The session screen shall be locked to **landscape** orientation.

### 9.4 Student Turn Capture
- **FR-ST-01** — While unmuted, on-device VAD (Silero) shall detect speech start/end; after ~1s of trailing silence (configurable constant), Smart Turn shall judge whether the student has finished before the turn finalises — an unfinished judgement resumes listening instead of sending a truncated turn.
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


### 9.5b File Uploads
- **FR-UP-01** — Tapping the file control shall open a modal with the upload sources appropriate to the current platform and a vertically scrollable, responsive preview grid (preview + file name) of the selected files, from which files can be removed before sending.
- **FR-UP-02** — Upload state shall be managed by the app itself with Flutter's built-in components only (no form-builder package), and selected files shall attach to the next student turn.

### 9.5c Attempt-First Pedagogy
- **FR-PED-01** — The tutor shall first invite an attempt or an approach ("How do you think we should start?") for any new problem, and shall assist with hints or single steps only as necessary. *It never opens by solving a problem the student has not tried.*
- **FR-PED-02** — Help escalates with need: hint → guided step → worked step; a complete solution requires a genuine attempt or an explicit request after trying.

### 9.5d Session Observation & Memory
- **FR-OB-01** — Each session shall have a Session Observation, initially blank, progressively updated by the tutor via efficient text edits (see Tech Specs), containing only important observations, at most two paragraphs, and allowed to remain empty.
- **FR-OB-02** — The last 3 sessions' observations shall always be included in the tutor's context, and the tutor shall be able to search observations by date, content, or a date-range-plus-content combination (full-text search for the MVP).
- **FR-ME-01** — A single cross-session Memory (level, goals, preferences, learning patterns, what helps/confuses) shall be kept concise and progressively revised by the tutor, and shall be included in the tutor's context for every session.

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
- **FR-DA-01** — Sessions (including their fixed model), board state, messages, observations and settings shall persist in the on-device `tostore` database (table engine with indexes, Tech Specs §10) only; the API key shall persist only in platform secure storage.
- **FR-DA-02** — No student work shall be lost on app kill, crash, or leaving a session (continuous autosave).
- **FR-DA-03** — Each message shall be saved to the local DB as it is sent (student turn) and as it is received (AI reply, before playback). Captured turn video files are deleted after the turn completes; board state and saved messages persist. A student turn's video bytes are kept in its saved message for local history playback, together with - once produced - its transcript and transcription status; only the newest 4 turns' videos are ever sent to the API, older turns being sent as their transcripts, so resuming a session restores the same video/transcript split (any transcription interrupted by an app kill is resumed automatically).

## 10. UX & Visual Design Requirements

- **Style:** modern, minimal, calm. Structured surfaces, generous whitespace, one primary action per screen, progressive disclosure. Brand: Google Sans Flex, primary blue `#3B82F6` with red `#EF6666`, green `#10B981`, yellow `#FBBF24` accents (per existing theme/logo). Light theme primary for the board experience; dark theme supported per existing theme definitions.
- **Home:** clean session cards (title, relative time — e.g. "2h ago"), single prominent New Session button/FAB. No dense metadata.
- **Board screen:** the board is ≥90% of the visual field. Toolbar and overlays are compact, translucent/floating, and recede. Status (Listening…/Thinking…/Speaking…) is a small pill, never a blocking spinner.
- **Captions:** bottom-anchored, high-contrast, at most ~2 lines, showing only the current spoken chunk.
- **Motion:** camera moves and drawing animations are smooth (300–500ms ease); no jarring cuts. AI drawing should visibly *draw in*, not pop.
- **Touch targets:** ≥44pt, overlays reachable one-handed on mobile within the More pattern.
- **Accessibility (prototype baseline):** captions serve hearing-impaired users; controls have semantic labels; text scales with system settings outside the board surface.
- **Landscape:** session screen forced landscape; camera pan/zoom used to work across the full fixed board. There is no text composer: students speak, draw, or attach files (the attach icon sits with the other session overlay icons; files are sent as a turn when the upload modal closes).

## 11. Content & Tutor Behaviour (Product Level)

- **Tone:** warm, patient, encouraging; addresses the student directly; never condescending. Age-appropriate for 11–18.
- **Pedagogy (attempt-first):** never solve a problem the student has not tried. First ask them to attempt it or to say how they think it should be approached; then assist only as necessary — a hint, a leading question, or one step — escalating only when they are stuck or ask for more. Never emit a full worked solution in one turn unless the student has genuinely attempted the problem, or explicitly asks to be shown after trying.
- **Modality discipline:** if a step is spatial (diagram, graph, molecule, circuit), it must be drawn; formulas must be written as LaTeX, not described in prose.
- **Length:** spoken turns should be short (target ≤ ~45 seconds of speech per AI turn); prefer more, smaller exchanges.
- Detailed prompt/system-instruction design is specified in Tech Specs §8.4.

## 12. Privacy, Safety & Trust

- **Prototype posture:** no accounts, no Texa servers; board video/audio go only to the Meta AI API. This must be stated plainly in setup/Settings ("Your board and voice are sent to Meta AI").
- API keys are stored locally only, in platform secure storage (`flutter_secure_storage`); the key field states this in the UI.
- The AI must stay on-topic (STEM tutoring), decline non-tutoring requests briefly and kindly, and never request personal information from the student.
- **Hallucination posture (initial version):** Texa must never present its guidance as guaranteed-correct. Because the risk of AI hallucination is never zero, the initial version recommends (in the first-launch welcome guide and Settings copy) that students bring problems they **already have a solution to but do not yet understand how to solve** — a very common situation — so they can verify Texa's step-by-step guidance against that known solution. Stronger grounding and teacher partnership are future mitigations (§6.2, §14), not prototype behaviour.
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
| AI hallucination — plausible but incorrect explanation or step | Initial version: attempt-first guidance plus recommending problems the student already has a solution to, so the guidance can be verified against it (§12); never present guidance as guaranteed-correct. Future: stronger grounding against verified sources/known solutions, and a teacher-partnership mode (teacher-supplied programme and pedagogy, with session recordings reported back to the teacher for review), which brings tutoring under teacher oversight and substantially reduces the risk (§6.2) |
| Latency breaks conversational feel | 1 FPS/540p payload, chunked TTS prefetch, progressive playback (start speaking before all chunks ready) |
| VAD false triggers (TV, siblings, classroom noise) | Mic mute is prominent; silence threshold tunable; degraded modes defined |
| Fixed board too small for large problems | Fixed 1600×1200 size + camera pan/zoom (Tech Specs §5) |
| API cost per turn surprises the key owner | Payload is deliberately tiny; each session displays its (fixed) model on its Home card (cost dashboard: future) |

## 15. Open Questions

1. Should New Session also prompt for subject/title, or stay zero-friction with auto-title beyond the required model selection? (PRD defaults to zero-friction.)
2. (Resolved in v1.2: voice barge-in is required — see F-06b.)

## 16. Milestones (Prototype)

| Milestone | Contents |
|---|---|
| M0 — Foundations | speech (VAD+Kokoro: sherpa-onnx native, texa-webspeech web) verified on target devices; canvas bake-in of SVG/LaTeX verified (Tech Specs §14 checks) |
| M1 — Board & Home | Home/session CRUD, fixed board, drawing tools, autosave/resume, overlays + More, landscape lock, fullscreen |
| M2 — Student Turn | Mic capture, Silero VAD turn finalisation, 1 FPS video encoding, send turn |
| M3 — AI Turn | Tool-call handling, SVG/LaTeX/plot rendering, playback timeline, camera framing, chunked TTS + captions |
| M4 — Polish & Validation | Empty/error states, Settings, moderated student tests, metrics in §13 |


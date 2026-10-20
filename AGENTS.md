# Reverie

A native macOS book reader with AI-generated insights. The only thing that matters is **insight quality**. If the annotations are generic "AI slop," the project is worthless. Every decision - architecture, UI, performance - serves delivering insights that go *beyond* the text: real science, historical context, connections to other works, philosophical depth. Not plot summaries. Not "explores themes of identity." Knowledge the reader couldn't get from the book alone.

## Model APIs

Model APIs evolve faster than training data. Use current official provider documentation to verify API behavior and model availability, not model memory or archived examples.

The provider implementations live in `Reverie/Services/LLM/`. Text-model IDs, capabilities, pricing, and utility-task selection belong in `Reverie/Services/SupportedModels.swift`; add ordinary model releases there rather than scattering model-name checks.

## Hard Rules

**No file deletion via shell.** Inform the user and let them handle it.

**No model downgrades.** Do not replace configured models based on model memory. Verify proposed changes against current official provider documentation and notify the user before any model name changes.

**Behavioral tests, not legacy baggage.** Never hardcode values to pass tests. New non-UI behavior requires focused coverage. Update or remove tests that preserve obsolete contracts; do not pin prompt wording, implementation details, or historical model lists. Keep tests for meaningful boundaries, transitions, errors, and regressions.

**Build must pass.** `swift build` and `swift test` must succeed. Report unrelated failures separately; do not assume their cause or expand scope to fix them.

**Subscription credentials stay in Keychain.** ChatGPT subscription access is separate from paid OpenAI API access. Never import credentials from other apps, log tokens, store them in settings, or silently fall back to a paid API key. Preserve native reasoning and tool-result state without treating displayed thinking summaries as replayable reasoning.

## How to Write Code

**Rewrite over patch.** If implementing a feature reveals that adjacent code is the root cause of friction, rewrite it properly instead of patching around it. Patches accumulate into unmaintainable code; rewrites fix the foundation. A clean rewrite is fewer lines, better performance, more readable, and won't break next time.

**Eliminate before optimizing.** Before optimizing anything, ask: should this exist? Delete the unnecessary, simplify what remains, then optimize what's left. The fastest code is code that doesn't run.

**Simple and fast.** Simple doesn't mean naive. Think about algorithmic complexity - choose O(n) over O(n²) when the solution is just as clear. Avoid unnecessary allocations, redundant iterations, and work that could be done once instead of repeatedly. Write code that's obvious *and* efficient.

**Trust the code you control.** Validate at system boundaries (user input, external APIs), then trust internal code. If a function's contract guarantees non-nil, don't check for nil. If an internal call can't fail, don't handle failure. No try/catch spam, no redundant guards, no defensive wrappers around your own code.

**Obvious over clever.** Code that needs comments to explain *what* it does is too clever. Fewer lines through intelligence, not compression. Early returns over deep nesting. Named intermediate values over long expressions.

**Generalize late.** Three uses minimum before abstracting. Premature abstraction is worse than duplication.

**Don't add what wasn't asked for.** No unrequested features, no speculative error handling for cases that can't happen, no documentation for code you didn't write. But if the task requires touching adjacent code to do it right, do it right.

## When to Ask

Ask when:
- Requirements are ambiguous and multiple interpretations would lead to significantly different implementations
- You're about to do something destructive or hard to reverse
- You're unsure whether a test failure indicates a bug in your code or a flawed test

Don't ask when:
- You can figure it out by reading the codebase
- The choice is minor and easily changed later
- You're just seeking confirmation for something obvious

## UI

- Native macOS with SwiftUI
- Rose Pine theme baseline - all UI respects the `Theme` system
- Navigation stability: programmatic navigation (e.g., clicking an insight to jump to it) takes precedence over passive scroll-tracking to prevent jitter and feedback loops

## Communication

Be direct. "O(n²) complexity" not "might be slow." State tradeoffs plainly.

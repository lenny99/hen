

# AGENTS.md

Guidance for coding agents working on this repository. For documentation please look at `docs/`.

## Core Rules

- Prefer small, focused changes over large refactoring.
- Do not add comments
- Do not add features, error handling, or abstractions beyond what the task needs.
- Do not commit, push, tag, or release.

## Writing Style

These guidelines apply to code comments, documentation pages, commit messages, and chat.

- Write in plain English with short sentences and everyday words. No colorful adjectives ("parser", not "robust parser").
- No em dashes. Restructure the sentence or use a semicolon.
- No colons in the middle of a sentence in new prose. A colon that introduces a code block or a list is fine. Reword existing text only when touching it anyway.
- Do not write that something "lives under" or "lives in" a path. Write "is in" or "is defined in".
- Oxford commas in inline lists.
- Headings in title case; minor words (a, an, the, and, but, or, for, in, on, at, to, by, of) stay lowercase unless first. Capitalize only the first part of a hyphenated compound ("Tail-call Detection").
- List items: sentence-case lead-in, never bold ("Upvalue capture: ..." not "**Upvalue Capture**: ..."). Prefer noun phrases for checklist items.
- Capitalize proper nouns (Zig, Scheme, Element 0, Elz, R7RS) and nothing else mid-sentence.
- Complete sentences, no made-up words or abbreviations, participial phrases only sparingly.

## Issue Workflow

Work beads issues with the beads-loop skill: one issue at a time, one step per message, stop for review after each step.
Run the skill when the user says "next bead", "work the beads", or names an issue id.



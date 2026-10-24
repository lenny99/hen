# Agent loop with Scheme as the environment

Draft for discussion. Research on the vendored CHICKEN C API, the tool-calling
wire format, and prior art is folded in. The M1 bridge prototype is done and
tested: `scheme/env.scm` plus `src/environment/env.zig`, 46 of 46 tests pass.

The design is split into ten phases. The plugin-facing surface, the forms a
Scheme tool module writes against, is drafted in `docs/plugin-api.md`.

## Phase #1. Goal

The LLM is the policy. It reads the transcript and picks actions.
CHICKEN Scheme is the environment. It holds tool state, runs actions, and
returns observations.
Zig is the body. It owns the provider transport, the transcript, the event
loop, the UI, and child processes.

The agent loop pairs policy and environment:

```text
user message
  -> model turn (streamed)
  -> actions (tool calls)
  -> environment runs each action
  -> observations appended to the transcript
  -> next model turn
  ... until the model answers with text only, or the round budget ends
```

## Phase #2. What exists today

- `src/instance`: `Session` holds a user/assistant transcript. `run` streams one
  turn and folds text deltas. `ToolDef` and the `tool_invocation` and
  `tool_return` delta kinds exist, but nothing executes tools.
- `src/providers`: OpenAI-compatible streaming over opencode zen
  (`go/v1/chat/completions`). `Chunk` parses `delta.tool_calls` fragments, but
  the generator drops them. The request payload has no `tools` field.
- `src/environment`: `Interpreter` wraps `CHICKEN_initialize`, `CHICKEN_run`,
  `CHICKEN_eval_string_to_string`, `CHICKEN_load`, `CHICKEN_get_error_message`,
  and `CHICKEN_yield`. Eval writes into one fixed caller buffer. A failed eval
  cannot be retried with a larger buffer without running side effects twice.
- `docs/libraries.md` sets the governing rule: Zig owns the process, event
  loop, provider connections, tool lifetimes, and UI. CHICKEN owns
  programmable Scheme state inside a controlled bridge or worker.

## Phase #3. Ownership split

| Concern | Owner | Reason |
|---|---|---|
| Provider transport and wire format | Zig | provider specifics stay out of Scheme |
| Transcript | Zig | the payload builder needs it in provider JSON shape |
| Loop policy: rounds, budgets, retries | Zig | one place, testable with the mock provider |
| Tool definitions and tool state | Scheme | tools change without rebuilding hen |
| Tool execution | Scheme | the environment |
| Process spawning, search, git | Zig | tool registry per libraries.md, exposed to Scheme later |

The transcript stays in Zig. Scheme sees one action and its arguments, not
the whole conversation. A Scheme-owned transcript was considered and
rejected: it would push provider message shaping into Scheme and duplicate
state.

### Module boundaries

Three Zig modules above the transport:

```text
environment    CHICKEN runtime, bridge, tool registry, generation loading
instance       transcript, loop policy, provider handle, action dispatch
generations    immutable environment snapshots, health checks, promotion
```

- `environment` owns the single CHICKEN runtime: the bridge, the registry
  behind `(hen-call!)`, and the loading of one generation of Scheme modules.
  It serves one request at a time on the runtime thread.
- `instance` owns one running agent: the transcript, the round budget, the
  provider stream, and the dispatch of actions to the environment. Branching
  lives here: fork a generation, run a child instance, return the child's
  final answer as the observation.
  - `generations` owns immutable snapshots of the environment: Scheme sources
    plus the configuration those sources declare. It builds a generation, runs
    health checks, swaps the active registry atomically, drains in-flight
    calls, and keeps the ledger. It never runs instances, so the dependency
    graph stays acyclic.

Dependencies point one way:

```text
instance -> provider -> http
instance -> environment
instance -> generations -> environment
```

One CHICKEN runtime lives in one process, and it stays in one native thread.
`CHICKEN_initialize` computes a stack limit for the calling thread, so it and
every later `CHICKEN_run` must run in that same thread
(`manual/Embedding:40-48`). A second `CHICKEN_initialize` in the same process
has no effect (`manual/Embedding:40-42`). So one process holds one runtime,
and one runtime holds one environment.

Isolation therefore comes from processes. CHICKEN modules control visible
bindings only. They do not create separate environments, and a redefinition
changes the imported binding (`manual/Modules:101-105`). The target is one
process per instance, each with its own runtime and its own environment,
talking over a restricted message channel. That work is scoped out for now:
hen runs one agent in one process. Process workers also stay the place for
risky branches.

The C interface advises one thread with pending C stack frames at a time
(`manual/C interface:1619`).

Autolith uses the same shape for its workers. The workers run in separate
images, they cannot change the active agent, and the parent reaches them over
a session protocol with leased requests (`docs/architecture.org`, "System"
and "ACP service").

Branching, first cut: a child instance gets a forked generation, an empty
transcript, and the same provider. The parent runs the child loop to
completion inside the tool call. The model drives branching through tools:
spawn, promote, discard. The full protocol is in Phase #9.

Today's code maps to this: `src/environment` plus `scheme/env.scm` is
`environment`; `src/instance` is `instance`; `generations` is new. The module
rename landed in M2.

## Phase #4. Loop protocol

One user request drives zero or more action rounds:

1. Append the user message.
2. Build the request: system prompt, transcript, tool list.
3. Stream one model turn. Fold text deltas. Assemble tool calls by `index`.
4. When the stream ends:
   - No actions: append the assistant text. Done.
   - Actions: append one assistant message that carries the calls. Run each
     action in the environment. Append one observation message per call.
5. Decided: when the round budget is spent, stop sending the tool list and ask
   for a final answer on the next turn.

Budgets: `max_rounds` per user request, default 8, set on the session.

Cancellation: the stream is released as today. Environment actions run
synchronously in the first cut, so cancellation between rounds is enough.
Eval timeout handling is in Phase #6.

Environment thread: deferred to this phase. The bridge runs synchronously on
the main thread until the decision is made.

## Phase #5. Bridge mechanics

The bridge is the synchronous call channel between Zig and the CHICKEN
runtime. It runs on one thread and it carries text. One call moves one
action in and one observation out. Tool state stays inside Scheme. No
conditions, no C values, and no state cross the bridge.

Research is done against the vendored tree (`vendors/chicken-core`,
`6.0.1pre1`) and its manual. Facts carry file references.

### Module and API

The bridge is the `environment` module of Phase #3: today's `src/environment`
plus `scheme/env.scm`, renamed in M2. Its public surface is three
functions: start the runtime, list the tools, run one action.

Decided: text over eval, not a C-value marshaling layer. Zig sends Scheme
source and reads back written representations. A `C_word`-level path exists
for a later optimization: `CHICKEN_read`, `CHICKEN_apply`
(`manual/Embedding:101-120`), and the GC root API `CHICKEN_new_gc_root`,
`CHICKEN_gc_root_set`, `CHICKEN_gc_root_ref`, `CHICKEN_global_lookup`
(`manual/Embedding:267-327`, `chicken.h:812-813`, `chicken.h:1786-1790`).

```zig
pub const ToolDesc = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const Environment = struct {
    pub fn init(allocator: std.mem.Allocator,
                modules: []const []const u8) Error!Environment;

    pub fn tools(self: *Environment,
                 allocator: std.mem.Allocator) Error![]ToolDesc;

    pub fn call(self: *Environment,
                allocator: std.mem.Allocator,
                name: []const u8,
                args: std.json.Value) Error![]u8;
};
```

- `init` starts one CHICKEN runtime on the calling thread and loads the
  given Scheme modules (`scheme/env.scm` today). Every later call must run
  on that thread. `src/environment/root.zig` enforces it and returns
  `error.WrongThread`.
- `tools` returns the tool descriptors for the provider `tools` array. It
  runs at session start, and again after a generation swap. `.name` and
  `.description` go to the provider as they are. `.parameters` is the JSON
  Schema for the arguments; the bridge renders it from the shape that the
  registry declares.
- `call` runs one action and returns its observation as caller-owned text.
  A tool error is an observation that starts with `Error: `, not a Zig
  error.
- `Error` is the set in `src/environment/root.zig`: allocation failure plus
  `InitializationFailed`, `InvalidCString`, `OutputBufferTooSmall`,
  `SchemeError`, `StringTooLarge`, `WrongThread`. `call` converts
  `SchemeError` and `OutputBufferTooSmall` into observations. The other
  errors propagate.
- There is no `deinit`. CHICKEN has no shutdown call, so the runtime lives
  until the process exits (`src/environment/root.zig`).
- The environment handles one call at a time.
- Phase #9 adds a `load` entry for the generation swap. It runs on the same
  thread and follows the same rules.

### Call path

The Scheme side is the registry of Phase #5:

```text
hen:tools/list         -> ((name description shape) ...)
hen:tools/call!        -> stored result length
hen:tools/fetch        -> stored result string
```

One `call` runs two evals on the runtime thread:

```text
eval "(hen:tools/call! \"name\" '<args>)"  -> stored result length
eval "(hen:tools/fetch)"                   -> written string literal
decode the top-level string literal        -> observation text
```

The first eval runs the action and stores its result inside Scheme. The
second eval reads it back. This two-phase fetch is `Env.call` with
`decodeResult` in `src/environment/env.zig`.

### Across the bridge

- Arguments in. Zig converts parsed JSON (`std.json.Value`) to Scheme data
  text: objects to alists, arrays to lists, strings to escaped literals,
  numbers, booleans, and null as-is. The dispatch evals the datum quoted:
  `(hen:tools/call! "<name>" '<args>)`. Object keys become symbols. Keys that
  read back as symbols stay plain; all others, such as `.` and number-like
  keys, go inside pipes `|...|`. The escaper writes backslash, double
  quote, newline, tab, and carriage return as one-character escapes, and
  NUL as `\x0;`; other bytes pass through unchanged. No JSON parser is
  needed in Scheme.
- Result channel. `CHICKEN_eval_string_to_string` writes the written
  representation of the value into a caller buffer: a string result comes
  back quoted and escaped. The manual does not document truncation
  (`manual/Embedding:93-98`). A failed eval cannot be retried with a larger
  buffer, because the action would run twice. So `call` sizes a scratch
  buffer from the length that `(hen:tools/call! ...)` returns, with slack for
  the written form, evals `(hen:tools/fetch)` into it, and decodes the string
  literal into the exact observation. `string-length` counts characters, not bytes,
  so the slack covers that too.
- Results out. The observation is text. Strings return as-is; other values
  use a written representation. The `medea` egg stays out: it needs
  `comparse` plus `srfi-1`, `srfi-13`, `srfi-14`, `srfi-69`, and those
  units are not confirmed in the static build. A small pure-Scheme JSON
  writer is the fallback when a tool must return JSON to the model.
- Errors. `(hen:tools/call! ...)` catches every condition and stores
  `Error: <message>` as the result. A failed eval at the bridge maps to the
  same shape (`Env.errorObservation`). The model sees the message and can
  retry. Errors never cross the bridge as conditions.

### Inside the runtime

- State. Modules loaded at environment start persist for the session.
  Per-session state lives in Scheme.
- Threads. `srfi-18` is a separate egg in this tree (`manual/Embedding:226`),
  not part of the static runtime. CHICKEN threads are green threads, and one
  blocking C call blocks them all. `CHICKEN_yield` runs the next green thread
  for one time slice (`manual/Embedding:137-143`). So the environment thread
  is a plain Zig thread that owns the runtime and serves a request queue.
  That thread must also run `CHICKEN_initialize`. First cut: the session
  calls the bridge synchronously on the main thread; the API does not change
  when the queue arrives (M4). Phase #4 decides when that changes.
- Limits. `CHICKEN_interrupt()` only sets the timer-interrupt flag; it takes
  effect at the next interrupt check and cannot stop blocking C code
  (`chicken.h:1792`, `runtime.c:1052-1055`). No eval timeout is documented.
  First cut: none. Later: cooperative deadline checks inside tools, and a
  separate process for risky evaluations.

### Host services into Scheme, for M5

The static link works: `csc -static -embedded` with host C was verified
against the vendored tree. Scheme reads host symbols with `foreign-value`
plus `foreign-declare "extern ..."`, and calls host functions with
`foreign-lambda` (`manual/Module (chicken foreign):34-48, 131-133`).
C-to-Scheme callbacks use `define-external` and `C_callback`; the
Scheme-to-C side must then use `foreign-safe-lambda`
(`manual/Module (chicken foreign):211-219`). A non-local exit out of a
callback C frame leaks the frame, and srfi-18 thread switches inside a
callback can crash (`manual/Module (chicken foreign):227-232`).

## Phase #6. Message and wire changes

`Message` gains:

- assistant messages with tool calls (id, name, arguments),
- tool result messages (call id, name, content).

Provider payload, `src/providers`:

- `Create` gains `tools` and `tool_choice`.
- The generator assembles `delta.tool_calls` fragments by `index` and emits
  `.tool_invocation` deltas.
- `finish_reason` `tool_calls` ends the turn as an action round.
- The conversation mapping emits the assistant `tool_calls` array and
  `role: "tool"` messages with `tool_call_id`.
- opencode zen does not document `tools` support on the go route. M3 verifies it
  with a live call before the loop relies on it.
- glm supports `tool_choice` `auto` only, so the budget forces the final answer
  by omitting the `tools` array, not by `tool_choice` `none`.

## Phase #7. Errors, budgets, safety

- A tool error is an observation, not a failure of the turn.
- A provider error keeps the history and releases the stream, as today.
- Decided: the budget forces a final text answer instead of failing.
- No sandbox policy now. The model can read and write files through Scheme,
  with the permissions of the hen process. The sandbox comes later, and the
  environment owns it. An early sandbox belongs to M2.

Autolith runs its command tools inside a sandbox: no network, read-only host
access, writes only in the workspace and temporary directories, and a 60 second
timeout (`docs/architecture.org`, "Workspace and workers"). hen does not apply
that policy now. It stays the reference for the later sandbox in the
environment.

## Phase #8. Generations and branching

A generation is an immutable snapshot: the Scheme sources, a manifest, a content
hash, and a parent ID. The ledger keeps every generation: promoted, failed, and
discarded. Nothing is deleted. Rollback repoints the active generation to an
earlier promoted one.

A generation carries configuration as well as code. Scheme code declares the
constants it needs and the places to read them from. The host resolves each
source at load time and passes the value to the runtime.

```scheme
(module foobar-provider
  (export provider-api-key)
  (define-config provider-api-key :sources (env 'FOOBAR_API_KEY)))
```

- `define-config` names a setting and its sources. `env` reads a process
  environment variable. The host owns the process, so the host reads the
  variable and passes the value in. Scheme does not call the operating system
  for it.
- A value that is not a secret is written in the generation as a literal. A
  secret stays in the process environment and is never written to a
  generation file.
- A declared constant is an ordinary value in the module. Code passes it on
  as a parameter.
- A later generation can override a constant. The override belongs to the
  snapshot, so the ledger keeps both values.
- A generation can also define a provider. The definition names the endpoint,
  the key source, and the model set. The wire format stays in Zig.
- CHICKEN module syntax is `(module NAME (EXPORT ...) BODY ...)`. The form
  above follows it.

The Darwin Gödel Machine keeps weaker but valid agents in its archive as
stepping stones. A keep-only-the-best variant of it scores worse: 39.7% against
50.0% on SWE-bench. So hen keeps valid but weaker generations too.

The gate is deterministic. A fresh CHICKEN runtime loads the candidate, then
the checks run: module load, the `hen:tools/list` call, a smoke eval, the tool
tests, a registry diff against the parent, and resource caps. Voyager admits
skills after execution plus a model critic, and reports that the critic
sometimes misjudges success. A critic may attach evidence; the deterministic
checks decide. Evaluation is noisy, so run the gate twice when a result is
close.

A branch is a child instance on a forked generation: empty transcript, same
provider. The fork pins the generation ID, the random seed, and the transcript
prefix, so a run replays the same way. The parent runs the child loop inside the
tool call and gets the child's final answer plus evidence: test results, logs,
and the changed-tool list. No environment state crosses the boundary. This is
the agents-as-tools pattern of the OpenAI Agents SDK. AutoGen and LangGraph
snapshot state for resume and fork; neither merges state, and neither does
hen. The parent decides: promote or discard.

The model drives the branching, and the environment can redefine itself. The
order of the steps follows Autolith: journal the proposal, install the
definition, run the checks, write a replay script, commit to a private
history, and select the new state atomically (`docs/architecture.org`, "Live
mutation and generations"). Hen keeps the order and changes the mechanism: a
branch proposes a generation, the parent checks it, and the ledger records
the result.

Promotion is parent-side. The parent applies the child's patch, reruns the
gate, then publishes the generation atomically and drains in-flight calls. The
generation graph is the audit log: every promote and discard records its parent
and its evidence.

Self-modification touches the tool layer only: tool modules and the registry.
The bridge, the loop, and the provider code stay fixed. New capabilities need an
explicit approval. Sandbox practice elsewhere (Claude Code, Codex) limits
damage; it does not validate correctness.

A generation may carry a lessons record in the Reflexion style: short
plain-text advice for the next branch. It never gates promotion.

No production system was found that lets an agent rewrite its own toolchain
and rolls back bad generations automatically. Treat that as unverified. Keep
the gate explicit and the ledger intact.

## Sources

- Vendored CHICKEN manual chapters: `vendors/chicken-core/manual/Embedding`,
  `vendors/chicken-core/manual/C interface`,
  `vendors/chicken-core/manual/Module (chicken foreign)`.
- [OpenAI function calling](https://platform.openai.com/docs/guides/function-calling)
- [CodeAct](https://arxiv.org/abs/2402.01030)
- [smolagents](https://huggingface.co/docs/smolagents/reference/agents)
- [Anthropic code execution](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/code-execution-tool)
- [z.ai function calling](https://docs.z.ai/guides/capabilities/function-calling)
- [Voyager](https://arxiv.org/abs/2305.16291)
- [Darwin Gödel Machine](https://arxiv.org/abs/2505.22954)
- [DGM overview, Sakana AI](https://sakana.ai/dgm/)
- [Reflexion](https://arxiv.org/abs/2303.11366)
- [AutoGen save and load state](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/state.html)
- [LangGraph persistence](https://langchain-ai.github.io/langgraph/concepts/persistence/)
- [OpenAI Agents SDK multi-agent](https://openai.github.io/openai-agents-python/multi_agent/)
- [Claude Code sandboxing](https://docs.claude.com/en/docs/claude-code/sandboxing)
- [OpenAI Codex security](https://developers.openai.com/codex/security)
- [Autolith architecture](https://github.com/lambda-symbolics/autolith/blob/master/docs/architecture.org)
- [opencode zen](https://opencode.ai/docs/zen)

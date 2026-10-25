# Plugin API — big picture

Draft for discussion. It states what a plugin author writes and what hen
promises around it. It sits on top of `docs/agent-loop.md` phases #3, #5, and
#8, and it does not change the ownership split there.

## 1. What a plugin is

A plugin is a Scheme module in a generation that contributes tools. It declares
the tools it offers, the configuration those tools need, and the capabilities it
expects to use. It never owns the process, the event loop, provider sockets, or
the UI (`docs/libraries.md`, governing rule).

The plugin layer is the only mutable layer. The bridge, the loop, and the
provider code stay fixed (`docs/agent-loop.md`, Phase #8). Self-modification
means: add, change, or remove tool modules and the registry.

Two kinds share one contract:

| Kind | Runtime | Status |
|---|---|---|
| In-process plugin | the hen process, the single CHICKEN runtime | first cut |
| Worker plugin | its own process, its own runtime, framed messages | later |

The manifest and the tool surface are the same for both, so a plugin can move
from in-process to worker without changing what it declares.

## 2. The six surfaces

| Surface | Direction | Fixed by |
|---|---|---|
| Declaration | plugin -> hen | the forms in section 3 |
| Documentation | plugin -> agent | the records in sections 4, 5, 6 |
| Registry | hen -> provider | `hen:tools/list`, section 7 |
| Call | provider -> plugin | `hen:tools/call!` plus `hen:tools/fetch`, sections 8, 9 |
| Capability | plugin -> host services | `foreign-value` plus `foreign-lambda`, section 10 |
| Configuration | host -> plugin | `config`, section 11 |

Everything else is out of the API. A plugin has no handle on the transcript,
the provider, or another plugin's state. The UI reads the same documentation
store the agent reads, so it needs no surface of its own.

## 3. Declaration forms

A plugin is one module. Its body registers tools at load time.

```scheme
(module hen-files
  (import hen-plugin)
  (config workspace-root :sources (env "HEN_WORKSPACE"))

  (register-module! #:summary "Workspace file reads and writes.")

  (register-tool! 'read-file
    #:summary "Read one UTF-8 file from the workspace."
    #:when "Any file read. Paths are workspace-relative."
    #:description "Returns the whole file as text."
    #:usage "A path outside the workspace root fails. Binary text comes back as-is."
    #:examples '("read-file \"src/main.zig\"" "read-file \"docs/x.md\" (limit 4096)")
    #:contract '(returns: text, errors: ("Error: missing argument path"),
                 effects: (fs-read), idempotent: #t)
    #:shape '(type object
              (properties (path (type string) (description "path inside the workspace"))
                          (limit (type integer) (description "max bytes")))
              (required path))
    #:handler (lambda (args)
                (read-file-body (arg args 'path) (arg args 'limit 'default 65536)))))
```

`register-module!` opens the module record, and the `register-tool!` and
`register-skill!` calls that follow belong to it. Load is serialized, so one
module is open at a time. A plugin that never calls `register-module!` fails
the gate lint: a tool with no module has no place in the help index.

Decided: registration is a procedure call, not a macro. Exported syntax needs a
compiled module (`manual/Modules:95-100`), and the first cut loads interpreted
sources. A `define-tool` macro can arrive later, when plugins are compiled with
`csc -o`.

Decided: loading a module does not publish anything by itself. A plugin that
imports another module does not export that module's tools. The registry and the
documentation store are built only from `register-module!`, `register-tool!`, and
`register-skill!` calls, so the gate's registry diff (Phase #8) has an explicit
list to compare.

The registry side stays as Phase #5 wrote it:

```text
hen:tools/list         -> ((name description shape) ...)
hen:tools/call!        -> stored result length
hen:tools/fetch        -> stored result string
hen:eval!              -> stored result length
```

`hen:eval!` (added 2026-10-25, hen-82r.8) takes the model's action expression
as one string and is the dispatch entry the two-eval call path runs; see the
agent-loop doc, Call path.

A plugin handler receives one datum and returns one value. Tool state lives in
the module and persists for the session (Phase #5, Inside the runtime).

## 4. Documentation records and progressive disclosure

A description string is not enough for an agent environment. Every registered
item carries a record, and the record is read in levels.

Three kinds: module, tool, skill. A record holds:

- `summary` — one line, at most 120 characters, what the item is
- `when` — one line, at most 80 characters, when to reach for it and when not to
- `description` — short prose, at most 600 characters
- `usage` — detail: preconditions, failure modes, cost, caveats, at most 2 KiB
- `examples` — concrete calls, at most 4
- `contract` — `returns`, `errors` (the observation prefixes it can produce),
  `effects` (the capabilities it uses), `idempotent`
- `links` — related tool and skill names

| Level | Content | Where it appears | Budget |
|---|---|---|---|
| L0 | name, summary, `when` — for the one action tool entry | every request, in the provider `tools` array | 240 characters per entry, 8 KiB for the whole array |
| L1 | name, summary, description, for one module's tools and skills | `hen-help <module>` | 600 characters per entry |
| L2 | the full record: description, usage, examples, contract, links | `hen-help <module> <item>` | 4 KiB per item |
| L3 | a skill body | `hen-skill` | 8 KiB per skill |

Decided: L0 is the floor, not a choice. The provider array is not per-tool:
since hen-82r.8 it carries one action tool entry (the string-parameter
action tool, section 7), so the level budget is about that entry, not about
listing every tool. Where the L0 catalog text enters the request — the system
prompt or the single entry's description — is Phase #6 wiring (hen-82r.4).
The `description` field holds `summary` plus `when`. Everything above L0 is
pulled, and a pull costs the session tokens once.

Decided: the documentation store is Scheme state and crosses the ordinary
bridge. There is no second channel and no C value; a help answer is an
observation like any other. The registry entries behind the levels are:

```text
hen:docs/list          -> ((kind name summary) ...) for one module, or all modules
hen:docs/get           -> the full record for one item
hen:docs/skill         -> the body of one skill
```

Decided: doc text lives in the sources, not beside them. Long prose goes in a
docs module (`hen-docs-*`) whose body only registers records, so tool modules
stay code-focused. The generation stays a self-contained snapshot, and a doc
change shows up in the gate diff as a doc change.

## 5. Skills

A skill is a guide for using several tools together: a workflow, a checklist, or
a house rule. It is not executable.

```scheme
(register-skill! 'edit-a-file
  #:summary "Change one file: read it, write it, re-read it."
  #:when "Before any file edit. Never edit a file you have not read."
  #:tools '(read-file write-file read-file)
  #:steps '("read the file" "write the new text" "read it back and check")
  #:body "Read first, so the text you write is based on the real file. ...")
```

A skill record holds `summary`, `when`, `tools`, `steps`, and `body`. `steps` is
the short form the help index shows; `body` is the L3 text.

Decided: a skill body crosses as text, once, and stays in the transcript. A
skill runs nothing and gates nothing; it is advice the model may ignore. The
gate checks that every name a skill lists exists in the registry, so a skill
cannot point at a tool that is not there.

## 6. The help surface

Two built-in tools, present in every generation:

```text
hen-help   args: module? item?   -> L0 all modules | L1 one module | L2 one item
hen-skill  args: module skill    -> L3, the body
```

`hen-help` with no arguments lists modules and their summaries. With a module it
lists that module's tools and skills with small descriptions, so the module's
whole interface comes up in one call. With a module and an item it returns the
full record. Every answer ends with the line that names what can be pulled next,
so the ladder is self-describing and the model does not have to be told it.

Decided: the meta tools are Scheme tools in a built-in module (`hen-core`), not
special host code. Dispatch stays uniform: the model calls a tool, the
environment runs it, an observation comes back. The registry diff excludes them.

Decided: one store, two consumers. The terminal reads the same levels:
`/help`, `/help <module>`, `/help <module> <item>`, `/skill <module> <skill>`.
The UI renders L0 as a list and pulls L1 to L3 on a key press. Nothing in the UI
path bypasses the store.

Decided: pulled docs are history. A level the model pulled stays in the
transcript as an observation, and the system prompt says not to pull a record it
already holds. The meta tools' own descriptors count against the L0 array
budget.

## 7. Tool descriptors and names

- `name` is what the provider sees. Charset `[A-Za-z0-9_.-]`, at most 64
  characters, unique across the generation. The gate rejects a duplicate, so a
  new plugin cannot shadow an existing tool.
- Convention: `<module>-<tool>`, so `hen-files-read-file`. The registry does not
  add the prefix itself; a plugin that wants a bare name must be the only
  holder of it.
- `description` is model-facing. At L0 it holds `summary` plus `when`, at most
  240 characters (section 4). The whole tool list is sent every round, so the
  level budget keeps the request bounded.
- ~~`parameters` is the JSON Schema the bridge renders from the declared
  shape.~~ Removed 2026-10-25 (hen-82r.8): there is no per-tool provider
  `parameters`; the bridge renders no schemas. The provider array carries one
  string-parameter action tool whose parameter is the model's Scheme
  expression, and its exact packaging is Phase #6 wiring (hen-82r.4). The
  name and description rules above stay as catalog rules for that entry.

Decided: the registry is frozen for a request. Tools change only at a
generation swap, which is when `tools` is recomputed (Phase #5). A plugin that
registers during a run changes the next request, not the current one.

## 8. Arguments

Decided 2026-10-25 (hen-82r.8): model actions are Scheme expressions. The
structured JSON argument surface here — §7 parameter schemas and this
section's shape subset and datum conversion — is removed. The bridge renders
no schemas and converts no JSON. Reasons: no consumer survives the channel
decision, and the JSON layer is an intermediary the operator removed. The
recovery point for the removed code and text is hen-82r.3 (commit 6fd7c3b).
What carries over: the registry entries in section 3, the handler contract
below (`arg`, untrusted text, handler validates), and `#:shape` as declared
registry and documentation data.

Removed 2026-10-25 (hen-82r.8). None of that runs now. The bridge used to
render a declared shape as a JSON Schema subset — types `string`, `number`,
`integer`, `boolean`, `array`, `object`, `enum`; keywords `type`,
`properties`, `items`, `enum`, `description`, `required`; no `$ref`,
`anyOf`, `allOf`, `oneOf` — and convert parsed JSON to the datum the handler
reads with `arg`: object to alist, array to list, string to an escaped
literal, keys to symbols, keys that do not read back as symbols inside
pipes. The action is now the model's Scheme expression as one string; see
the agent-loop doc, Call path.

Decided: arguments are untrusted text. A handler validates before it acts. The
bridge does not type-check against the shape, so a shape is a promise to the
model, not a guard.

## 9. Observations

One call moves one action in and one observation out. The observation is text.

- A string result crosses as-is. Any other value crosses as a written
  representation (Phase #5, Results out).
- Cap per observation: 64 KiB default. A tool may declare a larger cap in its
  registration. Past the cap, the bridge truncates and appends
  `[truncated N bytes]`.
- A failure is an observation that starts with `Error: `. Reserved prefixes:
  `Error:`, and later `Timeout:` and `Canceled:`. Errors never cross as
  conditions.
- A tool that must return JSON to the model uses the small pure-Scheme JSON
  writer named in Phase #5. `medea` stays out.
- No streaming observations. A tool that produces a large result trims it
  inside Scheme before it returns.

## 10. Capabilities and host services

First cut: no sandbox (Phase #7). A plugin has the permissions of the hen
process.

The manifest declares what a plugin intends to use:

```scheme
(capabilities fs-read fs-write process)
```

Declared now, enforced later. The declaration has two uses today: the gate
reports it, and the later sandbox reads it. Enforcement belongs to the
environment, not to the plugin.

Host services reach Scheme through `foreign-value` plus
`foreign-declare "extern ..."`, and `foreign-lambda`
(`manual/Module (chicken foreign):34-48,131-133`). Decided: the first cut has
no Scheme-to-C callbacks. `define-external` and `C_callback` keep a C frame
alive across a non-local exit and can crash on a thread switch
(`manual/Module (chicken foreign):211-232`). So a plugin may call a host
function; a host function never calls back into Scheme.

That rules out one shape: a plugin cannot ask the host to run a long job and
report progress. It calls the host synchronously and gets the result. A
blocking host call blocks the green threads, which is acceptable because the
environment serves one request at a time (Phase #5, Threads).

The host service set for M5: process spawn, search (`fff` or `rg`), git. Each
is one C function behind a Scheme wrapper. Nothing else.

## 11. Configuration

Phase #8's `define-config` becomes the plugin-facing form `config`:

```scheme
(config provider-api-key :sources (env "FOOBAR_API_KEY"))
```

- The host resolves the source at load time and passes the value in. A plugin
  never calls the operating system for configuration; the host owns the process.
- A non-secret value is a literal in the generation source. A secret stays in
  the process environment and never enters a generation file.
- A later generation may override a constant. The override belongs to the
  snapshot, so the ledger keeps both values.
- A resolved constant is an ordinary module value, and code passes it on as a
  parameter. A plugin has no "secret" type; it holds a string.
- A plugin that needs a value it did not declare gets a load failure, not an
  empty string. The manifest lists the config names a plugin needs, so the gate
  fails a missing value before the runtime starts.

A generation may also declare a provider: endpoint, key source, model set. The
wire format stays in Zig (Phase #3). First cut: the provider kinds are the ones
Zig implements, so a declaration selects a kind rather than defining one.

## 12. Loading a generation

A generation directory:

```text
generations/<id>/
  manifest.sexp   api version, modules, config names, capabilities, caps, parent
  sources/        Scheme modules, in load order
  tests/          tool tests, run by the gate
  lessons.sexp    optional Reflexion-style advice for the next branch
```

Load order, all on the runtime thread:

1. read the manifest, check the api version
2. resolve the config values
3. load the sources in order
4. build the registry and the documentation store from the registration calls
5. run `hen:tools/list` and `hen:docs/list`
6. run the gate, including the documentation lint

The mechanism is `repository-path` plus `require`, which loads `<id>.so` or
`<id>.scm` from the repository path (`manual/Module (chicken load):57-70`).
`provided?` makes a load idempotent. Compiled units come from `csc -o`, and a
plugin that links its own foreign C code loads with
`set-dynamic-load-mode! 'local` so its C symbols do not leak into the next
unit (`manual/Module (chicken load):110-120`).

## 13. The gate

Deterministic, in this order: module load, `hen:tools/list`, documentation lint,
a smoke eval, the generation's tool tests, the registry diff against the parent,
resource caps. Run it twice when a result is close (Phase #8). A model critic may
attach evidence; it never decides.

The documentation lint is part of the gate: every tool and skill has a summary
and a description, every record is inside its level budget, every `links` and
`tools` name resolves, and every registered item has a module.

The registry diff reports added, removed, and changed tools, tools and skills
whose records changed, and it excludes the meta tools. A doc-only change is a
cheap promotion: the lint and the budgets still run, and the diff says the code
did not move.

## 14. Promotion, and where isolation comes from

A load is a side effect that cannot be undone. Modules control visible bindings
only, and redefinition modifies the original imported definition
(`manual/Modules:101-105`). So an in-process "swap" leaves the old generation's
bindings and state inside the same runtime, and CHICKEN has no shutdown
(`src/environment/root.zig`, Phase #5).

Two shapes:

| Shape | Swap | Gate | Cost |
|---|---|---|---|
| A: one process | re-load sources into the live runtime | runs in the live runtime | state bleed; a failed candidate poisons the runtime |
| B: process per generation | new process with a fresh runtime, framed channel | runs in the candidate process | process machinery, drain, retirement |

B is the honest one: a fresh runtime is the only real isolation, and Phase #3
already says isolation comes from processes. A is enough while hen runs one
agent in one process and no promotion tool exists.

Decided: A through M4. B before `spawn`, `promote`, and `discard` become
model-facing tools, because promotion without isolation is not promotion.
The framed protocol follows `docs/libraries.md` 1.4: length-prefixed JSON
frames over a pipe or Unix socket, request routing, cancellation, health
checks, drain.

## 15. Versioning

The manifest declares an `api` version. The bridge advertises its protocol
version at load. A mismatch is a load failure.

The stable names are the registry entries above: `hen:tools/list`,
`hen:tools/call!`, `hen:tools/fetch`, `hen:eval!`, `hen:docs/list`,
`hen:docs/get`, `hen:docs/skill`, plus `hen:tools/load` when the swap lands
(Phase #9). An api bump is required when any of these change, when the
observation prefixes change, or when a record kind gains or loses a field.
The shape subset is no longer an api surface: it was removed with the JSON
argument surface (2026-10-25, hen-82r.8), so it cannot trigger a bump.

## 16. Non-goals

A plugin cannot: hold a `C_word`, open a socket, own a thread, call the OS for
configuration, write a secret into a generation, change the bridge or the loop,
delete a generation, register a provider kind Zig does not implement, read
another plugin's state, run a skill, or gate its own documentation.

The branching tools are host tools, not plugins. They touch generations, which
Zig owns.

## 17. Open questions

1. Is `register-tool!` the final form, or should the first cut commit to a
   `define-tool` macro and require compiled plugin sources from the start?

> It's the final form for this state. Nothing is really set it stone.

2. Tool naming: keep `<module>-<tool>` as a convention, or make the registry
   enforce a prefix?

> Make the registry enforce the prefix

3. Shape subset: keep the JSON Schema subset, or define a smaller Scheme shape
   form and render the Schema from it? The subset above is a walking subset;
   nesting depth is undecided.

> I **do not** want any JSON in this. Please use scheme or sexp for serialisation.

Decided 2026-10-25 (hen-82r.8): agreed and settled harder than this question
asked — the JSON subset is removed outright; the argument on the action path
is the model's Scheme expression as one string. `#:shape` stays as declared
registry and documentation data, never rendered as JSON (section 8).

4. Observation cap: 64 KiB default per call, or a per-session budget shared by
   the calls of one round?

> Well some tools probably use a lot more memory than others. So default pre-
> allocation with the ability to grow? What do we want to actually use from
> the tool call? If we extract what we want and persist the tool call to a file
> when can throw the whole call away -> Arena Allocator for the duration of
> the tool call.

5. Capabilities declared but unenforced: worth writing now, or do they arrive
   with the sandbox?

> Lets defer any security. We can continue with definitng capabilities until
> a concept is designed.

6. Providers declared in a generation: needed now, or does provider selection
   stay outside the plugin layer?

> I would like the provider configuration in a plugin. This mean we want to
> declare interference endpoints and what compatible API to use, then the
> efficiently implemented zig provider will use that configuration to access
> the endpoint.

7. Timing of shape B. What is the smallest step that makes promotion real: one
   worker process for a candidate, or a worker process per instance?

> Maybe we should seperate between small subagents that don't have soverigninty
> over themselves from more general subagents. When an instance spawns an agent
> that can't spawn other agents and is only there to scout and report back to
> the main process it should probably run in an in-process thread. A larger
> orchestration might need independent instances that communicate via message
> passing to their parent. The parent would then also need to monitor these.
>
> **This should definetly go into the second iteration**

8. Long host jobs: synchronous host calls only (section 10), or a deferred
   request shape where a plugin returns "run this" and the host resumes?

> Plugins **always** run in the instances environment. Not their own environments.

9. Lessons records: visible to the next branch's plugins, or only to the parent
   instance?

> Lets defer the whole lesson thing to a separate design document.

10. Levels: is four enough, and does L1 need to exist at all, or can `hen-help`
   jump straight from a module list to a full record?

> I think help should have several uses:
>  - get general API interface of a module (internal or plugins)
>  - search for symbols with nearest string search (fff?) so that even when
>    the search term doesnt quite fit it still finds the function
>  - pull up the description for a single function with different levels
>    of documentation. even showing the described source code when requested

11. `hen-help` and `hen-skill` as two tools, or one tool with modes? Two costs
   two array entries at L0; one costs one but carries a mode argument.

> as per the last answer we should probably enrich ´help´ in general

12. Does a skill carry a checklist the model is expected to follow, or only
   prose? A checklist is inspectable, and nothing checks that it was followed.

> tool skills should be guidence on how to use the tool so that the tool calls
> dont loop with slightly wrong parameter usage

13. Level budgets: fixed numbers, or a per-generation budget declared in the
   manifest and checked by the gate?

> Let's not do budgets right now

14. Should the argument shape shrink at L0 for tools with many arguments, so a
   wide tool costs less in every request, with the full shape at L2?

> What does that mean?

(The question meant rendering a condensed schema at L0 and the full one at
L2 so a wide tool costs less per request.) Decided 2026-10-25 (hen-82r.8):
moot — there is no per-tool provider argument shape anymore. The one action
tool entry is constant across requests; its cost does not vary with tool
complexity (section 7).

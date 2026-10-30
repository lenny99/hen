# Plugin API — big picture

Draft for discussion. It states what a plugin author writes and what hen
promises around it. It sits on top of `docs/agent-loop.md` phases #3, #5, and
#8, and it does not change the ownership split there. The open questions in
section 17 are answered in place (2026-10-25); the body carries those answers.

## 1. What a plugin is

A plugin is a Scheme source file in a generation that contributes tools. It
declares the tools it offers, the configuration those tools need, and the
capabilities it expects to use. It never owns the process, the event loop, provider sockets, or
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

A plugin is one flat source file. Its body registers tools at load time, and
it carries no module wrapper — the loader supplies the wrapper, its
imports, and the `register-module!` call.

```scheme
(define workspace-root
  (config 'workspace-root #:sources (env "HEN_WORKSPACE")))

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
              (read-file-body (arg args 'path) (arg args 'limit 'default 65536))))
```

Decided 2026-10-25 (open question 2): the loader owns the module wall. The
manifest names each module, and the host loads each source file through a
module wrapper — the body-as-single-string include form
(`manual/Modules:82-83`). The wall matters
because `hen:eval!` evaluates the model's expressions in the interaction
environment (agent-loop doc, Phase #7): inside the wrapper, a plugin's
internals are invisible there, and the model's only route to a tool is
`hen:tools/call!`. Modules are visibility control only, not separate
environments (`manual/Modules:101-105`), so the wrapper is a wall, not
isolation; isolation stays a process property (section 14).

Decided 2026-10-30 (hen-82r.6): the loader's actual wrapper is
`(module <name> * (import scheme (chicken base) (chicken condition)
(chicken port) hen-plugin) (register-module! '<name>) (include "<abs path>")
(and #t))` (`src/environment/env.zig`, `formatWrapper`). Three refinements
versus the malformed first-cut form `(module <name> (import hen-plugin)
(include "<path>"))`, where `(import hen-plugin)` sat in the export-list
position — the second operand of `module` is the export list
(`manual/Modules:46-47`): imports come first, because interpreted module
bodies perform `import` at transform time and the chicken sexports are the
only source of `define`/`include`; `(register-module! '<name>)` sits inside
the wrapper, because `##sys#current-module` is not bound at body-run time —
the loader calls it on the plugin's behalf, and the plugin source carries
only `register-tool!` and `config` calls; and the `(and #t)` tail keeps
`Interpreter.eval`'s written result tiny. Separately, `*` in the
export-list position is broken in interpreted modules for real exports
(verified against the vendored runtime in a probe), so it is used only for
these never-imported wrappers and every module other code imports uses an
explicit export list. Registration forms also stay toplevel-visible:
`scheme/env.scm` ends in a toplevel `(import hen)`, so bare registration
names work on the host and test path — model reachability of those forms is
an accepted looseness until a sandbox exists.

Decided 2026-10-25 (open question 2): the module name lives once, in the
manifest. `register-module!` opens the record of the module the loader named,
and the `register-tool!` and `register-skill!` calls that follow belong to it.
Load is serialized, so one module is open at a time. A source that loads
without its module opened fails the gate lint: a tool with no module has no
place in the help index (section 13 records today's lint scope).

Decided 2026-10-25 (open question 2): the registry qualifies short tool names
with the manifest's module name, so `register-tool! 'read-file` inside
`hen-files` publishes `hen-files-read-file`. A non-prefixed tool name cannot be
expressed, and cross-module collisions are impossible because module names are
unique in the manifest. The gate still rejects a module that registers the same
short name twice (section 7).

Decided (open question 1): registration is a procedure call, not a macro.
Exported syntax needs a compiled module (`manual/Modules:95-100`), and the first
cut loads interpreted sources. A `define-tool` macro can arrive later, when
plugins are compiled with `csc -o`.

Decided: loading a module does not publish anything by itself. A plugin cannot
reach another plugin's bindings: each source loads inside its own wrapper. The
registry and the documentation store are built only from `register-module!`,
`register-tool!`, and `register-skill!` calls, so the gate's registry diff
(Phase #8) has an explicit list to compare.

Decided 2026-10-25: a module splits across files with `include-relative`,
never with `load`. An included file's forms splice into the enclosing module
body at expansion time — same namespace, same wall — and the path resolves
relative to the including file, so a published plugin works from any process
directory (`manual/Module (chicken base):1145-1150`). The manifest names only
the entry file; the includes are the plugin's own business, and the
generation's content hash covers every included file. `load` escapes the wall:
it hands each expression to `eval` in the interaction environment, where the
model can reach the names, so the gate lint rejects a `load` call in plugin
sources (that particular check is not implemented yet — section 13 lists
today's lint scope). A module body sees only what it imports, so
`hen-plugin` re-exports `include-relative`.

Decided 2026-10-25: a plugin may import its declared dependencies — egg units
the runtime resolved for the generation (section 12) — and imported bindings
are visible only inside the plugin's module (`manual/Modules:133-140`). An
import the plugin never declared fails at load, because the scoped
`repository-path` holds exactly what the manifest resolved.

The registry side stays as Phase #5 wrote it:

```text
hen:tools/list         -> ((name summary when description shape) ...)
hen:tools/call!        -> stored result length
hen:tools/fetch        -> stored result string
hen:eval!              -> stored result length
```

`hen:eval!` (added 2026-10-25, hen-82r.8) takes the model's action expression
as one string and is the dispatch entry the two-eval call path runs; see the
agent-loop doc, Call path.

A plugin handler receives one datum and returns one value. Tool state lives in
the plugin and persists for the session (Phase #5, Inside the runtime).

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

| Level | Content | Where it appears |
|---|---|---|
| L0 | name, summary, `when` — for the one action tool entry | every request, in the provider `tools` array |
| L1 | name, summary, description, for one module's tools and skills | `hen-help <module>` |
| L2 | the full record: description, usage, examples, contract, links | `hen-help <module> <item>` |
| L3 | a skill body | `hen-skill` |

Decided: L0 is the floor, not a choice. The provider array is not per-tool:
since hen-82r.8 it carries one action tool entry (the string-parameter
action tool, section 7), so the level system is about that entry, not about
listing every tool. Decided (hen-82r.4, 2026-10-25): the catalog text enters
the single entry's `description`, not the system prompt — the shipped
description is 214 characters and states the one-expression contract directly.
Assembly from `register-tool!` records waits for Phase #8; the registry is
empty today. The `description` field holds `summary` plus `when`. Everything
above L0 is pulled, and a pull costs the session tokens once.

Decided 2026-10-25 (open question 13): no budgets for now. The sizes next to
the record fields above are author guidance; the gate does not enforce them,
and no per-generation budget is declared.

Decided: the documentation store is Scheme state and crosses the ordinary
bridge. There is no second channel and no C value; a help answer is an
observation like any other. The registry entries behind the levels are:

```text
hen:docs/list          -> ((kind name summary) ...) for one module, or all modules
hen:docs/get           -> the full record for one item
hen:docs/skill         -> the body of one skill
```

Decided: doc text lives inside the generation snapshot, not beside it. Short
text goes inline in a registration call; long prose goes in a docs module
(`hen-docs-*`) whose body only registers records, or in a text file a
registration pulls with `#:body-from` (section 5), so tool modules stay
code-focused. The generation stays a self-contained snapshot, and a doc
change shows up in the gate diff as a doc change.

## 5. Skills

A skill is guidance, not code. Most skills are usage guidance for one tool,
written so the model's calls do not loop on slightly wrong parameter usage
(open question 12). A skill can also be a guide for a module or a workflow, or
a house rule. It is not executable. The dispatch preflight of section 8 stops
the type-shaped loops; a skill's guidance covers the semantic ones the shape
cannot express.

```scheme
(register-skill! 'edit-a-file
  #:summary "Change one file: read it, write it, re-read it."
  #:when "Before any file edit. Never edit a file you have not read."
  #:tools '(read-file write-file read-file)
  #:steps '("read the file" "write the new text" "read it back and check")
  #:body-from "skills/edit-a-file.md")
```

A skill record holds `summary`, `when`, `tools`, `steps`, and a body. `steps`
is the short form the help index shows; the body is the L3 text. The body is
`#:body` inline, for a short one, or `#:body-from "<path>"`, and exactly one of
the two is required.

Decided 2026-10-25: with `#:body-from` the store reads the named file as text,
once, at load. The file is never evaluated and never included; its contents
become the record's L3 body, and help serves it like any other record. The
path resolves against the plugin's root directory — the directory that holds
`plugin.sexp` in a published plugin (section 12) — which the loader provides
for the duration of the load. The gate lint checks the file exists and lies
inside the generation snapshot. So a plugin's prose lives in a `skills/`
folder as ordinary text files — skimmable, git-reviewable, no escaping inside
string literals — and docs modules (`hen-docs-*`) pull their long prose the
same way.

Decided: a skill body crosses as text, once, and stays in the transcript. A
skill runs nothing and gates nothing; it is advice the model may ignore. The
gate checks that every name a skill lists exists in the registry, so a skill
cannot point at a tool that is not there.

## 6. The help surface

Two built-in tools, present in every generation:

```text
hen-help   args: module? item? | search term   -> L0 all modules | L1 one module | L2 one item | search hits
hen-skill  args: module skill                  -> L3, the body
```

Decided 2026-10-25 (open questions 10, 11): two tools, and `hen-help` is
enriched. It serves three uses:

- a module's general interface, for internal modules and plugin modules alike.
  With no arguments it lists modules and their summaries; with a module it
  lists that module's tools and skills with small descriptions, so the
  module's whole interface comes up in one call.
- symbol search. Given a search term, it finds items by nearest-string match,
  so a term that does not quite fit still finds the item. The search runs the
  M5 search host service (`fff` or `rg`, section 10).
- one item's record at its levels. With a module and an item it returns the
  full record, and at the deepest level it shows the item's source: the
  generation snapshot holds the sources, so the store can attach the
  definition text.

`hen-skill` stays separate: general skills — guides for modules, workflows, or
house rules — have larger bodies, and the two uses stay two tools (open
question 11). Every answer ends with the line that names what can be pulled
next, so the ladder is self-describing and the model does not have to be told
it.

Decided: the meta tools are Scheme tools in a built-in module, not special host
code. The built-in module is named `hen`, so its tools publish as `hen-help` and
`hen-skill` under the qualified naming of section 7. Dispatch stays uniform:
the model calls a tool, the environment runs it, an observation comes back.
The registry diff excludes them.

Decided: one store, two consumers. The terminal reads the same levels:
`/help`, `/help <module>`, `/help <module> <item>`, `/skill <module> <skill>`.
The UI renders L0 as a list and pulls L1 to L3 on a key press. Nothing in the UI
path bypasses the store.

Decided: pulled docs are history. A level the model pulled stays in the
transcript as an observation, and the system prompt says not to pull a record it
already holds.

## 7. Tool descriptors and names

- `name` is what the provider sees. The registry publishes the manifest's
  module name plus the registered short name, so `register-tool! 'read-file`
  inside `hen-files` publishes `hen-files-read-file`. The prefix is structural
  (section 3): a bare name cannot be expressed, a module cannot collide with
  another module's tools, and the gate rejects the same short name twice in
  one module. The published name's charset is `[A-Za-z0-9_.-]`, at most 64
  characters.
- `description` is model-facing. At L0 it holds `summary` plus `when`
  (section 4); the size is author guidance, not a gate check.
- ~~`parameters` is the JSON Schema the bridge renders from the declared
  shape.~~ Removed 2026-10-25 (hen-82r.8): there is no per-tool provider
  `parameters`; the bridge renders no schemas. The provider array carries one
  string-parameter action tool whose parameter is the model's Scheme
  expression. Its packaging landed 2026-10-25 (hen-82r.4): wire name
  `hen-eval` (within the charset above), one required string parameter
  `source`, the schema rendered in the provider layer, no registry
  involvement. The name and description rules above stay as catalog rules for
  that entry.

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

Decided 2026-10-25: arguments are untrusted text, and the guard lives inside
the environment. The bridge still renders no schemas and converts nothing; the
handler still validates before it acts. What is new, on Nodecode prior art
(`nlk:define-contract` refuses a misfit call before the body runs and answers
with a repair): `hen:tools/call!` checks the arguments against the declared
`#:shape` in Scheme, before the handler runs. A call that does not fit is an
`Error: ` observation with a repair hint — what was expected, what arrived,
retryable — so a wrong-parameter call fails in one round instead of looping.
This supersedes the earlier line that a shape is a promise to the model, not a
guard: the shape is a guard at dispatch, and the handler validates what the
shape cannot say.

## 9. Observations

One call moves one action in and one observation out. The observation is text.

- A string result crosses as-is. Any other value crosses as a written
  representation (Phase #5, Results out).
- Decided 2026-10-25 (open question 4): the memory of a call is an arena
  allocator, live for the duration of the tool call. It starts with a default
  pre-allocation and grows on demand. The call extracts what the request needs;
  the observation that enters the transcript is capped at 64 KiB default (a
  tool may declare a larger cap in its registration). Past the cap, the bridge
  persists the full result to a host-owned session file and the observation
  references the path, so the model can read it back. The arena is freed when
  the call ends: the whole working memory of the call is thrown away.
- A failure is an observation that starts with `Error: `. Reserved prefixes:
  `Error:`, and later `Timeout:` and `Canceled:`. Errors never cross as
  conditions.
- Decided 2026-10-25 (open question 3): no JSON on this path. A tool that must
  return structured data returns a written s-expression; serialization is
  sexps, not JSON. `medea` stays out. The pure-Scheme JSON writer named in
  Phase #5 is superseded (section 17, question 3).
- No streaming observations. A tool that produces a large result trims it
  inside Scheme before it returns.

## 10. Capabilities and host services

First cut: no sandbox (Phase #7). A plugin has the permissions of the hen
process.

The manifest declares what a plugin intends to use:

```scheme
(capabilities fs-read fs-write process)
```

Decided 2026-10-25 (open question 5): enforcement is deferred. Security waits
until a sandbox concept is designed; until then the capability vocabulary keeps
developing with the tools that use it. The declaration has two uses today: the
gate reports it, and the later sandbox reads it. Enforcement belongs to the
environment, not to the plugin.

Host services reach Scheme through `foreign-value` plus
`foreign-declare "extern ..."`, and `foreign-lambda`
(`manual/Module (chicken foreign):34-48,131-133`). Decided: the first cut has
no Scheme-to-C callbacks. `define-external` and `C_callback` keep a C frame
alive across a non-local exit and can crash on a thread switch
(`manual/Module (chicken foreign):211-232`). So a plugin may call a host
function; a host function never calls back into Scheme.

Decided 2026-10-25 (open question 8): plugins always run in the instance's
environment, never their own. That rules out one shape: a plugin cannot ask the
host to run a long job and report progress. It calls the host synchronously and
gets the result. A blocking host call blocks the green threads, which is
acceptable because the environment serves one request at a time (Phase #5,
Threads).

The host service set for M5: process spawn, search (`fff` or `rg`), git. Each
is one C function behind a Scheme wrapper. Nothing else.

## 11. Configuration

Phase #8's `define-config` becomes the plugin-facing procedure `config`:

```scheme
(define provider-api-key
  (config 'provider-api-key #:sources (env "FOOBAR_API_KEY")))
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

Decided 2026-10-30 (hen-82r.6): `config` is a procedure, not syntax —
interpreted modules cannot export syntax (open question 1) — and the keyword
is spelled `#:sources`, CHICKEN keyword syntax; `env` is a constructor
returning a source descriptor. The host pre-pops every resolved value
before any module load with `(begin (hen:config/set! "var" "value") #t)`
(`src/environment/env.zig`, one `ConfigValue { source_var, value }` per
resolved declaration; the `begin ... #t` wrap exists because
`hen:config/set!` itself returns the whole new config table). Resolution is
literal-wins with env fallback during manifest preparation
(`src/generations/load.zig`, `prepare`): a declaration with neither a
literal nor an env source fails `ConfigUnresolved` before any runtime
starts, as does a declaration with no env value for its source. A
declaration carrying only a literal publishes nothing beyond an ordinary
module value; a source with no host value still raises at `config`-call
time inside module load (`scheme/env.scm`, `resolve-config`), so a
generation loaded without the host's pre-population fails loudly.

Decided 2026-10-25 (open question 6): provider configuration is declared in a
generation. A plugin declares the endpoint(s), the compatible API to use, the
key source, and the model set; the efficiently implemented Zig provider takes
that configuration and uses it to access the endpoint. The wire format stays in
Zig (Phase #3): a declaration selects an API kind Zig implements rather than
defining one.

## 12. Loading a generation

A generation root:

```text
generations/
  ledger.sexp      append-only event log, one five-field tuple per line:
                   (generation ...) (parent ...) (hash ...) (status
                   candidate|promoted|failed|discarded) (evidence ...)
  active           the active generation id; repointing writes .active.tmp
                   and renames — that rename is rollback
generations/<id>/
  manifest.sexp    api version, modules (name, entry file, in load order),
                   config decls (name, env source, secret flag, literal),
                   capabilities, caps, provider block, parent, content hash
  sources/         Scheme sources, in load order
  tests/           tool tests, run by the gate
  registry.sexp    written when the gate passes: one parenthesized
                   five-field record per line — the parent diff's baseline
                   (section 13)
  lessons.sexp     deferred (open question 9) — a separate design document
                   owns the concept; nothing writes it yet
```

Preparation (`src/generations/load.zig`, `prepare`) happens before any
runtime starts: read and validate the manifest, check its api against
`environment.bridge_api_version` (`"1"`, `src/environment/env.zig`), and
check each module name — charset `[A-Za-z0-9_.-]`, non-empty, `hen-plugin`
reserved; the 64-character limit is the published-tool-name rule and lives
in the registry, not the manifest check. The config values then resolve
(section 11). The runtime then runs, all on the runtime thread:

1. `Env.init`/`Env.initGeneration` loads the host material `scheme/env.scm`
   first — the registry, never a generation source
2. eval `(begin (hen:config/set! ...) #t)` per resolved value
3. eval the module wrapper per manifest entry, in manifest order, entry
   paths absolute (section 3); the registry and the documentation store
   build from the registration calls, and the gate runs (section 13)

Decided 2026-10-30 (hen-82r.6): `Env.initGeneration` splits into `Env.init`
(host material only) plus `Env.loadGeneration` (the config values, then the
module wrappers in order), so the gate can run `loadGeneration` against a
bare checkpointed runtime (`src/environment/env.zig`). Host-material loading
is cwd-relative: `Env.init` loads `scheme/env.scm` and the vendored
chicken-core import stubs relative to the working directory, so hen needs a
repo-root-like cwd even though generation module paths are absolute.

Interpreted sources load through the module wrapper of section 3: the host
evals one wrapper per manifest entry, in order. Compiled units come from
`csc -o` and load with
`repository-path` plus `require`, which loads `<id>.so` or `<id>.scm` from the
repository path (`manual/Module (chicken load):57-70`); `provided?` makes a
compiled load idempotent. A plugin that links its own foreign C code loads
with `set-dynamic-load-mode! 'local` so its C symbols do not leak into the
next unit (`manual/Module (chicken load):110-120`).

A published plugin is a git repository, and the generation is materialized
from it — the runtime never loads from a checkout. A plugin repo follows one
layout:

```text
my-plugin/            (a git repository)
  plugin.sexp         module list (names, entry files, load order) and the
                      plugin's dependency declarations
  src/                Scheme sources (entry file first)
  skills/             skill bodies, pulled by #:body-from
  tests/              tool tests
```

`plugin.sexp` is the minimal descriptor the generation builder reads — the
same module-listing shape as the manifest's. A repo can contribute one module
or several (a tool module plus a `hen-docs-*` module). The builder pins a
commit, verifies it — HEAD is the pinned commit, no symlinks, no submodules,
no hooks run — copies the repo's files into the generation directory
preserving its layout, and records the module entries in the manifest plus the
repo URL and commit in the ledger. The content hash covers everything
materialized, the gate runs on the snapshot, and the pin plus copy is the wall
against upstream drift: a force-push or a moved repo cannot change what a
generation runs. Publishing a repo is `git push`; consuming it is a manifest
reference with a repository and a full commit id.

Decided 2026-10-25: eggs belong to the runtime; plugins declare dependencies
like normal programs. A plugin is not an egg, and an egg is not a plugin — an
egg that wants to expose tools is wrapped by a thin plugin that imports it and
registers. A plugin declares what it needs, in `plugin.sexp` or in its manifest
module entry, and never fetches anything itself. The runtime owns the rest:

- The egg store is content-addressed. The runtime fetches a pinned egg, builds
  it, and keeps it under its content hash; generations referencing the same
  pin share one entry. A pin is a git repository at a full commit id, or an
  official egg-server release, where the version string is the pin. Git pins
  get the same verification as plugin repos — HEAD is the pinned commit, no
  symlinks, no submodules, no hooks run.
- Resolution happens once, when a candidate generation is assembled. The
  runtime reads the plugins' declarations, resolves them and their transitive
  closure from the eggs' own descriptions, retrieves what the store lacks,
  and writes the resolved pins — egg name, source pin, content hash — into
  the manifest and the ledger. One version per unit per generation: two
  plugins wanting different versions is a build failure, not a selection.
- Loads replay. The host sets `repository-path` to exactly the referenced
  store entries, hash-checked, so an import the plugin never declared is a
  load failure — the same shape as an undeclared config value (section 11) —
  and no load touches the network. An egg upgrades only through a new
  generation.
- The gate runs on the assembled environment: the smoke eval and the tool
  tests exercise the imports, and the gate report gains a dependencies line
  alongside the registry diff.
- Staging: pure-Scheme eggs enter the store as interpreted sources —
  `require` tries `<id>.so` then `<id>.scm` (`manual/Module (chicken
  load):57-70`) — so the first cut needs no toolchain. Compiled units come
  later, with two verification items: exact-ABI builds against the vendored
  CHICKEN, and dynamic loading into the embedded static host.
- The fetch, build, and store are Zig-side runtime machinery (Phase #3: git
  and process spawning are Zig's); CHICKEN only sees the scoped
  `repository-path`. `hen-plugin` itself is host material, versioned with the
  bridge (section 15), never a store unit.

The generation carries resolved references, not egg bytes; a bundle step that
copies the referenced entries into a self-contained generation directory is
possible later, for portability.

## 13. The gate

Deterministic, in this order: module load, `hen:tools/list`, documentation lint,
a smoke eval, the generation's tool tests, the registry diff against the parent,
resource caps. Run it twice when a result is close (Phase #8). A model critic may
attach evidence; it never decides.

Decided 2026-10-30 (hen-82r.6): as shipped (`src/generations/gate.zig`,
`run`) the order is exact. `hen:registrations/checkpoint!` runs before the
candidate's modules load, then: module load, the `hen:tools/list` parse
(five-field records), the documentation lint, the smoke eval `(+ 1 2)`
returning `3`, the tool tests in sorted order, the registry diff, and
`hen:registrations/undo!` always — the checkpoint/undo pair is one rollback
contract, because a gate that does not checkpoint before load leaves a
mid-load failure's registrations in the registry. Resource caps are dropped
(open question 13): "run it twice when a result is close" has no closeness
metric in a deterministic pass/fail gate — it targets future scored, noisy
evaluation. The manifest's capabilities line is reported, not enforced
(open question 5). The report is a deterministic one-line gate sexp appended
to `ledger.sexp` as the candidate's evidence (section 12). The diff excludes
`hen-`-prefixed structural names and is evidence only — it never decides
pass or fail. After the gate the live registry reverts to the bare
pre-candidate state, not to the active generation: re-registering a name
and then undoing would delete the active generation's entries.

The documentation lint is part of the gate: today's checks are that every
tool is module-prefixed with a manifest module name and carries a non-empty
summary and a description; skills lint later (no skills exist). Budget
checks are dropped for now (open question 13).

The registry diff reports added, removed, and changed tools, tools and skills
whose records changed, and it excludes the `hen-` structural names. A
doc-only change is a cheap promotion: the lint still runs, and the diff says
the code did not move.

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

Decided 2026-10-25 (Nodecode prior art, `nle:define-cell` stop semantics —
clauses install in the order written and come off in reverse, a start that
fails halfway leaves nothing): registration builds an undo list. The
registration calls of a module install in order; a load that fails rolls them
back in reverse, so the registry and the documentation store stay consistent
even in shape A. This rolls back registrations, not Scheme bindings — nothing
undoes those — so a failed candidate still leaves its bindings and state in
the runtime. The undo list keeps the gate's view coherent; shape B stays the
real isolation.

Decided: A through M4. B before `spawn`, `promote`, and `discard` become
model-facing tools, because promotion without isolation is not promotion.
The framed protocol follows the shape of `docs/libraries.md` 1.4:
length-prefixed frames over a pipe or Unix socket, request routing,
cancellation, health checks, drain — with s-expression payloads, not JSON
frames (open question 3).

Decided 2026-10-25 (open question 7): the worker work lands in the second
iteration, and the design separates two subagent kinds. Small scouts without
sovereignty over themselves — they cannot spawn agents, they only scout and
report back to the main process — run in an in-process thread. A larger
orchestration runs as independent instances that communicate with their parent
by message passing, and the parent monitors them. Scout threads want srfi-18,
an egg in this tree rather than part of the static runtime (agent-loop doc,
Phase #5, Threads); how a scout thread runs belongs to that later design.

## 15. Versioning

The manifest declares an `api` version. The bridge advertises its protocol
version at load. A mismatch is a load failure.

The stable names are the registry entries above: `hen:tools/list`,
`hen:tools/call!`, `hen:tools/fetch`, `hen:eval!`, `hen:docs/list`,
`hen:docs/get`, `hen:docs/skill`, plus `hen:tools/load` when the swap lands
(Phase #9). An api bump is required when any of these change, when the
observation prefixes change, or when a record kind gains or loses a field.
The shape form left the api surface with the JSON argument removal
(2026-10-25, hen-82r.8) and returned to it with the dispatch preflight
(2026-10-25, section 8): a change to what a shape can express changes dispatch
behavior, and that is a bump.

Decided 2026-10-30 (hen-82r.6): the names above are the model-facing stable
names. `hen:config/set!`, `hen:registrations/checkpoint!`,
`hen:registrations/undo!`, and `hen:assert!` are bridge-versioned host
material of `scheme/env.scm`, not model-facing: they configure the runtime
and execute the gate, and a change to any of them requires a bump the same
way — generation loading already compares the manifest api against
`environment.bridge_api_version` (`"1"`). `hen:tools/load` is unchanged and
stays Phase #9. The `hen:assert!` contract for test authors:
`(hen:assert! value expected)` compares the written forms of both
arguments, returns `#t` on a match, and raises on a mismatch; the
written-form comparison equates `"42"` and `42`, so the expected value may
be written as either.

## 16. Non-goals

A plugin cannot: hold a `C_word`, open a socket, own a thread, call the OS for
configuration, fetch its own dependencies, write a secret into a generation,
change the bridge or the loop, delete a generation, register a provider kind
Zig does not implement, read another plugin's state, run a skill, or gate its
own documentation.

The branching tools are host tools, not plugins. They touch generations, which
Zig owns.

## 17. Open questions, answered 2026-10-25

1. Is `register-tool!` the final form, or should the first cut commit to a
   `define-tool` macro and require compiled plugin sources from the start?

> It's the final form for this state. Nothing is really set it stone.

Decided 2026-10-25: `register-tool!` is the form for this state, and nothing
is set in stone — a `define-tool` macro remains a later option when plugin
sources compile (section 3).

2. Tool naming: keep `<module>-<tool>` as a convention, or make the registry
   enforce a prefix?

> Make the registry enforce the prefix

Decided 2026-10-25: settled through the module-system discussion — the loader
owns the wall, and the registry qualifies short tool names with the manifest's
module name, so `<module>-<tool>` is structural rather than linted (sections 3,
7). Plugin authors never see the CHICKEN module system.

3. Shape subset: keep the JSON Schema subset, or define a smaller Scheme shape
   form and render the Schema from it? The subset above is a walking subset;
   nesting depth is undecided.

> I **do not** want any JSON in this. Please use scheme or sexp for serialisation.

Decided 2026-10-25 (hen-82r.8): agreed and settled harder than this question
asked — the JSON subset is removed outright; the argument on the action path
is the model's Scheme expression as one string. `#:shape` stays as declared
registry and documentation data, never rendered as JSON (section 8).

The answer's reach goes past the action path: tool results and worker frames
carry s-expressions too (sections 9, 14). The JSON-writer line in the
agent-loop doc, Phase #5, is superseded by this decision and needs the same
edit there. The `#:shape` line above is itself superseded in part by the
dispatch preflight of section 8: the shape is still never rendered as JSON,
but it is no longer documentation data only.

4. Observation cap: 64 KiB default per call, or a per-session budget shared by
   the calls of one round?

> Well some tools probably use a lot more memory than others. So default pre-
> allocation with the ability to grow? What do we want to actually use from
> the tool call? If we extract what we want and persist the tool call to a file
> when can throw the whole call away -> Arena Allocator for the duration of
> the tool call.

Decided 2026-10-25: an arena allocator scopes the memory of one tool call —
default pre-allocation, growth on demand, freed at call end. The observation
that enters the transcript is capped; the bridge persists the oversized
result to a file and the observation references the path (section 9).

5. Capabilities declared but unenforced: worth writing now, or do they arrive
   with the sandbox?

> Lets defer any security. We can continue with definitng capabilities until
> a concept is designed.

Decided 2026-10-25: enforcement deferred. The capability vocabulary keeps
developing in manifests until a sandbox concept is designed (section 10).

6. Providers declared in a generation: needed now, or does provider selection
   stay outside the plugin layer?

> I would like the provider configuration in a plugin. This mean we want to
> declare interference endpoints and what compatible API to use, then the
> efficiently implemented zig provider will use that configuration to access
> the endpoint.

Decided 2026-10-25: provider configuration is declared in a generation —
endpoints, compatible API kind, key source, model set — and the Zig provider
consumes it (section 11).

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

Decided 2026-10-25: second iteration. Scouts without sovereignty run
in-process and report back; orchestrations run as independent instances with
message passing, monitored by their parent (section 14).

8. Long host jobs: synchronous host calls only (section 10), or a deferred
   request shape where a plugin returns "run this" and the host resumes?

> Plugins **always** run in the instances environment. Not their own environments.

Decided 2026-10-25: plugins always run in the instance's environment, never
their own (section 10).

9. Lessons records: visible to the next branch's plugins, or only to the parent
   instance?

> Lets defer the whole lesson thing to a separate design document.

Deferred 2026-10-25: lessons get a separate design document (section 12).

10. Levels: is four enough, and does L1 need to exist at all, or can `hen-help`
   jump straight from a module list to a full record?

> I think help should have several uses:
>  - get general API interface of a module (internal or plugins)
>  - search for symbols with nearest string search (fff?) so that even when
>    the search term doesnt quite fit it still finds the function
>  - pull up the description for a single function with different levels
>    of documentation. even showing the described source code when requested

Decided 2026-10-25: all three uses are `hen-help`'s — module interfaces
(internal and plugin), nearest-string symbol search, and item records with
source on request (section 6).

11. `hen-help` and `hen-skill` as two tools, or one tool with modes? Two costs
   two array entries at L0; one costs one but carries a mode argument.

> as per the last answer we should probably enrich ´help´ in general

Decided 2026-10-25: two tools. `hen-help` is the enriched one and carries the
larger descriptions of individual tools; `hen-skill` serves general skills —
guides for modules, workflows, and the like (sections 5, 6).

12. Does a skill carry a checklist the model is expected to follow, or only
   prose? A checklist is inspectable, and nothing checks that it was followed.

> tool skills should be guidence on how to use the tool so that the tool calls
> dont loop with slightly wrong parameter usage

Decided 2026-10-25: skills are usage guidance, written so calls do not loop
on slightly wrong parameter usage; general module and workflow guides are the
wider case (section 5). The dispatch preflight (section 8) attacks the same
failure mechanically.

13. Level budgets: fixed numbers, or a per-generation budget declared in the
   manifest and checked by the gate?

> Let's not do budgets right now

Decided 2026-10-25: no budgets now. Sizes are author guidance; the gate does
not check them (sections 4, 13).

14. Should the argument shape shrink at L0 for tools with many arguments, so a
   wide tool costs less in every request, with the full shape at L2?

> What does that mean?

(The question meant rendering a condensed schema at L0 and the full one at
L2 so a wide tool costs less per request.) Decided 2026-10-25 (hen-82r.8):
moot — there is no per-tool provider argument shape anymore. The one action
tool entry is constant across requests; its cost does not vary with tool
complexity (section 7).

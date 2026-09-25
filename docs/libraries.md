# Native library options for the coding harness

This document surveys libraries that can be integrated with the current
project shape:

- Zig is the native host and kernel.
- CHICKEN Scheme is the programmable Scheme environment.
- The executable should own the terminal UI, event loop, provider connections,
  tool processes, and module lifecycle.
- Scheme modules and tools should be replaceable without replacing the whole
  executable.

The current checkout targets Zig `0.16.0`. The vendored CHICKEN submodule
currently reports `6.0.1pre1` in `vendors/chicken-core/buildversion`. Treat the
vendored source and headers as authoritative when an API differs from older
CHICKEN documentation.

## Executive recommendation

Start with this split:

```text
Zig supervisor
├── terminal UI and event loop
├── provider transport
├── tool registry
│   ├── fff
│   ├── Tree-sitter
│   └── git
├── CHICKEN C bridge
│   └── one serialized Scheme execution context
└── module workers
    ├── generation N
    └── generation N+1
```

Recommended order:

1. CHICKEN C bridge with a narrow, stable interface.
2. `fff` behind a Zig search-backend interface.
3. Tree-sitter for structural code extraction.
4. `libcurl` on a dedicated provider transport thread or event-loop worker.
5. An FTXUI prototype for the polished TUI.
6. A framed pipe or Unix-socket protocol for module workers.
7. Generation-based module promotion and draining.
8. `libgit2` or `yyjson` only after measurements justify them.

Keep the transport and tool interfaces in Zig. Avoid making CHICKEN the owner
of the UI, provider sockets, or the complete module lifecycle.

## 1. Infrastructure

### 1.1 Provider HTTP and streaming

The kernel should expose a provider abstraction rather than exposing a
particular HTTP client to the rest of the system:

```text
Provider.stream(request) -> provider events
```

Useful event types are:

```text
request_start
text_delta
tool_call_delta
usage
provider_error
complete
```

The transport adapter should deliver byte chunks. A separate incremental
parser should handle SSE framing, JSON payloads, cancellation, and provider
errors. This keeps provider-specific details out of the UI and Scheme layers.

#### Zig `std.http` and `std.Io`

The Zig 0.16 standard library is the first thing to test. It avoids a native
dependency and fits the existing `std.Io`-based program structure.

Use it directly when the required provider behavior is limited to ordinary
HTTPS requests and incremental response delivery. Validate the exact 0.16
API locally with `zig std` and a small probe before designing around it.

Useful areas to verify:

- `std.http.Client`
- `std.Io`
- `std.json`
- `std.process`
- `std.DynLib`, if native modules are later loaded in-process

Reference:

- [Zig 0.16 standard-library documentation](https://ziglang.org/documentation/0.16.0/std/)

#### libcurl

[libcurl](https://curl.se/libcurl/) is the safest first external transport
choice for a production harness. It offers a mature C API, TLS backends,
connection reuse, proxy support, HTTP/2 support when built with an appropriate
backend, and a multi interface for concurrent or cancellable transfers.

The multi interface is a better fit than repeatedly using
`curl_easy_perform` for long-lived streaming requests. A practical initial
arrangement is:

1. A dedicated transport worker owns a `curl_multi` handle.
2. Provider callbacks copy bytes into Zig-owned buffers.
3. The worker posts normalized provider events to the supervisor queue.
4. The UI and CHICKEN never block on network I/O.
5. Cancellation removes the easy handle and releases request state.

References:

- [libcurl C API](https://curl.se/libcurl/)
- [libcurl multi interface](https://curl.se/libcurl/c/libcurl-multi.html)
- [libcurl HTTP/2 documentation](https://curl.se/docs/http2.html)
- [libcurl copyright and license](https://curl.se/docs/copyright.html)

#### nghttp2

[nghttp2](https://nghttp2.org/documentation/apiref.html) is a protocol-level
HTTP/2 and HPACK library. It is useful when the harness needs direct control
over HTTP/2 streams, multiplexing, or flow control.

It is not a complete URL client. TLS, sockets, event-loop integration,
connection lifecycle, and higher-level request semantics still need to be
provided by the host. Use it after `libcurl` proves insufficient, not as the
first provider dependency.

References:

- [nghttp2 project](https://nghttp2.org/)
- [nghttp2 C API reference](https://nghttp2.org/documentation/apiref.html)
- [nghttp2 client tutorial](https://nghttp2.org/documentation/tutorial-client.html)

### 1.2 Event loop, processes, and PTYs

The current build already uses Zig process spawning for the vendored CHICKEN
build. That is enough to establish Zig's process API as the initial baseline.

Use one event-loop owner for the terminal, timers, child processes, and tool
I/O. Mixing several loops without a clear ownership boundary makes shutdown,
cancellation, and wakeups difficult.

#### libuv

[libuv](https://docs.libuv.org/en/v1.x/index.html) is a strong choice when the
harness needs broad platform support and mature handling of:

- subprocesses
- pipes and TTYs
- signals
- timers
- sockets
- filesystem events
- worker threads
- Windows support

It exposes a C API and documents a stable ABI across major releases.

References:

- [libuv documentation](https://docs.libuv.org/en/v1.x/index.html)
- [libuv design overview](https://docs.libuv.org/en/v1.x/design.html)
- [libuv repository](https://github.com/libuv/libuv)
- [libuv supported platforms](https://github.com/libuv/libuv/blob/v1.x/SUPPORTED_PLATFORMS.md)

#### libxev

[libxev](https://github.com/mitchellh/libxev) is a newer C-compatible event
loop with a proactor/completion-oriented design, timers, sockets, processes,
and a small runtime. It is attractive for a Linux/macOS-first harness.

Prefer it over libuv when modern completion semantics and a smaller runtime
matter more than broad platform coverage. Verify Windows support before making
it a cross-platform requirement.

#### PTY process host

A coding-agent harness will generally need a real pseudo-terminal rather than
ordinary pipes. Keep this behind a small `ProcessHost` interface:

```text
spawn
resize
write
read
wait
kill
```

On Unix, the baseline is `forkpty`/`openpty` with the chosen process API. On
Windows, use a ConPTY implementation. Provider and Scheme code should see only
the abstract process interface.

### 1.3 JSON

Start with Zig's `std.json`. It is sufficient for ordinary provider payloads
and avoids another native dependency.

If profiling shows that JSON parsing is material, evaluate
[yyjson](https://github.com/ibireme/yyjson). It exposes a compact C API and is
a reasonable candidate for a private static-library integration. Keep it
behind a Zig wrapper so its representation does not leak into the kernel.

Other JSON libraries can be revisited later:

- [cJSON](https://github.com/DaveGamble/cJSON)
- [simdjson](https://github.com/simdjson/simdjson)

### 1.4 Local IPC and RPC

The first worker protocol should be deliberately small:

```text
length-prefixed frames over stdin/stdout, a pipe, or a Unix socket
```

JSON frames are easy to inspect and debug. Move to a binary format only after
profiling shows that encoding or parsing is a bottleneck.

Possible later formats include CBOR or MessagePack. [Cap'n Proto](https://capnproto.org/)
is worth investigating if shared-memory IPC and capability-style RPC become
real requirements. gRPC is excessive for ordinary same-host module dispatch
unless its schema, streaming, and transport features are specifically needed.

Do not add a full RPC framework merely because the modules are modular. The
supervisor needs request routing, cancellation, health checks, and generation
promotion more than it needs a general RPC stack.

## 2. Coding tools

### 2.1 fff

`fff` is a good fit for the agent-oriented search path. Its project describes
features including typo-resistant path and content search, frequency-ranked
access, background watching, and an in-memory content index.

References:

- [fff upstream repository](https://github.com/dmtrKovalenko/fff)
- [fff MCP implementation](https://github.com/dmtrKovalenko/fff/tree/main/crates/fff-mcp)
- [RunMintOn/fff fork](https://github.com/RunMintOn/fff)

The upstream documentation clearly exposes an MCP-oriented interface. The C
SDK claim associated with the fork needs to be verified against the exact
revision used by the harness. For any selected revision:

- pin the commit;
- verify the public C header and linker recipe;
- verify ownership and string-lifetime rules;
- build it as a private dependency;
- wrap it in a C ABI shim;
- convert results immediately into Zig-owned data;
- marshal watcher callbacks onto a Zig queue;
- define cancellation and shutdown behavior.

Do not expose Rust types or internal Rust ABI symbols to Zig.

### 2.2 Tree-sitter

[Tree-sitter](https://tree-sitter.github.io/) is the strongest complementary
tool for code-aware behavior. The core runtime exposes a C API for parsers,
trees, queries, and cursors. It is useful for:

- symbol and declaration extraction;
- structural queries;
- function and class boundaries;
- language-aware code chunks;
- caller and callee discovery;
- syntax-aware edit validation.

References:

- [Tree-sitter C API header](https://github.com/tree-sitter/tree-sitter/blob/master/lib/include/tree_sitter/api.h)
- [Tree-sitter implementation overview](https://tree-sitter.github.io/tree-sitter/5-implementation.html)
- [Tree-sitter Zig bindings](https://github.com/tree-sitter/zig-tree-sitter)
- [Tree-sitter license](https://github.com/tree-sitter/tree-sitter/blob/master/LICENSE)

A useful division of labor is:

```text
fff         = which files and lines are relevant
Tree-sitter = what the code means structurally
```

Tree-sitter is a parser and query engine, not a replacement for filesystem
search or a semantic index.

### 2.3 Git

Start with the `git` executable for status, diffs, branches, worktrees, and
hooks. It respects the user's configuration and avoids linking another large
library into the kernel.

Consider [libgit2](https://libgit2.org/docs/reference/main/) later if
in-process repository queries become a measurable latency problem.

### 2.4 Other indexes and fallbacks

- [Universal Ctags](https://github.com/universal-ctags/ctags) is useful for
  broad language symbol indexing. Run it as a subprocess initially unless its
  embedding and licensing implications are acceptable.
- [`rg`](https://github.com/BurntSushi/ripgrep) and [`fd`](https://github.com/sharkdp/fd)
  are excellent subprocess fallbacks for fast filesystem and content search.
- A language server such as `clangd` or `ccls` can be integrated as an
  external analysis service when semantic diagnostics and navigation are
  needed.

## 3. TUI options

The TUI is a first-class interface requirement, so it should be tested early
rather than treated as a final polish pass.

### FTXUI

[FTXUI](https://github.com/ArthurSonzogni/FTXUI) is the first choice for a
polished terminal interface. It provides higher-level widgets, layout, input,
styling, and screen composition.

FTXUI is C++. Put a narrow C ABI around it instead of exposing C++ headers
throughout the Zig codebase:

```text
Zig supervisor -> C shim -> FTXUI
```

Reference:

- [FTXUI repository](https://github.com/ArthurSonzogni/FTXUI)
- [FTXUI documentation](https://arthursonzogni.com/FTXUI/)

### Native Zig candidates

[ZigTUI](https://github.com/adxdits/zigtui) has a documented composable API
with layouts, widgets, terminal restoration, raw mode, and buffer-oriented
rendering. It is a good candidate for a native prototype, but its release
history and long-term compatibility should be checked before making it a
foundation.

[TUI.zig](https://github.com/muhammad-fiaz/tui.zig) advertises Zig 0.16 support
and a broad terminal feature set. Its license and current API stability need
verification before dependency selection.

### Other options

- [cimgui](https://github.com/cimgui/cimgui): excellent immediate-mode UI and
  docking, but it requires more rendering/backend integration and is less
  naturally terminal-oriented.
- [ncurses](https://invisible-island.net/ncurses/): mature, portable C, but
  more layout and widget behavior must be written by the application.
- [Nuklear](https://github.com/Immediate-Mode-UI/Nuklear): convenient C
  embedding, but less compelling for a polished terminal coding harness.
- [libvterm](https://github.com/neovim/libvterm): terminal emulation rather than
  a widget toolkit; the repository was archived in June 2026 and should not be
  selected as the new TUI foundation.

## 4. CHICKEN embedding and hot swapping

The vendored `chicken.h` exposes the embedding entry points needed for a host
bridge, including:

```text
CHICKEN_run
CHICKEN_eval
CHICKEN_eval_string
CHICKEN_eval_to_string
CHICKEN_eval_string_to_string
CHICKEN_yield
```

The official manual documents the embedding and string-evaluation APIs:

- [CHICKEN embedding](https://wiki.call-cc.org/man/5/Embedding)
- [CHICKEN C interface](https://wiki.call-cc.org/man/5/C%20interface)
- [CHICKEN FFI reference](http://wiki.call-cc.org/manual/Interface%20to%20external%20functions%20and%20variables)
- [CHICKEN modules](http://wiki.call-cc.org/manual/Modules)
- [CHICKEN project](https://www.call-cc.org/)
- [CHICKEN source](https://code.call-cc.org/chicken-core/)

### C bridge

Create a small C shim with a stable Zig-facing interface rather than calling
CHICKEN directly throughout the Zig codebase:

```text
hen_scheme_create
hen_scheme_eval
hen_scheme_eval_string
hen_scheme_error
hen_scheme_yield
hen_scheme_destroy
```

The bridge should own:

- CHICKEN initialization;
- `C_word` lifetime;
- GC roots for values crossing the boundary;
- error conversion;
- callback registration;
- serialization of values returned to Zig.

Do not pass raw `C_word` values through the kernel. Convert values to owned
strings, bytes, or tagged messages while the Scheme value is rooted.

### Serialization rule

Use one designated Scheme execution context initially. Serialize host requests
into that context and emit events back to the Zig supervisor. Do not assume
that arbitrary host threads may call the embedding API concurrently.

`CHICKEN_yield` is useful for cooperative Scheme scheduling, but it is not a
complete host event-loop integration. External I/O should be owned by Zig or a
worker and delivered to Scheme through a controlled queue.

### Module generations

Ordinary `load`, `import`, and FFI shared-library loading should not be treated
as live upgrade mechanisms. They do not establish that already-running native
extensions can be safely replaced or unloaded.

Use explicit generations:

1. Build a module generation into an immutable artifact directory.
2. Start a fresh worker or execution context.
3. Run health and capability checks.
4. Atomically route new requests to the new generation.
5. Drain old requests.
6. Retire the old worker.

Use in-process native modules only with a versioned C ABI and an explicit
policy for library lifetime. Process workers are the safer choice for
fault-prone tools, long-running jobs, and untrusted Scheme extensions.

## 5. Suggested build order

1. CHICKEN C shim and versioned module descriptor.
2. fff behind a Zig `SearchBackend` interface.
3. Tree-sitter for structural code extraction.
4. `libcurl` transport on a dedicated worker.
5. FTXUI prototype.
6. Framed worker protocol.
7. Generation-based module supervisor.
8. `libgit2` or `yyjson` after measurements justify them.

The governing rule is:

> Zig owns the process, event loop, provider connections, tool lifetimes, and
> UI. CHICKEN owns programmable Scheme state inside a controlled bridge or
> worker.

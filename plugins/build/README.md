# Build plugin API

The build plugin operates on targets supplied by project/user configuration or
inferred by registered backends. Configure each target with:

| Field | Meaning |
| --- | --- |
| `name` | Target/configuration label |
| `backend` | Backend name or backend table |
| `binary` | Program to run/debug, relative to the project or absolute |
| `wd` | Program working directory, relative to the project |
| `run` | Program command vector or callback; `false` disables running |
| `build`, `clean` | Optional replacement callbacks; `false` disables the operation |

A replacement callback receives `(target, callback)` and reports an integer exit
status through `callback(status)`: zero succeeds, nonzero fails.

## Backends

A module in `plugins/build/backends` supplies `build(target, callback)` and
`clean(target, callback)`. Optional methods are `run(target)`, `can_build(target)`,
`can_clean(target)`, `can_run(target)` and `infer()`. Inference runs in an editor
coroutine and returns an array of targets. `priority` controls inference order;
the internal backend is the fallback when no other system is found.

Use `build.run_tasks(commands, on_done, on_line)` to execute an array of argument
vectors asynchronously. Concurrency is limited by `config.plugins.build.threads`.
The completion callback receives the aggregate exit status. Output callbacks
receive complete lines, including a final line without a newline. The default
output callback parses diagnostics into the build pane. Start failures and
cancellation complete once with a nonzero status. A completion callback may queue
the next stage of work.

`build.parse_compile_line(line)` returns plain text or a diagnostic table:
`{ severity, filename, line, column, message }`. Severity is `error`, `warning` or
`info`. Positions are numeric and Windows drive-letter filenames are supported.
Custom `error_pattern` and `file_pattern` configuration can override the compiler
patterns; captures should follow the same field order.

`build.set_targets(targets, backend)` resolves backend names. An optional backend
argument selects one backend for all targets. `build.set_target(index)` selects
a target and restores its recent arguments. `build.build`, `build.clean`,
`build.run`, `build.terminate` and `build.kill` control the current selection.
Check `build.is_running()` before starting another operation.

## Built-in backends

- Make detects `Makefile`, infers an `all` target, and uses the target name as the
  Make task. Cleaning runs `make clean`.
- CMake configures `build-<name>` unless `build_directory` is provided. Use
  `buildtype` for the CMake configuration and `build_target` for an optional
  target name. Supply `binary` explicitly for running/debugging.
- Meson configures `build-<name>` and discovers a default executable when `binary`
  is unset. Compilation and cleaning use `meson compile`, so the backend is not
  tied to invoking Ninja directly.
- Gradle detects the platform's wrapper and uses the target name as the task.
- Shell detects `build.sh` or uses explicit `command` and `arguments` fields.
- Internal discovers C/C++ files beneath `src`/`srcs`. It accepts `cc`, `cxx`,
  `ar`, `ld`, `cflags`, `cxxflags`, `ldflags`, `obj`, `ignored_files` and `files`.
  `files` maps source paths to per-file overrides and may include files outside
  `srcs`. Its `type` is `executable` (default), `static` or `shared`; shared builds
  should supply the compiler's required position-independent code flags.

See the repository README for example target configurations.

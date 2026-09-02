#!/usr/bin/env bash
# kit-detect.sh - language detection and gate planning.
#
# Every planner here is a PURE function: it takes a project root plus whatever
# facts were probed about the environment, and returns a plan. Nothing runs a
# build to decide what the gate should be. That is what makes the whole matrix
# testable from fixtures instead of requiring five toolchains installed.
#
# TWO RULES, applied everywhere below:
#
#   1. Never emit a command for a tool that was not observed to exist. A gate
#      that fails because ruff is not installed is a gate that fails for reasons
#      unrelated to the code, and people learn to ignore it.
#
#   2. When the build system genuinely cannot be inferred, emit NO command and
#      say so. A placeholder that fails honestly beats a guess that fails
#      confusingly - and beats an empty gate that fails silently, which is the
#      worst of the three because the project LOOKS wired.
#
# Gate plans are ARRAYS of single commands, not shell one-liners chained with
# `;` or `&&`. The runner executes them in order and stops at the first failure,
# so fail-fast is structural rather than something the shell has to be talked
# into.
#
# Plans are returned in globals rather than printed, for the same reason as
# elsewhere in the kit: commands contain every delimiter one might choose.

set -o pipefail

[[ -n "${_KIT_DETECT_SOURCED:-}" ]] && return 0
_KIT_DETECT_SOURCED=1

_kd_dir="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kit-common.sh
source "$_kd_dir/kit-common.sh"

# Directories that are never project-owned source. Shared by every detector so
# they cannot disagree about what "the project" means.
KIT_PRUNE_DIRS=(
  .git node_modules .venv venv env target build dist .tox .nox
  __pycache__ .mypy_cache .pytest_cache .ruff_cache bin obj
  vendor .gradle .idea .vscode .cache
)

# Build the `find` prune expression once.
_kit_find_prune() {
  local d out=''
  for d in "${KIT_PRUNE_DIRS[@]}"; do
    out+=" -name $d -o"
  done
  printf '%s' "${out% -o}"
}

# Does any file matching a glob exist within a bounded depth, ignoring the
# prune list? Bounded because an unbounded find on a monorepo is slow enough to
# be noticed at every session start.
kit_any_file() {  # kit_any_file <root> <maxdepth> <glob>...
  local root="$1" depth="$2"; shift 2
  local g
  for g in "$@"; do
    # shellcheck disable=SC2046
    if find "$root" -maxdepth "$depth" \( $(_kit_find_prune) \) -prune -o \
            -type f -name "$g" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

kit_first_file() {  # kit_first_file <root> <maxdepth> <glob> -> relative path
  local root="$1" depth="$2" glob="$3" hit
  # shellcheck disable=SC2046
  hit="$(find "$root" -maxdepth "$depth" \( $(_kit_find_prune) \) -prune -o \
         -type f -name "$glob" -print 2>/dev/null | sort | head -1)"
  [[ -z "$hit" ]] && return 1
  printf '%s' "${hit#"$root"/}"
}

# --- language detection -------------------------------------------------------
# Ordered most-specific first. Manifest files beat loose source files, because a
# repo with a Cargo.toml and one stray .cs file is a Rust project.
kit_detect_language() {  # kit_detect_language <root>
  local root="$1"

  [[ -f "$root/Cargo.toml" ]] && { printf 'rust'; return 0; }

  [[ -f "$root/go.mod" ]] && { printf 'go'; return 0; }

  if [[ -f "$root/CMakePresets.json" || -f "$root/CMakeUserPresets.json" || -f "$root/CMakeLists.txt" ]]; then
    printf 'cpp'; return 0
  fi
  # Meson and plain Make are real C/C++ build systems too; the planner below
  # distinguishes them.
  [[ -f "$root/meson.build" ]] && { printf 'cpp'; return 0; }

  if kit_any_file "$root" 3 '*.sln' '*.slnx' '*.csproj'; then printf 'cs'; return 0; fi

  if [[ -f "$root/pyproject.toml" || -f "$root/requirements.txt" \
        || -f "$root/setup.py" || -f "$root/setup.cfg" ]]; then
    printf 'python'; return 0
  fi

  [[ -f "$root/package.json" ]] && { printf 'node'; return 0; }

  # Loose source files, only once no manifest has claimed the repo.
  kit_any_file "$root" 4 '*.cs'                            && { printf 'cs';     return 0; }
  kit_any_file "$root" 4 '*.cpp' '*.cc' '*.cxx' '*.hpp' '*.c' && { printf 'cpp';    return 0; }
  kit_any_file "$root" 4 '*.py'                            && { printf 'python'; return 0; }
  kit_any_file "$root" 4 '*.rs'                            && { printf 'rust';   return 0; }
  kit_any_file "$root" 4 '*.go'                            && { printf 'go';     return 0; }
  kit_any_file "$root" 4 '*.sh' '*.bash'                   && { printf 'shell';  return 0; }

  printf 'unknown'
}

# --- plan output --------------------------------------------------------------
KIT_PLAN_FAST=()
KIT_PLAN_FULL=()
KIT_PLAN_NOTES=()
KIT_PLAN_CONFIGURED=0

_kit_plan_reset() { KIT_PLAN_FAST=(); KIT_PLAN_FULL=(); KIT_PLAN_NOTES=(); KIT_PLAN_CONFIGURED=0; }

# --- Node ---------------------------------------------------------------------
# Package manager from the lockfile, which is the only reliable signal.
# `packageManager` in package.json is honoured when present because it is
# explicit. Defaults to npm only when nothing says otherwise.
kit_node_package_manager() {  # kit_node_package_manager <root>
  local root="$1" pm=''
  if [[ -f "$root/package.json" ]]; then
    pm="$(jq -r '.packageManager // ""' "$root/package.json" 2>/dev/null)"
    case "$pm" in
      pnpm*) printf 'pnpm'; return 0 ;;
      yarn*) printf 'yarn'; return 0 ;;
      bun*)  printf 'bun';  return 0 ;;
      npm*)  printf 'npm';  return 0 ;;
    esac
  fi
  [[ -f "$root/pnpm-lock.yaml"    ]] && { printf 'pnpm'; return 0; }
  [[ -f "$root/yarn.lock"         ]] && { printf 'yarn'; return 0; }
  [[ -f "$root/bun.lockb"         ]] && { printf 'bun';  return 0; }
  [[ -f "$root/bun.lock"          ]] && { printf 'bun';  return 0; }
  [[ -f "$root/package-lock.json" ]] && { printf 'npm';  return 0; }
  printf 'npm'
}

kit_node_has_script() {  # kit_node_has_script <root> <name>
  [[ -f "$1/package.json" ]] || return 1
  jq -e --arg n "$2" '(.scripts // {}) | has($n)' "$1/package.json" >/dev/null 2>&1
}

# `npm init` writes "test": "echo \"Error: no test specified\" && exit 1".
# That script EXISTS but is a placeholder that always fails. Running it as a
# gate means the gate can never pass, which trains everyone to ignore the gate.
kit_node_placeholder_script() {  # kit_node_placeholder_script <root> <name>
  [[ -f "$1/package.json" ]] || return 1
  local body; body="$(jq -r --arg n "$2" '(.scripts // {})[$n] // ""' "$1/package.json" 2>/dev/null)"
  [[ "$body" == *'no test specified'* ]] && return 0
  [[ "$body" =~ ^[[:space:]]*exit[[:space:]]+1[[:space:]]*$ ]] && return 0
  return 1
}

kit_plan_node() {  # kit_plan_node <root>
  local root="$1"
  _kit_plan_reset
  local pm; pm="$(kit_node_package_manager "$root")"
  local runner="$pm run"

  # Only scripts that actually exist. Nothing is assumed into being.
  if kit_node_has_script "$root" typecheck; then
    KIT_PLAN_FAST+=("$runner typecheck"); KIT_PLAN_FULL+=("$runner typecheck")
  elif kit_node_has_script "$root" tsc; then
    KIT_PLAN_FAST+=("$runner tsc"); KIT_PLAN_FULL+=("$runner tsc")
  elif [[ -f "$root/tsconfig.json" ]]; then
    # A tsconfig means TypeScript is really here; npx --no-install resolves the
    # project's own compiler rather than assuming a global tsc or silently
    # downloading one mid-gate.
    KIT_PLAN_FAST+=('npx --no-install tsc --noEmit')
    KIT_PLAN_FULL+=('npx --no-install tsc --noEmit')
    KIT_PLAN_NOTES+=('tsconfig.json found but no typecheck script; using the project-local tsc via npx --no-install.')
  fi

  if kit_node_has_script "$root" lint; then
    KIT_PLAN_FAST+=("$runner lint"); KIT_PLAN_FULL+=("$runner lint")
  else
    KIT_PLAN_NOTES+=('No "lint" script in package.json, so no lint step was generated.')
  fi

  if kit_node_has_script "$root" test; then
    if kit_node_placeholder_script "$root" test; then
      KIT_PLAN_NOTES+=('package.json has the npm placeholder "test" script (always exits 1). It was deliberately NOT added to the gate - replace it with a real test command, then add it here.')
    else
      KIT_PLAN_FULL+=("$runner test")
    fi
  else
    KIT_PLAN_NOTES+=('No "test" script in package.json, so no test step was generated.')
  fi

  kit_node_has_script "$root" build && KIT_PLAN_FULL+=("$runner build")

  if (( ${#KIT_PLAN_FULL[@]} > 0 )); then
    KIT_PLAN_CONFIGURED=1
  else
    KIT_PLAN_NOTES+=('No runnable script was found in package.json. Add real typecheck/lint/test/build scripts, then put them in .claude/gate.json.')
  fi
}

# --- Python -------------------------------------------------------------------
# Find the interpreter this project actually uses. A project-local virtual
# environment wins over anything global - assuming a global `python` is how a
# gate ends up linting with the wrong dependencies installed, or with none.
kit_python_interpreter() {  # kit_python_interpreter <root>
  local root="$1" rel
  for rel in .venv/bin/python venv/bin/python env/bin/python .env/bin/python; do
    [[ -x "$root/$rel" ]] && { printf '%s' "$rel"; return 0; }
  done
  if [[ -n "${VIRTUAL_ENV:-}" && -x "$VIRTUAL_ENV/bin/python" ]]; then
    printf '%s' "$VIRTUAL_ENV/bin/python"; return 0
  fi
  # python3, not python: on a modern distro `python` may not exist at all.
  kit_have python3 && { printf 'python3'; return 0; }
  printf 'python'
}

# Ask the interpreter itself whether a module is importable. This is a PROBE,
# not a guess, and it is the caller's job - keeping the planner pure.
kit_python_has_module() {  # kit_python_has_module <interpreter> <module>
  local py="$1" mod="$2"
  [[ "$py" != /* && "$py" == */* ]] && py="./$py"
  "$py" -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('$mod') else 1)" \
    >/dev/null 2>&1
}

kit_plan_python() {  # kit_plan_python <root> <interpreter> <has_ruff 0|1> <has_pytest 0|1>
  local root="$1" py="$2" has_ruff="${3:-0}" has_pytest="${4:-0}"
  _kit_plan_reset
  local q="$py"
  [[ "$q" == *' '* ]] && q="\"$py\""

  # A syntax check is always generated - it needs nothing but the interpreter -
  # so there is a real gate even with no dev tooling installed.
  #
  # NOT `python -m compileall .`: compileall recurses into EVERYTHING under the
  # root including .venv, and it WRITES bytecode next to each source file. So a
  # project whose site-packages vendors an unparseable file (Python 2 sources
  # are still shipped in the wild) fails the gate for code it does not own, and
  # every gate run litters the tree with __pycache__. py-syntax.py compiles in
  # memory - no bytecode, no traversal of dependency trees.
  KIT_PLAN_FAST+=("$q .claude/py-syntax.py")
  KIT_PLAN_FULL+=("$q .claude/py-syntax.py")

  # --extend-exclude, not --exclude: --exclude REPLACES ruff's default exclude
  # list (.venv, node_modules, build, dist ...), which would quietly widen the
  # lint to the dependency tree. .claude/ is the kit's own runtime state - the
  # syntax step already skips it, and linting the checker the kit just wrote
  # there fails the project's gate for a file the project does not own.
  local ruff_cmd="$q -m ruff check --extend-exclude=.claude ."
  if (( has_ruff )); then
    KIT_PLAN_FAST+=("$ruff_cmd"); KIT_PLAN_FULL+=("$ruff_cmd")
  else
    KIT_PLAN_NOTES+=("Ruff is not installed in this interpreter, so no lint step was generated. Install it (\"$py -m pip install ruff\") and add \"$ruff_cmd\" to gate.json.")
  fi

  if (( has_pytest )); then
    KIT_PLAN_FULL+=("$q -m pytest -q")
  else
    # "pytest is not installed" is true but weak when the project plainly INTENDS
    # to run tests - a [tool.pytest.ini_options] section, a pytest dependency, or
    # a tests/ tree full of test_*.py. Saying only "not installed" for a project
    # with 20 test files reads as a shrug, and the gate silently validates less
    # than the author thinks. Detect the intent and make the note actionable.
    local intends_tests=0 evidence=''
    if [[ -f "$root/pyproject.toml" ]] \
       && grep -qE '^\s*\[tool\.pytest' "$root/pyproject.toml" 2>/dev/null; then
      intends_tests=1; evidence='pyproject.toml configures pytest'
    elif [[ -f "$root/pytest.ini" || -f "$root/tox.ini" ]]; then
      intends_tests=1; evidence='a pytest/tox config file is present'
    elif [[ -f "$root/pyproject.toml" ]] \
         && grep -qE '"pytest[><=~]' "$root/pyproject.toml" 2>/dev/null; then
      intends_tests=1; evidence='pyproject.toml declares a pytest dependency'
    elif kit_any_file "$root" 4 'test_*.py' '*_test.py'; then
      intends_tests=1; evidence='the project contains test files'
    fi

    if (( intends_tests )); then
      KIT_PLAN_NOTES+=("THIS PROJECT HAS TESTS THAT THE GATE IS NOT RUNNING: $evidence, but pytest is not importable by \"$py\", so no test step was generated. The gate therefore checks syntax only. Install pytest into the interpreter this project uses and re-run new-project.sh, or add \"$q -m pytest -q\" to gate.json yourself.")
    else
      KIT_PLAN_NOTES+=('pytest is not installed in this interpreter, so no test step was generated.')
    fi
  fi

  if [[ "$py" == 'python' || "$py" == 'python3' ]]; then
    KIT_PLAN_NOTES+=('No project virtual environment was found (.venv/venv/env); the gate uses whatever "python3" resolves to. Create a venv for reproducible results.')
  fi
  KIT_PLAN_NOTES+=('The syntax step (.claude/py-syntax.py) compiles project-owned sources in memory. It skips virtual environments, dependency stores, caches, VCS metadata and build output - it does not write bytecode and does not walk .venv.')
  KIT_PLAN_CONFIGURED=1
}

# The syntax checker written into a Python project as .claude/py-syntax.py.
# Emitted as text so the command in gate.json and the script it names are
# defined together, and so it can be tested without shelling out.
kit_python_syntax_checker() {
  cat <<'PYEOF'
"""Written by claude-agent-kit new-project.sh - do not edit here.

Syntax-checks every Python file this project owns. Replaces
`python -m compileall .`, which recursed into .venv and wrote bytecode, so a
project could fail its own gate over vendored code it does not own.
"""

import os
import sys

# The project root is this file's parent's parent (.claude/py-syntax.py), NOT
# the working directory - the gate must check the same tree wherever it is run
# from.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Directory names that are never project-owned Python source. This is ruff's
# default exclude set (so the syntax step and the lint step in the same gate
# agree), plus __pycache__ and the kit's own .claude/ runtime state.
PRUNE = frozenset([
    ".bzr", ".direnv", ".eggs", ".git", ".git-rewrite", ".hg",
    ".ipynb_checkpoints", ".mypy_cache", ".nox", ".pants.d", ".pyenv",
    ".pytest_cache", ".pytype", ".ruff_cache", ".svn", ".tox", ".venv",
    ".vscode", "__pypackages__", "_build", "buck-out", "build", "dist",
    "node_modules", "site-packages", "venv",
    "__pycache__", ".claude",
])


def is_virtualenv(path):
    """pyvenv.cfg is what actually makes a directory a virtual environment.
    Detecting it beats matching names: it catches venv313/.env-3.12/whatever,
    and it does not silence a package that happens to be called env."""
    return os.path.isfile(os.path.join(path, "pyvenv.cfg"))


def emit(text):
    try:
        print(text)
    except UnicodeEncodeError:
        enc = getattr(sys.stdout, "encoding", None) or "ascii"
        print(text.encode(enc, "replace").decode(enc, "replace"))


def main():
    bad = 0
    checked = 0
    for dirpath, dirnames, filenames in os.walk(ROOT):
        keep = []
        for name in dirnames:
            if name in PRUNE or name.endswith(".egg-info"):
                continue
            if is_virtualenv(os.path.join(dirpath, name)):
                continue
            keep.append(name)
        dirnames[:] = keep

        for name in filenames:
            if not name.endswith((".py", ".pyw")):
                continue
            full = os.path.join(dirpath, name)
            # Reported relative to the project root: a diagnostic carrying the
            # machine's absolute path is noise in an agent's context.
            rel = os.path.relpath(full, ROOT)
            checked += 1
            try:
                with open(full, "rb") as handle:
                    source = handle.read()
            except OSError as err:
                bad += 1
                emit("{}: could not be read: {}".format(rel, err))
                continue
            try:
                # compile(), not py_compile: in memory, no .pyc written.
                # Bytes in, so the PEP 263 coding cookie and a BOM are honoured
                # exactly as the interpreter would.
                compile(source, rel, "exec", dont_inherit=True)
            except SyntaxError as err:
                bad += 1
                emit("{}({}): {}".format(rel, err.lineno or 0, err.msg))
            except ValueError as err:
                bad += 1
                emit("{}: {}".format(rel, err))

    if bad:
        emit("{} file(s) failed to compile ({} checked).".format(bad, checked))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
}

# --- C++ ----------------------------------------------------------------------
# The first non-hidden build preset, or nothing.
kit_cmake_build_preset() {  # kit_cmake_build_preset <root>
  local root="$1" f name
  for f in CMakeUserPresets.json CMakePresets.json; do
    [[ -f "$root/$f" ]] || continue
    name="$(jq -r '[(.buildPresets // [])[] | select((.hidden // false) | not) | .name] | first // ""' \
            "$root/$f" 2>/dev/null)"
    [[ -n "$name" && "$name" != "null" ]] && { printf '%s' "$name"; return 0; }
  done
  return 1
}

# C++ has no single answer, so this refuses to guess.
#
#   CMake presets  -> use the preset. Unambiguous and reproducible.
#   CMakeLists.txt -> configure THEN build. Configuring first is what makes it
#                     safe not to assume a build/ directory already exists.
#   meson / Makefile -> use them.
#   anything else  -> emit nothing and say what to configure.
kit_plan_cpp() {  # kit_plan_cpp <root> <has_ctest 0|1>
  local root="$1" has_ctest="${2:-0}"
  _kit_plan_reset

  local preset
  if preset="$(kit_cmake_build_preset "$root")"; then
    KIT_PLAN_FAST+=("cmake --build --preset $preset")
    KIT_PLAN_FULL+=("cmake --build --preset $preset")
    # A test preset is a separate thing from a build preset; only add a test
    # step if the project actually declares tests.
    if (( has_ctest )); then
      KIT_PLAN_FULL+=("ctest --preset $preset --output-on-failure")
    else
      KIT_PLAN_NOTES+=('No test preset or CTest configuration was detected, so no test step was generated.')
    fi
    KIT_PLAN_NOTES+=("Using CMake build preset '$preset'.")
    KIT_PLAN_CONFIGURED=1
    return 0
  fi

  if [[ -f "$root/CMakeLists.txt" ]]; then
    KIT_PLAN_FAST+=('cmake --build build')
    KIT_PLAN_FULL+=('cmake -S . -B build')
    KIT_PLAN_FULL+=('cmake --build build')
    if (( has_ctest )); then
      KIT_PLAN_FULL+=('ctest --test-dir build --output-on-failure')
    else
      KIT_PLAN_NOTES+=('No enable_testing()/add_test() was found, so no ctest step was generated.')
    fi
    KIT_PLAN_NOTES+=('No CMake presets found. The FULL gate configures into ./build first, so it does not assume that directory already exists; the FAST gate builds only, assuming a prior configure.')
    KIT_PLAN_NOTES+=('If you use a specific generator or toolchain (Ninja, a cross toolchain file), put the exact commands in .claude/gate.json.')
    KIT_PLAN_CONFIGURED=1
    return 0
  fi

  if [[ -f "$root/meson.build" ]]; then
    KIT_PLAN_FAST+=('meson compile -C build')
    KIT_PLAN_FULL+=('meson setup --reconfigure build')
    KIT_PLAN_FULL+=('meson compile -C build')
    KIT_PLAN_FULL+=('meson test -C build')
    KIT_PLAN_NOTES+=('Meson project detected.')
    KIT_PLAN_CONFIGURED=1
    return 0
  fi

  if [[ -f "$root/Makefile" || -f "$root/makefile" || -f "$root/GNUmakefile" ]]; then
    KIT_PLAN_FAST+=('make')
    KIT_PLAN_FULL+=('make')
    # `make test` on a Makefile with no test target fails with "No rule to make
    # target", which is a gate failure that says nothing about the code. Only
    # add it when the target really exists.
    if grep -qE '^(test|check):' "$root/Makefile" "$root/makefile" "$root/GNUmakefile" 2>/dev/null; then
      KIT_PLAN_FULL+=('make test')
    else
      KIT_PLAN_NOTES+=('No "test" or "check" target found in the Makefile, so no test step was generated.')
    fi
    KIT_PLAN_NOTES+=('Plain Makefile detected. If the default target is not the right gate, put the real command in .claude/gate.json.')
    KIT_PLAN_CONFIGURED=1
    return 0
  fi

  KIT_PLAN_NOTES+=('C/C++ sources were found but no build system could be inferred (no CMakePresets.json, CMakeLists.txt, meson.build or Makefile).')
  KIT_PLAN_NOTES+=('The kit will not invent a build command. Put the real configure/build/test commands in .claude/gate.json.')
  KIT_PLAN_CONFIGURED=0
}

# --- Rust ---------------------------------------------------------------------
kit_plan_rust() {  # kit_plan_rust <root>
  _kit_plan_reset
  # Ordered cheapest-first so the fastest signal fails first.
  KIT_PLAN_FAST+=('cargo fmt --all -- --check')
  KIT_PLAN_FAST+=('cargo check --all-targets')
  KIT_PLAN_FULL+=('cargo fmt --all -- --check')
  KIT_PLAN_FULL+=('cargo clippy --all-targets')
  KIT_PLAN_FULL+=('cargo build')
  KIT_PLAN_FULL+=('cargo test')
  KIT_PLAN_NOTES+=('Raw cargo/rustc diagnostics are preserved - no output filter is applied, because a repair needs the full error.')
  KIT_PLAN_NOTES+=('Clippy warnings do not fail the gate by default. To make them fail, change the clippy line in gate.json to "cargo clippy --all-targets -- -D warnings".')
  KIT_PLAN_CONFIGURED=1
}

# --- Go -----------------------------------------------------------------------
kit_plan_go() {  # kit_plan_go <root>
  _kit_plan_reset
  KIT_PLAN_FAST+=('gofmt -l .')
  KIT_PLAN_FAST+=('go vet ./...')
  KIT_PLAN_FULL+=('go vet ./...')
  KIT_PLAN_FULL+=('go build ./...')
  KIT_PLAN_FULL+=('go test ./...')
  # gofmt -l PRINTS offending files and still exits 0, so as written it is a
  # reporting step, not a gate. Say so rather than letting it look enforced.
  KIT_PLAN_NOTES+=('"gofmt -l ." lists unformatted files but exits 0, so it reports rather than fails. To enforce it, use: test -z "$(gofmt -l .)"')
  KIT_PLAN_CONFIGURED=1
}

# --- .NET ---------------------------------------------------------------------
kit_plan_dotnet() {  # kit_plan_dotnet <root>
  local root="$1"
  _kit_plan_reset
  local target='.' sln
  if sln="$(kit_first_file "$root" 3 '*.sln')"; then target="$sln"
  elif sln="$(kit_first_file "$root" 3 '*.slnx')"; then target="$sln"; fi
  [[ "$target" == *' '* ]] && target="\"$target\""

  # --nologo keeps the banner out of the diagnostics; -clp:ErrorsOnly keeps
  # MSBuild's output to what actually failed.
  KIT_PLAN_FAST+=("dotnet build $target --nologo -clp:ErrorsOnly")
  KIT_PLAN_FULL+=("dotnet build $target --nologo -clp:ErrorsOnly")

  # Only add a test step if there is something to test. `dotnet test` on a
  # solution with no test project succeeds vacuously and looks like coverage.
  local has_tests=0
  kit_any_file "$root" 4 '*Tests.csproj' '*Test.csproj' && has_tests=1
  if (( ! has_tests )); then
    # shellcheck disable=SC2046
    if find "$root" -maxdepth 4 \( $(_kit_find_prune) \) -prune -o -type f -name '*.csproj' -print 2>/dev/null \
       | head -40 | xargs -r grep -lEi 'Microsoft\.NET\.Test\.Sdk|xunit|nunit|MSTest' 2>/dev/null | grep -q .; then
      has_tests=1
    fi
  fi
  if (( has_tests )); then
    KIT_PLAN_FULL+=("dotnet test $target --nologo")
  else
    KIT_PLAN_NOTES+=('No test project was detected, so no "dotnet test" step was generated. Add one when you add tests.')
  fi
  KIT_PLAN_CONFIGURED=1
}

# --- shell --------------------------------------------------------------------
kit_plan_shell() {  # kit_plan_shell <root> <has_shellcheck 0|1>
  local root="$1" has_sc="${2:-0}"
  _kit_plan_reset
  # `bash -n` is a parse check that needs nothing installed, so there is always
  # a real gate. It is a SYNTAX gate only and says so.
  KIT_PLAN_FAST+=('.claude/sh-syntax.sh')
  KIT_PLAN_FULL+=('.claude/sh-syntax.sh')
  if (( has_sc )); then
    KIT_PLAN_FULL+=("find . -path ./.git -prune -o -name '*.sh' -print0 | xargs -0 -r shellcheck")
  else
    KIT_PLAN_NOTES+=('shellcheck is not installed, so no lint step was generated. Install it and add a shellcheck step to gate.json.')
  fi
  KIT_PLAN_NOTES+=('The syntax step runs "bash -n" over project-owned scripts. That catches parse errors, not logic errors.')
  KIT_PLAN_CONFIGURED=1
}

kit_shell_syntax_checker() {
  cat <<'SHEOF'
#!/usr/bin/env bash
# Written by claude-agent-kit new-project.sh - do not edit here.
# Parse-checks every shell script this project owns. `bash -n` catches syntax
# errors that would otherwise only surface the first time a script runs.
set -uo pipefail
ROOT="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bad=0
checked=0
while IFS= read -r -d '' f; do
  checked=$((checked+1))
  if ! err="$(bash -n "$f" 2>&1)"; then
    bad=$((bad+1))
    rel="${f#"$ROOT"/}"
    # bash -n prints the ABSOLUTE path it was given, so the raw message carries
    # the machine's full path twice over. That is noise in an agent's context
    # and it makes two runs of the same failure look different. Strip the root
    # so the diagnostic reads "oops.sh: line 3: ..." like the Python checker's.
    printf '%s: %s\n' "$rel" "${err//$ROOT\//}"
  fi
done < <(find "$ROOT" \
           \( -name .git -o -name node_modules -o -name .venv -o -name venv \
              -o -name build -o -name dist -o -name target -o -name .claude \) -prune -o \
           -type f \( -name '*.sh' -o -name '*.bash' \) -print0 2>/dev/null)
if (( bad )); then
  printf '%d script(s) failed to parse (%d checked).\n' "$bad" "$checked"
  exit 1
fi
exit 0
SHEOF
}

# --- unknown ------------------------------------------------------------------
kit_plan_unknown() {
  _kit_plan_reset
  KIT_PLAN_NOTES+=('The project language could not be determined, so NO validation commands were generated.')
  KIT_PLAN_NOTES+=('This is deliberate: an invented gate fails confusingly, and an empty one fails silently.')
  KIT_PLAN_NOTES+=('Edit .claude/gate.json and give this project real build/lint/test commands in "full" (and the quick subset in "fast").')
  KIT_PLAN_CONFIGURED=0
}

# --- top-level dispatch -------------------------------------------------------
# Probes the environment, then calls the matching pure planner. This is the ONLY
# function here that touches anything outside the project tree.
kit_build_plan() {  # kit_build_plan <root> <language>
  local root="$1" lang="$2"
  case "$lang" in
    node)   kit_plan_node "$root" ;;
    python)
      local py has_ruff=0 has_pytest=0
      py="$(kit_python_interpreter "$root")"
      ( cd "$root" && kit_python_has_module "$py" ruff )   && has_ruff=1
      ( cd "$root" && kit_python_has_module "$py" pytest ) && has_pytest=1
      kit_plan_python "$root" "$py" "$has_ruff" "$has_pytest"
      ;;
    cpp)
      local has_ctest=0
      if [[ -f "$root/CTestTestfile.cmake" ]] \
         || grep -rqsE '^\s*(enable_testing|add_test)\s*\(' "$root/CMakeLists.txt" 2>/dev/null; then
        has_ctest=1
      fi
      kit_plan_cpp "$root" "$has_ctest"
      ;;
    rust)   kit_plan_rust "$root" ;;
    go)     kit_plan_go "$root" ;;
    cs)     kit_plan_dotnet "$root" ;;
    shell)
      local has_sc=0; kit_have shellcheck && has_sc=1
      kit_plan_shell "$root" "$has_sc"
      ;;
    *)      kit_plan_unknown ;;
  esac
}

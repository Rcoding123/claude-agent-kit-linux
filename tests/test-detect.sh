#!/usr/bin/env bash
# test-detect.sh - language detection and gate planning, from fixtures.
#
# Every planner is pure, so the whole matrix is exercised here without any
# toolchain installed. That is the point of the split: you do not need dotnet on
# the box to know that the .NET planner refuses to emit `dotnet test` for a
# solution with no test project.
#
# The assertions to care about are the NEGATIVE ones - the steps the planners
# refuse to emit. A gate that runs a tool nobody installed, or tests a project
# that has none, fails for reasons unrelated to the code, and people learn to
# ignore it.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname -- "$TEST_DIR")"
source "$TEST_DIR/kit-test-lib.sh"
source "$KIT_ROOT/lib/kit-detect.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fixture() {  # fixture <name> -> prints root
  local root="$WORK/$1"; mkdir -p "$root"; printf '%s' "$root"
}

# Join the current plan's arrays so a whole list can be searched at once.
plan_fast() { printf '%s\n' "${KIT_PLAN_FAST[@]:-}"; }
plan_full() { printf '%s\n' "${KIT_PLAN_FULL[@]:-}"; }
plan_notes() { printf '%s\n' "${KIT_PLAN_NOTES[@]:-}"; }

kit_section 'language detection'

R="$(fixture rust)";   touch "$R/Cargo.toml"
kit_assert_eq 'rust' "$(kit_detect_language "$R")" 'Cargo.toml means rust'

R="$(fixture go)";     touch "$R/go.mod"
kit_assert_eq 'go' "$(kit_detect_language "$R")" 'go.mod means go'

R="$(fixture cmake)";  touch "$R/CMakeLists.txt"
kit_assert_eq 'cpp' "$(kit_detect_language "$R")" 'CMakeLists.txt means cpp'

R="$(fixture meson)";  touch "$R/meson.build"
kit_assert_eq 'cpp' "$(kit_detect_language "$R")" 'meson.build means cpp'

R="$(fixture dotnet)"; touch "$R/App.csproj"
kit_assert_eq 'cs' "$(kit_detect_language "$R")" 'a .csproj means cs'

R="$(fixture py)";     touch "$R/pyproject.toml"
kit_assert_eq 'python' "$(kit_detect_language "$R")" 'pyproject.toml means python'

R="$(fixture pyreq)";  touch "$R/requirements.txt"
kit_assert_eq 'python' "$(kit_detect_language "$R")" 'requirements.txt means python'

R="$(fixture node)";   echo '{}' > "$R/package.json"
kit_assert_eq 'node' "$(kit_detect_language "$R")" 'package.json means node'

R="$(fixture loosepy)"; mkdir -p "$R/src"; touch "$R/src/thing.py"
kit_assert_eq 'python' "$(kit_detect_language "$R")" 'loose .py files mean python'

R="$(fixture loosesh)"; touch "$R/deploy.sh"
kit_assert_eq 'shell' "$(kit_detect_language "$R")" 'loose .sh files mean shell'

R="$(fixture empty)"
kit_assert_eq 'unknown' "$(kit_detect_language "$R")" 'an empty directory is unknown'

# A manifest must beat a loose source file: a Rust repo with one stray .cs file
# is still a Rust repo.
R="$(fixture mixed)"; touch "$R/Cargo.toml" "$R/Stray.cs"
kit_assert_eq 'rust' "$(kit_detect_language "$R")" 'a manifest beats a loose source file'

# Files inside pruned directories must not decide the language.
R="$(fixture pruned)"; mkdir -p "$R/node_modules/dep"; touch "$R/node_modules/dep/x.py"
kit_assert_eq 'unknown' "$(kit_detect_language "$R")" 'source inside node_modules does not count'

R="$(fixture prunedvenv)"; mkdir -p "$R/.venv/lib"; touch "$R/.venv/lib/x.py"
kit_assert_eq 'unknown' "$(kit_detect_language "$R")" 'source inside .venv does not count'

kit_section 'node: package manager'

R="$(fixture pmnpm)";  echo '{}' > "$R/package.json"; touch "$R/package-lock.json"
kit_assert_eq 'npm' "$(kit_node_package_manager "$R")" 'package-lock.json means npm'

R="$(fixture pmpnpm)"; echo '{}' > "$R/package.json"; touch "$R/pnpm-lock.yaml"
kit_assert_eq 'pnpm' "$(kit_node_package_manager "$R")" 'pnpm-lock.yaml means pnpm'

R="$(fixture pmyarn)"; echo '{}' > "$R/package.json"; touch "$R/yarn.lock"
kit_assert_eq 'yarn' "$(kit_node_package_manager "$R")" 'yarn.lock means yarn'

R="$(fixture pmbun)";  echo '{}' > "$R/package.json"; touch "$R/bun.lockb"
kit_assert_eq 'bun' "$(kit_node_package_manager "$R")" 'bun.lockb means bun'

# An explicit declaration beats a lockfile that disagrees.
R="$(fixture pmexplicit)"; jq -n '{packageManager:"pnpm@9.0.0"}' > "$R/package.json"; touch "$R/package-lock.json"
kit_assert_eq 'pnpm' "$(kit_node_package_manager "$R")" 'an explicit packageManager beats the lockfile'

R="$(fixture pmnone)"; echo '{}' > "$R/package.json"
kit_assert_eq 'npm' "$(kit_node_package_manager "$R")" 'nothing declared defaults to npm'

kit_section 'node: planning'

R="$(fixture nodefull)"
jq -n '{scripts:{lint:"eslint .",test:"vitest run",build:"tsc",typecheck:"tsc --noEmit"}}' > "$R/package.json"
kit_plan_node "$R"
kit_assert_contains "$(plan_fast)" 'npm run typecheck' 'typecheck goes in the fast gate'
kit_assert_contains "$(plan_fast)" 'npm run lint'      'lint goes in the fast gate'
kit_assert_contains "$(plan_full)" 'npm run test'      'test goes in the full gate'
kit_assert_contains "$(plan_full)" 'npm run build'     'build goes in the full gate'
kit_assert_not_contains "$(plan_fast)" 'npm run test'  'test does NOT go in the fast gate'
kit_assert_eq '1' "$KIT_PLAN_CONFIGURED" 'a project with real scripts is configured'

# THE npm placeholder. It EXISTS and always exits 1, so running it means the
# gate can never pass.
R="$(fixture nodeplaceholder)"
jq -n '{scripts:{test:"echo \"Error: no test specified\" && exit 1"}}' > "$R/package.json"
kit_plan_node "$R"
kit_assert_not_contains "$(plan_full)" 'run test' 'the npm placeholder test script is NOT put in the gate'
kit_assert_contains "$(plan_notes)" 'placeholder' 'and the plan explains why'

R="$(fixture nodebareexit)"
jq -n '{scripts:{test:"exit 1"}}' > "$R/package.json"
kit_plan_node "$R"
kit_assert_not_contains "$(plan_full)" 'run test' 'a bare "exit 1" test script is also refused'

# No scripts at all: nothing invented, and the project is marked unconfigured.
R="$(fixture nodeempty)"; echo '{}' > "$R/package.json"
kit_plan_node "$R"
kit_assert_eq '0' "${#KIT_PLAN_FULL[@]}" 'a package.json with no scripts generates no commands'
kit_assert_eq '0' "$KIT_PLAN_CONFIGURED" 'and is reported as NOT configured'
kit_assert_contains "$(plan_notes)" 'No runnable script' 'and says so'

# tsconfig without a typecheck script: use the project-local compiler, never a
# global tsc and never a silent download.
R="$(fixture nodetsconfig)"
jq -n '{scripts:{lint:"eslint ."}}' > "$R/package.json"; touch "$R/tsconfig.json"
kit_plan_node "$R"
kit_assert_contains "$(plan_fast)" 'npx --no-install tsc --noEmit' 'tsconfig implies a project-local tsc check'

# The runner must follow the detected package manager, not always be npm.
R="$(fixture nodepnpm)"
jq -n '{scripts:{lint:"eslint ."}}' > "$R/package.json"; touch "$R/pnpm-lock.yaml"
kit_plan_node "$R"
kit_assert_contains "$(plan_fast)" 'pnpm run lint' 'the plan uses the detected package manager'

kit_section 'python: planning'

R="$(fixture pyplan)"
kit_plan_python "$R" 'python3' 1 1
kit_assert_contains "$(plan_fast)" '.claude/py-syntax.py' 'a syntax step is ALWAYS generated'
kit_assert_contains "$(plan_fast)" 'ruff check'           'ruff is in the fast gate when installed'
kit_assert_contains "$(plan_full)" 'pytest -q'            'pytest is in the full gate when installed'
kit_assert_not_contains "$(plan_fast)" 'pytest'           'pytest is NOT in the fast gate'
kit_assert_contains "$(plan_fast)" 'extend-exclude'       'ruff uses --extend-exclude, not --exclude'

# The whole point of probing: absent tools produce no step and an explanation.
kit_plan_python "$R" 'python3' 0 0
kit_assert_not_contains "$(plan_fast)" 'ruff'   'no ruff step when ruff is not installed'
kit_assert_not_contains "$(plan_full)" 'pytest' 'no pytest step when pytest is not installed'
kit_assert_contains "$(plan_notes)" 'Ruff is not installed'   'and the plan says why ruff is missing'
kit_assert_contains "$(plan_notes)" 'pytest is not installed' 'and why pytest is missing'
kit_assert_contains "$(plan_fast)" 'py-syntax.py' 'but a real gate still exists with no dev tooling'
kit_assert_eq '1' "$KIT_PLAN_CONFIGURED" 'python is configured even with no dev tooling'

# compileall is the thing being replaced; it must never appear.
kit_assert_not_contains "$(plan_full)" 'compileall' 'compileall is never used (it walks .venv and writes bytecode)'

# A venv interpreter is preferred over the global one.
R="$(fixture pyvenv)"; mkdir -p "$R/.venv/bin"
printf '#!/bin/sh\n' > "$R/.venv/bin/python"; chmod +x "$R/.venv/bin/python"
kit_assert_eq '.venv/bin/python' "$(kit_python_interpreter "$R")" 'a project .venv wins over the global interpreter'

R="$(fixture pynovenv)"
kit_assert_matches "$(kit_python_interpreter "$R")" '^python3?$' 'with no venv it falls back to python3'
kit_plan_python "$R" 'python3' 0 0
kit_assert_contains "$(plan_notes)" 'No project environment was found' 'and warns that results are not reproducible'
kit_assert_contains "$(plan_notes)" 'conda' 'and mentions conda among the places it looked'

kit_section 'a project that INTENDS tests but cannot run them'

# Found by pointing the kit at a real project: ML-Viz declares
# [tool.pytest.ini_options] and pytest>=8.3 and has three test files, but pytest
# was not importable by the system interpreter - so the gate covered syntax only
# and said merely "pytest is not installed". For a project with twenty test
# files that note reads as a shrug, and the author does not notice the gate is
# validating far less than they think. Intent is detectable; say so loudly.

R="$(fixture pytest_configured)"
printf '[tool.pytest.ini_options]\ntestpaths = ["tests"]\n' > "$R/pyproject.toml"
kit_plan_python "$R" 'python3' 0 0
kit_assert_contains "$(plan_notes)" 'NOT RUNNING' \
  'a pyproject that CONFIGURES pytest gets a loud note, not a shrug'
kit_assert_contains "$(plan_notes)" 'syntax only' \
  'and says exactly what the gate does cover'
kit_assert_contains "$(plan_notes)" 'gate.json' \
  'and says how to fix it'

R="$(fixture pytest_declared)"
printf 'dependencies = ["pytest>=8.3"]\n' > "$R/pyproject.toml"
kit_plan_python "$R" 'python3' 0 0
kit_assert_contains "$(plan_notes)" 'NOT RUNNING' \
  'a declared pytest dependency also counts as intent'

R="$(fixture pytest_files)"; mkdir -p "$R/tests"
touch "$R/pyproject.toml" "$R/tests/test_thing.py"
kit_plan_python "$R" 'python3' 0 0
kit_assert_contains "$(plan_notes)" 'NOT RUNNING' \
  'test files alone count as intent'

R="$(fixture pytest_ini)"; touch "$R/pyproject.toml" "$R/pytest.ini"
kit_plan_python "$R" 'python3' 0 0
kit_assert_contains "$(plan_notes)" 'NOT RUNNING' 'a pytest.ini counts as intent'

# A project with NO sign of tests keeps the quiet note - the loud one would be
# noise, and a warning that fires everywhere is a warning nobody reads.
R="$(fixture no_tests)"; touch "$R/pyproject.toml"
printf 'x = 1\n' > "$R/app.py"
kit_plan_python "$R" 'python3' 0 0
kit_assert_not_contains "$(plan_notes)" 'NOT RUNNING' \
  'a project with no tests gets the quiet note, not the alarm'
kit_assert_contains "$(plan_notes)" 'pytest is not installed' 'but still explains itself'

# And when pytest IS available there is a real test step and no warning at all.
R="$(fixture pytest_present)"; mkdir -p "$R/tests"
printf '[tool.pytest.ini_options]\n' > "$R/pyproject.toml"
touch "$R/tests/test_thing.py"
kit_plan_python "$R" 'python3' 0 1
kit_assert_contains "$(plan_full)" 'pytest -q' 'with pytest installed the gate really runs the tests'
kit_assert_not_contains "$(plan_notes)" 'NOT RUNNING' 'and there is nothing to warn about'

kit_section 'conda environments'

# Found on a real project: 63 passing tests, every dependency installed in a
# conda env, and the kit generated a syntax-only gate reporting "pytest is not
# installed" - because it only ever looked for .venv/venv/env. A whole class of
# Python project was invisible to it.

# An ACTIVE conda env wins: the user has said which one they mean.
R="$(fixture conda_active)"
FAKE="$WORK/fake-conda"; mkdir -p "$FAKE/bin"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/bin/python"; chmod +x "$FAKE/bin/python"
kit_assert_eq "$FAKE/bin/python" "$(CONDA_PREFIX="$FAKE" kit_python_interpreter "$R")" \
  'an ACTIVE conda env is used'

# A project .venv still beats an active conda env - it is more specific to the
# project than whatever the shell happens to have activated.
R="$(fixture conda_vs_venv)"; mkdir -p "$R/.venv/bin"
printf '#!/bin/sh\n' > "$R/.venv/bin/python"; chmod +x "$R/.venv/bin/python"
kit_assert_eq '.venv/bin/python' "$(CONDA_PREFIX="$FAKE" kit_python_interpreter "$R")" \
  'a project .venv still beats an active conda env'

# An env NAMED after the project directory, discovered under a conda root.
CONDA_HOME="$WORK/condahome"
mkdir -p "$CONDA_HOME/envs/named_proj/bin"
printf '#!/bin/sh\n' > "$CONDA_HOME/envs/named_proj/bin/python"
chmod +x "$CONDA_HOME/envs/named_proj/bin/python"
R="$WORK/named_proj"; mkdir -p "$R"
kit_assert_eq "$CONDA_HOME/envs/named_proj/bin/python" \
  "$(CONDA_ROOT="$CONDA_HOME" kit_python_interpreter "$R")" \
  'a conda env named after the project directory is found'

# ...but only when it really exists. No guessing.
R2="$WORK/no_such_env"; mkdir -p "$R2"
kit_assert_matches "$(CONDA_ROOT="$CONDA_HOME" kit_python_interpreter "$R2")" '^python3?$' \
  'a project with no matching conda env falls back to python3'

# The plan must NAME the conda interpreter, because it is invisible from the
# project tree - nothing in the repo says which python the gate uses.
kit_plan_python "$R" "$CONDA_HOME/envs/named_proj/bin/python" 0 1
kit_assert_contains "$(plan_notes)" 'conda environment' 'the plan says a conda env is being used'
kit_assert_contains "$(plan_notes)" 'machine-specific' 'and warns the path is machine-specific'
kit_assert_not_contains "$(plan_notes)" 'No project environment was found' \
  'and does NOT also claim no environment was found'

# With pytest present in that env, a real test step appears.
kit_assert_contains "$(plan_full)" 'pytest -q' 'and the gate really runs the tests'

kit_section 'python: the syntax checker actually works'

R="$(fixture pysyntax)"; mkdir -p "$R/.claude"
kit_python_syntax_checker > "$R/.claude/py-syntax.py"
mkdir -p "$R/src"
printf 'x = 1\n' > "$R/src/good.py"
( cd "$R" && python3 .claude/py-syntax.py >/dev/null 2>&1 )
kit_assert_eq '0' "$?" 'the syntax checker passes a clean tree'

printf 'def broken(:\n' > "$R/src/bad.py"
OUT="$( cd "$R" && python3 .claude/py-syntax.py 2>&1 )"; RC=$?
kit_assert_eq '1' "$RC" 'the syntax checker fails on a syntax error'
kit_assert_contains "$OUT" 'src/bad.py' 'and names the offending file relative to the project root'
kit_assert_not_contains "$OUT" "$R" 'and does NOT leak the absolute path into the diagnostic'
rm -f "$R/src/bad.py"

# It must not walk a virtual environment, nor fail over vendored code.
mkdir -p "$R/.venv/lib/site-packages"
printf 'pyvenv\n' > "$R/.venv/pyvenv.cfg"
printf 'print "python 2 syntax"\n' > "$R/.venv/lib/site-packages/legacy.py"
( cd "$R" && python3 .claude/py-syntax.py >/dev/null 2>&1 )
kit_assert_eq '0' "$?" 'the syntax checker ignores .venv (detected via pyvenv.cfg, not by name)'

# It must not write bytecode next to the sources it checks.
kit_assert_eq '0' "$(find "$R/src" -name '__pycache__' 2>/dev/null | wc -l)" \
  'the syntax checker writes no bytecode'

kit_section 'cpp: planning'

R="$(fixture cpppreset)"
jq -n '{version:3, buildPresets:[{name:"hidden-one",hidden:true},{name:"default"}]}' > "$R/CMakePresets.json"
kit_plan_cpp "$R" 0
kit_assert_contains "$(plan_full)" 'cmake --build --preset default' 'a build preset is used when present'
kit_assert_not_contains "$(plan_full)" 'hidden-one' 'hidden presets are skipped - they are not directly runnable'
kit_assert_not_contains "$(plan_full)" 'ctest' 'no ctest step when the project declares no tests'

kit_plan_cpp "$R" 1
kit_assert_contains "$(plan_full)" 'ctest --preset default' 'a ctest step appears when tests are declared'

R="$(fixture cpplists)"; touch "$R/CMakeLists.txt"
kit_plan_cpp "$R" 0
kit_assert_contains "$(plan_full)" 'cmake -S . -B build' 'without presets the FULL gate configures first'
kit_assert_contains "$(plan_full)" 'cmake --build build' 'and then builds'
FULLTXT="$(plan_full)"
[[ "$(printf '%s\n' "$FULLTXT" | grep -n 'cmake -S' | cut -d: -f1)" -lt \
   "$(printf '%s\n' "$FULLTXT" | grep -n 'cmake --build' | cut -d: -f1)" ]] \
  && kit_pass 'configure is ordered BEFORE build' \
  || kit_fail_test 'configure is ordered before build'

# The regression this exists to make impossible.
kit_assert_not_contains "$(plan_full)" 'cargo' 'the C++ planner never invokes cargo'

R="$(fixture cppmeson)"; touch "$R/meson.build"
kit_plan_cpp "$R" 0
kit_assert_contains "$(plan_full)" 'meson compile' 'meson projects get a meson gate'

R="$(fixture cppmake)"; printf 'all:\n\techo hi\n' > "$R/Makefile"
kit_plan_cpp "$R" 0
kit_assert_contains "$(plan_full)" 'make' 'a Makefile project gets make'
kit_assert_not_contains "$(plan_full)" 'make test' 'no "make test" when there is no test target'
kit_assert_contains "$(plan_notes)" 'No "test" or "check" target' 'and it says why'

R="$(fixture cppmaketest)"; printf 'all:\n\techo hi\ntest:\n\techo t\n' > "$R/Makefile"
kit_plan_cpp "$R" 0
kit_assert_contains "$(plan_full)" 'make test' '"make test" appears when the target really exists'

# No inferable build system: refuse to guess.
R="$(fixture cppbare)"; touch "$R/main.cpp"
kit_plan_cpp "$R" 0
kit_assert_eq '0' "${#KIT_PLAN_FULL[@]}" 'C++ with no build system generates NO commands'
kit_assert_eq '0' "$KIT_PLAN_CONFIGURED" 'and is reported as NOT configured'
kit_assert_contains "$(plan_notes)" 'will not invent' 'and says the kit refuses to invent one'

kit_section 'rust / go / dotnet'

kit_plan_rust "$(fixture rustplan)"
kit_assert_contains "$(plan_fast)" 'cargo check'  'rust fast gate uses cargo check'
kit_assert_contains "$(plan_full)" 'cargo test'   'rust full gate runs tests'
kit_assert_not_contains "$(plan_fast)" 'cargo test' 'rust fast gate does NOT run the test suite'
kit_assert_not_contains "$(plan_full)" '-D warnings' 'clippy does not fail the gate by default'
kit_assert_contains "$(plan_notes)" '-D warnings' 'but the plan says how to make it fail'

kit_plan_go "$(fixture goplan)"
kit_assert_contains "$(plan_full)" 'go test ./...' 'go full gate runs tests'
kit_assert_contains "$(plan_notes)" 'exits 0' 'the plan admits gofmt -l does not fail on its own'

R="$(fixture dotnetnotests)"; touch "$R/App.csproj"
kit_plan_dotnet "$R"
kit_assert_contains "$(plan_full)" 'dotnet build' 'dotnet projects get a build step'
kit_assert_not_contains "$(plan_full)" 'dotnet test' 'no dotnet test when there is no test project'
kit_assert_contains "$(plan_notes)" 'No test project' 'and it says why'

R="$(fixture dotnettests)"; touch "$R/App.csproj" "$R/App.Tests.csproj"
kit_plan_dotnet "$R"
kit_assert_contains "$(plan_full)" 'dotnet test' 'dotnet test appears when a test project exists'

# A test project detected by its package reference rather than its filename.
R="$(fixture dotnetbyref)"; touch "$R/App.csproj"
cat > "$R/Other.csproj" <<'EOF'
<Project><ItemGroup><PackageReference Include="xunit" Version="2.0.0" /></ItemGroup></Project>
EOF
kit_plan_dotnet "$R"
kit_assert_contains "$(plan_full)" 'dotnet test' 'a test project is detected by its xunit reference too'

kit_section 'shell'

R="$(fixture shplan)"; touch "$R/x.sh"
kit_plan_shell "$R" 0
kit_assert_contains "$(plan_fast)" 'sh-syntax.sh' 'shell projects always get a parse check'
kit_assert_not_contains "$(plan_full)" 'shellcheck' 'no shellcheck step when it is not installed'
kit_plan_shell "$R" 1
kit_assert_contains "$(plan_full)" 'shellcheck' 'shellcheck appears when installed'

R="$(fixture shsyntax)"; mkdir -p "$R/.claude"
kit_shell_syntax_checker > "$R/.claude/sh-syntax.sh"; chmod +x "$R/.claude/sh-syntax.sh"
printf '#!/bin/bash\necho ok\n' > "$R/good.sh"
( cd "$R" && ./.claude/sh-syntax.sh >/dev/null 2>&1 )
kit_assert_eq '0' "$?" 'the shell syntax checker passes a clean tree'
printf '#!/bin/bash\nif [ 1 ; then\n' > "$R/bad.sh"
OUT="$( cd "$R" && ./.claude/sh-syntax.sh 2>&1 )"; RC=$?
kit_assert_eq '1' "$RC" 'the shell syntax checker fails on a parse error'
kit_assert_contains "$OUT" 'bad.sh' 'and names the offending script'
# `bash -n` prints the absolute path it was handed, so the raw message carried
# the machine's full path - noise in an agent's context, and it makes the same
# failure look different from two different checkouts. Caught by running the
# gate against a real project and reading the output rather than just its exit
# code. The Python checker already reported relative paths; these now agree.
kit_assert_not_contains "$OUT" "$R" \
  'and does NOT leak the absolute project path into the diagnostic'
kit_assert_not_contains "$OUT" "$WORK" 'nor the temp root'

kit_section 'unknown'

kit_plan_unknown
kit_assert_eq '0' "${#KIT_PLAN_FULL[@]}" 'an unknown language generates NO commands'
kit_assert_eq '0' "$KIT_PLAN_CONFIGURED" 'and is NOT marked configured'
kit_assert_contains "$(plan_notes)" 'deliberate' 'and explains that this is deliberate, not an oversight'

kit_test_summary

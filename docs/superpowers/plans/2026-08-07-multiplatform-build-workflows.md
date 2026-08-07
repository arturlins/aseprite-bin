# Aseprite Multi-Platform Build Workflows — Implementation Plan

> **Historical planning document.** This plan predates several rounds of
> code review and fixes. Its embedded code blocks (e.g. the `build.cmd`
> packaging step, the resolver test file's case count, the inline `xcrun`
> call) have drifted from what actually shipped and are not being kept in
> sync going forward. Where this document and the committed code disagree,
> **the committed code is authoritative.** It is kept for the decisions and
> rationale it records, not as a spec of the current state.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Corrigir a resolução da versão do Aseprite (último *release*, não última *tag*) e separar o build em três workflows independentes por sistema operacional — Windows (uso diário), Linux e macOS arm64 (à prova de futuro) — mantendo o fluxo estritamente manual conforme o EULA.

**Architecture:** A lógica frágil de resolver/validar a versão sai dos scripts de build e vira um único script POSIX testável (`scripts/resolve-version.sh`), embrulhado numa composite action local consumida pelos três workflows. Cada workflow é uma casca fina que resolve a versão, chama o script de build da sua plataforma (`build.cmd` no Windows, `build.sh` no Linux/macOS) e publica um artifact com retenção de 7 dias. Não há matrix e não há acoplamento entre plataformas: um job quebrado nunca afeta os outros.

**Tech Stack:** GitHub Actions (composite actions, `workflow_dispatch`), Bash (POSIX-ish, roda em Git Bash no Windows), cmd/batch, PowerShell (substitui a dependência de Python), CMake + Ninja, Skia pré-compilada do `aseprite/skia`.

## Global Constraints

- **Trigger:** exclusivamente `workflow_dispatch`. Nunca `push`, `pull_request`, `schedule` ou `release`. Todo workflow carrega a guarda `if: github.event_name == 'workflow_dispatch'`.
- **Distribuição:** nenhum step pode criar GitHub Release, Package ou publicar binário fora de `actions/upload-artifact`. É vedado pelo EULA do Aseprite.
- **Permissões:** todo workflow declara `permissions: contents: read` explicitamente.
- **Retenção de artifact:** `retention-days: 7`.
- **Runners:** Windows = `windows-2025` (imagem com VS 2026, aceito conscientemente). Linux = `ubuntu-22.04` (glibc 2.35, piso de portabilidade). macOS = `macos-15` (arm64, runner padrão e gratuito em repo público).
- **Arquiteturas:** Windows x64, Linux x64, macOS **arm64 apenas**. Sem universal binary, sem x86_64 no macOS.
- **Repositório é público.** Minutos de runner padrão são gratuitos nas três plataformas.
- **Sem cache de Skia e sem ccache.** Explicitamente fora de escopo (ganho marginal, complexidade real).
- **Regex canônica de versão:** `^v[0-9]+(\.[0-9]+){1,3}(-beta[0-9]+)?$`
- **Nome do diretório de saída:** sempre `dist/` na raiz do repo, nas três plataformas.
- **Nome do artifact:** `aseprite-<versao>-<os>-<arch>` (ex.: `aseprite-v1.3.18.1-windows-x64`).
- **Upstream:** `https://github.com/aseprite/aseprite`. A versão numérica do CMake é a tag sem o `v` inicial (`v1.3.18.1` → `1.3.18.1`).

---

## File Structure

| Arquivo | Responsabilidade |
|---|---|
| `scripts/resolve-version.sh` | **Criar.** Única fonte de verdade da resolução de versão: consulta `releases/latest`, normaliza, valida contra a regex, confirma que a tag existe. Sem dependência de `jq` ou `gh` — só `curl`, `grep`, `sed`. |
| `tests/resolve-version.test.sh` | **Criar.** Suíte de testes do script acima, com `curl` stubado. Sem framework externo. |
| `.github/actions/resolve-version/action.yml` | **Criar.** Composite action que roda o script em `shell: bash` (funciona no Windows via Git Bash) e expõe `outputs.version`. |
| `.github/workflows/build-windows.yml` | **Criar.** Substitui `aseprite.yml`. |
| `.github/workflows/build-linux.yml` | **Criar.** |
| `.github/workflows/build-macos.yml` | **Criar.** |
| `.github/workflows/aseprite.yml` | **Deletar.** |
| `build.cmd` | **Reescrever.** Deixa de resolver versão (passa a exigir `ASEPRITE_VERSION`), passa a fazer clone shallow da tag, troca Python por PowerShell, produz `dist/`. |
| `build.sh` | **Criar.** Equivalente para Linux e macOS, ramificando por `uname -s`. |
| `README.md` | **Reescrever por completo.** |
| `.gitignore` | **Modificar.** Adicionar `dist/`. |

**Por que o `.gitignore` importa aqui:** a linha `aseprite*` casa com qualquer arquivo começando em `aseprite` em qualquer nível — inclusive `.github/workflows/aseprite.yml`, que só está versionado por já ter sido adicionado antes. Nomear os novos workflows como `build-*.yml` elimina essa armadilha de vez.

---

### Task 1: Script de resolução de versão (TDD)

**Files:**
- Create: `scripts/resolve-version.sh`
- Test: `tests/resolve-version.test.sh`

**Interfaces:**
- Consumes: nada (primeira task).
- Produces: executável `scripts/resolve-version.sh`. Uso: `resolve-version.sh [versao-solicitada]`. Imprime a tag resolvida em stdout (ex.: `v1.3.18.1`), exit 0. Em erro, mensagem em stderr e exit 1. Respeita as variáveis de ambiente `ASEPRITE_REPO` (default `aseprite/aseprite`) e `GITHUB_TOKEN` (opcional, apenas para autenticar a API).

- [ ] **Step 1: Escrever a suíte de testes que falha**

Crie `tests/resolve-version.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/resolve-version.sh
# Run: bash tests/resolve-version.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/resolve-version.sh"

pass=0
fail=0

# Creates a fake `curl` in $1 that mimics the GitHub API.
#   $2 = tag_name returned by /releases/latest ("" makes the call fail)
#   $3 = space-separated list of tags that exist in /git/ref/tags/
make_stub_curl() {
  mkdir -p "$1"
  cat > "$1/curl" <<STUB
#!/usr/bin/env bash
url="\${!#}"
case "\$url" in
  */releases/latest)
    if [ -z "$2" ]; then exit 22; fi
    printf '{"tag_name": "%s", "prerelease": false}\n' "$2"
    ;;
  */git/ref/tags/*)
    tag="\${url##*/}"
    for t in $3; do
      if [ "\$t" = "\$tag" ]; then
        printf '{"ref": "refs/tags/%s"}\n' "\$tag"
        exit 0
      fi
    done
    exit 22
    ;;
  *)
    exit 22
    ;;
esac
STUB
  chmod +x "$1/curl"
}

# run_case <name> <expected_status> <expected_stdout> <latest> <existing_tags> [args...]
run_case() {
  local name="$1" want_status="$2" want_out="$3" latest="$4" existing="$5"
  shift 5

  local tmp
  tmp="$(mktemp -d)"
  make_stub_curl "$tmp/bin" "$latest" "$existing"

  local out status
  out="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" 2>/dev/null)"
  status=$?
  rm -rf "$tmp"

  if [ "$status" = "$want_status" ] && [ "$out" = "$want_out" ]; then
    pass=$((pass + 1))
    printf 'ok   - %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s\n       want status=%s stdout=%q\n       got  status=%s stdout=%q\n' \
      "$name" "$want_status" "$want_out" "$status" "$out"
  fi
}

ALL_TAGS="v1.3.18.1 v1.3.18 v1.3.18-beta1 v1.2.40"

run_case "sem argumento resolve o ultimo release" \
  0 "v1.3.18.1" "v1.3.18.1" "$ALL_TAGS"

run_case "versao explicita e respeitada" \
  0 "v1.3.18" "v1.3.18.1" "$ALL_TAGS" "v1.3.18"

run_case "versao sem prefixo v e normalizada" \
  0 "v1.2.40" "v1.3.18.1" "$ALL_TAGS" "1.2.40"

run_case "prerelease explicito e aceito" \
  0 "v1.3.18-beta1" "v1.3.18.1" "$ALL_TAGS" "v1.3.18-beta1"

run_case "tag inexistente e rejeitada" \
  1 "" "v1.3.18.1" "$ALL_TAGS" "v9.9.9"

run_case "injecao de comando e rejeitada" \
  1 "" "v1.3.18.1" "$ALL_TAGS" 'v1.3.18; rm -rf /'

run_case "argumento nao-versao e rejeitado" \
  1 "" "v1.3.18.1" "$ALL_TAGS" "main"

run_case "falha da api sem argumento e reportada" \
  1 "" "" "$ALL_TAGS"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Rodar os testes e confirmar que falham**

```bash
bash tests/resolve-version.test.sh
```

Esperado: **FAIL** em todos os 8 casos, porque `scripts/resolve-version.sh` ainda não existe (`bash: ... No such file or directory`, status 127).

- [ ] **Step 3: Escrever a implementação mínima**

Crie `scripts/resolve-version.sh`:

```bash
#!/usr/bin/env bash
#
# Resolves which Aseprite tag to build.
#
# Usage: resolve-version.sh [requested-version]
#
#   With no argument, resolves the latest published release (the GitHub API
#   already excludes drafts and prereleases). With an argument, normalizes and
#   validates it, then confirms the tag really exists upstream.
#
# Prints the resolved tag (e.g. "v1.3.18.1") to stdout.
#
# Environment:
#   ASEPRITE_REPO  upstream repo, default "aseprite/aseprite"
#   GITHUB_TOKEN   optional, only used to authenticate API calls
#
set -euo pipefail

REPO="${ASEPRITE_REPO:-aseprite/aseprite}"
API="https://api.github.com/repos/$REPO"
VERSION_RE='^v[0-9]+(\.[0-9]+){1,3}(-beta[0-9]+)?$'

api() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -sfL -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
  else
    curl -sfL -H "Accept: application/vnd.github+json" "$1"
  fi
}

version="${1:-}"

if [ -z "$version" ]; then
  if ! json="$(api "$API/releases/latest")"; then
    echo "error: could not query the latest release of $REPO" >&2
    exit 1
  fi
  # `|| true` prevents `pipefail` + `set -e` from killing the script right
  # here if `grep` finds no match (e.g. a 200 response with an unexpected
  # body shape) -- the emptiness check right below must stay reachable so
  # the error is reported on stderr instead of the script dying silently.
  version="$(printf '%s' "$json" \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
    || true)"
  if [ -z "$version" ]; then
    echo "error: no tag_name in the latest release of $REPO" >&2
    exit 1
  fi
fi

case "$version" in
  v*) ;;
  *) version="v$version" ;;
esac

# Validate BEFORE the tag is ever interpolated into a URL or a git command.
# `[[ =~ ]]` matches the whole string ($VERSION_RE left unquoted so it is
# treated as a regex, not a literal) -- unlike `grep`, which matches
# line-by-line, so a multi-line value can't sneak a valid-looking first line
# past this check and reach the URL interpolation below.
if ! [[ "$version" =~ $VERSION_RE ]]; then
  echo "error: invalid version '$version' (expected e.g. v1.3.18.1 or v1.3.18-beta1)" >&2
  exit 1
fi

if ! api "$API/git/ref/tags/$version" >/dev/null; then
  echo "error: tag '$version' does not exist in $REPO" >&2
  exit 1
fi

printf '%s\n' "$version"
```

Torne executável:

```bash
chmod +x scripts/resolve-version.sh
git update-index --chmod=+x scripts/resolve-version.sh 2>/dev/null || true
```

- [ ] **Step 4: Rodar os testes e confirmar que passam**

```bash
bash tests/resolve-version.test.sh
```

Esperado: `8 passed, 0 failed`, exit 0.

- [ ] **Step 5: Verificar contra a API real (sem stub)**

```bash
bash scripts/resolve-version.sh
bash scripts/resolve-version.sh v1.3.17
bash scripts/resolve-version.sh v9.9.9 ; echo "exit=$?"
```

Esperado: primeira linha imprime a tag do release atual (`v1.3.18.1` ou mais nova); segunda imprime `v1.3.17`; terceira imprime erro em stderr e `exit=1`.

- [ ] **Step 6: Commit**

```bash
git add scripts/resolve-version.sh tests/resolve-version.test.sh
git commit -m "feat: add tested version resolver based on the latest release"
```

---

### Task 2: Composite action `resolve-version`

**Files:**
- Create: `.github/actions/resolve-version/action.yml`

**Interfaces:**
- Consumes: `scripts/resolve-version.sh` da Task 1.
- Produces: action local usada como `uses: ./.github/actions/resolve-version`, com input opcional `version` (string) e output `version` (string, a tag resolvida). Os workflows referenciam o resultado como `steps.<id>.outputs.version`.

- [ ] **Step 1: Criar a action**

Crie `.github/actions/resolve-version/action.yml`:

```yaml
name: Resolve Aseprite version
description: >-
  Resolves and validates which Aseprite tag to build. With no input, resolves
  the latest published release (drafts and prereleases excluded by the API).

inputs:
  version:
    description: "Aseprite tag to build (e.g. v1.3.18.1). Empty means latest release."
    required: false
    default: ""

outputs:
  version:
    description: "The resolved Aseprite tag, always prefixed with 'v'."
    value: ${{ steps.resolve.outputs.version }}

runs:
  using: composite
  steps:
    - id: resolve
      shell: bash
      env:
        GITHUB_TOKEN: ${{ github.token }}
        REQUESTED_VERSION: ${{ inputs.version }}
      run: |
        set -euo pipefail
        # Invoked through `bash` on purpose: a Windows checkout does not
        # necessarily preserve the executable bit.
        version="$(bash "${GITHUB_ACTION_PATH}/../../../scripts/resolve-version.sh" "${REQUESTED_VERSION}")"
        echo "Resolved Aseprite version: ${version}"
        echo "version=${version}" >> "$GITHUB_OUTPUT"
        echo "### Building Aseprite \`${version}\`" >> "$GITHUB_STEP_SUMMARY"
```

Nota sobre o caminho: `GITHUB_ACTION_PATH` aponta para `.github/actions/resolve-version`, então três níveis acima é a raiz do repositório. O `shell: bash` funciona no runner Windows porque a imagem inclui o Git Bash.

- [ ] **Step 2: Validar a sintaxe do YAML**

```bash
python -c "import yaml,sys; yaml.safe_load(open('.github/actions/resolve-version/action.yml')); print('ok')"
```

Esperado: `ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/actions/resolve-version/action.yml
git commit -m "feat: add resolve-version composite action"
```

---

### Task 3: Reescrever `build.cmd`

**Files:**
- Modify: `build.cmd` (reescrita completa)

**Interfaces:**
- Consumes: variável de ambiente `ASEPRITE_VERSION` (obrigatória, formato `v1.3.18.1`), fornecida pelo output da action da Task 2.
- Produces: diretório `dist/aseprite-<versao>-windows-x64/` contendo `aseprite.exe`, `data/`, `docs/` e `aseprite.ini`. Não escreve mais em `GITHUB_OUTPUT` — o workflow já conhece a versão.

Mudanças em relação ao arquivo atual: sai a listagem de tags (`build.cmd:44-72` hoje), sai o clone completo, sai a dependência de Python, entra clone shallow da tag exata, entra saída em `dist/`.

- [ ] **Step 1: Substituir o conteúdo de `build.cmd`**

```batch
@echo off
setlocal enabledelayedexpansion

rem *** Aseprite build script for Windows x64.
rem *** ASEPRITE_VERSION must be set (e.g. v1.3.18.1).
rem *** Run "bash scripts/resolve-version.sh" to resolve the latest release.

if "%ASEPRITE_VERSION%" equ "" (
  echo ERROR: ASEPRITE_VERSION is not set, e.g. set ASEPRITE_VERSION=v1.3.18.1
  echo Run "bash scripts/resolve-version.sh" to resolve the latest release.
  exit /b 1
)

set PATH="C:\Program Files\7-Zip";%PATH%

where /q git.exe || (
  echo ERROR: "git.exe" not found
  exit /b 1
)

if exist "%ProgramFiles%\7-Zip\7z.exe" (
  set SZIP="%ProgramFiles%\7-Zip\7z.exe"
) else (
  where /q 7za.exe || (
    echo ERROR: 7-Zip installation or "7za.exe" not found
    exit /b 1
  )
  set SZIP=7za.exe
)


rem *** Visual Studio environment ***

where /Q cl.exe || (
  set __VSCMD_ARG_NO_LOGO=1
  for /f "tokens=*" %%i in ('"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath') do set VS=%%i
  if "!VS!" equ "" (
    echo ERROR: Visual Studio installation not found
    exit /b 1
  )
  call "!VS!\VC\Auxiliary\Build\vcvarsall.bat" amd64 || exit /b 1
)


rem *** ninja ***

where /q ninja.exe || (
  curl -LOsf https://github.com/ninja-build/ninja/releases/download/v1.13.1/ninja-win.zip || exit /b 1
  %SZIP% x -bb0 -y ninja-win.zip 1>nul 2>nul || exit /b 1
  del ninja-win.zip 1>nul 2>nul
)


rem *** shallow clone of the requested tag ***

echo Building Aseprite %ASEPRITE_VERSION%

if exist aseprite rd /s /q aseprite
call git clone --quiet --depth 1 --branch %ASEPRITE_VERSION% --recurse-submodules --shallow-submodules https://github.com/aseprite/aseprite.git aseprite || echo failed to clone %ASEPRITE_VERSION% && exit /b 1

set ASEPRITE_VERSION_NUMBER=%ASEPRITE_VERSION:~1%
powershell -NoProfile -Command "$p='aseprite/src/ver/CMakeLists.txt'; (Get-Content $p -Raw).Replace('1.x-dev','%ASEPRITE_VERSION_NUMBER%') | Set-Content $p -NoNewline" || echo failed to stamp version && exit /b 1


rem *** download skia ***

if exist aseprite\laf\misc\skia-tag.txt (
  set /p SKIA_VERSION=<aseprite\laf\misc\skia-tag.txt
) else (
  if "%ASEPRITE_VERSION:beta=%" neq "%ASEPRITE_VERSION%" (
    set SKIA_VERSION=m124-08a5439a6b
  ) else (
    set SKIA_VERSION=m102-861e4743af
  )
)

echo Using Skia %SKIA_VERSION%

if not exist skia-%SKIA_VERSION% (
  mkdir skia-%SKIA_VERSION%
  pushd skia-%SKIA_VERSION%
  curl -sfLO https://github.com/aseprite/skia/releases/download/%SKIA_VERSION%/Skia-Windows-Release-x64.zip || echo failed to download skia && exit /b 1
  %SZIP% x -y Skia-Windows-Release-x64.zip
  popd
)


rem *** build aseprite ***

if exist build rd /s /q build

set LINK=opengl32.lib
cmake.exe                                                     ^
  -G Ninja                                                    ^
  -S aseprite                                                 ^
  -B build                                                    ^
  -DCMAKE_BUILD_TYPE=Release                                  ^
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5                          ^
  -DCMAKE_POLICY_DEFAULT_CMP0074=NEW                          ^
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW                          ^
  -DCMAKE_POLICY_DEFAULT_CMP0092=NEW                          ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded                  ^
  -DENABLE_CCACHE=OFF                                         ^
  -DOPENSSL_USE_STATIC_LIBS=TRUE                              ^
  -DLAF_BACKEND=skia                                          ^
  -DSKIA_DIR=%CD%\skia-%SKIA_VERSION%                         ^
  -DSKIA_LIBRARY_DIR=%CD%\skia-%SKIA_VERSION%\out\Release-x64 ^
  -DSKIA_OPENGL_LIBRARY=                                      || echo failed to configure build && exit /b 1
ninja.exe -C build || echo build failed && exit /b 1


rem *** package ***

if exist dist rd /s /q dist
set OUTDIR=dist\aseprite-%ASEPRITE_VERSION%-windows-x64
mkdir %OUTDIR%
echo # This file is here so Aseprite behaves as a portable program >%OUTDIR%\aseprite.ini
copy /Y build\bin\aseprite.exe %OUTDIR%\ 1>nul || echo failed to copy binary && exit /b 1
xcopy /E /Q /Y build\bin\data %OUTDIR%\data\ || echo failed to copy data && exit /b 1
xcopy /E /Q /Y aseprite\docs %OUTDIR%\docs\ || echo failed to copy docs && exit /b 1

echo Done: %OUTDIR%
```

- [ ] **Step 2: Verificar que o script rejeita a ausência da versão**

Rode pelo PowerShell — chamar `.cmd` a partir do Git Bash com `cmd //c` não
resolve o caminho de forma confiável:

```powershell
$env:ASEPRITE_VERSION = ""
cmd /c "D:\Workspaces\CPP\aseprite-bin\build.cmd"
"exit=$LASTEXITCODE"
```

Esperado: mensagem `ERROR: ASEPRITE_VERSION is not set...` e `exit=1`. Nenhum clone iniciado.

- [ ] **Step 3: Commit**

```bash
git add build.cmd
git commit -m "refactor: build.cmd consumes a resolved version and outputs to dist/"
```

---

### Task 4: Workflow do Windows (entregável principal)

**Files:**
- Create: `.github/workflows/build-windows.yml`
- Delete: `.github/workflows/aseprite.yml`

**Interfaces:**
- Consumes: `.github/actions/resolve-version` (Task 2), `build.cmd` (Task 3).
- Produces: artifact `aseprite-<versao>-windows-x64`. É o único workflow que o usuário roda no dia a dia.

- [ ] **Step 1: Criar o workflow**

Crie `.github/workflows/build-windows.yml`:

```yaml
name: Build (Windows)

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Aseprite version to build (e.g. v1.3.18.1). Leave empty for the latest release."
        required: false
        type: string

# Aseprite's EULA forbids redistributing binaries. This workflow is manual only
# and must never publish a Release, a Package, or anything outside of a
# short-lived build artifact.
permissions:
  contents: read

concurrency:
  group: build-windows
  cancel-in-progress: false

jobs:
  build:
    if: github.event_name == 'workflow_dispatch'
    runs-on: windows-2025
    timeout-minutes: 90

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Resolve version
        id: resolve
        uses: ./.github/actions/resolve-version
        with:
          version: ${{ inputs.version }}

      - name: Build
        shell: cmd
        run: call build.cmd
        env:
          ASEPRITE_VERSION: ${{ steps.resolve.outputs.version }}

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: aseprite-${{ steps.resolve.outputs.version }}-windows-x64
          path: dist
          if-no-files-found: error
          retention-days: 7
```

- [ ] **Step 2: Remover o workflow antigo**

```bash
git rm .github/workflows/aseprite.yml
```

- [ ] **Step 3: Validar a sintaxe do YAML**

```bash
python -c "import yaml; yaml.safe_load(open('.github/workflows/build-windows.yml')); print('ok')"
```

Esperado: `ok`.

- [ ] **Step 4: Commit e push**

```bash
git add .github/workflows/build-windows.yml
git commit -m "feat: split Windows build into its own workflow"
git push
```

- [ ] **Step 5: Rodar o workflow e verificar (obrigatório)**

```bash
gh workflow run "Build (Windows)"
gh run watch
```

Esperado, verificado no log da execução:
1. O step `Resolve version` imprime `Resolved Aseprite version: v1.3.18.1` (ou a tag mais recente do momento).
2. O step `Build` imprime `Building Aseprite v...` e `Using Skia m...`.
3. Conclusão `success`, com o artifact `aseprite-v1.3.18.1-windows-x64` listado.

Baixe e confirme o conteúdo:

```bash
gh run download --name "aseprite-v1.3.18.1-windows-x64" --dir /tmp/win-check
ls -R /tmp/win-check
```

Esperado: `aseprite.exe`, `aseprite.ini`, `data/`, `docs/`.

- [ ] **Step 6: Rodar uma vez com versão explícita**

```bash
gh workflow run "Build (Windows)" -f version=v1.3.17
gh run watch
```

Esperado: `Resolved Aseprite version: v1.3.17` e artifact `aseprite-v1.3.17-windows-x64`.

---

### Task 5: `build.sh` para Linux e macOS

**Files:**
- Create: `build.sh`

**Interfaces:**
- Consumes: variável de ambiente `ASEPRITE_VERSION` (obrigatória).
- Produces:
  - Linux → `dist/aseprite-<versao>-linux-x64.tar.gz`
  - macOS → `dist/aseprite-<versao>-macos-arm64.tar.gz`

  O tarball existe porque `actions/upload-artifact` **não preserva o bit de execução nem symlinks**. Sem ele, o binário Linux chega sem `+x` e o `Aseprite.app` chega quebrado.

- [ ] **Step 1: Criar `build.sh`**

```bash
#!/usr/bin/env bash
#
# Aseprite build script for Linux x64 and macOS arm64.
#
# ASEPRITE_VERSION must be set (e.g. v1.3.18.1). Run
# "bash scripts/resolve-version.sh" to resolve the latest release.
#
# Produces a .tar.gz inside dist/ — a tarball rather than a plain directory
# because actions/upload-artifact drops the executable bit and symlinks.
#
set -euo pipefail

if [ -z "${ASEPRITE_VERSION:-}" ]; then
  echo "error: ASEPRITE_VERSION is not set (e.g. export ASEPRITE_VERSION=v1.3.18.1)" >&2
  echo "       run \"bash scripts/resolve-version.sh\" to resolve the latest release" >&2
  exit 1
fi

VERSION="$ASEPRITE_VERSION"
VERSION_NUMBER="${VERSION#v}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

case "$(uname -s)" in
  Linux)
    OS=linux
    ARCH=x64
    SKIA_OUT=Release-x64
    SKIA_ASSETS="Skia-Linux-Release-x64.zip Skia-Linux-Release-x64-libstdc++.zip"
    ;;
  Darwin)
    OS=macos
    ARCH=arm64
    SKIA_OUT=Release-arm64
    SKIA_ASSETS="Skia-macOS-Release-arm64.zip"
    ;;
  *)
    echo "error: unsupported platform $(uname -s)" >&2
    exit 1
    ;;
esac

echo "Building Aseprite $VERSION for $OS-$ARCH"


# --- toolchain -------------------------------------------------------------

command -v cmake >/dev/null || { echo "error: cmake not found" >&2; exit 1; }
command -v git   >/dev/null || { echo "error: git not found" >&2; exit 1; }
command -v unzip >/dev/null || { echo "error: unzip not found" >&2; exit 1; }

if ! command -v ninja >/dev/null; then
  echo "error: ninja not found (apt: ninja-build, brew: ninja)" >&2
  exit 1
fi


# --- shallow clone of the requested tag ------------------------------------

rm -rf aseprite
git clone --quiet --depth 1 --branch "$VERSION" \
  --recurse-submodules --shallow-submodules \
  https://github.com/aseprite/aseprite.git aseprite

# Stamp the real version instead of "1.x-dev". perl is used because GNU sed
# and BSD sed disagree on the syntax of -i.
perl -pi -e "s/\Q1.x-dev\E/$VERSION_NUMBER/g" aseprite/src/ver/CMakeLists.txt


# --- skia ------------------------------------------------------------------

if [ -f aseprite/laf/misc/skia-tag.txt ]; then
  SKIA_VERSION="$(tr -d '[:space:]' < aseprite/laf/misc/skia-tag.txt)"
elif [ "${VERSION#*beta}" != "$VERSION" ]; then
  SKIA_VERSION=m124-08a5439a6b
else
  SKIA_VERSION=m102-861e4743af
fi

echo "Using Skia $SKIA_VERSION"

SKIA_DIR="$ROOT/skia-$SKIA_VERSION"
if [ ! -d "$SKIA_DIR" ]; then
  mkdir -p "$SKIA_DIR"
  downloaded=""
  for asset in $SKIA_ASSETS; do
    url="https://github.com/aseprite/skia/releases/download/$SKIA_VERSION/$asset"
    echo "Trying $asset"
    if curl -sfL -o "$SKIA_DIR/skia.zip" "$url"; then
      downloaded="$asset"
      break
    fi
  done
  if [ -z "$downloaded" ]; then
    rm -rf "$SKIA_DIR"
    echo "error: no Skia asset found for $SKIA_VERSION on $OS-$ARCH" >&2
    exit 1
  fi
  unzip -q "$SKIA_DIR/skia.zip" -d "$SKIA_DIR"
  rm -f "$SKIA_DIR/skia.zip"
fi

SKIA_LIBRARY_DIR="$SKIA_DIR/out/$SKIA_OUT"
if [ ! -f "$SKIA_LIBRARY_DIR/libskia.a" ]; then
  echo "error: libskia.a not found in $SKIA_LIBRARY_DIR" >&2
  exit 1
fi


# --- configure & build -----------------------------------------------------

rm -rf build

common_args=(
  -G Ninja
  -S aseprite
  -B build
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DENABLE_CCACHE=OFF
  -DLAF_BACKEND=skia
  "-DSKIA_DIR=$SKIA_DIR"
  "-DSKIA_LIBRARY_DIR=$SKIA_LIBRARY_DIR"
  "-DSKIA_LIBRARY=$SKIA_LIBRARY_DIR/libskia.a"
)

if [ "$OS" = linux ]; then
  # The prebuilt Skia is linked against libstdc++, so Aseprite must be too.
  export CC=clang
  export CXX=clang++
  cmake "${common_args[@]}" \
    -DCMAKE_CXX_FLAGS:STRING=-stdlib=libstdc++ \
    -DCMAKE_EXE_LINKER_FLAGS:STRING=-stdlib=libstdc++
else
  cmake "${common_args[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    "-DCMAKE_OSX_SYSROOT=$(xcrun --sdk macosx --show-sdk-path)" \
    -DPNG_ARM_NEON:STRING=on
fi

ninja -C build aseprite


# --- package ---------------------------------------------------------------

rm -rf dist
mkdir -p dist

TARBALL="dist/aseprite-$VERSION-$OS-$ARCH.tar.gz"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ "$OS" = linux ]; then
  STAGE_DIR="$STAGE/aseprite-$VERSION-$OS-$ARCH"
  mkdir -p "$STAGE_DIR"
  cp build/bin/aseprite "$STAGE_DIR/"
  chmod +x "$STAGE_DIR/aseprite"
  cp -R build/bin/data "$STAGE_DIR/data"
  cp -R aseprite/docs "$STAGE_DIR/docs"
  echo '# This file is here so Aseprite behaves as a portable program' > "$STAGE_DIR/aseprite.ini"
else
  STAGE_DIR="$STAGE/aseprite-$VERSION-$OS-$ARCH"
  mkdir -p "$STAGE_DIR"
  # ditto preserves the bundle structure, symlinks and permissions.
  ditto build/bin/Aseprite.app "$STAGE_DIR/Aseprite.app"
  cp -R aseprite/docs "$STAGE_DIR/docs"
fi

tar -czf "$TARBALL" -C "$STAGE" "aseprite-$VERSION-$OS-$ARCH"

echo "Done: $TARBALL"
```

- [ ] **Step 2: Tornar executável**

```bash
chmod +x build.sh
git update-index --chmod=+x build.sh 2>/dev/null || true
```

- [ ] **Step 3: Verificar que o script rejeita a ausência da versão**

```bash
env -u ASEPRITE_VERSION bash build.sh ; echo "exit=$?"
```

Esperado: `error: ASEPRITE_VERSION is not set...` e `exit=1`. Nenhum clone iniciado.

- [ ] **Step 4: Verificar a checagem de plataforma**

Usa a mesma técnica de stub em `PATH` dos testes da Task 1, em vez de exportar
uma função de shell:

```bash
stub="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho Windows_NT\n' > "$stub/uname"
chmod +x "$stub/uname"
PATH="$stub:$PATH" ASEPRITE_VERSION=v1.3.18.1 bash build.sh ; echo "exit=$?"
rm -rf "$stub"
```

Esperado: `error: unsupported platform Windows_NT` e `exit=1`. A detecção de
plataforma acontece antes de qualquer clone ou checagem de toolchain, então
nada é baixado.

- [ ] **Step 5: Commit**

```bash
git add build.sh
git commit -m "feat: add build.sh for Linux x64 and macOS arm64"
```

---

### Task 6: Workflow do Linux

**Files:**
- Create: `.github/workflows/build-linux.yml`

**Interfaces:**
- Consumes: `.github/actions/resolve-version` (Task 2), `build.sh` (Task 5).
- Produces: artifact `aseprite-<versao>-linux-x64` contendo um `.tar.gz`.

- [ ] **Step 1: Criar o workflow**

```yaml
name: Build (Linux)

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Aseprite version to build (e.g. v1.3.18.1). Leave empty for the latest release."
        required: false
        type: string

# Aseprite's EULA forbids redistributing binaries. This workflow is manual only
# and must never publish a Release, a Package, or anything outside of a
# short-lived build artifact.
permissions:
  contents: read

concurrency:
  group: build-linux
  cancel-in-progress: false

jobs:
  build:
    if: github.event_name == 'workflow_dispatch'
    # 22.04 (glibc 2.35) is the oldest available image and therefore the widest
    # compatibility floor for the produced binary.
    runs-on: ubuntu-22.04
    timeout-minutes: 90

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            g++ clang cmake ninja-build unzip \
            libx11-dev libxcursor-dev libxi-dev libxrandr-dev \
            libgl1-mesa-dev libfontconfig1-dev

      - name: Resolve version
        id: resolve
        uses: ./.github/actions/resolve-version
        with:
          version: ${{ inputs.version }}

      - name: Build
        run: ./build.sh
        env:
          ASEPRITE_VERSION: ${{ steps.resolve.outputs.version }}

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: aseprite-${{ steps.resolve.outputs.version }}-linux-x64
          path: dist/*.tar.gz
          if-no-files-found: error
          retention-days: 7
```

- [ ] **Step 2: Validar a sintaxe do YAML**

```bash
python -c "import yaml; yaml.safe_load(open('.github/workflows/build-linux.yml')); print('ok')"
```

Esperado: `ok`.

- [ ] **Step 3: Commit e push**

```bash
git add .github/workflows/build-linux.yml
git commit -m "feat: add Linux build workflow"
git push
```

- [ ] **Step 4: Rodar e verificar (obrigatório — um workflow nunca executado é decorativo)**

```bash
gh workflow run "Build (Linux)"
gh run watch
```

Esperado: conclusão `success`, artifact `aseprite-<versao>-linux-x64`.

- [ ] **Step 5: Verificar que o binário sobreviveu ao empacotamento**

```bash
gh run download --name "aseprite-v1.3.18.1-linux-x64" --dir /tmp/linux-check
tar -tvzf /tmp/linux-check/*.tar.gz | head -20
```

Esperado: a listagem mostra `aseprite` com permissão `-rwxr-xr-x` (bit de execução preservado), além de `data/`, `docs/` e `aseprite.ini`.

---

### Task 7: Workflow do macOS

**Files:**
- Create: `.github/workflows/build-macos.yml`

**Interfaces:**
- Consumes: `.github/actions/resolve-version` (Task 2), `build.sh` (Task 5).
- Produces: artifact `aseprite-<versao>-macos-arm64` contendo um `.tar.gz` com `Aseprite.app`.

- [ ] **Step 1: Criar o workflow**

```yaml
name: Build (macOS)

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Aseprite version to build (e.g. v1.3.18.1). Leave empty for the latest release."
        required: false
        type: string

# Aseprite's EULA forbids redistributing binaries. This workflow is manual only
# and must never publish a Release, a Package, or anything outside of a
# short-lived build artifact.
permissions:
  contents: read

concurrency:
  group: build-macos
  cancel-in-progress: false

jobs:
  build:
    if: github.event_name == 'workflow_dispatch'
    # macos-15 is the standard arm64 runner: free for public repositories.
    runs-on: macos-15
    timeout-minutes: 120

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install dependencies
        run: brew install ninja

      - name: Resolve version
        id: resolve
        uses: ./.github/actions/resolve-version
        with:
          version: ${{ inputs.version }}

      - name: Build
        run: ./build.sh
        env:
          ASEPRITE_VERSION: ${{ steps.resolve.outputs.version }}

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: aseprite-${{ steps.resolve.outputs.version }}-macos-arm64
          path: dist/*.tar.gz
          if-no-files-found: error
          retention-days: 7
```

- [ ] **Step 2: Validar a sintaxe do YAML**

```bash
python -c "import yaml; yaml.safe_load(open('.github/workflows/build-macos.yml')); print('ok')"
```

Esperado: `ok`.

- [ ] **Step 3: Commit e push**

```bash
git add .github/workflows/build-macos.yml
git commit -m "feat: add macOS arm64 build workflow"
git push
```

- [ ] **Step 4: Rodar e verificar (obrigatório)**

```bash
gh workflow run "Build (macOS)"
gh run watch
```

Esperado: conclusão `success`, artifact `aseprite-<versao>-macos-arm64`.

- [ ] **Step 5: Verificar a integridade do bundle**

```bash
gh run download --name "aseprite-v1.3.18.1-macos-arm64" --dir /tmp/mac-check
tar -tvzf /tmp/mac-check/*.tar.gz | grep -E "Aseprite.app/Contents/(MacOS/aseprite|Info.plist|Resources/data)" | head
```

Esperado: aparecem `Aseprite.app/Contents/MacOS/aseprite` (com bit de execução), `Aseprite.app/Contents/Info.plist` e `Aseprite.app/Contents/Resources/data/`.

---

### Task 8: Reescrever o README e ajustar o `.gitignore`

**Files:**
- Modify: `README.md` (reescrita completa)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: os três workflows das Tasks 4, 6 e 7 e seus nomes exatos (`Build (Windows)`, `Build (Linux)`, `Build (macOS)`).
- Produces: documentação final. Nenhum artefato consumido por outras tasks.

- [ ] **Step 1: Atualizar o `.gitignore`**

Substitua o conteúdo por:

```gitignore
*.zip
skia*
build
aseprite*
dist
```

- [ ] **Step 2: Reescrever o `README.md`**

```markdown
# aseprite-bin

Ambiente de build automatizado do [Aseprite][] via GitHub Actions, para
Windows x64, Linux x64 e macOS arm64.

> [!IMPORTANT]
> **Você precisa de uma licença do Aseprite.** O [EULA][] permite compilar
> a partir do código-fonte para uso próprio, mas **proíbe a redistribuição
> dos binários gerados**. Os workflows deste repositório são exclusivamente
> manuais e nunca publicam Releases. Os artifacts expiram em 7 dias.
>
> Se este repositório for público, qualquer pessoa autenticada no GitHub
> consegue baixar os artifacts das suas execuções. Se isso te incomoda,
> use **Import repository** em vez de **Fork** e crie uma cópia privada —
> forks de repositórios públicos não podem ser tornados privados.

Para comprar uma licença, visite a [página de download][download page].

## Workflows disponíveis

| Workflow | Runner | Saída |
|---|---|---|
| `Build (Windows)` | `windows-2025` | pasta com `aseprite.exe`, `data/`, `docs/` |
| `Build (Linux)` | `ubuntu-22.04` | `.tar.gz` com o binário, `data/`, `docs/` |
| `Build (macOS)` | `macos-15` (arm64) | `.tar.gz` com `Aseprite.app` |

Cada plataforma tem seu próprio workflow: você roda só o que precisa, e uma
falha numa plataforma nunca afeta as outras.

## Como gerar um build

### 1. Crie sua própria cópia do repositório

Clique em `Fork` no topo da página.

![step1a](images/step1a.png)
![step1b](images/step1b.png)

> Para manter os binários fora do alcance de terceiros, use
> **`+` → Import repository** e marque a cópia como **Private** em vez de
> fazer um fork.

### 2. Habilite as Actions

Abra a aba `Actions` e confirme a ativação.

![step2](images/step2.png)

### 3. Rode o workflow da sua plataforma

Escolha `Build (Windows)`, `Build (Linux)` ou `Build (macOS)` na lista à
esquerda e clique em `Run workflow`.

O campo `version` é opcional:

- **Vazio** — compila o **último release publicado** do Aseprite. Prereleases
  e drafts são ignorados.
- **Preenchido** — compila a versão indicada, por exemplo `v1.3.18.1` ou
  `v1.3.18-beta1`. A lista completa está nas [tags do Aseprite][versions].

![step3](images/step3.png)

### 4. Aguarde a conclusão e abra a execução

O build leva em torno de 15 a 25 minutos, dependendo da plataforma.

![step4](images/step4.png)

### 5. Baixe o artifact no fim da página

![step5](images/step5.png)

Para compilar uma versão nova depois, repita os passos 3 a 5.

## Depois do download

### Windows

O artifact é um `.zip`. Extraia e execute `aseprite.exe`. O `aseprite.ini`
incluso faz o programa se comportar como portable, guardando as configurações
na própria pasta.

### Linux

O artifact é um `.zip` contendo um `.tar.gz` — a camada extra existe porque o
GitHub Actions descarta a permissão de execução ao compactar diretórios.

    unzip aseprite-v1.3.18.1-linux-x64.zip
    tar -xzf aseprite-v1.3.18.1-linux-x64.tar.gz
    cd aseprite-v1.3.18.1-linux-x64
    ./aseprite

O binário é compilado no Ubuntu 22.04 (glibc 2.35) e roda em distribuições
dessa geração ou mais novas.

### macOS

Mesma estrutura de `.zip` contendo `.tar.gz`:

    unzip aseprite-v1.3.18.1-macos-arm64.zip
    tar -xzf aseprite-v1.3.18.1-macos-arm64.tar.gz
    cd aseprite-v1.3.18.1-macos-arm64

O binário **não é assinado nem notarizado** — assinar exigiria uma conta
Apple Developer paga. O Gatekeeper vai bloquear a primeira execução. Remova a
marca de quarentena:

    xattr -dr com.apple.quarantine Aseprite.app
    open Aseprite.app

Só há build **arm64** (Apple Silicon). Macs Intel não são suportados por este
repositório.

## Build local

Os mesmos scripts usados no CI funcionam na sua máquina. Descubra a versão a
compilar e exporte-a:

**Windows** (requer Visual Studio com "Desktop development with C++", Git,
7-Zip e CMake):

    set ASEPRITE_VERSION=v1.3.18.1
    build.cmd

Para descobrir a versão mais recente sem abrir o navegador, use o Git Bash que
acompanha o Git for Windows:

    bash scripts/resolve-version.sh

**Linux / macOS:**

    export ASEPRITE_VERSION="$(bash scripts/resolve-version.sh)"
    ./build.sh

Os scripts sempre re-clonam o Aseprite na versão exata solicitada, então cada
execução parte de uma árvore limpa. O download da Skia é reaproveitado entre
execuções.

As dependências de cada plataforma estão no [INSTALL.md](INSTALL.md) oficial
do Aseprite.

## Como a versão é resolvida

`scripts/resolve-version.sh` é a única fonte de verdade:

1. Sem argumento, consulta `GET /repos/aseprite/aseprite/releases/latest` — a
   API já exclui drafts e prereleases.
2. Normaliza a entrada, adicionando o prefixo `v` se faltar.
3. Valida contra `^v[0-9]+(\.[0-9]+){1,3}(-beta[0-9]+)?$` **antes** de a string
   chegar a qualquer URL ou comando `git`.
4. Confirma que a tag existe no repositório oficial, falhando cedo e com
   mensagem clara se não existir.

A suíte de testes roda sem dependências externas:

    bash tests/resolve-version.test.sh

## Aviso legal

Este repositório não distribui nem contém código ou binários do Aseprite. Ele
apenas automatiza a compilação a partir do código-fonte oficial. O Aseprite é
propriedade da Igara Studio S.A. e está sujeito ao seu [EULA][]. Compile
somente se você possui uma licença válida e não redistribua os binários
gerados.

[Aseprite]: https://github.com/aseprite/aseprite
[EULA]: https://github.com/aseprite/aseprite/blob/main/EULA.txt
[versions]: https://github.com/aseprite/aseprite/tags
[download page]: https://www.aseprite.org/download/
```

- [ ] **Step 3: Verificar que todos os links e imagens resolvem**

```bash
grep -oE '\]\((images/[^)]+)\)' README.md | sed -E 's/.*\((.*)\)/\1/' | while read -r f; do
  [ -f "$f" ] && echo "ok   $f" || echo "MISS $f"
done
grep -oE '^\[[^]]+\]: .*' README.md
```

Esperado: as seis imagens marcadas `ok` e as quatro definições de link listadas (`Aseprite`, `EULA`, `versions`, `download page`).

- [ ] **Step 4: Confirmar que nenhum workflow ganhou trigger automático**

```bash
grep -nE "^on:|workflow_dispatch|push:|schedule:|pull_request:|release:" .github/workflows/*.yml
grep -rn "gh-release\|create-release\|softprops" .github/ || echo "no release publishing: ok"
```

Esperado: cada workflow mostra apenas `on:` seguido de `workflow_dispatch:`; nenhuma ocorrência de `push:`, `schedule:`, `pull_request:` ou `release:`; e a segunda busca imprime `no release publishing: ok`.

- [ ] **Step 5: Commit e push**

```bash
git add README.md .gitignore
git commit -m "docs: rewrite README for the three per-OS workflows"
git push
```

---

## Fora de escopo (registrado deliberadamente)

- **Cache da Skia e ccache.** O ganho é de ~30s por execução contra duas chamadas de API extras e um problema de ordem (a tag da Skia só é conhecida após o clone). Não compensa.
- **macOS x86_64 e universal binary.** Exigiria dois builds e um merge via `lipo`.
- **Assinatura e notarização no macOS.** Depende de conta Apple Developer paga (US$ 99/ano) e de secrets no repositório.
- **Windows arm64.** Sem Skia pré-compilada oficial para essa arquitetura.
- **Pinagem do VS 2022.** Decisão explícita de aceitar o VS 2026 que a imagem `windows-2025` traz hoje. Se um build futuro quebrar por incompatibilidade de toolset, o primeiro suspeito é este.

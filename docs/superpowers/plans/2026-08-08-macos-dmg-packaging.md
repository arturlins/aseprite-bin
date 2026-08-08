# macOS `.dmg` Packaging — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Substituir o `.tar.gz` do build macOS por um `.dmg` com `Aseprite.app`, alias para `/Applications` e um `READ ME FIRST.txt`, dando ao bundle o ícone que ele hoje não tem, e reescrever o README por inteiro em inglês para público leigo.

**Architecture:** Duas unidades novas e independentes, cada uma consumível isoladamente numa máquina de dev sem repetir os ~10 minutos de compilação: `scripts/make-icns.sh` converte os PNGs versionados do upstream num `Aseprite.icns` (o `Info.plist` do upstream declara esse arquivo, mas o repositório do Aseprite não o versiona), e `scripts/make-dmg.sh` empacota um `.app` pronto num `.dmg` via `dmgbuild`. O `build.sh` orquestra as duas no branch Darwin; Linux e Windows ficam intocados.

**Tech Stack:** Bash (POSIX-ish, `set -euo pipefail`), `iconutil` e `hdiutil` (nativos do macOS), `dmgbuild` 1.6.7 num venv Python descartável com pins por hash, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-08-macos-dmg-packaging-design.md`

## Global Constraints

- **Plataforma dos scripts novos:** macOS apenas. `make-icns.sh` e `make-dmg.sh` nunca rodam no Linux nem no Windows.
- **Linux e Windows intocados.** `build.cmd`, `build-linux.yml`, `build-windows.yml` e o branch Linux do `build.sh` não mudam.
- **Falha ao gerar o DMG falha o build.** Nenhum fallback silencioso para tarball.
- **Sem background customizado no DMG.** Arte de instalador faria o pacote parecer um instalador oficial do Aseprite; este repositório não é um.
- **Sem assinatura e sem notarização.** Fora de escopo (exigiria conta Apple Developer paga).
- **Nome do volume:** `Aseprite <versao-sem-v>` (ex.: `Aseprite 1.3.18.1`), limite de 27 caracteres do HFS+.
- **Nome do arquivo de saída:** `dist/aseprite-<versao>-macos-arm64.dmg`.
- **Arquivo dentro do DMG:** `READ ME FIRST.txt`, exatamente com esse nome, espaços incluídos.
- **Idioma do conteúdo voltado ao usuário:** inglês. Vale para o `README.md` e para o `READ ME FIRST.txt`.
- **Idioma dos testes:** português, para casar com `tests/resolve-version.test.sh` já existente. Não é contradição com a linha acima: testes não são voltados ao usuário. Uma passagem de tradução na suíte inteira seria uma limpeza separada.
- **Convenção de teste:** bash puro, sem framework, stubs em `PATH`, contadores `pass`/`fail`, linhas `ok   - <nome>` / `FAIL - <nome>`, e `[ "$fail" -eq 0 ]` na última linha. Copie o formato de `tests/resolve-version.test.sh`.
- **Pins do `dmgbuild` (verificados em 2026-08-08 na API do PyPI):**
  - `dmgbuild==1.6.7` wheel `37ee5771c377beb3203d9164aae8046ffed8531c06edf9227f5788b3c599b1bf`
  - `ds-store==1.3.3` wheel `b92a371efbf1b4ccce2a04d1ed13fceacc4736c81ba09cf5aefb74c088160a35`
  - `mac-alias==2.2.3` wheel `7362b521d2132ef92f606a37abfed5fcd849ceb2f28b6f9743e014b02af92f0d`
- **Tempos de build a citar no README:** ~20 min Windows, ~13 min Linux, ~10 min macOS (valores já publicados no README atual).

---

## File Structure

| Arquivo | Responsabilidade |
|---|---|
| `scripts/make-icns.sh` | **Criar.** Recebe a árvore de fontes do Aseprite e um caminho de saída; monta um `.iconset` e chama `iconutil`. Não sabe o que é um bundle. |
| `tests/make-icns.test.sh` | **Criar.** Cobre a tabela de mapeamento e o aborto por PNG ausente, com `iconutil` stubado. Roda em qualquer plataforma. |
| `tests/make-dmg.test.sh` | **Criar.** Cobre as pré-condições de `make-dmg.sh` (argumentos, `.app` ausente, ícone ausente, nome de volume longo demais) — tudo que acontece antes de qualquer ferramenta macOS. |
| `tests/run-all.sh` | **Criar.** Roda todos os `tests/*.test.sh`. Com dois arquivos de teste, listar cada um no README à mão vira dívida na hora. |
| `scripts/make-dmg.sh` | **Criar.** Recebe um `.app` pronto, gera o `READ ME FIRST.txt`, chama `dmgbuild` e verifica o resultado montando a imagem. |
| `scripts/dmg-settings.py` | **Criar.** Arquivo de configuração do `dmgbuild`: layout da janela, posições, ícone de volume. Lê caminhos do ambiente. |
| `scripts/dmg-requirements.txt` | **Criar.** Pins por versão e hash de `dmgbuild`, `ds-store`, `mac-alias`. |
| `build.sh` | **Modificar.** Branch Darwin: gera o ícone após o `ninja` e chama `make-dmg.sh` no lugar do tarball. Branch Linux inalterado. |
| `.github/workflows/build-macos.yml` | **Modificar.** Uma linha: `path: dist/*.dmg`. |
| `README.md` | **Reescrever por completo, em inglês, para público leigo.** |

`.gitignore` não muda: `build` já é ignorado, o que cobre `build/.dmg-venv`.

**Ordem:** Tasks 1 e 2 são independentes entre si. A Task 3 depende das duas. As Tasks 4 e 5 dependem da 3.

---

### Task 1: `make-icns.sh` — o ícone que falta

**Files:**
- Create: `scripts/make-icns.sh`
- Test: `tests/make-icns.test.sh`
- Create: `tests/run-all.sh`

**Interfaces:**
- Consumes: nada.
- Produces: executável `scripts/make-icns.sh`. Uso: `make-icns.sh <aseprite-src-dir> <output.icns>`. Escreve o `.icns` exatamente no caminho pedido, criando o diretório-pai se preciso. Exit 0 em sucesso; exit 1 com mensagem em stderr se faltar argumento ou se qualquer PNG de origem não existir. Não imprime nada em stdout além da linha final `Icon: <caminho>`.

**Contexto para quem implementa:** o `src/main/osx/Info.plist` do Aseprite declara `CFBundleIconFile = Aseprite.icns`, mas o `.icns` não está versionado no repositório deles e o CMake não gera nenhum. Um bundle compilado do fonte sai sem ícone. Os PNGs em `data/icons/`, porém, estão versionados. `iconutil` (nativo do macOS) transforma um diretório `.iconset` de PNGs com nomes canônicos num `.icns`.

Não existe `icon_512x512@2x.png` (1024px) porque o upstream não tem essa arte. `iconutil` aceita iconset parcial; 512 já cobre Dock e Finder em uso normal.

- [ ] **Step 1: Escrever a suíte de testes que falha**

Crie `tests/make-icns.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/make-icns.sh
# Run: bash tests/make-icns.test.sh
#
# make-icns.sh only runs for real on macOS, because iconutil is a macOS tool.
# What these tests cover is everything that happens *before* iconutil: the
# mapping from upstream PNG paths to canonical iconset names, and the refusal
# to carry on when upstream moves a file. A stub iconutil on PATH makes both
# reachable from any platform.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/make-icns.sh"

pass=0
fail=0

check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "1" ]; then
    pass=$((pass + 1))
    printf 'ok   - %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s\n       %s\n' "$name" "$detail"
  fi
}

# Creates a fake `iconutil` in $1 that mimics `iconutil -c icns <set> -o <out>`.
# It writes the sorted listing of the iconset it was handed to the file named
# by $ICONSET_MANIFEST, which is how the tests below inspect the mapping
# without needing a real macOS.
make_stub_iconutil() {
  mkdir -p "$1"
  cat > "$1/iconutil" <<'STUB'
#!/usr/bin/env bash
iconset=""
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *)  iconset="$1"; shift ;;
  esac
done
[ -n "$iconset" ] || { echo "stub: no iconset argument" >&2; exit 1; }
[ -n "$out" ] || { echo "stub: no -o argument" >&2; exit 1; }
[ -d "$iconset" ] || { echo "stub: iconset $iconset is not a directory" >&2; exit 1; }
if [ -n "${ICONSET_MANIFEST:-}" ]; then
  ls "$iconset" | LC_ALL=C sort > "$ICONSET_MANIFEST"
fi
printf 'fake icns payload\n' > "$out"
STUB
  chmod +x "$1/iconutil"
}

# Builds a fake Aseprite source tree in $1 containing every PNG make-icns.sh
# needs. $2, if given, names one PNG to leave out, which is how the
# missing-upstream-file case is set up.
make_fake_src() {
  local root="$1" skip="${2:-}"
  mkdir -p "$root/data/icons/hd"
  local f
  for f in ase16.png ase32.png ase64.png ase128.png ase256.png; do
    [ "$f" = "$skip" ] && continue
    printf 'png\n' > "$root/data/icons/$f"
  done
  [ "$skip" = "asehd.png" ] || printf 'png\n' > "$root/data/icons/hd/asehd.png"
}

# The nine canonical names iconutil must be handed, in LC_ALL=C order.
# 1024px (icon_512x512@2x) is deliberately absent: upstream ships no artwork
# that large. Captured through a command substitution, not `read -d ''`, so
# the trailing newline is stripped on this side exactly as it is on the
# `$(cat manifest)` side being compared against.
EXPECTED_ICONSET="$(cat <<'EOF'
icon_128x128.png
icon_128x128@2x.png
icon_16x16.png
icon_16x16@2x.png
icon_256x256.png
icon_256x256@2x.png
icon_32x32.png
icon_32x32@2x.png
icon_512x512.png
EOF
)"

# --- the iconset handed to iconutil is exactly the canonical set ------------

tmp="$(mktemp -d)"
make_stub_iconutil "$tmp/bin"
make_fake_src "$tmp/src"
ICONSET_MANIFEST="$tmp/manifest" \
  PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$tmp/src" "$tmp/out/Aseprite.icns" >/dev/null 2>&1
status=$?
got="$(cat "$tmp/manifest" 2>/dev/null)"
if [ "$status" = "0" ] && [ "$got" = "$EXPECTED_ICONSET" ]; then
  check "iconset contem exatamente os nove nomes canonicos" 1
else
  check "iconset contem exatamente os nove nomes canonicos" 0 \
    "$(printf 'status=%s\n       want=%q\n       got =%q' "$status" "$EXPECTED_ICONSET" "$got")"
fi

# The output directory does not exist beforehand on purpose: build.sh points
# this script straight at Aseprite.app/Contents/Resources/, which a bundle
# built from source may not have yet.
if [ -f "$tmp/out/Aseprite.icns" ]; then
  check "cria o diretorio de saida e escreve no caminho pedido" 1
else
  check "cria o diretorio de saida e escreve no caminho pedido" 0 "arquivo nao criado"
fi
rm -rf "$tmp"

# --- a PNG upstream no longer ships is a hard failure -----------------------
#
# This is the regression that matters most. A silently missing icon is exactly
# the bug being fixed here, so it must never come back by omission.

tmp="$(mktemp -d)"
make_stub_iconutil "$tmp/bin"
make_fake_src "$tmp/src" "asehd.png"
err="$(ICONSET_MANIFEST="$tmp/manifest" \
  PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$tmp/src" "$tmp/out/Aseprite.icns" 2>&1 >/dev/null)"
status=$?
[ "$status" = "1" ] \
  && check "png ausente no upstream aborta com status 1" 1 \
  || check "png ausente no upstream aborta com status 1" 0 "status=$status"
[ -n "$err" ] \
  && check "png ausente reporta o motivo em stderr" 1 \
  || check "png ausente reporta o motivo em stderr" 0 "stderr vazio"
[ ! -f "$tmp/out/Aseprite.icns" ] \
  && check "png ausente nao deixa icns pela metade" 1 \
  || check "png ausente nao deixa icns pela metade" 0 "arquivo de saida foi criado"
rm -rf "$tmp"

# --- argument handling ------------------------------------------------------

tmp="$(mktemp -d)"
make_stub_iconutil "$tmp/bin"
err="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" 2>&1 >/dev/null)"
status=$?
[ "$status" = "1" ] && [ -n "$err" ] \
  && check "sem argumentos aborta com uso em stderr" 1 \
  || check "sem argumentos aborta com uso em stderr" 0 "status=$status stderr=$err"

err="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$tmp/src" 2>&1 >/dev/null)"
status=$?
[ "$status" = "1" ] && [ -n "$err" ] \
  && check "um argumento so aborta com uso em stderr" 1 \
  || check "um argumento so aborta com uso em stderr" 0 "status=$status stderr=$err"
rm -rf "$tmp"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Rodar os testes para confirmar que falham**

Run: `bash tests/make-icns.test.sh`
Expected: FAIL em todos os casos, porque `scripts/make-icns.sh` ainda não existe (`bash: .../make-icns.sh: No such file or directory`, status 127).

- [ ] **Step 3: Escrever `scripts/make-icns.sh`**

```bash
#!/usr/bin/env bash
#
# Builds Aseprite.icns from the PNG icons the Aseprite source tree ships.
#
# Upstream declares CFBundleIconFile = Aseprite.icns in src/main/osx/Info.plist
# but does not version the .icns itself, and its CMake does not generate one --
# so a bundle built straight from source has no icon at all. The PNGs under
# data/icons/ *are* versioned, and iconutil (part of macOS) turns them into the
# missing file.
#
# Usage: make-icns.sh <aseprite-src-dir> <output.icns>
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: make-icns.sh <aseprite-src-dir> <output.icns>" >&2
  exit 1
fi

SRC="$1"
OUT="$2"

# <canonical iconset name>:<path relative to the Aseprite source tree>.
# The @2x entries are the same artwork at double resolution, which is why
# several sources appear twice. There is no icon_512x512@2x.png (1024px)
# because upstream ships no artwork that large; iconutil accepts a partial
# iconset, and 512 already covers the Dock and Finder at normal sizes.
MAPPING="
icon_16x16.png:data/icons/ase16.png
icon_16x16@2x.png:data/icons/ase32.png
icon_32x32.png:data/icons/ase32.png
icon_32x32@2x.png:data/icons/ase64.png
icon_128x128.png:data/icons/ase128.png
icon_128x128@2x.png:data/icons/ase256.png
icon_256x256.png:data/icons/ase256.png
icon_256x256@2x.png:data/icons/hd/asehd.png
icon_512x512.png:data/icons/hd/asehd.png
"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Aseprite.iconset"
mkdir -p "$ICONSET"

for entry in $MAPPING; do
  name="${entry%%:*}"
  src="${entry#*:}"
  if [ ! -f "$SRC/$src" ]; then
    echo "error: $SRC/$src not found" >&2
    echo "       upstream may have moved or renamed its icon PNGs -- the app" >&2
    echo "       would ship with no icon at all, so this is a hard failure" >&2
    exit 1
  fi
  cp "$SRC/$src" "$ICONSET/$name"
done

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"

# iconutil has been known to report success while writing nothing when handed
# an iconset it dislikes. The whole point of this script is that the icon is
# actually there, so confirm it rather than trust the exit code.
if [ ! -f "$OUT" ]; then
  echo "error: iconutil reported success but did not produce $OUT" >&2
  exit 1
fi

echo "Icon: $OUT"
```

- [ ] **Step 4: Tornar o script executável e rodar os testes**

Run:
```bash
chmod +x scripts/make-icns.sh
bash tests/make-icns.test.sh
```
Expected: `7 passed, 0 failed`, exit 0.

- [ ] **Step 5: Criar `tests/run-all.sh`**

```bash
#!/usr/bin/env bash
# Runs every test suite in this directory.
# Run: bash tests/run-all.sh
set -uo pipefail

cd "$(dirname "$0")"

failed=0
for suite in *.test.sh; do
  printf '== %s\n' "$suite"
  bash "$suite" || failed=$((failed + 1))
  printf '\n'
done

if [ "$failed" -ne 0 ]; then
  printf '%d suite(s) failed\n' "$failed" >&2
  exit 1
fi

printf 'all suites passed\n'
```

- [ ] **Step 6: Rodar a suíte completa**

Run:
```bash
chmod +x tests/run-all.sh
bash tests/run-all.sh
```
Expected: `resolve-version.test.sh` e `make-icns.test.sh` passam, e a última linha é `all suites passed`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/make-icns.sh tests/make-icns.test.sh tests/run-all.sh
git commit -m "feat: gerar o Aseprite.icns que o upstream nao versiona

O Info.plist do Aseprite declara CFBundleIconFile = Aseprite.icns, mas o
repositorio nao versiona esse arquivo e o CMake nao gera nenhum, entao o
bundle compilado do fonte sai sem icone. Os PNGs em data/icons/ estao
versionados e o iconutil resolve o resto.

Os testes stubam o iconutil para cobrir, de qualquer plataforma, as duas
partes que erram na pratica: a tabela de mapeamento e o aborto quando o
upstream move um PNG. Sem esse aborto, o bug volta por omissao."
```

---

### Task 2: `make-dmg.sh` — o pacote

**Files:**
- Create: `scripts/make-dmg.sh`
- Create: `scripts/dmg-settings.py`
- Create: `scripts/dmg-requirements.txt`
- Test: `tests/make-dmg.test.sh`

**Interfaces:**
- Consumes: um `.app` que já contenha `Contents/Resources/Aseprite.icns` (produzido pela Task 1 via `build.sh`).
- Produces: executável `scripts/make-dmg.sh`. Uso: `make-dmg.sh <app-path> <version> <output.dmg>`, com `<version>` no formato `v1.3.18.1`. Exit 0 em sucesso, imprimindo `DMG: <caminho>` como última linha. Exit 1 com mensagem em stderr se: contagem de argumentos ≠ 3, `.app` inexistente, `Aseprite.icns` ausente dentro do bundle, nome de volume acima de 27 caracteres, ou qualquer asserção da verificação pós-geração falhar.

**Contexto para quem implementa:** `dmgbuild` foi escolhido sobre `create-dmg` porque a prettificação do `create-dmg` é feita por AppleScript dirigindo o Finder, que falha de forma intermitente justamente no runner `macos-15` (Sequoia) que este repositório usa. `dmgbuild` escreve o `.DS_Store` diretamente, sem Finder envolvido.

O venv existe para contornar o PEP 668 (o Python do sistema no runner é "externally managed") e para tornar a dependência descartável. Fica em `build/.dmg-venv`, que já é ignorado pelo `.gitignore` (`build`).

- [ ] **Step 1: Escrever a suíte de testes que falha**

Crie `tests/make-dmg.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/make-dmg.sh
# Run: bash tests/make-dmg.test.sh
#
# Everything make-dmg.sh does after its preconditions pass -- creating a venv,
# running dmgbuild, mounting the result -- is macOS-only and cannot run here.
# What these tests pin down is the guard rail in front of all that: the script
# must refuse, loudly and before doing any work, when handed something it
# cannot package. The real coverage of the packaging itself is the
# mount-and-assert block at the end of the script, which runs on every build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/make-dmg.sh"

pass=0
fail=0

check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "1" ]; then
    pass=$((pass + 1))
    printf 'ok   - %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s\n       %s\n' "$name" "$detail"
  fi
}

# Builds a fake Aseprite.app in $1. $2 = "no-icon" leaves out the .icns that
# make-icns.sh is supposed to have put there.
make_fake_app() {
  local app="$1" variant="${2:-}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  printf 'fake binary\n' > "$app/Contents/MacOS/aseprite"
  [ "$variant" = "no-icon" ] || printf 'fake icns\n' > "$app/Contents/Resources/Aseprite.icns"
}

# run_precondition <name> <expected_status> <want_stderr:yes|no> [args...]
# Asserts on status and on whether anything was written to stderr. A status
# code alone cannot tell a script that explained its refusal apart from one
# that died silently.
run_precondition() {
  local name="$1" want_status="$2" want_stderr="$3"
  shift 3

  local err status
  err="$(bash "$SCRIPT" "$@" 2>&1 >/dev/null)"
  status=$?

  local ok=1 detail=""
  if [ "$status" != "$want_status" ]; then
    ok=0; detail="want status=$want_status got=$status"
  elif [ "$want_stderr" = "yes" ] && [ -z "$err" ]; then
    ok=0; detail="esperava mensagem em stderr, veio vazio"
  elif [ "$want_stderr" = "no" ] && [ -n "$err" ]; then
    ok=0; detail="esperava stderr vazio, veio: $err"
  fi
  check "$name" "$ok" "$detail"
}

run_precondition "sem argumentos aborta" 1 yes
run_precondition "argumentos de menos abortam" 1 yes "/nope/Aseprite.app"
run_precondition "argumentos demais abortam" 1 yes \
  "/nope/Aseprite.app" "v1.3.18.1" "out.dmg" "extra"

tmp="$(mktemp -d)"
run_precondition "app inexistente aborta" 1 yes \
  "$tmp/missing/Aseprite.app" "v1.3.18.1" "$tmp/out.dmg"

# The .icns is what make-icns.sh is responsible for. If packaging ran anyway,
# the user would get a DMG whose app has no icon and whose volume has no icon
# -- silently, which is the failure mode this whole change exists to remove.
make_fake_app "$tmp/no-icon/Aseprite.app" "no-icon"
run_precondition "app sem Aseprite.icns aborta" 1 yes \
  "$tmp/no-icon/Aseprite.app" "v1.3.18.1" "$tmp/out.dmg"

# HFS+ caps volume names at 27 characters. Nothing the version regex allows
# gets near that today, but a silently truncated volume name would be a
# baffling thing to debug, so the script checks instead of hoping.
make_fake_app "$tmp/ok/Aseprite.app"
run_precondition "nome de volume longo demais aborta" 1 yes \
  "$tmp/ok/Aseprite.app" "v1.3.18.1-this-version-string-is-far-too-long" "$tmp/out.dmg"

[ ! -f "$tmp/out.dmg" ] \
  && check "nenhuma pre-condicao falha deixa dmg pela metade" 1 \
  || check "nenhuma pre-condicao falha deixa dmg pela metade" 0 "out.dmg foi criado"
rm -rf "$tmp"

# --- the settings file must not drift from the script -----------------------
#
# dmg-settings.py reads its paths from the environment. If a name is changed
# on one side only, dmgbuild dies with a KeyError deep inside a CI run instead
# of here.
SETTINGS="$ROOT/scripts/dmg-settings.py"
for var in DMG_APP_PATH DMG_README_PATH DMG_VOLUME_ICON; do
  if grep -q "$var" "$SETTINGS" && grep -q "$var" "$SCRIPT"; then
    check "$var e usado nos dois lados" 1
  else
    check "$var e usado nos dois lados" 0 "ausente em dmg-settings.py ou em make-dmg.sh"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Rodar os testes para confirmar que falham**

Run: `bash tests/make-dmg.test.sh`
Expected: FAIL em todos os casos — `scripts/make-dmg.sh` e `scripts/dmg-settings.py` ainda não existem.

- [ ] **Step 3: Criar `scripts/dmg-requirements.txt`**

```
# Pinned by version and hash, the same discipline this repository already
# applies to GitHub Actions (pinned by commit SHA). Installed into a throwaway
# venv by scripts/make-dmg.sh.
#
# dmgbuild is used instead of create-dmg because create-dmg's window layout is
# produced by AppleScript driving the Finder, which fails intermittently on the
# macos-15 runners this repository builds on. dmgbuild writes the .DS_Store
# directly.
#
# ds-store and mac-alias are dmgbuild's runtime dependencies; --require-hashes
# demands that every package in the resolved graph be pinned, transitive ones
# included.
#
# To refresh: look up the wheel sha256 for each package at
# https://pypi.org/pypi/<name>/json

dmgbuild==1.6.7 \
    --hash=sha256:37ee5771c377beb3203d9164aae8046ffed8531c06edf9227f5788b3c599b1bf
ds-store==1.3.3 \
    --hash=sha256:b92a371efbf1b4ccce2a04d1ed13fceacc4736c81ba09cf5aefb74c088160a35
mac-alias==2.2.3 \
    --hash=sha256:7362b521d2132ef92f606a37abfed5fcd849ceb2f28b6f9743e014b02af92f0d
```

- [ ] **Step 4: Criar `scripts/dmg-settings.py`**

```python
# dmgbuild settings for the Aseprite disk image.
#
# Consumed by scripts/make-dmg.sh, which passes paths in through the
# environment so this file holds layout only and nothing build-specific.
#
# There is deliberately no custom background image. A DMG with installer
# artwork would read as an official Aseprite installer, and this repository is
# emphatically not one -- it only automates compiling from source for someone
# who already owns a license.

import os

application = os.environ["DMG_APP_PATH"]
readme = os.environ["DMG_README_PATH"]

app_name = os.path.basename(application)
readme_name = os.path.basename(readme)

# --- contents ---------------------------------------------------------------

files = [application, readme]
symlinks = {"Applications": "/Applications"}

# Volume icon, shown once the image is mounted. This is the icon that lives
# inside the image and survives any transport. Giving the .dmg *file* itself a
# custom icon would mean an extended attribute, which does not survive the zip
# GitHub Actions wraps every artifact in -- so it is not attempted.
icon = os.environ["DMG_VOLUME_ICON"]

# --- image ------------------------------------------------------------------

format = "UDZO"
size = None  # dmgbuild sizes the image from its contents

# --- window -----------------------------------------------------------------

window_rect = ((100, 100), (640, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
background = None

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_locations = {
    app_name: (160, 170),
    "Applications": (480, 170),
    readme_name: (320, 310),
}
```

- [ ] **Step 5: Escrever `scripts/make-dmg.sh`**

```bash
#!/usr/bin/env bash
#
# Packages a built Aseprite.app into a .dmg the user can drag into
# /Applications.
#
# Replaces a .tar.gz, which forced the user through zip -> tar.gz -> folder ->
# .app with no hint that any of it belonged in /Applications.
#
# Usage: make-dmg.sh <app-path> <version> <output.dmg>
#   e.g. make-dmg.sh build/bin/Aseprite.app v1.3.18.1 dist/aseprite.dmg
#
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "usage: make-dmg.sh <app-path> <version> <output.dmg>" >&2
  exit 1
fi

APP="$1"
VERSION="$2"
OUT="$3"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$APP" ]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

# The icon is make-icns.sh's job. Packaging without it would hand the user a
# DMG whose app and volume are both iconless -- silently, which is exactly the
# failure this change exists to remove.
ICNS="$APP/Contents/Resources/Aseprite.icns"
if [ ! -f "$ICNS" ]; then
  echo "error: $ICNS not found" >&2
  echo "       run scripts/make-icns.sh against the bundle before packaging" >&2
  exit 1
fi

VERSION_NUMBER="${VERSION#v}"
VOLNAME="Aseprite $VERSION_NUMBER"

# HFS+ caps volume names at 27 characters. Nothing the version regex allows
# gets near that, but a silently truncated volume name is a baffling thing to
# debug, so check rather than hope.
if [ "${#VOLNAME}" -gt 27 ]; then
  echo "error: volume name '$VOLNAME' exceeds the 27-character HFS+ limit" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
MOUNT="$(mktemp -d)"
# Detach unconditionally: this runs on the success path and on every failure
# path, and a still-mounted image would wedge the next build on the same
# runner. Errors are swallowed so a failed detach cannot mask the real error.
cleanup() {
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  rm -rf "$STAGE" "$MOUNT"
}
trap cleanup EXIT


# --- the note that unblocks the user ---------------------------------------
#
# A DMG fixes how the app is installed, not the fact that macOS refuses to run
# it. The binary is ad-hoc signed and not notarized, and Sequoia removed the
# Control-click -> Open shortcut, so without this note a user who successfully
# drags the app into /Applications is still stuck.

README="$STAGE/READ ME FIRST.txt"
cat > "$README" <<EOF
Aseprite $VERSION_NUMBER — how to install


STEP 1 — Copy the app

    Drag the Aseprite icon on the left onto the Applications folder on the
    right. That copies Aseprite onto your Mac.


STEP 2 — Allow it to run

    Open the Terminal app. (Press Command+Space, type "Terminal", press
    Return.) Copy the line below, paste it into the Terminal window, and
    press Return:

        xattr -dr com.apple.quarantine /Applications/Aseprite.app

    It prints nothing at all when it works. That is normal.


STEP 3 — Open Aseprite

    Open your Applications folder and double-click Aseprite.

    You only ever do steps 1 and 2 once per build.


WHY IS STEP 2 NEEDED?

    macOS refuses to open apps that have not been "notarized" by Apple.
    Notarizing requires a paid Apple Developer account, which this build
    does not use — so macOS treats Aseprite as untrusted even though you
    compiled it yourself from the official Aseprite source code.

    The command in step 2 clears that flag, for this one app only.

    Prefer not to use the Terminal? Try to open Aseprite and let macOS block
    it. Then open System Settings, go to Privacy & Security, scroll to the
    bottom, and click "Open Anyway".


LICENSE

    You need an Aseprite license to use this build, and you may not
    redistribute it. https://www.aseprite.org/
EOF


# --- dmgbuild ---------------------------------------------------------------
#
# Installed into a throwaway venv rather than the system Python, which is
# marked externally-managed (PEP 668) on the runner. --require-hashes makes
# the pinned hashes in dmg-requirements.txt binding; --only-binary keeps pip
# on wheels, so no package ever gets to run a build script.

VENV="$ROOT/build/.dmg-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check \
    --require-hashes --only-binary=:all: \
    -r "$ROOT/scripts/dmg-requirements.txt"
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

DMG_APP_PATH="$APP" \
DMG_README_PATH="$README" \
DMG_VOLUME_ICON="$ICNS" \
  "$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" "$VOLNAME" "$OUT"


# --- verify -----------------------------------------------------------------
#
# This script is macOS-only, so tests/ (which runs anywhere) can only cover its
# preconditions. This block is the real test of the packaging, and it runs on
# every build rather than on demand.

hdiutil attach "$OUT" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null

verify_failed() {
  echo "error: DMG verification failed -- $1" >&2
  exit 1
}

[ -d "$MOUNT/Aseprite.app" ] \
  || verify_failed "Aseprite.app is missing from the image"
[ -L "$MOUNT/Applications" ] \
  || verify_failed "the Applications symlink is missing -- users cannot drag-install"
[ "$(readlink "$MOUNT/Applications")" = "/Applications" ] \
  || verify_failed "Applications points at $(readlink "$MOUNT/Applications"), not /Applications"
[ -f "$MOUNT/Aseprite.app/Contents/Resources/Aseprite.icns" ] \
  || verify_failed "the app bundle inside the image has no icon"
[ -f "$MOUNT/READ ME FIRST.txt" ] \
  || verify_failed "READ ME FIRST.txt is missing -- users would hit Gatekeeper with no way out"

echo "DMG: $OUT"
```

- [ ] **Step 6: Tornar executável e rodar os testes**

Run:
```bash
chmod +x scripts/make-dmg.sh
bash tests/make-dmg.test.sh
```
Expected: `10 passed, 0 failed`, exit 0.

- [ ] **Step 7: Rodar a suíte completa**

Run: `bash tests/run-all.sh`
Expected: três suítes passam, `all suites passed`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add scripts/make-dmg.sh scripts/dmg-settings.py scripts/dmg-requirements.txt tests/make-dmg.test.sh
git commit -m "feat: empacotar o build macOS num .dmg

Substitui o .tar.gz, que obrigava o usuario a passar por zip -> tar.gz ->
pasta -> .app sem nenhum sinal de que aquilo pertencia a /Applications.

dmgbuild em vez de create-dmg: a prettificacao do create-dmg depende de
AppleScript dirigindo o Finder, que falha de forma intermitente no runner
macos-15 usado aqui. dmgbuild escreve o .DS_Store direto.

O DMG nao remove o bloqueio do Gatekeeper -- o binario nao e notarizado e
o Sequoia tirou o Ctrl+clique -> Abrir. Dai o READ ME FIRST.txt, que
explica o porque e nao so o comando a copiar.

Como esses scripts sao macOS-only e a suite tests/ roda em qualquer
plataforma, a verificacao que monta a imagem no fim do script e o teste de
verdade, e ela roda em todo build."
```

---

### Task 3: Integrar no `build.sh`

**Files:**
- Modify: `build.sh:178` (após `ninja -C build aseprite`) e `build.sh:181-212` (seção de packaging)

**Interfaces:**
- Consumes: `scripts/make-icns.sh` e `scripts/make-dmg.sh` das Tasks 1 e 2, com as assinaturas ali definidas.
- Produces: `dist/aseprite-<versao>-macos-arm64.dmg` no macOS. No Linux, `dist/aseprite-<versao>-linux-x64.tar.gz`, exatamente como hoje.

**Contexto:** o `build.sh` de hoje monta um `STAGE` e um tarball para as duas plataformas. Depois desta task, o tarball vira exclusividade do Linux. As variáveis `OS`, `ARCH` e `VERSION` já existem no escopo (definidas em `build.sh:34-56`).

- [ ] **Step 1: Inserir a geração do ícone logo após o `ninja`**

Em `build.sh`, localize:

```bash
ninja -C build aseprite


# --- package ---------------------------------------------------------------
```

Substitua por:

```bash
ninja -C build aseprite


# --- app icon (macOS) ------------------------------------------------------
#
# Upstream's Info.plist declares CFBundleIconFile = Aseprite.icns but the
# Aseprite repository does not version that file, so a bundle built from
# source has no icon. Belongs here rather than in packaging: the icon is part
# of the app, not of how the app is shipped.

if [ "$OS" = macos ]; then
  ICNS="build/bin/Aseprite.app/Contents/Resources/Aseprite.icns"
  if [ -f "$ICNS" ]; then
    echo "Bundle already ships an icon, keeping upstream's"
  else
    ./scripts/make-icns.sh aseprite "$ICNS"
  fi
fi


# --- package ---------------------------------------------------------------
```

- [ ] **Step 2: Trocar o packaging do macOS pelo DMG**

Localize o bloco de packaging inteiro, de `rm -rf dist` até `echo "Done: $TARBALL"`:

```bash
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
  # No aseprite.ini here on purpose: macOS .app bundles keep preferences
  # under ~/Library, not next to the executable, so an ini inside
  # Contents/MacOS would have no effect (unlike the Linux/Windows portable
  # mode below).
fi

tar -czf "$TARBALL" -C "$STAGE" "aseprite-$VERSION-$OS-$ARCH"

echo "Done: $TARBALL"
```

Substitua por:

```bash
rm -rf dist
mkdir -p dist

if [ "$OS" = linux ]; then
  TARBALL="dist/aseprite-$VERSION-$OS-$ARCH.tar.gz"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT

  STAGE_DIR="$STAGE/aseprite-$VERSION-$OS-$ARCH"
  mkdir -p "$STAGE_DIR"
  cp build/bin/aseprite "$STAGE_DIR/"
  chmod +x "$STAGE_DIR/aseprite"
  cp -R build/bin/data "$STAGE_DIR/data"
  cp -R aseprite/docs "$STAGE_DIR/docs"
  echo '# This file is here so Aseprite behaves as a portable program' > "$STAGE_DIR/aseprite.ini"

  # A tarball rather than a plain directory because actions/upload-artifact
  # drops the executable bit and symlinks.
  tar -czf "$TARBALL" -C "$STAGE" "aseprite-$VERSION-$OS-$ARCH"

  echo "Done: $TARBALL"
else
  # A .dmg rather than a tarball: the artifact already arrives wrapped in a
  # zip, and asking a user to then unpack a tar.gz and move a bundle by hand
  # was the whole problem. Dragging onto the Applications alias is the
  # install step every Mac user already knows.
  #
  # aseprite/docs is dropped on purpose -- it is the manual, which is
  # available online, and it has no place inside an installer volume.
  DMG="dist/aseprite-$VERSION-$OS-$ARCH.dmg"
  ./scripts/make-dmg.sh build/bin/Aseprite.app "$VERSION" "$DMG"

  echo "Done: $DMG"
fi
```

- [ ] **Step 3: Atualizar o cabeçalho do `build.sh`**

Localize, no topo do arquivo:

```bash
# Produces a .tar.gz inside dist/ — a tarball rather than a plain directory
# because actions/upload-artifact drops the executable bit and symlinks.
```

Substitua por:

```bash
# Produces, inside dist/: a .tar.gz on Linux (a tarball rather than a plain
# directory because actions/upload-artifact drops the executable bit and
# symlinks) and a .dmg on macOS.
```

- [ ] **Step 4: Verificar a sintaxe do script**

Run: `bash -n build.sh`
Expected: sem saída, exit 0.

Rode também, se `shellcheck` estiver disponível:

Run: `shellcheck build.sh scripts/make-icns.sh scripts/make-dmg.sh || true`
Expected: nenhum aviso de nível `error`. Avisos de `info`/`style` são aceitáveis se o código existente já os produz.

- [ ] **Step 5: Confirmar que o branch Linux não mudou de comportamento**

Run:
```bash
git diff build.sh
```
Expected: revisar manualmente que, dentro do branch `if [ "$OS" = linux ]`, as linhas `cp`, `chmod`, `cp -R`, `echo` e `tar -czf` são idênticas às anteriores — apenas reindentadas e reordenadas. Nenhuma mudança semântica no Linux.

- [ ] **Step 6: Commit**

```bash
git add build.sh
git commit -m "feat: build.sh gera .dmg no macOS em vez de .tar.gz

O tarball passa a ser exclusividade do Linux. No macOS, o build gera o
icone no bundle logo apos o ninja (o icone e parte do app, nao de como ele
e distribuido) e delega o empacotamento ao scripts/make-dmg.sh.

A pasta aseprite/docs sai do pacote macOS: e o manual, disponivel online,
e nao tem o que fazer dentro de um volume de instalacao.

Branch Linux inalterado em comportamento -- so reindentado."
```

---

### Task 4: Publicar o `.dmg` no workflow

**Files:**
- Modify: `.github/workflows/build-macos.yml:57`

**Interfaces:**
- Consumes: `dist/aseprite-<versao>-macos-arm64.dmg` produzido pela Task 3.
- Produces: artifact `aseprite-<versao>-macos-arm64` contendo o `.dmg`.

- [ ] **Step 1: Trocar o path do upload**

Em `.github/workflows/build-macos.yml`, localize:

```yaml
      - name: Upload artifact
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: aseprite-${{ steps.resolve.outputs.version }}-macos-arm64
          path: dist/*.tar.gz
          if-no-files-found: error
          retention-days: 7
```

Substitua por:

```yaml
      - name: Upload artifact
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: aseprite-${{ steps.resolve.outputs.version }}-macos-arm64
          path: dist/*.dmg
          if-no-files-found: error
          retention-days: 7
```

`if-no-files-found: error` continua sendo a rede de segurança: se o `make-dmg.sh` não produzir nada, o job falha em vez de publicar um artifact vazio.

- [ ] **Step 2: Validar o YAML**

Run: `python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build-macos.yml')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Confirmar que nenhuma outra referência a tar.gz sobrou no workflow macOS**

Run: `grep -n "tar.gz" .github/workflows/build-macos.yml || echo "nenhuma referencia"`
Expected: `nenhuma referencia`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-macos.yml
git commit -m "feat: publicar o .dmg como artifact do build macOS"
```

---

### Task 5: Reescrever o README em inglês

**Files:**
- Modify: `README.md` (substituição integral)

**Interfaces:**
- Consumes: os formatos de saída definidos nas Tasks 3 e 4.
- Produces: nada consumido por outra task.

**Contexto:** o README de hoje é em português e assume familiaridade com CI, tarballs e terminal. O público real é majoritariamente leigo e internacional. Idioma único, inglês — nada de versão bilíngue, porque duas versões divergem na primeira correção.

Regras que o texto tem que respeitar:

- Nenhum termo de CI, build ou terminal aparece sem uma explicação de uma linha na primeira ocorrência.
- As capturas em `images/` são mantidas e continuam ancorando os passos.
- A instalação macOS descreve o resultado esperado de cada passo.
- A quarentena é explicada, não só comandada.
- O aviso de licença continua no topo, sem suavizar.
- Nada é prometido sobre o ícone do arquivo `.dmg` desmontado — isso não foi verificado num Mac real.

- [ ] **Step 1: Substituir o `README.md` inteiro**

```markdown
# aseprite-bin

Compile [Aseprite][] for yourself using GitHub Actions, for Windows, Linux, or
macOS. No development tools to install and nothing to configure — you click a
button on a web page, wait, and download the result.

> [!IMPORTANT]
> **You need an Aseprite license.** The [EULA][] lets you compile Aseprite from
> source for your own use, but **forbids redistributing the binaries you
> produce**. The workflows here are manual-only and never publish a Release.
> Build artifacts expire after 7 days.
>
> If this repository is public, anyone signed in to GitHub can download the
> artifacts from your runs. If that bothers you, use **Import repository**
> instead of **Fork** and make your copy private — a fork of a public
> repository cannot be made private.

To buy a license, visit the [Aseprite download page][download page].

## What you get

A *workflow* is an automated job that GitHub runs for you on its own computers.
This repository has one per operating system, so you run only the one you need,
and a failure on one platform never affects the others.

| Workflow | Runs on | You download |
|---|---|---|
| `Build (Windows)` | `windows-2025` | a folder with `aseprite.exe`, `data/` and `docs/` |
| `Build (Linux)` | `ubuntu-22.04` | a `.tar.gz` archive with the program, `data/` and `docs/` |
| `Build (macOS)` | `macos-15` (Apple Silicon) | a `.dmg` disk image with `Aseprite.app` |

## How to build

### 1. Make your own copy of this repository

Click `Fork` at the top of the page.

![step1a](images/step1a.png)
![step1b](images/step1b.png)

> To keep your binaries out of reach of other people, use **`+` → Import
> repository** and mark the copy as **Private**, instead of forking.

### 2. Turn Actions on

Open the `Actions` tab and confirm that you want to enable workflows. GitHub
disables them by default on a new copy.

![step2](images/step2.png)

### 3. Run the workflow for your platform

Pick `Build (Windows)`, `Build (Linux)` or `Build (macOS)` from the list on the
left, then click `Run workflow`.

The `version` field is optional:

- **Leave it empty** — builds the **latest published release** of Aseprite.
  Prereleases and drafts are skipped.
- **Fill it in** — builds the version you name, for example `v1.3.18.1` or
  `v1.3.18-beta1`. The full list is on the [Aseprite tags page][versions].

![step3](images/step3.png)

### 4. Wait, then open the run

Compiling takes a while: roughly 20 minutes on Windows, 13 on Linux, 10 on
macOS. You can close the page and come back later.

![step4](images/step4.png)

### 5. Download the artifact at the bottom of the page

An *artifact* is just the file the job produced. GitHub always wraps it in a
`.zip`, whatever is inside.

![step5](images/step5.png)

To build a newer version later, repeat steps 3 to 5.

## After you download

### macOS

You downloaded a `.zip`. Inside it is a `.dmg` — a disk image, the usual way
Mac apps are delivered.

1. **Double-click the `.zip`.** A `.dmg` file appears next to it.

2. **Double-click the `.dmg`.** A window opens showing the Aseprite icon on the
   left and a folder called Applications on the right.

3. **Drag the Aseprite icon onto the Applications folder.** That copies
   Aseprite onto your Mac. When the copy finishes you can close the window and
   eject the disk image.

4. **Allow Aseprite to run.** Open the Terminal app — press Command+Space, type
   `Terminal`, press Return — then paste this line and press Return:

       xattr -dr com.apple.quarantine /Applications/Aseprite.app

   It prints nothing when it works. That is normal.

5. **Open Aseprite** from your Applications folder.

Steps 4 and 5 are only needed once per build.

#### Why is step 4 needed?

macOS refuses to open apps that have not been *notarized* by Apple. Notarizing
requires a paid Apple Developer account, which this project does not use — so
macOS treats Aseprite as untrusted even though you compiled it yourself from
the official source code. It is not a sign that anything is wrong with the
build.

The command in step 4 clears that flag for this one app.

If you would rather not use the Terminal: try to open Aseprite and let macOS
block it, then open System Settings, go to Privacy & Security, scroll to the
bottom, and click **Open Anyway**.

The same instructions are included as `READ ME FIRST.txt` inside the disk
image.

Only **Apple Silicon** (M1 and newer) is supported. Intel Macs are not built
here.

### Windows

The artifact is a `.zip` containing the folder
`aseprite-v1.3.18.1-windows-x64`. Unzip it anywhere you like and run:

    aseprite-v1.3.18.1-windows-x64\aseprite.exe

The included `aseprite.ini` makes the program portable, keeping its settings in
that same folder instead of in your user profile. Move the folder and your
settings come along.

### Linux

The artifact is a `.zip` containing a `.tar.gz`. The extra layer exists because
GitHub strips the executable permission when it packs a directory, and the
program would not start.

    unzip aseprite-v1.3.18.1-linux-x64.zip
    tar -xzf aseprite-v1.3.18.1-linux-x64.tar.gz
    cd aseprite-v1.3.18.1-linux-x64
    ./aseprite

It is compiled on Ubuntu 22.04 (glibc 2.35) and runs on distributions of that
generation or newer.

## Building on your own machine

The same scripts the automated builds use also run locally. First find the
version you want and set it as an environment variable.

**Windows** — needs Visual Studio with "Desktop development with C++", Git,
7-Zip and CMake:

    set ASEPRITE_VERSION=v1.3.18.1
    build.cmd

To look up the latest version without opening a browser, use the Git Bash that
comes with Git for Windows:

    bash scripts/resolve-version.sh

**Linux and macOS:**

    export ASEPRITE_VERSION="$(bash scripts/resolve-version.sh)"
    ./build.sh

Every run re-clones Aseprite at the exact version requested, so each build
starts from a clean tree. The Skia download is reused between runs.

Each platform's prerequisites are listed in Aseprite's official [INSTALL.md][].

## How the version is resolved

`scripts/resolve-version.sh` is the single source of truth:

1. With no argument, it queries `GET /repos/aseprite/aseprite/releases/latest`
   — that endpoint already excludes drafts and prereleases.
2. It normalizes the input, adding the `v` prefix if you left it out.
3. It validates against `^v[0-9]+(\.[0-9]+){1,3}(-beta[0-9]+)?$` **before** the
   string reaches any URL or `git` command.
4. It confirms the tag exists in the official repository, failing early and
   clearly if it does not.

The test suite runs with no external dependencies:

    bash tests/run-all.sh

## macOS packaging notes

The macOS build does two things the Aseprite source tree does not do on its
own.

**It gives the app its icon.** Aseprite's `Info.plist` declares an
`Aseprite.icns`, but that file is not in the open-source repository and its
CMake does not generate one — so an app compiled straight from source has no
icon at all. `scripts/make-icns.sh` builds it from the PNGs under
`data/icons/`, which are in the repository, using `iconutil`.

**It builds the disk image with [dmgbuild][], not `create-dmg`.**
`create-dmg` lays out its window by running AppleScript against the Finder,
which fails intermittently on the macOS runners used here. `dmgbuild` writes
the window layout directly, with no Finder involved. Its version is pinned by
hash in `scripts/dmg-requirements.txt`.

The disk image is not signed or notarized, and there is no plan to change that
— see step 4 above.

## Legal

This repository does not distribute or contain any Aseprite code or binaries.
It only automates compiling from the official source. Aseprite is the property
of Igara Studio S.A. and is subject to its [EULA][]. Compile only if you hold a
valid license, and do not redistribute what you build.

[Aseprite]: https://github.com/aseprite/aseprite
[INSTALL.md]: https://github.com/aseprite/aseprite/blob/main/INSTALL.md
[EULA]: https://github.com/aseprite/aseprite/blob/main/EULA.txt
[versions]: https://github.com/aseprite/aseprite/tags
[download page]: https://www.aseprite.org/download/
[dmgbuild]: https://github.com/dmgbuild/dmgbuild
```

- [ ] **Step 2: Conferir que as imagens referenciadas existem**

Run:
```bash
for f in step1a step1b step2 step3 step4 step5; do
  [ -f "images/$f.png" ] || echo "MISSING: images/$f.png"
done; echo "check done"
```
Expected: `check done` sem nenhuma linha `MISSING`.

- [ ] **Step 3: Conferir que nenhuma promessa desatualizada sobrou**

Run: `grep -n -i "tar.gz" README.md`
Expected: apenas ocorrências na seção **Linux** e na tabela `What you get`. Nenhuma na seção macOS.

Run: `grep -n "resolve-version.test.sh" README.md || echo "ok, aponta para run-all.sh"`
Expected: `ok, aponta para run-all.sh`

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: reescrever o README em ingles para publico leigo

Ingles para alcance, idioma unico -- versao bilingue diverge na primeira
correcao.

Cada termo de CI ou terminal ganha uma explicacao de uma linha na primeira
ocorrencia, e a instalacao no macOS descreve o resultado esperado de cada
passo em vez de assumir que .zip, .dmg e arrastar-para-Applications sao
obvios.

A quarentena e explicada, nao so comandada: copiar um comando sem entender
o porque e exatamente o que trava usuario leigo, e a mensagem do Gatekeeper
parece um build defeituoso quando na verdade e a ausencia de notarizacao."
```

---

## Verificação final (após todas as tasks)

Estes passos não pertencem a nenhuma task porque cruzam todas elas.

- [ ] **Suíte completa passa**

Run: `bash tests/run-all.sh`
Expected: `all suites passed`, exit 0.

- [ ] **Sintaxe de todo script shell**

Run: `for f in build.sh scripts/*.sh tests/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done; echo "check done"`
Expected: `check done`, sem linhas `SYNTAX ERROR`.

- [ ] **Nenhuma referência órfã ao tarball do macOS**

Run: `grep -rn "macos.*tar.gz\|tar.gz.*macos" --include="*.sh" --include="*.yml" --include="*.md" . || echo "nenhuma"`
Expected: `nenhuma`

- [ ] **Rodar o workflow `Build (macOS)` de verdade e baixar o artifact**

Esta é a única verificação que fecha o ciclo, e nenhum teste local a substitui. No Mac, confirmar:

1. O `.zip` contém um único `.dmg`.
2. O `.dmg` abre com `Aseprite.app` à esquerda, `Applications` à direita e `READ ME FIRST.txt` embaixo, em ícones de 128px numa janela de 640×400.
3. **`Aseprite.app` mostra o ícone do Aseprite**, não o genérico — é a correção principal e nenhum teste local prova isso.
4. O volume montado mostra o ícone do Aseprite.
5. Arrastar para Applications, rodar o comando do `READ ME FIRST.txt`, e o app abre.
6. `Aseprite > About` reporta a versão que foi pedida no workflow.

- [ ] **Item em aberto do spec: ícone do arquivo `.dmg` desmontado**

Enquanto o DMG do passo anterior estiver na pasta de Downloads, **antes de montar**, anotar se o Finder mostra o ícone do Aseprite ou o ícone genérico de imagem de disco. O spec registra isso como não resolvido pela pesquisa. Se mostrar o genérico, nada muda — o README já não promete o contrário. Registrar o resultado no spec.

---

## Self-review

**Cobertura do spec:**

| Requisito do spec | Task |
|---|---|
| `make-icns.sh`, tabela de mapeamento, aborto por PNG ausente | 1 |
| `make-dmg.sh`, `dmg-settings.py`, requirements pinados por hash | 2 |
| `READ ME FIRST.txt` em inglês, para leigo | 2, Step 5 |
| Verificação pós-geração montando a imagem | 2, Step 5 |
| Limite de 27 caracteres do nome de volume | 2 |
| Sem background customizado | 2, `dmg-settings.py` |
| Ícone de volume vindo de dentro do `.app` | 2, `dmg-settings.py` |
| `build.sh` gera o ícone após o `ninja`, pula se já existir | 3, Step 1 |
| `.tar.gz` do macOS removido, Linux intocado | 3, Steps 2 e 5 |
| Pasta `docs/` descartada no macOS | 3, Step 2 |
| Workflow publica `dist/*.dmg` | 4 |
| README reescrito por inteiro em inglês, para leigo | 5 |
| Quarentena explicada, não só comandada | 5 (`Why is step 4 needed?`) |
| Nada prometido sobre o ícone do `.dmg` desmontado | 5 + verificação final |
| Item em aberto a validar num Mac real | Verificação final |

**Consistência de nomes entre tasks:**

- `scripts/make-icns.sh <src> <out.icns>` — definido na Task 1, chamado na Task 3 Step 1 com essa assinatura.
- `scripts/make-dmg.sh <app> <version> <out.dmg>` — definido na Task 2, chamado na Task 3 Step 2 com essa assinatura.
- `DMG_APP_PATH`, `DMG_README_PATH`, `DMG_VOLUME_ICON` — usados em `make-dmg.sh` e em `dmg-settings.py`, e a Task 2 tem um teste que falha se um lado divergir do outro.
- `Aseprite.icns` no caminho `Contents/Resources/` — mesmo literal na Task 1 (teste), Task 2 (pré-condição e verificação) e Task 3 (variável `ICNS`).
- `READ ME FIRST.txt` — mesmo literal, com espaços, na Task 2 (geração, `icon_locations`, verificação) e na Task 5 (README).
- `tests/run-all.sh` — criado na Task 1, referenciado no README da Task 5.

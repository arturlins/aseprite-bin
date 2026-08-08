# Empacotamento macOS em `.dmg` — Design

**Data:** 2026-08-08
**Status:** aprovado, pronto para virar plano de implementação

## Problema

O build macOS entrega `dist/aseprite-<versao>-macos-arm64.tar.gz`. Como o GitHub
Actions sempre serve artifacts como `.zip`, o usuário percorre `zip` → `tar.gz` →
pasta → `.app`. O Archive Utility do macOS trata `.tar.gz` em dois passos e larga
tudo em `~/Downloads`, sem nenhum sinal de que aquilo deveria ir para
`/Applications`. Usuários relatam não conseguir instalar.

Um segundo problema, não relatado mas provavelmente responsável por parte da
confusão: **o `.app` que produzimos hoje não tem ícone.**

## Achados que fundamentam o design

### O `.app` não tem ícone — e a correção é gratuita

`src/main/osx/Info.plist` do upstream declara `CFBundleIconFile = Aseprite.icns`,
mas **não existe nenhum `.icns` no repositório do Aseprite** (verificado na
árvore completa via API do GitHub) e `src/CMakeLists.txt` não contém nenhum
tratamento de ícone. A Igara mantém o `.icns` fora do código aberto. Resultado:
nosso bundle referencia um recurso inexistente e o Finder/Dock caem no ícone
genérico.

O material de origem, porém, está versionado e é suficiente:

| Fonte no repo do Aseprite | Tamanhos |
|---|---|
| `data/icons/ase{16,20,24,28,32,48,64,128,256}.png` | 16 a 256, pixel art |
| `data/icons/hd/asehd.png` | 512, versão HD do ícone do app |

Dá para montar um `.iconset` e rodar `iconutil -c icns` — ferramenta nativa do
macOS, sem dependência. Falta apenas o 1024 (`icon_512x512@2x`); `iconutil`
aceita iconset parcial, e 512 já cobre Dock e Finder em uso normal.

Gravar `Contents/Resources/Aseprite.icns` no bundle é seguro: o `.app` carrega
apenas a assinatura ad-hoc que o linker aplica ao Mach-O arm64, não há
`_CodeSignature/CodeResources` selando recursos que pudesse ser invalidado.

Usar o ícone do próprio Aseprite, compilado do fonte do próprio Aseprite, para
uso pessoal, não conflita com o EULA — é o mesmo ato de compilar.

### O DMG não resolve o Gatekeeper

O binário é ad-hoc, não notarizado. O `.dmg` chega dentro do `.zip` do Actions,
baixado por browser, então a quarentena se propaga para tudo que sai dele. E o
macOS 15 Sequoia **removeu** o atalho Ctrl+clique → Abrir.

O caminho do usuário passa a ser `xattr -dr com.apple.quarantine`, ou System
Settings → Privacy & Security → "Open Anyway".

Consequência de design: o DMG melhora a **ergonomia de instalação**, não o
bloqueio de segurança. Se o objetivo é o usuário conseguir instalar, tratar
apenas o empacotamento resolve metade. O passo da quarentena precisa ser
impossível de errar — por isso o `LEIA-ME.txt` dentro do DMG faz parte do
escopo, não é enfeite.

O conserto real seria uma conta Apple Developer (US$ 99/ano) com Developer ID e
notarização. Fora de escopo, mas a ferramenta escolhida já tem o gancho.

### Escolha da ferramenta: `dmgbuild`

Três candidatos avaliados:

**`create-dmg`** — o layout bonito dele (posição de ícones, tamanho de janela) é
produzido por AppleScript dirigindo o Finder. É exatamente o ponto frágil no CI:

- [create-dmg#186](https://github.com/create-dmg/create-dmg/issues/186) —
  "Failed running AppleScript" / `Can't get disk -1728` **no macOS 15 Sequoia**,
  que é o `macos-15` do nosso runner
- [runner-images#7522](https://github.com/actions/runner-images/issues/7522) e
  [#12323](https://github.com/actions/runner-images/issues/12323) —
  `hdiutil create failed - Resource busy` aleatório nos runners macOS

Tem mitigações (`--hdiutil-retries`, default 5; `--applescript-sleep-duration`),
e `--skip-jenkins` / `--sandbox-safe` — mas essas duas desligam justamente a
prettificação, reduzindo a ferramenta a "hdiutil com passos extras".

**`hdiutil` puro** — nativo e determinístico, mas sem `.DS_Store` não há layout:
a janela abre na visualização padrão do Finder.

**`dmgbuild` (escolhido)** — escreve o `.DS_Store` diretamente via `ds_store` e
`mac_alias`, **sem Finder e sem AppleScript**. Layout completo (window rect,
tamanho de ícone, posições, ícone de volume) sem exposição à flakiness acima.
v1.6.7 publicada em 2026-01-15, projeto ativo. Dependências puro-Python. O extra
`badge-icons` (que puxaria `pyobjc-framework-Quartz`) não é necessário: ele só
serve para compor o ícone sobre o badge genérico de disco, e nós fornecemos um
`.icns` pronto.

### Ícone do arquivo `.dmg` vs. ícone do volume

São mecanismos distintos:

- **Volume montado** — o `.icns` vive dentro da imagem, é controlável e sobrevive
  a qualquer transporte. Está no escopo.
- **O arquivo `.dmg` no Finder** — exigiria gravar o ícone no próprio arquivo
  (resource fork / `com.apple.FinderInfo`). Isso é extended attribute, e **não
  sobrevive ao `.zip` do Actions**. Fora de escopo.

Não foi encontrada fonte definitiva sobre o Finder exibir, ou não, o ícone de
volume para um `.dmg` desmontado. **Item a validar num Mac real.** Não altera o
design; altera apenas o que o README promete.

### Risco de marca

Um DMG com background customizado e seta "arraste para cá" passa a parecer um
**instalador oficial do Aseprite**. Este repositório é deliberadamente cuidadoso
com o EULA (workflow manual, sem Release, aviso legal no README). Usar o ícone do
app é legítimo; desenhar arte de instalador não é.

**Decisão: sem background customizado.** Layout limpo, ícone real.

## Decisões

| Decisão | Escolha |
|---|---|
| Ferramenta de DMG | `dmgbuild` |
| Conteúdo do DMG | `Aseprite.app` + alias `Applications` + `LEIA-ME.txt` |
| Pasta `docs/` | Descartada (é o manual, disponível online) |
| `.tar.gz` do macOS | Removido — o DMG o substitui |
| Falha ao gerar o DMG | Falha o build. Sem fallback silencioso para tarball |
| Background do DMG | Nenhum |
| Ícone do arquivo `.dmg` | Fora de escopo (não sobrevive ao zip do Actions) |
| Assinatura / notarização | Fora de escopo |
| Linux e Windows | Intocados |

## Arquitetura

Três unidades, cada uma com um propósito e uma interface explícita.

### `scripts/make-icns.sh`

```
make-icns.sh <aseprite-src-dir> <saida.icns>
```

Monta um `.iconset` a partir dos PNGs do upstream e roda `iconutil -c icns`.
Mapeamento:

| Nome no iconset | Origem |
|---|---|
| `icon_16x16.png` | `data/icons/ase16.png` |
| `icon_16x16@2x.png` | `data/icons/ase32.png` |
| `icon_32x32.png` | `data/icons/ase32.png` |
| `icon_32x32@2x.png` | `data/icons/ase64.png` |
| `icon_128x128.png` | `data/icons/ase128.png` |
| `icon_128x128@2x.png` | `data/icons/ase256.png` |
| `icon_256x256.png` | `data/icons/ase256.png` |
| `icon_256x256@2x.png` | `data/icons/hd/asehd.png` |
| `icon_512x512.png` | `data/icons/hd/asehd.png` |

O script escreve exatamente no caminho recebido e não conhece nada sobre bundles.
Aborta com mensagem clara se qualquer PNG de origem tiver sumido do upstream —
mesmo padrão do assert de version stamp já presente em `build.sh`. Um ícone
silenciosamente ausente é exatamente o bug que estamos consertando; ele não pode
voltar por omissão.

Gerar o ícone é parte de **construir** o app, não de empacotá-lo. Quem decide
onde ele vai é o `build.sh`, logo após o `ninja`: se
`build/bin/Aseprite.app/Contents/Resources/Aseprite.icns` **já existir** (ou
seja, o upstream passou a fornecer o próprio ícone), o `build.sh` não chama o
script; caso contrário, chama passando esse caminho como destino. É o caminho
que o `Info.plist` do upstream já declara.

### `scripts/make-dmg.sh` + `scripts/dmg-settings.py`

```
make-dmg.sh <app-path> <versao> <saida.dmg>
```

Consome um `.app` pronto. Isolado assim, o visual do DMG pode ser iterado num Mac
de dev em segundos, sem repetir os ~10 minutos de compilação.

`dmgbuild` é instalado num venv descartável em `build/.dmg-venv`, a partir de
`scripts/dmg-requirements.txt` **pinado por versão e hash** — mesmo rigor que o
repositório já aplica às Actions, pinadas por SHA. O venv também contorna o
PEP 668 do Python do sistema no runner.

Pins no momento do design (a confirmar na implementação):

```
dmgbuild==1.6.7   sha256:37ee5771c377beb3203d9164aae8046ffed8531c06edf9227f5788b3c599b1bf
ds-store==1.3.3   sha256:b92a371efbf1b4ccce2a04d1ed13fceacc4736c81ba09cf5aefb74c088160a35
mac-alias==2.2.3  sha256:7362b521d2132ef92f606a37abfed5fcd849ceb2f28b6f9743e014b02af92f0d
```

`dmg-settings.py` é o arquivo de configuração do `dmgbuild`, lendo caminhos e
versão do ambiente:

- `volume_name`: `Aseprite <versao-sem-v>` (ex.: `Aseprite 1.3.18.1`) — dentro do
  limite de 27 caracteres do HFS+
- `format`: `UDZO`
- `window_rect`: `((100, 100), (640, 400))`
- `icon_size`: 128
- posições: `Aseprite.app` em (160, 170), `Applications` em (480, 170),
  `LEIA-ME.txt` em (320, 310)
- `icon`: ícone de volume, lido de `<app-path>/Contents/Resources/Aseprite.icns`
  — o `make-dmg.sh` recebe só o `.app` e tira o ícone de dentro dele, sem
  precisar de um argumento a mais nem saber como o ícone foi produzido
- `background`: nenhum

### `LEIA-ME.txt`

Gerado pelo `make-dmg.sh` em diretório temporário (não versionado), com a versão
interpolada. Conteúdo:

1. Arraste `Aseprite.app` para `Applications`
2. Rode `xattr -dr com.apple.quarantine /Applications/Aseprite.app`
3. Uma linha explicando o porquê: o binário não é notarizado, o que exigiria uma
   conta Apple Developer paga
4. Alternativa sem terminal: System Settings → Privacy & Security → "Open Anyway"

## Fluxo de dados

```
build.sh (Darwin)
  └─ ninja -C build aseprite
       → build/bin/Aseprite.app            (sem ícone)
  └─ scripts/make-icns.sh aseprite \
         build/bin/Aseprite.app/Contents/Resources/Aseprite.icns
       (pulado se o arquivo já existir)
  └─ scripts/make-dmg.sh build/bin/Aseprite.app <versao> dist/<nome>.dmg
       ├─ venv + dmgbuild (pinado por hash)
       ├─ gera LEIA-ME.txt
       ├─ dmgbuild -s dmg-settings.py
       └─ verificação pós-geração
            → dist/aseprite-<versao>-macos-arm64.dmg

build-macos.yml
  └─ upload-artifact: dist/*.dmg
```

## Tratamento de erro e verificação

Todo script roda sob `set -euo pipefail`, consistente com `build.sh`.

`make-dmg.sh` termina montando o DMG em modo read-only e afirmando:

- `Aseprite.app` existe na raiz do volume
- `Applications` é symlink para `/Applications`
- `Aseprite.app/Contents/Resources/Aseprite.icns` existe
- `LEIA-ME.txt` existe

Depois desmonta (com `trap` garantindo o detach mesmo em falha) e sai diferente
de zero em qualquer asserção quebrada.

Isso é deliberado e precisa ser dito com honestidade: `make-icns.sh` e
`make-dmg.sh` são macOS-only, então não há como cobri-los pela suíte `tests/`,
que roda em qualquer plataforma. **Essa verificação pós-geração é o teste**, e
ela roda em todo build — não é um passo opcional de QA.

## Arquivos afetados

| Arquivo | Ação |
|---|---|
| `scripts/make-icns.sh` | **Criar.** Gera `Aseprite.icns` dos PNGs do upstream. |
| `scripts/make-dmg.sh` | **Criar.** Gera e verifica o `.dmg`. |
| `scripts/dmg-settings.py` | **Criar.** Configuração do `dmgbuild`. |
| `scripts/dmg-requirements.txt` | **Criar.** Pins com hash de `dmgbuild`, `ds-store`, `mac-alias`. |
| `build.sh` | **Modificar.** Branch macOS chama os dois scripts e deixa de gerar tarball. Branch Linux intocado. |
| `.github/workflows/build-macos.yml` | **Modificar.** `path: dist/*.dmg`. |
| `README.md` | **Modificar.** Linha da tabela e seção "macOS". |
| `.gitignore` | **Verificar.** `build/` já é ignorado, cobrindo `build/.dmg-venv`. |

## Fora de escopo

- Assinatura com Developer ID e notarização
- Build universal (x86_64) — o repositório é arm64-only por decisão anterior
- Background customizado no DMG
- Ícone customizado no arquivo `.dmg` desmontado
- Alterações nos builds Linux e Windows
- Cache do venv entre execuções (ganho marginal, complexidade real — mesma
  postura já adotada para o cache da Skia)

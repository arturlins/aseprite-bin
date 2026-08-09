# Instalador Windows via NSIS — Design

**Data:** 2026-08-09
**Status:** aprovado, pronto para virar plano de implementação

## Problema

O build Windows hoje só entrega uma pasta portátil,
`dist/aseprite-<versao>-windows-x64/`, com um `aseprite.ini` marcador forçando
modo portátil (configurações salvas na própria pasta). O GitHub Actions zipa
essa pasta automaticamente ao publicar o artifact — não existe nenhum passo de
empacotamento explícito além disso.

Isso é adequado para quem quer rodar sem instalar, mas não oferece o caminho
"instala no PC, cria atalho, associa `.aseprite`/`.ase`, aparece em
Adicionar/Remover Programas" que a maioria dos usuários espera de um programa
Windows. O pedido é acrescentar esse caminho sem descontinuar o portátil.

## Achados que fundamentam o design

### O repositório oficial do Aseprite não tem instalador NSIS pronto

[aseprite/aseprite#322](https://github.com/aseprite/aseprite/issues/322) é um
pedido de "Windows Installer" ainda em aberto. Não existe `.nsi`, script CPack
NSIS, nem qualquer coisa equivalente na árvore do projeto. O script precisa ser
escrito do zero neste repositório, no mesmo espírito de `scripts/make-dmg.sh` /
`scripts/dmg-settings.py` para o macOS: infraestrutura nossa, consumindo o
binário compilado do Aseprite sem tocar no código dele.

### `windows-2025` (o runner atual) não vem com NSIS

Confirmado em
[actions/runner-images#11754](https://github.com/actions/runner-images/issues/11754)
e [#11755](https://github.com/actions/runner-images/pull/11755): NSIS não está
na imagem `windows-2025` (só passou a ser cogitado depois). O workflow precisa
instalar antes de compilar — `choco install nsis -y` resolve, já que o
Chocolatey vem pronto em todo runner hospedado do GitHub, sem exigir uma action
de terceiro.

### Compilar uma vez, empacotar duas

Portátil e instalador usam exatamente o mesmo `aseprite.exe` e a mesma pasta
`data/`. Compilar duas vezes (~20 min cada) para gerar dois formatos do mesmo
binário não tem propósito — o mesmo raciocínio que já levou este repositório a
reaproveitar o download de Skia entre execuções locais. O empacotamento do
instalador consome a pasta portátil já montada (`dist/aseprite-<versao>
-windows-x64/`) como fonte, em vez de copiar os arquivos do `build/bin` de novo.

### Elevação: nem sempre é opção, então precisa ser escolha em tempo de execução

O pedido original era instalar sempre em Program Files (admin). Mas em máquina
corporativa travada por política de grupo, o usuário simplesmente não tem
privilégio de admin — um instalador que exige elevação incondicionalmente não
roda. A resposta padrão do mercado (Chrome, Firefox, VS Code, Discord) é deixar
o usuário escolher em tempo de execução: "para todos os usuários" (Program
Files, precisa admin) ou "só para mim" (`%LocalAppData%\Programs`, sem admin).

Duas formas de implementar essa escolha com auto-elevação foram avaliadas:

- **`MultiUser.nsh` + plugin `UAC.dll`** — é o par que instaladores grandes
  (Inkscape, Notepad++) usam, com a implementação mais madura e testada.
  `MultiUser.nsh` vem no NSIS padrão, mas `UAC.dll` **não** — é um plugin de
  terceiro, baixado à parte e precisaria ser fixado por hash tanto no CI quanto
  localmente, como mais uma dependência externa pinada para manter.
- **Feito à mão, sem plugin extra (escolhido)** — usa só o que já vem em
  `choco install nsis`: o plugin `UserInfo` (embutido no NSIS padrão) para
  detectar se o processo já está elevado, e a instrução nativa `ExecShell
  "runas"` para relançar o próprio instalador elevado somente quando "todos os
  usuários" for escolhido e o processo ainda não estiver elevado. Mais lógica
  para manter no `.nsi` deste repositório, mas nenhuma dependência de terceiro
  nova — mesma postura já adotada no macOS ao preferir `dmgbuild` a
  `create-dmg` por causa da fragilidade de dependências externas em CI.

### Ícone: possivelmente já embutido no `.exe`

Diferente do `.icns` do macOS (comprovadamente ausente do repositório do
Aseprite), o Windows normalmente embute o ícone do app como recurso do próprio
`.exe` via um `.rc` compilado pelo CMake. Não foi possível confirmar isso sem
um clone local da árvore do Aseprite (o `build.cmd` só clona durante o build).
**Item a verificar na implementação**: se `build\bin\aseprite.exe` já carrega
um ícone, o instalador e os atalhos reaproveitam `$INSTDIR\aseprite.exe,0`
diretamente, sem gerar nenhum `.ico` à parte. Só se o ícone realmente não
existir é que entra um passo equivalente ao `make-icns.sh` do macOS, desta vez
gerando um `.ico` a partir de `data/icons/*.png` (mesma fonte já usada lá).

## Decisões

| Decisão | Escolha |
|---|---|
| Compilação | Uma vez só; portátil e instalador reaproveitam o mesmo binário |
| Empacotamento do instalador | `makensis` sobre `scripts/installer.nsi`, consumindo a pasta portátil já montada como fonte |
| NSIS no CI | `choco install nsis -y`, novo step antes do build |
| Artifacts no Actions | Dois, separados: `aseprite-<versao>-windows-x64` (portátil, como hoje) e `aseprite-<versao>-windows-x64-setup` (instalador) |
| Escopo de instalação | Escolha em tempo de execução: todos os usuários (Program Files, `HKLM`) vs. só o usuário atual (`%LocalAppData%\Programs`, `HKCU`) |
| Opção pré-selecionada | "Todos os usuários" |
| Mecanismo de auto-elevação | `UserInfo` (embutido) + `ExecShell "runas"` — sem plugin `UAC.dll` de terceiro |
| `RequestExecutionLevel` | `user` — nunca pede UAC só por abrir o instalador |
| Pasta de instalação | Sem número de versão: `Aseprite`, não `aseprite-<versao>-windows-x64` |
| Upgrade / reinstalação | Apaga `$INSTDIR\data` antes de copiar os arquivos novos, evitando arquivos órfãos de versões antigas |
| `aseprite.ini` (marcador portátil) | Não copiado no instalador — versão instalada usa `%APPDATA%` normalmente |
| Atalho de Menu Iniciar | Sempre criado |
| Atalho de Desktop | Checkbox opcional, **desmarcado** por padrão |
| Associação `.aseprite` / `.ase` | Checkbox opcional, **marcado** por padrão |
| Add/Remove Programs | Entrada registrada (nome, versão, ícone, publisher, tamanho, string de desinstalação) |
| Desinstalador | Detecta o próprio escopo pelo caminho de onde está rodando (`$INSTDIR` sob Program Files vs. LocalAppData) — sem precisar de marcador extra |
| Ícone | Reaproveita o do `.exe` se já existir; gera um `.ico` só se necessário (a confirmar na implementação) |
| Assinatura do instalador | Fora de escopo, mesma postura já adotada para o `.dmg` do macOS (sem notarização) |
| Linux e macOS | Intocados |

## Arquitetura

### `scripts/installer.nsi`

Script NSIS único, Modern UI 2. Parametrizado via `/D` na linha de comando do
`makensis` (versão, caminho de origem, caminho de saída) — mesmo padrão de
"script não sabe de onde veio o valor" já usado em `dmg-settings.py`.

Fluxo do instalador:

1. **Tela de escolha de escopo** — radio "Todos os usuários" (pré-selecionado)
   / "Só para mim".
2. **Ao avançar:**
   - "Todos os usuários" + processo não elevado → `ExecShell "runas"` relança
     o próprio `.exe` com um argumento marcador (ex.: `/ALLUSERS`) que faz a
     instância elevada pular a tela de escolha; a instância original chama
     `Quit`. Se o usuário recusar o prompt UAC, mostra aviso e sai, sem tentar
     escrever em Program Files sem permissão.
   - "Todos os usuários" + já elevado → segue direto.
   - "Só para mim" → segue sem pedir elevação, sempre.
3. **Diretório e contexto** definidos pelo escopo:
   - Todos os usuários: `$INSTDIR = $PROGRAMFILES64\Aseprite`,
     `SetShellVarContext all`, registro em `HKLM`.
   - Só para mim: `$INSTDIR = $LOCALAPPDATA\Programs\Aseprite`,
     `SetShellVarContext current`, registro em `HKCU`.
4. **Tela de componentes** — checkboxes de atalho de desktop (desmarcado) e
   associação de arquivo (marcado).
5. **Instalação**: `RMDir /r "$INSTDIR\data"` (se existir) → copia
   `aseprite.exe`, `data\`, `docs\` da pasta portátil já montada → grava
   atalho de Menu Iniciar sempre, atalho de Desktop se marcado → registra
   `.aseprite`/`.ase` se marcado → grava entrada de Add/Remove Programs →
   grava desinstalador.
6. **Associação de arquivo**: ProgId `Aseprite.Document` em
   `<hive>\Software\Classes`, com `DefaultIcon` e `shell\open\command`
   apontando para `$INSTDIR\aseprite.exe`; chama `SHChangeNotify` para o
   Explorer atualizar sem precisar de logoff.
7. **Desinstalador**: lê o próprio caminho para inferir escopo (Program Files
   vs. LocalAppData), remove `$INSTDIR`, atalhos, chave de Uninstall e chaves
   de associação de arquivo.

### `build.cmd`

- Novo guard `where /q makensis.exe`, ao lado dos guards já existentes (`git`,
  `7z`), **antes** de compilar — falha em segundos se faltar, não depois de
  ~20 min de build.
- Novo bloco no final, depois do empacotamento portátil existente: chama
  `makensis` com `/DVERSION=%ASEPRITE_VERSION%` e os caminhos de origem/saída,
  gerando `dist\aseprite-%ASEPRITE_VERSION%-windows-x64-setup.exe`.

### `.github/workflows/build-windows.yml`

- Novo step `choco install nsis -y` antes do step `Build`.
- Novo step `actions/upload-artifact` (mesma versão pinada por hash já usada),
  `name: aseprite-<versao>-windows-x64-setup`, `path: dist\*.exe`.

### `README.md`

- Tabela "What you get": linha do Windows passa a citar os dois formatos.
- Seção "Windows": instruções do instalador (rodar o `.exe`, escolher escopo,
  associação de arquivo, atalho de desktop) ao lado das instruções já
  existentes do portátil.
- Seção "Building on your own machine": NSIS entra como pré-requisito para
  quem quiser gerar o instalador localmente.

## Fluxo de dados

```
build.cmd
  └─ cmake + ninja                          (inalterado)
       → build\bin\aseprite.exe, data\
  └─ empacotamento portátil                 (inalterado)
       → dist\aseprite-<versao>-windows-x64\
  └─ makensis /DVERSION=<versao> scripts\installer.nsi
       ├─ fonte: dist\aseprite-<versao>-windows-x64\
       └─ saída: dist\aseprite-<versao>-windows-x64-setup.exe

build-windows.yml
  ├─ upload-artifact: dist\aseprite-<versao>-windows-x64      (portátil)
  └─ upload-artifact: dist\*.exe                              (instalador)
```

## Tratamento de erro e verificação

- `build.cmd` falha cedo (guard de `makensis.exe`) em vez de compilar e só
  descobrir a dependência faltando na hora de empacotar — mesmo padrão já
  usado para `git.exe` e `7z.exe`.
- O relançamento elevado (`ExecShell "runas"`) checa o código de erro; se o
  usuário recusar o UAC, o instalador mostra uma mensagem explicando e sai,
  em vez de tentar (e falhar silenciosamente) escrever em Program Files sem
  permissão.
- Teste de fumaça `tests/make-installer.test.sh`, no espírito de
  `make-dmg.test.sh`: monta uma pasta fixture mínima (exe e dados fake) e roda
  `makensis` contra `scripts/installer.nsi` com uma versão de teste,
  verificando que o `.exe` de saída é gerado sem erro. Isso cobre erros de
  sintaxe/referência no script, não o comportamento em tempo de instalação.
- O comportamento de instalação em si (registro, atalhos, elevação,
  desinstalação limpa) não é testável por script de forma realista — ao
  contrário do macOS, esta máquina roda Windows de verdade, então o plano é
  uma validação manual ao final da implementação: instalar em cada escopo,
  abrir um `.aseprite` por duplo clique, desinstalar, e confirmar que as
  chaves de registro somem.

## Arquivos afetados

| Arquivo | Ação |
|---|---|
| `scripts/installer.nsi` | **Criar.** Script NSIS completo descrito acima. |
| `scripts/make-ico.ps1` (ou similar) | **Criar, se necessário** — só se a checagem de ícone embutido no `.exe` (achado acima) confirmar que falta gerar um `.ico`. |
| `build.cmd` | **Modificar.** Guard de `makensis.exe` + bloco de empacotamento do instalador. |
| `.github/workflows/build-windows.yml` | **Modificar.** Step `choco install nsis -y` + segundo `upload-artifact`. |
| `tests/make-installer.test.sh` | **Criar.** Teste de fumaça do `makensis`. |
| `README.md` | **Modificar.** Tabela, seção Windows, pré-requisitos locais. |

## Fora de escopo

- Assinatura de código do instalador
- `MultiUser.nsh` + plugin `UAC.dll` (preterido pela implementação sem plugin
  extra)
- Migração de configurações entre modo portátil e modo instalado
- Alterações nos builds Linux e macOS
- Atualização automática (auto-update) do Aseprite instalado

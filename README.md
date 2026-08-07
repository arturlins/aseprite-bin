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

O tempo de build varia por plataforma: cerca de 24 minutos no Windows, 13 no
Linux e 10 no macOS.

![step4](images/step4.png)

### 5. Baixe o artifact no fim da página

![step5](images/step5.png)

Para compilar uma versão nova depois, repita os passos 3 a 5.

## Depois do download

### Windows

O artifact é um `.zip` contendo a pasta `aseprite-v1.3.18.1-windows-x64`:

    aseprite-v1.3.18.1-windows-x64\aseprite.exe

O `aseprite.ini` incluso faz o programa se comportar como portable, guardando
as configurações na própria pasta.

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

As dependências de cada plataforma estão no [INSTALL.md][] oficial
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
[INSTALL.md]: https://github.com/aseprite/aseprite/blob/main/INSTALL.md
[EULA]: https://github.com/aseprite/aseprite/blob/main/EULA.txt
[versions]: https://github.com/aseprite/aseprite/tags
[download page]: https://www.aseprite.org/download/

# Instalador NSIS — Ícone, Upgrade Robusto e Escudo UAC — Design

**Data:** 2026-08-12
**Status:** aprovado, pronto para virar plano de implementação

## Problema

O instalador NSIS descrito em
[2026-08-09-windows-nsis-installer-design.md](2026-08-09-windows-nsis-installer-design.md)
está funcional, mas testado em uso real (upgrade de v1.3.18.1 para v1.3.18.2)
expôs três lacunas de polimento:

1. `setup.exe` e o `uninstall.exe` gerado usam o ícone genérico do NSIS, não o
   ícone do Aseprite — o item "verificar na implementação" do design anterior
   ficou pendente.
2. O upgrade funcionou, mas hoje o instalador só apaga `$INSTDIR\data` antes
   de copiar os arquivos novos (`Section "-core" SecCore`). Isso não cobre
   arquivos órfãos fora de `data\`, nem o caso de uma instalação anterior em
   outro diretório (o usuário pode ter redirecionado `$INSTDIR` na tela de
   diretório em alguma execução anterior), nem deixa o Add/Remove Programs e
   os atalhos garantidamente consistentes com a nova versão.
3. A tela de escolha de escopo ("todos os usuários" vs. "só para mim") não
   deixa visualmente óbvio que a primeira opção vai disparar um prompt UAC —
   outros instaladores (Chrome, Discord, VS Code) resolvem isso com o ícone de
   escudo do Windows sobreposto ao botão "Next".

## Achados que fundamentam o design

### O `.ico` do Aseprite já existe no clone, não precisa ser gerado

`src/main/win/resources_win32.rc`, no repositório oficial do Aseprite,
referencia `data/icons/ase.ico` como o ícone (resource ID 0, o que o Explorer
trata como ícone padrão) do próprio `aseprite.exe`:

```rc
0 ICON data/icons/ase.ico
1 ICON data/icons/doc.ico
2 ICON data/icons/ext.ico
```

Esse `.ico` é um arquivo binário já commitado no repositório oficial, não algo
gerado em build time — diferente do `.icns` do macOS, que precisou de
`make-icns.sh` porque só existiam PNGs soltos. `build.cmd` já clona
`aseprite/` inteiro e mantém essa árvore presente durante o passo de
empacotamento do instalador (não é apagada antes disso), então
`aseprite\data\icons\ase.ico` está disponível no momento em que `makensis` é
chamado, sem precisar de conversão nem de nada commitado neste repositório.

### O botão Next é um controle único, compartilhado por todas as páginas

No MUI2, o botão "Next"/"Install"/"Finish" pertence ao frame pai (`$HWNDPARENT`),
não à página individual — é o mesmo `HWND` do início ao fim do wizard. Isso
importa para o escudo UAC: se ele for ligado na página de escolha de escopo e
nunca desligado, ele permanece colado no botão em todas as páginas seguintes
(Directory, Components, Install), mesmo depois que a decisão de elevação já
foi tomada.

### Configurações já sobrevivem a um uninstall/reinstall completo

A versão instalada (diferente da portátil) não copia `aseprite.ini`, então usa
`%APPDATA%` normalmente — e o desinstalador atual nunca toca em `%APPDATA%`.
Isso significa que trocar a estratégia de upgrade de "apaga só `data\`" para
"desinstala a versão anterior por completo, depois instala a nova" não tem
custo nenhum em termos de configurações do usuário; é estritamente mais
robusto contra arquivos órfãos, sem trade-off.

### `_?=` é obrigatório para esperar um uninstall.exe de verdade

Um uninstaller NSIS chamado normalmente se copia para uma pasta temporária e
se relança de lá (para poder apagar sua própria pasta de instalação depois).
Isso significa que `ExecWait` num `uninstall.exe` sem o parâmetro `_?=$INSTDIR`
retorna assim que essa cópia-e-relançamento acontece — não quando a remoção de
fato termina. Chamar o desinstalador antigo dessa forma e prosseguir para
copiar os arquivos novos criaria exatamente a corrida (e o risco de
incompatibilidade) que este design existe para eliminar. `_?=$0` (onde `$0` é
o `InstallLocation` da instalação antiga) faz o desinstalador rodar no lugar,
sem a cópia temporária, tornando o `ExecWait` uma espera real.

## Decisões

| Decisão | Escolha |
|---|---|
| Ícone do `setup.exe` / `uninstall.exe` | Reaproveita `aseprite\data\icons\ase.ico` do clone feito pelo build, via novo define `/DICONFILE`. Nada gerado, nada commitado neste repositório. |
| Estratégia de upgrade | Desinstala a instalação anterior detectada via registro (mesmo escopo) silenciosamente e de forma síncrona (`ExecWait ... _?=`) antes de copiar os arquivos novos, em vez de só apagar `data\`. O wipe de `data\` existente é mantido como rede de segurança (registro presente mas `uninstall.exe` ausente, ou instalação muito antiga sem essa chave). |
| Upgrade cross-scope (instalou "todos" antes, agora escolhe "só eu", ou vice-versa) | Também detectado e removido. Instalar "todos" e achar um resíduo "só eu" (`HKCU`) não precisa de elevação extra (`HKCU` é sempre gravável). Instalar "só eu" e achar um resíduo "todos" (`HKLM`) precisa — nova marca de relançamento `/CLEANUPALLUSERS`, distinta de `/ALLUSERS`, que eleva o processo mas mantém `$Scope = user` (instala em `%LocalAppData%`, não em Program Files). |
| Recusa da elevação extra (`/CLEANUPALLUSERS`) | Aborta a instalação inteira com mensagem explicativa — mesma postura já usada para a recusa da elevação principal (`/ALLUSERS`). Preferível a deixar duas cópias conflitantes instaladas. |
| Escudo UAC no botão Next | `SendMessage $0 ${BCM_SETSHIELD} 0 1/0` nativo (constante `0x160C`), sem plugin `UAC.dll` de terceiro — mesma postura já adotada no design original do instalador. Liga por padrão (escopo pré-selecionado é "todos os usuários"), alterna via `${NSD_OnClick}` nos dois radios, e é explicitamente desligado em `PageScopeLeave` antes de prosseguir para páginas seguintes (já que o botão é compartilhado entre todas as páginas do wizard). |

## Arquitetura

### `build.cmd`

Novo define passado ao `makensis`, ao lado de `VERSION`/`SRCDIR`/`OUTFILE`:

```
/DICONFILE=%CD%\aseprite\data\icons\ase.ico
```

### `scripts/installer.nsi`

**Ícone:**

```nsis
!ifndef ICONFILE
  !error "ICONFILE not defined -- pass /DICONFILE=<path> to makensis"
!endif
...
!define MUI_ICON "${ICONFILE}"
!define MUI_UNICON "${ICONFILE}"
```

(antes dos `!insertmacro MUI_PAGE_*`, junto das outras diretivas `MUI_*`.)

**Escudo UAC**, adicionado à seção da tela de escopo:

```nsis
!define BCM_SETSHIELD 0x0000160C

Function PageScope
  ...
  ${NSD_CreateRadioButton} 0 20u 100% 12u "Install for all users (requires administrator rights)"
  Pop $ScopeAllUsersRadio
  ${NSD_SetState} $ScopeAllUsersRadio ${BST_CHECKED}
  ${NSD_OnClick} $ScopeAllUsersRadio UpdateScopeShield

  ${NSD_CreateRadioButton} 0 40u 100% 12u "Install for me only (no administrator rights required)"
  Pop $ScopeCurrentUserRadio
  ${NSD_OnClick} $ScopeCurrentUserRadio UpdateScopeShield

  Call UpdateScopeShield ; estado inicial: "all" pré-selecionado -> escudo ligado

  nsDialogs::Show
FunctionEnd

Function UpdateScopeShield
  GetDlgItem $0 $HWNDPARENT 1 ; 1 = botão Next/Install/Finish do wizard
  ${NSD_GetState} $ScopeAllUsersRadio $1
  ${If} $1 == ${BST_CHECKED}
    SendMessage $0 ${BCM_SETSHIELD} 0 1
  ${Else}
    SendMessage $0 ${BCM_SETSHIELD} 0 0
  ${EndIf}
FunctionEnd
```

`PageScopeLeave` desliga o escudo antes de cair para a próxima página (nos
ramos que não terminam em `Quit`):

```nsis
GetDlgItem $0 $HWNDPARENT 1
SendMessage $0 ${BCM_SETSHIELD} 0 0
```

**Upgrade / desinstalação da versão anterior**, nova marca de relançamento e
lógica de elevação estendida em `PageScope` / `PageScopeLeave`:

```nsis
Function PageScope
  ${GetParameters} $R0

  ClearErrors
  ${GetOptions} $R0 "/ALLUSERS" $R1
  ${IfNot} ${Errors}
    ; ramo existente, inalterado: Scope=all, INSTDIR=ProgramFiles64, Abort
    ...
  ${Else}
    ClearErrors
    ${GetOptions} $R0 "/CLEANUPALLUSERS" $R1
    ${IfNot} ${Errors}
      Call IsElevated
      Pop $0
      ${If} $0 == "0"
        MessageBox MB_OK|MB_ICONEXCLAMATION \
          "Administrator rights are required to remove the existing all-users installation before continuing.$\r$\n$\r$\nRestart the installer and accept the elevation prompt, or uninstall the existing Aseprite installation manually first."
        Quit
      ${EndIf}
      StrCpy $Scope "user"
      SetShellVarContext current
      StrCpy $INSTDIR "$LOCALAPPDATA\Programs\Aseprite"
      Abort ; pula a página -- a escolha já foi feita antes do relançamento
    ${EndIf}
  ${EndIf}

  ; ... resto inalterado (mostra a página) ...
FunctionEnd

Function PageScopeLeave
  ${NSD_GetState} $ScopeAllUsersRadio $0
  ${If} $0 == ${BST_CHECKED}
    StrCpy $Scope "all"
  ${Else}
    StrCpy $Scope "user"
  ${EndIf}

  GetDlgItem $0 $HWNDPARENT 1
  SendMessage $0 ${BCM_SETSHIELD} 0 0 ; desliga antes de prosseguir

  ${If} $Scope == "all"
    Call IsElevated
    Pop $0
    ${If} $0 == "0"
      ExecShell "runas" "$EXEPATH" "/ALLUSERS"
      ... ; inalterado
      Quit
    ${EndIf}
    SetShellVarContext all
    StrCpy $INSTDIR "$PROGRAMFILES64\Aseprite"
  ${Else}
    ; Novo: se existir uma instalação "todos os usuários" órfã, precisa de
    ; elevação extra só para removê-la -- o novo install continua "user".
    ReadRegStr $0 HKLM "${UNINST_KEY}" "InstallLocation"
    ${If} $0 != ""
    ${AndIf} ${FileExists} "$0\uninstall.exe"
      Call IsElevated
      Pop $1
      ${If} $1 == "0"
        ClearErrors
        ExecShell "runas" "$EXEPATH" "/CLEANUPALLUSERS"
        ${If} ${Errors}
          MessageBox MB_OK|MB_ICONEXCLAMATION \
            "Administrator rights are required to remove the existing all-users installation before continuing.$\r$\n$\r$\nRestart the installer and accept the elevation prompt, or uninstall the existing Aseprite installation manually first."
        ${EndIf}
        Quit
      ${EndIf}
    ${EndIf}
    SetShellVarContext current
    StrCpy $INSTDIR "$LOCALAPPDATA\Programs\Aseprite"
  ${EndIf}
FunctionEnd
```

`Section "-core" SecCore` ganha a remoção da instalação anterior, antes da
cópia de arquivos:

```nsis
Section "-core" SecCore
  ; Mesmo escopo: se o registro aponta pra uma instalação anterior com
  ; uninstall.exe presente, remove por completo (síncrono) antes de
  ; prosseguir -- mais robusto que só apagar data\, cobre arquivos órfãos
  ; fora dela e garante que atalhos/registro fiquem consistentes com a
  ; versão nova. _?= evita a cópia-pra-temp do NSIS, que faria o ExecWait
  ; retornar antes da remoção real terminar.
  ReadRegStr $0 SHCTX "${UNINST_KEY}" "InstallLocation"
  ${If} $0 != ""
  ${AndIf} ${FileExists} "$0\uninstall.exe"
    DetailPrint "Removing previous installation..."
    ExecWait '"$0\uninstall.exe" /S _?=$0'
  ${EndIf}

  ; Cross-scope: limpa um resíduo no OUTRO hive, se existir. HKCU nunca
  ; precisa de elevação; HKLM já foi garantido via /CLEANUPALLUSERS acima
  ; quando Scope == user.
  ${If} $Scope == "all"
    ReadRegStr $1 HKCU "${UNINST_KEY}" "InstallLocation"
    ${If} $1 != ""
    ${AndIf} ${FileExists} "$1\uninstall.exe"
      DetailPrint "Removing previous per-user installation..."
      ExecWait '"$1\uninstall.exe" /S _?=$1'
    ${EndIf}
  ${Else}
    ReadRegStr $1 HKLM "${UNINST_KEY}" "InstallLocation"
    ${If} $1 != ""
    ${AndIf} ${FileExists} "$1\uninstall.exe"
      DetailPrint "Removing previous all-users installation..."
      ExecWait '"$1\uninstall.exe" /S _?=$1'
    ${EndIf}
  ${EndIf}

  SetOutPath "$INSTDIR"

  ; Rede de segurança pré-existente: cobre o caso de um registro ausente ou
  ; um uninstall.exe faltando, mas ainda assim já existirem arquivos aqui.
  ${If} ${FileExists} "$INSTDIR\aseprite.exe"
    RMDir /r "$INSTDIR\data"
  ${EndIf}

  File "${SRCDIR}\aseprite.exe"
  ... ; resto inalterado
SectionEnd
```

## Fluxo de dados

```
build.cmd
  └─ makensis /DICONFILE=%CD%\aseprite\data\icons\ase.ico ... scripts\installer.nsi
       └─ setup.exe e uninstall.exe embutem o ícone do Aseprite

setup.exe (fluxo de upgrade, mesmo escopo)
  PageScope/PageScopeLeave decide $Scope, eleva se preciso (/ALLUSERS)
    └─ SecCore: lê InstallLocation do hive de $Scope
         └─ se existir uninstall.exe -> ExecWait "...uninstall.exe" /S _?=<local>
              └─ copia os arquivos novos por cima do diretório já limpo

setup.exe (fluxo de upgrade, troca de escopo: "todos" -> "só eu")
  PageScope/PageScopeLeave decide Scope=user
    └─ acha resíduo em HKLM -> ExecShell runas .../CLEANUPALLUSERS -> Quit
         └─ processo elevado: PageScope reconhece /CLEANUPALLUSERS,
            Scope=user, INSTDIR=LocalAppData, pula a página
              └─ SecCore remove o resíduo HKLM, depois instala normalmente
```

## Tratamento de erro e verificação

- Recusa de qualquer uma das duas elevações (`/ALLUSERS` ou
  `/CLEANUPALLUSERS`) aborta a instalação inteira com uma mensagem
  explicando o motivo, em vez de prosseguir num estado parcial.
- A remoção da instalação anterior é síncrona (`ExecWait ... _?=`) tanto no
  caso de mesmo escopo quanto nos dois casos de cross-scope, então os
  arquivos novos nunca são copiados por cima de uma remoção ainda em
  andamento.
- `tests/make-installer.test.sh` ganha novas asserções estáticas (grep sobre
  `scripts/installer.nsi` e `build.cmd`): presença de `ICONFILE`/`MUI_ICON`/
  `MUI_UNICON`, de `BCM_SETSHIELD`, do parâmetro `/CLEANUPALLUSERS`, e do
  padrão `ExecWait` com `_?=` para a remoção da instalação anterior. Mesma
  filosofia do teste existente: cobre presença/ausência de trechos
  estruturais, não o comportamento em tempo de instalação.
- Validação manual ao final da implementação, cobrindo os fluxos que só
  fazem sentido testar numa máquina Windows real: instalar a v1.3.18.1,
  fazer upgrade para uma versão mais nova no mesmo escopo (confirmar que o
  ícone aparece em `setup.exe`/`uninstall.exe`, que o botão Next mostra o
  escudo quando "todos os usuários" está selecionado e some quando alterna
  pra "só eu", e que o Add/Remove Programs reflete só a versão nova depois
  do upgrade); repetir trocando de escopo entre as duas execuções e
  confirmar o prompt UAC extra e a limpeza do resíduo.

## Arquivos afetados

| Arquivo | Ação |
|---|---|
| `scripts/installer.nsi` | **Modificar.** `MUI_ICON`/`MUI_UNICON`, escudo UAC no botão Next, remoção da instalação anterior (mesmo escopo e cross-scope) antes da cópia de arquivos. |
| `build.cmd` | **Modificar.** Novo define `/DICONFILE` na chamada do `makensis`. |
| `tests/make-installer.test.sh` | **Modificar.** Novas asserções estáticas para as três mudanças. |

## Fora de escopo

- Migração de configurações entre modo portátil e modo instalado (já era
  fora de escopo do design original, continua sendo).
- Assinatura de código do instalador.
- Cobrir instalações muito antigas que não gravaram `InstallLocation`/
  `uninstall.exe` no registro (a rede de segurança de apagar `data\` já
  existente continua sendo o tratamento para esse caso).
- Linux e macOS.

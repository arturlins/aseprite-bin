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

rem *** Re-validate ASEPRITE_VERSION here too: the composite action enforces
rem *** this format, but this script is also documented for direct/local use
rem *** with a hand-set env var, which bypasses the resolver entirely. The
rem *** value later reaches injection-capable sinks (a single-quoted
rem *** PowerShell string, --branch, several unquoted directory names), so
rem *** reject anything that doesn't match before any of that happens. Batch
rem *** has no regex, so delegate to PowerShell and act on its exit code;
rem *** read the value via $env: rather than string-interpolating it into
rem *** the -Command text, so the check itself isn't vulnerable to the same
rem *** injection it is guarding against.
powershell -NoProfile -Command "if ($env:ASEPRITE_VERSION -cmatch '^v[0-9]+(\.[0-9]+){1,3}(-beta[0-9]+)?$') { exit 0 } else { exit 1 }"
if errorlevel 1 (
  echo ERROR: invalid ASEPRITE_VERSION "%ASEPRITE_VERSION%" ^(expected e.g. v1.3.18.1 or v1.3.18-beta1^)
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

if exist "%ProgramFiles(x86)%\NSIS\makensis.exe" (
  set MAKENSIS="%ProgramFiles(x86)%\NSIS\makensis.exe"
) else (
  where /q makensis.exe || (
    echo ERROR: NSIS "makensis.exe" not found
    echo Install it from https://nsis.sourceforge.io/ or run "choco install nsis"
    exit /b 1
  )
  set MAKENSIS=makensis.exe
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

rem *** If upstream ever renames the "1.x-dev" placeholder, the replace
rem *** above becomes a silent no-op and the build would ship a binary
rem *** reporting the wrong version -- assert it actually applied.
findstr /C:"%ASEPRITE_VERSION_NUMBER%" aseprite\src\ver\CMakeLists.txt >nul || (
  echo ERROR: version stamp failed -- "%ASEPRITE_VERSION_NUMBER%" not found in aseprite\src\ver\CMakeLists.txt
  echo Upstream may have renamed the "1.x-dev" placeholder.
  exit /b 1
)


rem *** download skia ***

if exist aseprite\laf\misc\skia-tag.txt (
  rem *** `set /p` strips the trailing CRLF but not a trailing space or a
  rem *** BOM; read via PowerShell and strip all whitespace and a leading
  rem *** BOM, the same way build.sh does with `tr -d '[:space:]'`.
  for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content -Raw -Path 'aseprite\laf\misc\skia-tag.txt') -replace '[\s\uFEFF]',''"`) do set SKIA_VERSION=%%v
) else (
  if "%ASEPRITE_VERSION:beta=%" neq "%ASEPRITE_VERSION%" (
    set SKIA_VERSION=m124-08a5439a6b
  ) else (
    set SKIA_VERSION=m102-861e4743af
  )
)

echo Using Skia %SKIA_VERSION%

set SKIA_LIBRARY=skia-%SKIA_VERSION%\out\Release-x64\skia.lib

rem *** Gate reuse on the library file, not just the directory: an
rem *** interrupted local download or extraction leaves the directory
rem *** present but incomplete, which would otherwise make every later run
rem *** skip the download forever.
if not exist "%SKIA_LIBRARY%" (
  if not exist skia-%SKIA_VERSION% mkdir skia-%SKIA_VERSION%
  pushd skia-%SKIA_VERSION%
  curl -sfLO https://github.com/aseprite/skia/releases/download/%SKIA_VERSION%/Skia-Windows-Release-x64.zip || echo failed to download skia && exit /b 1
  %SZIP% x -y Skia-Windows-Release-x64.zip || echo failed to extract skia && exit /b 1
  popd
  if not exist "%SKIA_LIBRARY%" (
    echo ERROR: %SKIA_LIBRARY% not found after download; delete skia-%SKIA_VERSION% and re-run
    exit /b 1
  )
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
ninja.exe -C build aseprite || echo build failed && exit /b 1


rem *** package ***

if exist dist rd /s /q dist
set OUTDIR=dist\aseprite-%ASEPRITE_VERSION%-windows-x64
mkdir %OUTDIR% || echo failed to create output directory && exit /b 1
echo # This file is here so Aseprite behaves as a portable program >%OUTDIR%\aseprite.ini || echo failed to write aseprite.ini && exit /b 1
copy /Y build\bin\aseprite.exe %OUTDIR%\ 1>nul || echo failed to copy binary && exit /b 1
xcopy /E /Q /Y build\bin\data %OUTDIR%\data\ || echo failed to copy data && exit /b 1
xcopy /E /Q /Y aseprite\docs %OUTDIR%\docs\ || echo failed to copy docs && exit /b 1

echo Done: %OUTDIR%


rem *** installer (NSIS) ***

set SETUPFILE=dist\aseprite-%ASEPRITE_VERSION%-windows-x64-setup.exe
%MAKENSIS% /WX /DVERSION=%ASEPRITE_VERSION% /DVERSION_NUMBER=%ASEPRITE_VERSION_NUMBER% "/DSRCDIR=%CD%\%OUTDIR%" "/DOUTFILE=%CD%\%SETUPFILE%" scripts\installer.nsi || echo failed to build installer && exit /b 1

echo Done: %SETUPFILE%

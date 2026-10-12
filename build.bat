@echo off
setlocal
cd /d "%~dp0"

where nasm >nul 2>nul || (echo nasm not found on PATH & exit /b 1)

set "LINKER=lld-link"
where lld-link >nul 2>nul || set "LINKER=link"

set "KITS=%ProgramFiles(x86)%\Windows Kits\10\Lib"
for /f "delims=" %%v in ('dir /b /ad /o-n "%KITS%\10.*" 2^>nul') do (
    if exist "%KITS%\%%v\um\x64\winhttp.lib" (
        set "SDKLIB=%KITS%\%%v\um\x64"
        goto :build
    )
)
echo windows SDK import libraries not found
exit /b 1

:build
if not exist build mkdir build
nasm -f win64 %NASMFLAGS% src\bot.asm -o build\bot.obj || exit /b 1
%LINKER% /nologo /subsystem:console /entry:main /nodefaultlib /libpath:"%SDKLIB%" ^
    build\bot.obj kernel32.lib winhttp.lib /out:build\assembly-bot.exe || exit /b 1
echo Built build\assembly-bot.exe
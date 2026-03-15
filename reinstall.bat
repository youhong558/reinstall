@echo off
mode con cp select=437 >nul
setlocal EnableDelayedExpansion

set confhome=https://raw.githubusercontent.com/youhong558/reinstall/main
set confhome_cn=https://cnb.cool/youhong558/reinstall/-/git/raw/main
rem set confhome_cn=https://www.ghproxy.cc/https://raw.githubusercontent.com/youhong558/reinstall/main

set pkgs=curl,cpio,p7zip,dos2unix,jq,xz,gzip,zstd,openssl,bind-utils,libiconv,binutils
set cmds=curl,cpio,p7zip,dos2unix,jq,xz,gzip,zstd,openssl,nslookup,iconv,ar

rem 65001 代码页会乱码

rem 不要用 :: 注释
rem 否则可能会出现 系统找不到指定的驱动器

rem Windows 7 SP1 winhttp 默认不支持 tls 1.2
rem https://support.microsoft.com/en-us/topic/update-to-enable-tls-1-1-and-tls-1-2-as-default-secure-protocols-in-winhttp-in-windows-c4bd73d2-31d7-761e-0178-11268bb10392
rem 有些系统根证书没更新
rem 所以不要用https
rem 进入脚本目录
cd /d %~dp0

rem 检查是否有管理员权限
fltmc >nul 2>&1
if errorlevel 1 (
    echo Please run as administrator^^!
    exit /b
)

rem 下载 geoip
if not exist geoip (
    call :download http://www.qualcomm.cn/cdn-cgi/trace %~dp0geoip || goto :download_failed
)

rem 判断是否有 loc=
findstr /c:"loc=" geoip >nul
if errorlevel 1 (
    echo Invalid geoip file
    del geoip
    exit /b 1
)

rem 检查是否国内
findstr /c:"loc=CN" geoip >nul
if not errorlevel 1 (
    set mirror=http://mirror.nju.edu.cn
    if defined confhome_cn (
        set confhome=!confhome_cn!
    ) else if defined github_proxy (
        echo !confhome! | findstr /c:"://raw.githubusercontent.com/" >nul
        if not errorlevel 1 (
            set confhome=!confhome:http://=https://!
            set confhome=!confhome:https://raw.githubusercontent.com=%github_proxy%!
        )
    )
) else (
    set mirror=http://mirrors.kernel.org
)

call :check_cygwin_installed || (
    for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v PROCESSOR_ARCHITECTURE') do (
        set SystemArch=%%a
    )

    for /f "tokens=3" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber') do (
        set /a BuildNumber=%%a
    )

    set CygwinEOL=1

    echo !SystemArch! | find "ARM" > nul
    if not errorlevel 1 (
        if !BuildNumber! GEQ 22000 (
            set CygwinEOL=0
        )
    ) else (
        echo !SystemArch! | find "AMD64" > nul
        if not errorlevel 1 (
            if !BuildNumber! GEQ 9600 (
                set CygwinEOL=0
            )
        )
    )

    if !CygwinEOL! == 1 (
        set CygwinArch=x86
        set dir=/sourceware/cygwin-archive/20221123
    ) else (
        set CygwinArch=x86_64
        set dir=/sourceware/cygwin
    )

    rem 下载 Cygwin
    if not exist setup-!CygwinArch!.exe (
        call :download http://www.cygwin.com/setup-!CygwinArch!.exe %~dp0setup-!CygwinArch!.exe || goto :download_failed
    )

    rem 少于 1M 视为无效
    for %%A in (setup-!CygwinArch!.exe) do if %%~zA LSS 1048576 (
        echo Invalid Cgywin installer
        del setup-!CygwinArch!.exe
        exit /b 1
    )

    rem 安装 Cygwin
    set site=!mirror!!dir!
    start /wait setup-!CygwinArch!.exe ^
        --allow-unsupported-windows ^
        --quiet-mode ^
        --only-site ^
        --site !site! ^
        --root %SystemDrive%\cygwin ^
        --local-package-dir %~dp0cygwin-local-package-dir ^
        --packages %pkgs%

    rem 检查 Cygwin 是否成功安装
    if errorlevel 1 goto :install_cygwin_failed
    call :check_cygwin_installed || goto :install_cygwin_failed
)

rem 在c盘根目录下执行 cygpath -ua . 会得到 /cygdrive/c，因此末尾要有 /
for /f %%a in ('%SystemDrive%\cygwin\bin\cygpath -ua ./') do set thisdir=%%a

rem 下载 reinstall.sh
if not exist reinstall.sh (
    call :download_with_curl %confhome%/reinstall.sh %thisdir%reinstall.sh || goto :download_failed
    call :chmod a+x %thisdir%reinstall.sh
)

rem 转成 unix 格式，避免用户用 windows 记事本编辑后换行符不对
%SystemDrive%\cygwin\bin\dos2unix -q '%thisdir%reinstall.sh'

rem 用 bash 运行
%SystemDrive%\cygwin\bin\bash %thisdir%reinstall.sh %*
exit /b

:download
echo Downloading: %~1 %~2
del /q "%~2" 2>nul
if exist "%~2" (echo Cannot delete %~2 & exit /b 1)

certutil -urlcache -f -split "%~1" "%~2" >nul
if not errorlevel 1 if exist "%~2" exit /b 0

certutil -urlcache -split "%~1" "%~2" >nul
if not errorlevel 1 if exist "%~2" exit /b 0

del /q "%~2" 2>nul
exit /b 1

:download_with_curl
echo Download: %~1 %~2
%SystemDrive%\cygwin\bin\curl -L --insecure "%~1" -o "%~2"
exit /b

:chmod
%SystemDrive%\cygwin\bin\chmod "%~1" "%~2"
exit /b

:download_failed
echo Download failed.
exit /b 1

:install_cygwin_failed
echo Failed to install Cygwin.
exit /b 1

:check_cygwin_installed
set "cmds_space=%cmds:,= %"
for %%c in (%cmds_space%) do (
    if not exist "%SystemDrive%\cygwin\bin\%%c" if not exist "%SystemDrive%\cygwin\bin\%%c.exe" (
        exit /b 1
    )
)
exit /b 0
exit /b 0

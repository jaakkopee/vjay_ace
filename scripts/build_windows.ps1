param(
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$Configuration = "Release",
    [string]$BuildDir = "build-win",
    [switch]$Clean,
    [switch]$UseNinja,
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-CommandExists {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WithWinget {
    param(
        [string]$Id,
        [string]$Description,
        [string]$Override = ""
    )

    if (-not (Test-CommandExists "winget")) {
        return $false
    }

    Write-Step "Installing $Description via winget ($Id)"
    $args = @(
        "install",
        "--id", $Id,
        "--exact",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )

    if ($Override -ne "") {
        $args += @("--override", $Override)
    }

    & winget @args
    return $LASTEXITCODE -eq 0
}

function Install-WithChoco {
    param(
        [string]$Package,
        [string]$Description
    )

    if (-not (Test-CommandExists "choco")) {
        return $false
    }

    Write-Step "Installing $Description via chocolatey ($Package)"
    & choco install $Package -y --no-progress
    return $LASTEXITCODE -eq 0
}

function Ensure-Tool {
    param(
        [string]$Command,
        [string]$Description,
        [string]$WingetId,
        [string]$ChocoPackage
    )

    if (Test-CommandExists $Command) {
        Write-Host "Found $Description"
        return
    }

    if ($SkipInstall) {
        throw "$Description is missing and -SkipInstall was used."
    }

    $installed = $false
    if ($WingetId -ne "") {
        $installed = Install-WithWinget -Id $WingetId -Description $Description
    }
    if (-not $installed -and $ChocoPackage -ne "") {
        $installed = Install-WithChoco -Package $ChocoPackage -Description $Description
    }

    if (-not $installed) {
        throw "Could not install $Description automatically. Install it manually and rerun this script."
    }

    if (-not (Test-CommandExists $Command)) {
        throw "$Description still not found in PATH after installation. Open a new terminal and rerun."
    }
}

function Get-VsWherePath {
    $candidate = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $candidate) {
        return $candidate
    }
    return $null
}

function Get-VsInstallPath {
    param([string]$VsWhere)

    $installPath = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installPath)) {
        return $null
    }

    return $installPath.Trim()
}

function Ensure-VsBuildTools {
    Write-Step "Checking Visual Studio C++ Build Tools"

    $vsWhere = Get-VsWherePath
    if ($vsWhere) {
        $existing = Get-VsInstallPath -VsWhere $vsWhere
        if ($existing) {
            Write-Host "Found Visual Studio tools at: $existing"
            return $existing
        }
    }

    if ($SkipInstall) {
        throw "Visual Studio C++ Build Tools are missing and -SkipInstall was used."
    }

    $override = "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    $installed = Install-WithWinget -Id "Microsoft.VisualStudio.2022.BuildTools" -Description "Visual Studio 2022 Build Tools" -Override $override
    if (-not $installed) {
        $installed = Install-WithChoco -Package "visualstudio2022buildtools" -Description "Visual Studio 2022 Build Tools"
    }
    if (-not $installed) {
        throw "Could not install Visual Studio Build Tools automatically."
    }

    $vsWhere = Get-VsWherePath
    if (-not $vsWhere) {
        throw "vswhere.exe not found after installation."
    }

    $existing = Get-VsInstallPath -VsWhere $vsWhere
    if (-not $existing) {
        throw "Visual Studio C++ toolchain not detected after installation."
    }

    Write-Host "Installed Visual Studio tools at: $existing"
    return $existing
}

function Invoke-InVsDevShell {
    param(
        [string]$VsInstallPath,
        [string]$CommandLine
    )

    $vsDevCmd = Join-Path $VsInstallPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) {
        throw "VsDevCmd.bat not found at: $vsDevCmd"
    }

    $cmd = "call `"$vsDevCmd`" -arch=x64 -host_arch=x64 && $CommandLine"
    & cmd.exe /d /s /c $cmd
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed in VS dev shell: $CommandLine"
    }
}

if (-not $IsWindows) {
    throw "This script is intended for Windows PowerShell/PowerShell Core on Windows."
}

Write-Step "Checking required tools"
Ensure-Tool -Command "cmake" -Description "CMake" -WingetId "Kitware.CMake" -ChocoPackage "cmake"

$vsInstallPath = Ensure-VsBuildTools

$hasNinja = Test-CommandExists "ninja"
if ($UseNinja -or $hasNinja) {
    if (-not $hasNinja) {
        if ($SkipInstall) {
            throw "Ninja is missing and -SkipInstall was used."
        }
        Ensure-Tool -Command "ninja" -Description "Ninja" -WingetId "Ninja-build.Ninja" -ChocoPackage "ninja"
    }
    $generator = "Ninja"
} else {
    $generator = "Visual Studio 17 2022"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$buildPath = Join-Path $repoRoot $BuildDir

if ($Clean -and (Test-Path $buildPath)) {
    Write-Step "Cleaning build directory: $buildPath"
    Remove-Item -Recurse -Force $buildPath
}

Write-Step "Configuring project ($generator, $Configuration)"
$configureCmd = "cmake -S `"$repoRoot`" -B `"$buildPath`" -G `"$generator`""
if ($generator -eq "Ninja") {
    $configureCmd += " -DCMAKE_BUILD_TYPE=$Configuration"
}
Invoke-InVsDevShell -VsInstallPath $vsInstallPath -CommandLine $configureCmd

Write-Step "Building project"
if ($generator -eq "Ninja") {
    $buildCmd = "cmake --build `"$buildPath`" --parallel"
} else {
    $buildCmd = "cmake --build `"$buildPath`" --config $Configuration --parallel"
}
Invoke-InVsDevShell -VsInstallPath $vsInstallPath -CommandLine $buildCmd

Write-Step "Build completed successfully"
Write-Host "Build directory: $buildPath"

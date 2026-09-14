<#
.SYNOPSIS
    Mogok Maung local testing & build gate (mobile + web) on Windows.

.DESCRIPTION
    Single-command pipeline that checks, in order:
      1. Flutter SDK discovery (PATH / FLUTTER_HOME / well-known roots /
         opencode toolchain fallback) + `flutter doctor` summary.
      2. mobile: `flutter pub get` -> `flutter analyze` -> `flutter test`.
      3. mobile integration smoke (flutter test integration_test) — runs ONLY
         when a device/emulator is attached AND -SkipIntegration is not set;
         it points the app at $BackendUrl for the health-ping assertion.
      4. optional debug APK build with the local-backend dart-defines.
      5. web: ensures .env.local exists, `npm run typecheck`, `npm run build`
         (Next.js production build -> .next/).
      6. optional `npm run start` (next start) preview on http://localhost:3000.

    Exit code 0 = everything passed; non-zero = at least one stage failed.

.PARAMETER SkipMobile
    Skip every Flutter stage (tests, analyze, APK).
.PARAMETER SkipWeb
    Skip the Next.js stage.
.PARAMETER SkipIntegration
    Do not run integration tests even if a device is attached.
.PARAMETER BuildApk
    Build a debug APK wired to the local backend ($BackendUrl).
.PARAMETER BackendUrl
    Backend origin the mobile app should talk to during integration/APK.
    Windows desktop / web:   http://localhost:8080
    Android emulator (host loopback alias): http://10.0.2.2:8080 (default).
.PARAMETER Preview
    After a successful web build, run `next start` (press Ctrl+C to stop).
.PARAMETER FlutterHome
    Explicit flutter SDK root; skips auto-discovery.

.EXAMPLE
    ./scripts/dev/test_and_build.ps1 -BackendUrl http://10.0.2.2:8080 -BuildApk
.EXAMPLE
    ./scripts/dev/test_and_build.ps1 -SkipIntegration -Preview
#>
[CmdletBinding()]
param(
    [switch]$SkipMobile,
    [switch]$SkipWeb,
    [switch]$SkipIntegration,
    [switch]$BuildApk,
    [string]$BackendUrl = 'http://10.0.2.2:8080',
    [switch]$Preview,
    [string]$FlutterHome
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Failures = 0

function Write-Step([string]$Name, [scriptblock]$Body) {
    Write-Host "`n==> $Name" -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "    [PASS] $Name" -ForegroundColor Green
    }
    catch {
        Write-Host "    [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red
        $script:Failures++
    }
}

function Invoke-InDir([string]$Dir, [string]$Command) {
    & powershell -NoProfile -Command "Set-Location -LiteralPath '$Dir'; $Command"
    if ($LASTEXITCODE -ne 0) { throw "command exited $LASTEXITCODE in $Dir : $Command" }
}

$mobile = "$RepoRoot\mobile"
$web    = "$RepoRoot\web"

# ---------------------------------------------------------------------------
# 1) Flutter SDK discovery
# ---------------------------------------------------------------------------
if (-not $SkipMobile) {
    Write-Step 'Flutter SDK discovery' {
        if (-not $script:FlutterHome) {
            $candidates = @(
                $env:FLUTTER_HOME,
                (Get-Command flutter.bat -ErrorAction SilentlyContinue).Source,
                'C:\flutter', 'C:\src\flutter', "$env:USERPROFILE\flutter",
                "$env:TEMP\opencode\toolchains\flutter"
            ) | Where-Object { $_ }
            foreach ($cand in $candidates) {
                if ($cand -and (Test-Path "$cand\bin\flutter.bat")) { $script:FlutterHome = $cand; break }
            }
        }
        if (-not $script:FlutterHome -or -not (Test-Path "$script:FlutterHome\bin\flutter.bat")) {
            throw "flutter.bat not found. Install the SDK, add bin/ to PATH, or pass -FlutterHome. Known roots tried: C:\flutter, C:\src\flutter, %USERPROFILE%\flutter, %TEMP%\opencode\toolchains\flutter."
        }
        $env:Path = "$script:FlutterHome\bin;$script:FlutterHome\bin\cache\dart-sdk\bin;$env:Path"
        $env:FLUTTER_HOME = $script:FlutterHome
        Write-Host "    flutter detected: $script:FlutterHome"

        $doctor = & "$script:FlutterHome\bin\flutter.bat" doctor 2>&1
        $doctor | Select-String -Pattern 'Flutter version|Android toolchain|Windows toolchain' | ForEach-Object { Write-Host "    $($_.Line.Trim())" -ForegroundColor DarkGray }
        $doctor | Select-String -Pattern '\[!\]' | ForEach-Object { Write-Host "    [warn] $($_.Line.Trim())" -ForegroundColor Yellow }
    }
}

# ---------------------------------------------------------------------------
# 2) Mobile: dependencies, static analysis, unit/widget tests
# ---------------------------------------------------------------------------
if (-not $SkipMobile) {
    Write-Step 'mobile: flutter pub get' {
        Invoke-InDir $mobile "& `"$script:FlutterHome\bin\flutter.bat`" pub get"
    }
    Write-Step 'mobile: flutter analyze' {
        Invoke-InDir $mobile "& `"$script:FlutterHome\bin\flutter.bat`" analyze"
    }
    Write-Step 'mobile: flutter test (unit + widget)' {
        Invoke-InDir $mobile "& `"$script:FlutterHome\bin\flutter.bat`" test"
    }

    # -----------------------------------------------------------------------
    # 3) Mobile: integration smoke on an attached device/emulator
    # -----------------------------------------------------------------------
    if (-not $SkipIntegration) {
        Write-Step 'mobile: integration smoke (device required)' {
            $devices = & "$script:FlutterHome\bin\flutter.bat" devices 2>&1
            $deviceLine = $devices | Select-String -Pattern 'emulator-|^windows\s|^Windows|^chrome\s|^macos\s|^linux\s' | Select-Object -First 1
            if (-not $deviceLine) {
                Write-Host '    [SKIP] no emulator/desktop device attached (start one with flutter emulators --launch <id> or adb devices)' -ForegroundColor Yellow
            }
            else {
                $deviceId = ($deviceLine.Line -split '\s+')[0]
                Write-Host "    device: $deviceId"
                $wsUrl = $BackendUrl -replace '^http', 'ws'
                Invoke-InDir $mobile "& `"$script:FlutterHome\bin\flutter.bat`" test integration_test -d $deviceId --dart-define=API_BASE_URL=$BackendUrl --dart-define=WS_BASE_URL=$wsUrl"
            }
        }
    }

    # -----------------------------------------------------------------------
    # 4) Mobile: optional debug APK wired to the local backend
    # -----------------------------------------------------------------------
    if ($BuildApk) {
        Write-Step 'mobile: flutter build apk (debug, local backend)' {
            $wsUrl = $BackendUrl -replace '^http', 'ws'
            Invoke-InDir $mobile "& `"$script:FlutterHome\bin\flutter.bat`" build apk --debug --dart-define=API_BASE_URL=$BackendUrl --dart-define=WS_BASE_URL=$wsUrl"
            Write-Host "    APK: $mobile\build\app\outputs\flutter-apk\app-debug.apk"
        }
    }
}

# ---------------------------------------------------------------------------
# 5) Web (Next.js): env wiring, typecheck, production build
# ---------------------------------------------------------------------------
if (-not $SkipWeb) {
    Write-Step 'web: ensure .env.local (BACKEND_URL)' {
        if (-not (Test-Path "$web\.env.local")) {
            Copy-Item "$web\.env.local.example" "$web\.env.local"
            Write-Host '    created .env.local from .env.local.example (BACKEND_URL defaults to http://localhost:8080)'
        }
        else {
            Write-Host '    .env.local already present'
        }
    }
    Write-Step 'web: npm ci (if node_modules missing)' {
        if (-not (Test-Path "$web\node_modules")) {
            Invoke-InDir $web 'npm ci'
        }
        else {
            Write-Host '    node_modules present, skipping install'
        }
    }
    Write-Step 'web: npm run typecheck (tsc --noEmit)' {
        Invoke-InDir $web 'npm run typecheck'
    }
    Write-Step 'web: npm run build (next build)' {
        Invoke-InDir $web 'npm run build'
    }
    if ($Preview) {
        Write-Step 'web: npm run start (preview :3000, Ctrl+C to stop)' {
            Invoke-InDir $web 'npm run start'
        }
    }
}

# ---------------------------------------------------------------------------
# 6) Summary
# ---------------------------------------------------------------------------
Write-Host "`n======================================================"
if ($script:Failures -eq 0) {
    Write-Host 'ALL STAGES PASSED' -ForegroundColor Green
}
else {
    Write-Host "$script:Failures stage(s) FAILED" -ForegroundColor Red
    exit 1
}
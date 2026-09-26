$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

$Pinned = "ba4b934147855025df30bbca3ad6d436158fe671"
$Python = Join-Path (Get-Location) ".pilot-venv\Scripts\python.exe"
if (!(Test-Path $Python)) {
    throw "Pilot venv missing. Create .pilot-venv before running qualification."
}

$resolved = (git rev-parse "$Pinned^{commit}").Trim()
if ($resolved -ne $Pinned) {
    throw "Pinned FCC commit is not present locally."
}

$outside = @(
    git diff --name-only $Pinned HEAD -- . ":(exclude)pilot/**" ":(exclude).gitignore"
)
if ($outside.Count -gt 0 -and $outside[0]) {
    throw "Non-pilot source differs from pinned FCC: $($outside -join ', ')"
}

$dirty = @(git status --porcelain --untracked-files=all)
$badDirty = @($dirty | Where-Object {
    $_ -and $_ -notmatch "pilot/" -and $_ -notmatch "\.gitignore"
})
if ($badDirty.Count -gt 0) {
    throw "Non-pilot working tree is dirty: $($badDirty -join ', ')"
}
$pythonVersion = (& $Python --version 2>&1 | Out-String).Trim()
if ($pythonVersion -ne "Python 3.14.7") {
    throw "Unexpected Python: $pythonVersion"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resultDir = Join-Path $PSScriptRoot "results\$stamp"
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

$metadata = [ordered]@{
    pilot = "karp-fcc-pilot-v1"
    pinned_sha = $Pinned
    branch = (git branch --show-current).Trim()
    python = $pythonVersion
    started_at = (Get-Date).ToString("o")
    external_network_allowed = $false
}
$metadata | ConvertTo-Json -Depth 4 |
    Set-Content -Encoding UTF8 (Join-Path $resultDir "manifest.json")

$tests = @(
    "pilot/test_fault_matrix.py",
    "pilot/test_cost_guard.py",
    "tests/api/test_model_fallback.py",
    "tests/application/test_routing.py"
)
$log = Join-Path $resultDir "pytest.txt"
& $Python -m pytest -n 0 --tb=short @tests *> $log
$exitCode = $LASTEXITCODE
Get-Content $log

$verdict = if ($exitCode -eq 0) { "PASS" } else { "FAIL" }
$summary = [ordered]@{
    verdict = $verdict
    pytest_exit_code = $exitCode
    finished_at = (Get-Date).ToString("o")
    pinned_sha = $Pinned
}
$summary | ConvertTo-Json -Depth 4 |
    Set-Content -Encoding UTF8 (Join-Path $resultDir "verdict.json")

Write-Output "FCC deterministic pilot verdict: $verdict"
Write-Output "Evidence: $resultDir"
exit $exitCode

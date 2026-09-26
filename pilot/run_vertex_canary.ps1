param(
    [string]$PolicyPath = (Join-Path $PSScriptRoot "vertex_preflight_policy.json")
)

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $Repo ".pilot-venv\Scripts\python.exe"
$env:FCC_VERTEX_PREFLIGHT_PASSED = $null
$env:FCC_VERTEX_RESERVATION_LEDGER = $null

& (Join-Path $PSScriptRoot "vertex_preflight.ps1") -PolicyPath $PolicyPath
if ($LASTEXITCODE -ne 0 -or $env:FCC_VERTEX_PREFLIGHT_PASSED -ne "1") {
    throw "Vertex canary blocked: preflight did not PASS."
}

$Policy = Get-Content -Raw $PolicyPath | ConvertFrom-Json
$Ledger = $env:FCC_VERTEX_RESERVATION_LEDGER
if ([string]::IsNullOrWhiteSpace($Ledger)) {
    throw "Vertex canary blocked: reservation ledger was not supplied by preflight."
}
$LedgerDir = Split-Path -Parent $Ledger
New-Item -ItemType Directory -Force -Path $LedgerDir | Out-Null

$Reservation = [ordered]@{
    reserved_at_utc = [datetimeoffset]::UtcNow.ToString("o")
    project_id = [string]$Policy.expected_project_id
    model = [string]$Policy.selected_model
    reserved_usd = [decimal]$Policy.local_caps.run_reservation_usd
    max_requests = [int]$Policy.local_caps.max_requests_per_run
    max_output_tokens_per_request = [int]$Policy.local_caps.max_output_tokens_per_request
}
$ReservationLine = $Reservation | ConvertTo-Json -Compress
Add-Content -Encoding UTF8 -Path $Ledger -Value $ReservationLine

$env:FCC_LIVE_SMOKE = "1"
$env:FCC_SMOKE_TARGETS = "providers"
$env:FCC_SMOKE_PROVIDER_MATRIX = "vertex"
$env:FCC_SMOKE_MODEL_VERTEX = [string]$Policy.selected_model
$env:VERTEX_PROJECT_ID = [string]$Policy.expected_project_id
$env:VERTEX_LOCATION = [string]$Policy.selected_location
$env:FCC_SMOKE_TIMEOUT_S = "45"

Set-Location $Repo

# The initial canary is deliberately narrow: one known smoke scenario.
# That scenario performs two short Vertex generation turns with max_tokens=256.
$PytestArgs = @(
    "-m", "pytest",
    "smoke/product/test_provider_product_live.py::test_provider_text_multiturn_e2e",
    "-n", "0", "-s", "--tb=short"
)
& $Python @PytestArgs

$ExitCode = $LASTEXITCODE
if ($ExitCode -ne 0) {
    Write-Error "Vertex canary failed. Reservation remains consumed by design."
    exit $ExitCode
}

Write-Output "Vertex canary: PASS"
Write-Output "Reservation ledger: $Ledger"
exit 0

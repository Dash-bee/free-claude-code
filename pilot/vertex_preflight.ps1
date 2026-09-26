param(
    [string]$PolicyPath = (Join-Path $PSScriptRoot "vertex_preflight_policy.json")
)

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $Repo ".pilot-venv\Scripts\python.exe"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ResultDir = Join-Path $PSScriptRoot "results\vertex-preflight\$Stamp"
New-Item -ItemType Directory -Force -Path $ResultDir | Out-Null
$Checks = [System.Collections.Generic.List[object]]::new()

function Add-Pass([string]$Name, [string]$Detail) {
    $Checks.Add([pscustomobject]@{ name=$Name; status="PASS"; detail=$Detail })
}
function Stop-Preflight([string]$Name, [string]$Detail) {
    $Checks.Add([pscustomobject]@{ name=$Name; status="FAIL"; detail=$Detail })
    throw "$($Name): $Detail"
}
function FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}
function Assert-Equal([string]$Name, $Actual, $Expected) {
    if ("$Actual" -ne "$Expected") {
        Stop-Preflight $Name "expected '$Expected' but found '$Actual'"
    }
    Add-Pass $Name "$Actual"
}
function Invoke-GcloudJson([string[]]$Args) {
    $raw = & gcloud @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud $($Args -join ' ') failed: $($raw | Out-String)"
    }
    $text = ($raw | Out-String).Trim()
    if (!$text) { return $null }
    return $text | ConvertFrom-Json
}
function Invoke-GcloudText([string[]]$Args) {
    $raw = & gcloud @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud $($Args -join ' ') failed: $($raw | Out-String)"
    }
    return ($raw | Out-String).Trim()
}
function Money-Usd($SpecifiedAmount) {
    $units = [decimal]0
    $nanos = [decimal]0
    if ($null -ne $SpecifiedAmount.units) { $units = [decimal]$SpecifiedAmount.units }
    if ($null -ne $SpecifiedAmount.nanos) { $nanos = [decimal]$SpecifiedAmount.nanos }
    return $units + ($nanos / [decimal]1000000000)
}

$Verdict = "FAIL"
$Failure = $null
try {
    if (!(Test-Path $PolicyPath)) { Stop-Preflight "policy_file" "missing $PolicyPath" }
    if (!(Test-Path $Python)) { Stop-Preflight "pilot_python" "missing $Python" }
    $Policy = Get-Content -Raw $PolicyPath | ConvertFrom-Json

    & $Python (Join-Path $PSScriptRoot "vertex_policy_check.py") *> (Join-Path $ResultDir "policy-check.txt")
    if ($LASTEXITCODE -ne 0) {
        $detail = Get-Content -Raw (Join-Path $ResultDir "policy-check.txt")
        Stop-Preflight "local_policy" $detail.Trim()
    }
    Add-Pass "local_policy" "model, pricing freshness, and hard-cap arithmetic valid"
    $Gcloud = Get-Command gcloud -ErrorAction SilentlyContinue
    if ($null -eq $Gcloud) { Stop-Preflight "gcloud" "Google Cloud CLI is not installed" }
    Add-Pass "gcloud" $Gcloud.Source

    $IsoRoot = Join-Path $Repo ".auth\google-vertex"
    $ExpectedAppData = FullPath (Join-Path $IsoRoot "AppData")
    $ExpectedCloudSdk = FullPath (Join-Path $IsoRoot "CloudSDK")
    $ExpectedAdc = FullPath (Join-Path $ExpectedAppData "gcloud\application_default_credentials.json")

    Assert-Equal "isolated_APPDATA" (FullPath $env:APPDATA) $ExpectedAppData
    Assert-Equal "isolated_CLOUDSDK_CONFIG" (FullPath $env:CLOUDSDK_CONFIG) $ExpectedCloudSdk
    Assert-Equal "isolated_ADC_path" (FullPath $env:GOOGLE_APPLICATION_CREDENTIALS) $ExpectedAdc
    if (!(Test-Path $ExpectedAdc)) { Stop-Preflight "isolated_ADC_file" "ADC file is missing" }
    Add-Pass "isolated_ADC_file" $ExpectedAdc

    $ProjectId = [string]$Policy.expected_project_id
    $BillingId = [string]$Policy.expected_billing_account_id
    $Model = [string]$Policy.selected_model
    $Location = [string]$Policy.selected_location

    $ConfiguredProject = Invoke-GcloudText @("config","get-value","project","--quiet")
    Assert-Equal "active_gcloud_project" $ConfiguredProject $ProjectId

    & gcloud auth application-default print-access-token *> $null
    if ($LASTEXITCODE -ne 0) { Stop-Preflight "adc_refresh" "isolated ADC cannot mint an access token" }
    Add-Pass "adc_refresh" "isolated ADC token refresh succeeded; token not printed"
    $Project = Invoke-GcloudJson @("projects","describe",$ProjectId,"--format=json")
    Assert-Equal "project_id" $Project.projectId $ProjectId
    Assert-Equal "project_state" $Project.lifecycleState "ACTIVE"
    $ProjectNumber = [string]$Project.projectNumber

    $LabelKey = [string]$Policy.required_project_label_key
    $LabelValue = [string]$Policy.required_project_label_value
    $ActualLabel = $null
    if ($null -ne $Project.labels) {
        $prop = $Project.labels.PSObject.Properties[$LabelKey]
        if ($null -ne $prop) { $ActualLabel = [string]$prop.Value }
    }
    Assert-Equal "dedicated_project_label" $ActualLabel $LabelValue

    $BillingProject = Invoke-GcloudJson @(
        "beta","billing","projects","describe",$ProjectId,"--format=json"
    )
    if ($BillingProject.billingEnabled -ne $true) {
        Stop-Preflight "project_billing_enabled" "billingEnabled is not true"
    }
    Add-Pass "project_billing_enabled" "true"
    Assert-Equal "linked_billing_account" $BillingProject.billingAccountName "billingAccounts/$BillingId"

    $BillingAccount = Invoke-GcloudJson @(
        "beta","billing","accounts","describe",$BillingId,"--format=json"
    )
    if ($BillingAccount.open -ne $true) {
        Stop-Preflight "billing_account_open" "billing account is closed or suspended"
    }
    Add-Pass "billing_account_open" $BillingId
    $Api = Invoke-GcloudText @(
        "services","list","--enabled","--project=$ProjectId",
        "--filter=config.name=$($Policy.required_api)",
        "--format=value(config.name)"
    )
    Assert-Equal "vertex_api_enabled" $Api $Policy.required_api

    if ($Policy.allowed_models -notcontains $Model) {
        Stop-Preflight "model_allowlist" "$Model is not allowlisted"
    }
    if ($Policy.allowed_locations -notcontains $Location) {
        Stop-Preflight "location_allowlist" "$Location is not allowlisted"
    }
    Add-Pass "model_allowlist" $Model
    Add-Pass "location_allowlist" $Location

    $InheritedModelVars = @(
        "FCC_SMOKE_MODEL_VERTEX","MODEL","MODEL_FABLE","MODEL_OPUS","MODEL_SONNET","MODEL_HAIKU"
    )
    foreach ($name in $InheritedModelVars) {
        $item = Get-Item "Env:$name" -ErrorAction SilentlyContinue
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace($item.Value)) { continue }
        $value = [string]$item.Value
        if (($value -like "vertex/*" -or $value -like "gemini/*") -and
            ($Policy.allowed_models -notcontains $value)) {
            Stop-Preflight "inherited_model_route" "$name=$value is not allowlisted"
        }
    }
    Add-Pass "inherited_model_route" "no unallowlisted Gemini/Vertex route inherited"
    $Budgets = @(Invoke-GcloudJson @(
        "billing","budgets","list","--billing-account=$BillingId","--format=json"
    ))
    $BudgetName = [string]$Policy.google_budget.display_name
    $Matching = @($Budgets | Where-Object { $_.displayName -eq $BudgetName })
    if ($Matching.Count -ne 1) {
        Stop-Preflight "google_budget_unique" "expected exactly one '$BudgetName' budget; found $($Matching.Count)"
    }
    $Budget = $Matching[0]
    Add-Pass "google_budget_unique" $BudgetName

    $Amount = $Budget.amount.specifiedAmount
    if ($null -eq $Amount) { Stop-Preflight "google_budget_amount" "budget is not a specified amount" }
    Assert-Equal "google_budget_currency" $Amount.currencyCode "USD"
    $BudgetUsd = Money-Usd $Amount
    if ($BudgetUsd -gt [decimal]$Policy.google_budget.max_amount_usd) {
        Stop-Preflight "google_budget_amount" "$BudgetUsd USD exceeds policy"
    }
    Add-Pass "google_budget_amount" "$BudgetUsd USD"

    $ProjectScopes = @($Budget.budgetFilter.projects)
    $AllowedProjectScopes = @("projects/$ProjectId","projects/$ProjectNumber")
    if ($ProjectScopes.Count -ne 1 -or $AllowedProjectScopes -notcontains $ProjectScopes[0]) {
        Stop-Preflight "budget_project_scope" "budget must contain only the dedicated project"
    }
    Add-Pass "budget_project_scope" $ProjectScopes[0]
    $ServiceScopes = @($Budget.budgetFilter.services)
    $ExpectedService = [string]$Policy.google_budget.service_resource
    if ($ServiceScopes.Count -ne 1 -or $ServiceScopes[0] -ne $ExpectedService) {
        Stop-Preflight "budget_service_scope" "budget must contain only $ExpectedService"
    }
    Add-Pass "budget_service_scope" $ExpectedService
    Assert-Equal "budget_period" $Budget.budgetFilter.calendarPeriod $Policy.google_budget.calendar_period

    $AttestationPath = Join-Path $PSScriptRoot ".vertex-spend-cap-attestation.json"
    if (!(Test-Path $AttestationPath)) {
        Stop-Preflight "spend_cap_attestation" "missing $AttestationPath"
    }
    $Att = Get-Content -Raw $AttestationPath | ConvertFrom-Json
    Assert-Equal "attested_project" $Att.project_id $ProjectId
    Assert-Equal "attested_billing" $Att.billing_account_id $BillingId
    Assert-Equal "attested_budget" $Att.budget_display_name $BudgetName
    Assert-Equal "attested_service" $Att.service_resource $ExpectedService
    if ($Att.spend_cap_enabled -ne $true) {
        Stop-Preflight "spend_cap_enabled" "attestation does not say spend_cap_enabled=true"
    }
    if ([decimal]$Att.budget_amount_usd -gt [decimal]$Policy.google_budget.max_amount_usd) {
        Stop-Preflight "attested_cap_amount" "attested Google cap exceeds policy"
    }
    $Confirmed = [datetimeoffset]::Parse([string]$Att.confirmed_at_utc)
    $AgeHours = ([datetimeoffset]::UtcNow - $Confirmed.ToUniversalTime()).TotalHours
    $MaxAge = [double]$Policy.google_budget.spend_cap_attestation_max_age_hours
    if ($AgeHours -lt 0 -or $AgeHours -gt $MaxAge) {
        Stop-Preflight "spend_cap_attestation_fresh" "attestation age is $([math]::Round($AgeHours,1))h"
    }
    Add-Pass "spend_cap_enabled" "fresh console attestation; age=$([math]::Round($AgeHours,1))h"

    $Caps = $Policy.local_caps
    $Pricing = $Policy.pricing_guard
    $WorstRequest = (
        ([decimal]$Caps.max_input_tokens_per_request * [decimal]$Pricing.input_per_million_usd / 1000000) +
        ([decimal]$Caps.max_output_tokens_per_request * [decimal]$Pricing.output_per_million_usd / 1000000)
    )
    $WorstRun = $WorstRequest * [decimal]$Caps.max_requests_per_run
    if ($WorstRequest -gt [decimal]$Caps.per_task_usd) {
        Stop-Preflight "per_request_hard_cap" "$WorstRequest exceeds $($Caps.per_task_usd)"
    }
    if ($WorstRun -gt [decimal]$Caps.run_reservation_usd) {
        Stop-Preflight "run_hard_cap" "$WorstRun exceeds $($Caps.run_reservation_usd)"
    }
    if ([decimal]$Caps.run_reservation_usd -gt [decimal]$Caps.pilot_total_usd) {
        Stop-Preflight "pilot_hard_cap" "run reservation exceeds pilot total"
    }
    Add-Pass "per_request_hard_cap" ("worst-case {0:N6} USD <= {1} USD" -f $WorstRequest,$Caps.per_task_usd)
    Add-Pass "run_hard_cap" ("worst-case {0:N6} USD <= {1} USD" -f $WorstRun,$Caps.run_reservation_usd)

    $ReservationDir = Join-Path $PSScriptRoot "results\live_vertex"
    $ReservationLedger = Join-Path $ReservationDir "reservations.jsonl"
    $ReservedTotal = [decimal]0
    if (Test-Path $ReservationLedger) {
        foreach ($line in Get-Content $ReservationLedger) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            $ReservedTotal += [decimal]$row.reserved_usd
        }
    }
    $AfterReservation = $ReservedTotal + [decimal]$Caps.run_reservation_usd
    if ($AfterReservation -gt [decimal]$Caps.pilot_total_usd) {
        Stop-Preflight "pilot_reservation_capacity" "$AfterReservation USD would exceed pilot cap"
    }
    Add-Pass "pilot_reservation_capacity" "$ReservedTotal USD reserved; next run remains within cap"

    $env:FCC_VERTEX_RESERVATION_LEDGER = $ReservationLedger
    $env:FCC_VERTEX_PREFLIGHT_PASSED = "1"
    $env:FCC_SMOKE_MODEL_VERTEX = $Model
    $env:VERTEX_PROJECT_ID = $ProjectId
    $env:VERTEX_LOCATION = $Location
    $Verdict = "PASS"
}
catch {
    $Failure = $_.Exception.Message
}
finally {
    $Evidence = [ordered]@{
        verdict = $Verdict
        generated_at_utc = [datetimeoffset]::UtcNow.ToString("o")
        policy_path = $PolicyPath
        checks = $Checks
        failure = $Failure
    }
    $Evidence | ConvertTo-Json -Depth 8 |
        Set-Content -Encoding UTF8 (Join-Path $ResultDir "preflight.json")
}

Write-Output "Vertex ADC preflight: $Verdict"
Write-Output "Evidence: $ResultDir"
if ($Failure) { Write-Error $Failure }
if ($Verdict -ne "PASS") { exit 2 }
exit 0

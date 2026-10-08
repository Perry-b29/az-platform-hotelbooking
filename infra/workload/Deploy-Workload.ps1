#requires -Version 7.0
<#
.SYNOPSIS
    Runs preflight validation for the workload infrastructure and optionally deploys it.

.DESCRIPTION
    Preflight always runs first: Bicep build and lint, resource provider registration check,
    caller permission check, and a what-if. The what-if is stopped when it contains a delete
    or a change to the hub other than its peering. Nothing is deployed unless -Deploy is given.

    Run from PowerShell 7+ with az CLI already logged in (`az login`) and the correct
    subscription selected (`az account set`).

.PARAMETER Environment
    Target environment: test (default) or prod. Selects workload.<env>.bicepparam and the resource group.

.PARAMETER Deploy
    Deploy after a clean preflight. Without it the script only validates.

.EXAMPLE
    ./Deploy-Workload.ps1
    Validates only.

.EXAMPLE
    ./Deploy-Workload.ps1 -Deploy
    Validates, then deploys.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('test', 'prod')]
    [string]$Environment = 'test',
    [string]$ResourceGroupName,
    [string]$HubResourceGroupName = 'rg-platform',
    [string]$Location,
    [string]$DeploymentName = "workload-$(Get-Date -Format 'yyyyMMddHHmmss')",
    [switch]$Deploy
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateFile = Join-Path $scriptRoot 'main.bicep'
$parameterFile = Join-Path $scriptRoot "workload.$Environment.bicepparam"

# Per-environment defaults. The test resource group keeps its original name; its resources live in polandcentral.
$environmentDefaults = @{
    test = @{ ResourceGroupName = 'rg-hotelbooking-test-swedencentral-001'; Location = 'swedencentral' }
    prod = @{ ResourceGroupName = 'rg-hotelbooking-prod-polandcentral-001'; Location = 'polandcentral' }
}
if (-not $ResourceGroupName) { $ResourceGroupName = $environmentDefaults[$Environment].ResourceGroupName }
if (-not $Location) { $Location = $environmentDefaults[$Environment].Location }
if (-not (Test-Path -LiteralPath $parameterFile)) { throw "Parameter file not found: $parameterFile" }

$requiredProviders = @(
    'Microsoft.App'
    'Microsoft.Insights'
    'Microsoft.ManagedIdentity'
    'Microsoft.Network'
    'Microsoft.OperationalInsights'
    'Microsoft.Resources'
    'Microsoft.Sql'
)

function Invoke-AzCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
    $output
}

function Get-CallerObjectId {
    [CmdletBinding()]
    param()

    $objectId = az ad signed-in-user show --query id --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $objectId) {
        return $objectId.Trim()
    }

    # A service principal login has no signed-in user; resolve it from the app ID instead.
    $appId = Invoke-AzCli -Arguments @('account', 'show', '--query', 'user.name', '--output', 'tsv')
    (Invoke-AzCli -Arguments @('ad', 'sp', 'show', '--id', $appId.Trim(), '--query', 'id', '--output', 'tsv')).Trim()
}

function Test-RoleOnScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ObjectId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string[]]$AcceptedRoles
    )

    $json = Invoke-AzCli -Arguments @(
        'role', 'assignment', 'list',
        '--assignee', $ObjectId,
        '--scope', $Scope,
        '--include-inherited',
        '--include-groups',
        '--query', '[].roleDefinitionName',
        '--output', 'json'
    )
    $roles = @(($json -join '') | ConvertFrom-Json)
    [bool]($roles | Where-Object { $_ -in $AcceptedRoles })
}

function Invoke-WhatIfPreflight {
    [CmdletBinding()]
    param()

    foreach ($level in 'Provider', 'ProviderNoRbac') {
        $azArguments = @(
            'deployment', 'group', 'what-if',
            '--resource-group', $ResourceGroupName,
            '--template-file', $templateFile,
            '--parameters', $parameterFile,
            '--validation-level', $level,
            '--no-pretty-print',
            '--output', 'json'
        )
        $raw = & az @azArguments
        if ($LASTEXITCODE -eq 0) {
            if ($level -ne 'Provider') {
                Write-Warning "What-if only succeeded with validation level '$level'. RBAC was not validated; check your permissions."
            }
            return ($raw -join "`n") | ConvertFrom-Json -Depth 100
        }
        Write-Warning "What-if with validation level '$level' failed."
    }

    throw 'What-if failed at both validation levels.'
}

Write-Host 'Using subscription:' -ForegroundColor Cyan
Invoke-AzCli -Arguments @('account', 'show', '--query', '{name:name, id:id}', '--output', 'table')
$subscriptionId = (Invoke-AzCli -Arguments @('account', 'show', '--query', 'id', '--output', 'tsv')).Trim()

Write-Host 'Building and linting Bicep...' -ForegroundColor Cyan
Invoke-AzCli -Arguments @('bicep', 'build', '--file', $templateFile, '--stdout') | Out-Null
Invoke-AzCli -Arguments @('bicep', 'lint', '--file', $templateFile) | Out-Null

Write-Host 'Checking resource provider registration...' -ForegroundColor Cyan
$unregistered = foreach ($namespace in $requiredProviders) {
    $state = (Invoke-AzCli -Arguments @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState', '--output', 'tsv')).Trim()
    if ($state -ne 'Registered') { "$namespace ($state)" }
}
if ($unregistered) {
    throw "Resource providers not registered: $($unregistered -join ', '). Register them first; this script does not change the subscription."
}

Write-Host 'Checking permissions...' -ForegroundColor Cyan
$callerId = Get-CallerObjectId
$workloadScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName"
$hubScope = "/subscriptions/$subscriptionId/resourceGroups/$HubResourceGroupName"

if (-not (Test-RoleOnScope -ObjectId $callerId -Scope $workloadScope -AcceptedRoles 'Owner', 'Contributor')) {
    throw "The caller needs Contributor or Owner on '$ResourceGroupName'."
}
# The hub peering is deployed into the hub resource group, and the Private DNS link needs join rights on the hub VNet.
if (-not (Test-RoleOnScope -ObjectId $callerId -Scope $hubScope -AcceptedRoles 'Owner', 'Contributor', 'Network Contributor')) {
    throw "The caller needs Network Contributor (or higher) on '$HubResourceGroupName'."
}

$groupExists = (Invoke-AzCli -Arguments @('group', 'exists', '--name', $ResourceGroupName)).Trim() -eq 'true'
if (-not $groupExists) {
    if (-not $Deploy) {
        throw "Resource group '$ResourceGroupName' does not exist. Create it, or run with -Deploy."
    }
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create resource group')) {
        Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan
        Invoke-AzCli -Arguments @('group', 'create', '--name', $ResourceGroupName, '--location', $Location, '--output', 'none') | Out-Null
    }
}

Write-Host 'Running what-if...' -ForegroundColor Cyan
$whatIf = Invoke-WhatIfPreflight
$changes = @($whatIf.changes)

$changes | Group-Object -Property changeType | Select-Object -Property Name, Count | Format-Table -AutoSize
$changes |
    Where-Object { $_.changeType -notin 'NoChange', 'Ignore' } |
    ForEach-Object { '{0,-8} {1}' -f $_.changeType, $_.resourceId } |
    Write-Host

if ($changes | Where-Object { $_.changeType -eq 'Delete' }) {
    throw 'The what-if contains a Delete. Stopping: this template must not delete anything.'
}

$hubMarker = "/resourcegroups/$($HubResourceGroupName.ToLowerInvariant())/"
$unexpectedHubChanges = $changes | Where-Object {
    $_.changeType -notin 'NoChange', 'Ignore' -and
    $_.resourceId.ToLowerInvariant().Contains($hubMarker) -and
    $_.resourceId -notmatch '/virtualNetworkPeerings/'
}
if ($unexpectedHubChanges) {
    throw "The what-if changes the hub beyond its peering: $($unexpectedHubChanges.resourceId -join ', ')"
}

if (-not $Deploy) {
    Write-Host 'Preflight passed. Nothing was deployed; re-run with -Deploy to deploy.' -ForegroundColor Green
    return
}

if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy workload infrastructure ($DeploymentName)")) {
    Write-Host "Deploying workload infrastructure ($DeploymentName)..." -ForegroundColor Cyan
    Invoke-AzCli -Arguments @(
        'deployment', 'group', 'create',
        '--resource-group', $ResourceGroupName,
        '--name', $DeploymentName,
        '--template-file', $templateFile,
        '--parameters', $parameterFile,
        '--output', 'table'
    )
    Write-Host 'Done.' -ForegroundColor Green
}

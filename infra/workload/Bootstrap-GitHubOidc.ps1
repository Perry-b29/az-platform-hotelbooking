#requires -Version 7.0
<#
.SYNOPSIS
    Bootstraps GitHub Actions OIDC federation to Azure, per environment, without any long-lived secret.

.DESCRIPTION
    For each environment (test, prod) the script, check-then-write so a re-run changes nothing:
      1. creates a user-assigned managed identity dedicated to GitHub Actions in the workload resource group;
      2. assigns Contributor on that resource group and Network Contributor on the hub scope;
      3. creates or updates exactly one federated credential for the matching GitHub Environment;
      4. creates the GitHub Environment (prod requires a reviewer, test is unprotected);
      5. sets AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID and AZURE_RESOURCE_GROUP as environment variables.

    Run from PowerShell 7+ with `az login` and `gh auth login` done. Use -WhatIf to preview without changes.

.PARAMETER HubScope
    ResourceGroup (default) assigns Network Contributor on the hub resource group. The AVM peering deployment runs as a
    nested deployment in that resource group and needs Microsoft.Resources/deployments/write there; scoping to the VNet
    resource alone fails with AuthorizationFailed. Vnet scopes the role to the hub VNet resource only.

.EXAMPLE
    ./Bootstrap-GitHubOidc.ps1 -WhatIf

.EXAMPLE
    ./Bootstrap-GitHubOidc.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkloadName = 'hotelbooking',
    [ValidateSet('test', 'prod')]
    [string[]]$Environments = @('test', 'prod'),
    [hashtable]$ResourceGroupNames = @{
        test = 'rg-hotelbooking-test-swedencentral-001'
        prod = 'rg-hotelbooking-prod-polandcentral-001'
    },
    [string]$HubResourceGroupName = 'rg-platform',
    [string]$HubVnetName = 'vnet-hub',
    [ValidateSet('ResourceGroup', 'Vnet')]
    [string]$HubScope = 'ResourceGroup',
    [string]$Location = 'polandcentral',
    [ValidateSet('Id', 'Name')]
    [string]$SubjectFormat = 'Id',
    [string]$RepoOwner,
    [string]$RepoName
)

$ErrorActionPreference = 'Stop'

$issuer = 'https://token.actions.githubusercontent.com'
$audience = 'api://AzureADTokenExchange'

function Invoke-Az {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
    $output
}

function Get-AzJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & az @Arguments --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }
    ($output -join "`n") | ConvertFrom-Json
}

function Get-GhJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & gh @Arguments 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }
    ($output -join "`n") | ConvertFrom-Json
}

if (-not $RepoOwner -or -not $RepoName) {
    $remote = (git remote get-url origin).Trim()
    if ($remote -notmatch 'github\.com[:/](?<owner>[^/]+)/(?<name>[^/]+?)(\.git)?$') {
        throw "Cannot infer the GitHub repository from origin '$remote'. Pass -RepoOwner and -RepoName."
    }
    if (-not $RepoOwner) { $RepoOwner = $Matches.owner }
    if (-not $RepoName) { $RepoName = $Matches.name }
}
$repo = "$RepoOwner/$RepoName"

# GitHub sends owner and repository IDs in the OIDC subject by default for newer repositories, and it ignored a
# name-based template on this repository. The default is the stable choice, so the credential is registered with
# the subject GitHub actually sends. -SubjectFormat Name registers the name-based subject instead.
$repoInfo = Get-GhJson -Arguments @('api', "repos/$repo")
if (-not $repoInfo) { throw "Cannot read repository $repo. Check gh auth status." }
$subjectBase = if ($SubjectFormat -eq 'Id') { "repo:$RepoOwner@$($repoInfo.owner.id)/$RepoName@$($repoInfo.id)" } else { "repo:$RepoOwner/$RepoName" }

$subjectTemplate = Get-GhJson -Arguments @('api', "repos/$repo/actions/oidc/customization/sub")
if ($SubjectFormat -eq 'Id') { $templateBody = @{ use_default = $true } } else { $templateBody = @{ use_default = $false; include_claim_keys = @('repo', 'context') } }
$templateCurrent = $false
if ($subjectTemplate) {
    if ($SubjectFormat -eq 'Id') { $templateCurrent = [bool]$subjectTemplate.use_default }
    else { $templateCurrent = (-not $subjectTemplate.use_default) -and ((@($subjectTemplate.include_claim_keys) -join ',') -eq 'repo,context') }
}
if (-not $templateCurrent) {
    if ($PSCmdlet.ShouldProcess($repo, "Set the OIDC subject claim template for the $SubjectFormat format")) {
        ($templateBody | ConvertTo-Json -Compress) | & gh api --method PUT "repos/$repo/actions/oidc/customization/sub" --input - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not set the OIDC subject claim template for $repo." }
        Write-Host "OIDC subject claim template set for the $SubjectFormat format"
    }
}
else {
    Write-Host 'OIDC subject claim template up to date'
}

Write-Host "Repository: $repo" -ForegroundColor Cyan
Write-Host 'Using subscription:' -ForegroundColor Cyan
$account = Get-AzJson -Arguments @('account', 'show')
if (-not $account) { throw 'Not logged in to Azure. Run az login.' }
Write-Host "  $($account.name)"
$subscriptionId = $account.id
$tenantId = $account.tenantId

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw 'Not logged in to GitHub. Run gh auth login.' }
$reviewerId = [int](& gh api user --jq '.id')

$hubScopeId = if ($HubScope -eq 'ResourceGroup') {
    "/subscriptions/$subscriptionId/resourceGroups/$HubResourceGroupName"
}
else {
    (Invoke-Az -Arguments @('network', 'vnet', 'show', '--resource-group', $HubResourceGroupName, '--name', $HubVnetName, '--query', 'id', '--output', 'tsv')).Trim()
}

$summary = foreach ($environmentName in $Environments) {
    $resourceGroup = $ResourceGroupNames[$environmentName]
    if (-not $resourceGroup) { throw "No resource group configured for environment '$environmentName'." }
    $identityName = "id-github-$WorkloadName-$environmentName-$Location-001"
    $workloadScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
    Write-Host "`n[$environmentName] $identityName" -ForegroundColor Cyan

    if (-not (Get-AzJson -Arguments @('group', 'show', '--name', $resourceGroup))) {
        throw "Resource group '$resourceGroup' does not exist."
    }

    $identity = Get-AzJson -Arguments @('identity', 'show', '--resource-group', $resourceGroup, '--name', $identityName)
    if (-not $identity) {
        if ($PSCmdlet.ShouldProcess($identityName, 'Create user-assigned managed identity')) {
            $identity = Get-AzJson -Arguments @('identity', 'create', '--resource-group', $resourceGroup, '--name', $identityName, '--location', $Location)
            Write-Host '  identity created'
        }
    }
    else {
        Write-Host '  identity exists'
    }

    if ($identity) {
        foreach ($assignment in @(
                @{ Role = 'Contributor'; Scope = $workloadScope },
                @{ Role = 'Network Contributor'; Scope = $hubScopeId })) {
            $existingAssignments = @(Invoke-Az -Arguments @('role', 'assignment', 'list', '--scope', $assignment.Scope, '--role', $assignment.Role, '--query', "[?principalId=='$($identity.principalId)'].id", '--output', 'tsv') | Where-Object { $_ })
            $count = $existingAssignments.Count
            if ($count -gt 0) {
                Write-Host "  $($assignment.Role) already assigned"
            }
            elseif ($PSCmdlet.ShouldProcess($assignment.Scope, "Assign $($assignment.Role)")) {
                # Assign by object ID so a not-yet-replicated identity does not fail the lookup.
                # A new identity can take a while to replicate; retry the assignment instead of failing.
                for ($attempt = 1; $attempt -le 6; $attempt++) {
                    & az role assignment create --assignee-object-id $identity.principalId --assignee-principal-type ServicePrincipal --role $assignment.Role --scope $assignment.Scope --output none 2>$null
                    if ($LASTEXITCODE -eq 0) { break }
                    if ($attempt -eq 6) { throw "Could not assign $($assignment.Role) on $($assignment.Scope) after $attempt attempts." }
                    Start-Sleep -Seconds 10
                }
                Write-Host "  $($assignment.Role) assigned"
            }
        }

        # The subject is generated from variables, never typed.
        $subject = "$subjectBase`:environment:$environmentName"
        $credentialName = "github-$environmentName"
        $credentials = @(Get-AzJson -Arguments @('identity', 'federated-credential', 'list', '--resource-group', $resourceGroup, '--identity-name', $identityName))
        $others = @($credentials | Where-Object { $_ -and $_.name -ne $credentialName })
        if ($others.Count -gt 0) { Write-Warning "Unexpected extra federated credentials on ${identityName}: $($others.name -join ', ')" }

        $current = $credentials | Where-Object { $_ -and $_.name -eq $credentialName }
        $credentialArguments = @('--name', $credentialName, '--identity-name', $identityName, '--resource-group', $resourceGroup, '--issuer', $issuer, '--subject', $subject, '--audiences', $audience)
        if (-not $current) {
            if ($PSCmdlet.ShouldProcess($credentialName, "Create federated credential ($subject)")) {
                Invoke-Az -Arguments (@('identity', 'federated-credential', 'create') + $credentialArguments + @('--output', 'none')) | Out-Null
                Write-Host "  federated credential created: $subject"
            }
        }
        elseif ($current.subject -ne $subject -or $current.issuer -ne $issuer -or $current.audiences -notcontains $audience) {
            if ($PSCmdlet.ShouldProcess($credentialName, "Update federated credential ($subject)")) {
                Invoke-Az -Arguments (@('identity', 'federated-credential', 'update') + $credentialArguments + @('--output', 'none')) | Out-Null
                Write-Host "  federated credential updated: $subject"
            }
        }
        else {
            Write-Host '  federated credential up to date'
        }
    }

    $environment = Get-GhJson -Arguments @('api', "repos/$repo/environments/$environmentName")
    $reviewerPresent = $environment -and (@($environment.protection_rules | Where-Object { $_.type -eq 'required_reviewers' } | ForEach-Object { $_.reviewers.reviewer.id }) -contains $reviewerId)
    if ($environmentName -eq 'prod') {
        if (-not $reviewerPresent -and $PSCmdlet.ShouldProcess("$repo/$environmentName", 'Create environment with required reviewer')) {
            $body = @{ reviewers = @(@{ type = 'User'; id = $reviewerId }) } | ConvertTo-Json -Depth 5 -Compress
            $body | & gh api --method PUT "repos/$repo/environments/$environmentName" --input - | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not configure GitHub Environment '$environmentName'. Environment protection on a private repository may need a paid GitHub plan." }
            Write-Host '  environment configured with required reviewer'
        }
        elseif ($reviewerPresent) { Write-Host '  environment has the required reviewer' }
    }
    else {
        if (-not $environment -and $PSCmdlet.ShouldProcess("$repo/$environmentName", 'Create environment')) {
            & gh api --method PUT "repos/$repo/environments/$environmentName" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not create GitHub Environment '$environmentName'." }
            Write-Host '  environment created'
        }
        elseif ($environment) {
            Write-Host '  environment exists'
            if (@($environment.protection_rules).Count -gt 0) { Write-Warning "Environment '$environmentName' has protection rules; it is expected to be unprotected." }
        }
    }

    if ($identity) {
        $desired = [ordered]@{
            AZURE_CLIENT_ID       = $identity.clientId
            AZURE_TENANT_ID       = $tenantId
            AZURE_SUBSCRIPTION_ID = $subscriptionId
            AZURE_RESOURCE_GROUP  = $resourceGroup
        }
        $existing = @{}
        $listed = Get-GhJson -Arguments @('api', "repos/$repo/environments/$environmentName/variables")
        foreach ($variable in @($listed.variables)) { if ($variable) { $existing[$variable.name] = $variable.value } }
        foreach ($name in $desired.Keys) {
            if ($existing[$name] -eq $desired[$name]) { continue }
            if ($PSCmdlet.ShouldProcess("$repo/$environmentName", "Set variable $name")) {
                & gh variable set $name --env $environmentName --repo $repo --body $desired[$name] | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Could not set variable $name for environment '$environmentName'." }
                Write-Host "  variable $name set"
            }
        }
    }

    [pscustomobject]@{ Environment = $environmentName; Identity = $identityName; ResourceGroup = $resourceGroup; Subject = "$subjectBase`:environment:$environmentName" }
}

Write-Host "`nSummary" -ForegroundColor Green
$summary | Format-Table -AutoSize

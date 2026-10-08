targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all workload resources.')
param location string = 'polandcentral'

@description('Workload token used in CAF resource names.')
@minLength(2)
@maxLength(20)
param workloadToken string = 'hotelbooking'

@description('Environment token used in CAF resource names.')
@minLength(2)
@maxLength(8)
param environmentToken string = 'test'

@description('Region token used in CAF resource names.')
@minLength(2)
@maxLength(20)
param regionToken string = 'polandcentral'

@description('Short region token for names with a tight length limit (Container Apps: 32 characters).')
@minLength(2)
@maxLength(6)
param regionShort string = 'plc'

@description('Instance number used in CAF resource names.')
@minLength(3)
@maxLength(3)
param instance string = '001'

@description('Name of the existing hub resource group. The hub is never modified except for the hub-side peering.')
param hubResourceGroupName string = 'rg-platform'

@description('Name of the existing hub virtual network.')
param hubVnetName string = 'vnet-hub'

@description('Address space of the spoke virtual network. Must not overlap the hub or the Sweden spoke (10.20.0.0/16).')
param spokeAddressPrefix string = '10.30.0.0/16'

@description('Name of the private endpoint subnet.')
param privateEndpointSubnetName string = 'snet-private-endpoints'

@description('Address prefix of the private endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.30.0.0/24'

@description('Address prefix of the Container Apps infrastructure subnet. A /23 leaves room for growth.')
param appSubnetPrefix string = '10.30.2.0/23'

@description('Backend container image. The workshop image is public, so no registry credentials are needed.')
param backendImage string = 'ghcr.io/azureholic/az-platform-engineering-workshop/backend:latest'

@description('Frontend container image. The workshop image is public, so no registry credentials are needed.')
param frontendImage string = 'ghcr.io/azureholic/az-platform-engineering-workshop/frontend:latest'

@description('SQL database SKU: name, tier, capacity and, for vCore SKUs, family.')
param sqlSku object = {
  name: 'Basic'
  tier: 'Basic'
  capacity: 5
}

@description('Zone redundancy for the SQL database. Only General Purpose and above support it.')
param sqlZoneRedundant bool = false

@description('Backup storage redundancy for the SQL database.')
@allowed([
  'Local'
  'Zone'
  'Geo'
])
param sqlBackupRedundancy string = 'Local'

@description('SQL auto-pause delay in minutes. -1 disables auto-pause.')
param sqlAutoPauseDelay int = -1

@description('Zone redundancy for the Container Apps environment. It can only be set when the environment is created.')
param acaZoneRedundant bool = false

@description('Minimum replicas per container app. 0 enables scale to zero.')
@minValue(0)
param minReplicas int = 0

@description('Maximum replicas per container app.')
@minValue(1)
param maxReplicas int = 1

@description('Name of the peering on the hub VNet. It must be unique per spoke.')
@minLength(1)
@maxLength(80)
param hubPeeringName string = 'peer-hub-to-polandcentral-spoke'

@description('Link the hub VNet to this environment Private DNS zone. A VNet cannot be linked to two zones with the same name, so only one environment sets this to true.')
param linkHubToDns bool = true

@description('Maximum SQL database size in bytes (Basic supports up to 2 GB).')
param sqlMaxSizeBytes int = 2147483648

@description('Backend container CPU cores.')
param backendCpu string = '0.5'

@description('Backend container memory.')
param backendMemory string = '1Gi'

@description('Frontend container CPU cores.')
param frontendCpu string = '0.25'

@description('Frontend container memory.')
param frontendMemory string = '0.5Gi'

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@description('Tags applied to all resources.')
param tags object = {
  workload: 'hotelbooking'
  environment: 'test'
  role: 'spoke'
}

// ---------------------------------------------------------------------------
// Names (CAF)
// ---------------------------------------------------------------------------

var nameSuffix = '${workloadToken}-${environmentToken}-${regionToken}-${instance}'
var shortSuffix = '${environmentToken}-${regionShort}-${instance}'
var regionSuffix = '${environmentToken}-${regionToken}-${instance}'

var spokeVnetName = 'vnet-${nameSuffix}'
var appSubnetName = 'snet-apps-${regionSuffix}'
var backendIdentityName = 'id-hotelapi-${regionSuffix}'
var frontendIdentityName = 'id-hotelweb-${regionSuffix}'
var logWorkspaceName = 'log-${nameSuffix}'
var appInsightsName = 'appi-${nameSuffix}'
var sqlServerName = 'sql-${nameSuffix}-${uniqueString(resourceGroup().id)}'
var sqlDatabaseName = 'sqldb-${nameSuffix}'
var sqlPrivateEndpointName = 'pep-sql-${nameSuffix}'
var containerEnvironmentName = 'cae-${nameSuffix}'
var backendAppName = 'ca-hotelapi-${shortSuffix}'
var frontendAppName = 'ca-hotelweb-${shortSuffix}'

var sqlPrivateDnsZoneName = 'privatelink${environment().suffixes.sqlServerHostname}'
var spokeToHubPeeringName = 'peer-spoke-to-hub'
// Includes the region: the hub already holds a peering named 'peer-hub-to-spoke' for the Sweden spoke,
// and a peering cannot be repointed to another VNet.
var hubToSpokePeeringName = hubPeeringName

// ---------------------------------------------------------------------------
// Identities (user-assigned; no secrets)
// ---------------------------------------------------------------------------

module backendIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'id-backend'
  params: {
    name: backendIdentityName
    location: location
    tags: tags
    enableTelemetry: false
  }
}

module frontendIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'id-frontend'
  params: {
    name: frontendIdentityName
    location: location
    tags: tags
    enableTelemetry: false
  }
}

// ---------------------------------------------------------------------------
// Monitor stack. Public by design: no private endpoints, no Private Link scope.
// ---------------------------------------------------------------------------

module logWorkspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'log-workspace'
  params: {
    name: logWorkspaceName
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: logRetentionDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    enableTelemetry: false
  }
}

module appInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'app-insights'
  params: {
    name: appInsightsName
    location: location
    tags: tags
    workspaceResourceId: logWorkspace.outputs.resourceId
    kind: 'web'
    applicationType: 'web'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    enableTelemetry: false
  }
}

// ---------------------------------------------------------------------------
// Network: existing spoke (both subnets + spoke-side peering), hub-side peering, Private DNS
// ---------------------------------------------------------------------------

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
  scope: resourceGroup(hubResourceGroupName)
}

module spokeVnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'spoke-vnet'
  params: {
    name: spokeVnetName
    location: location
    tags: tags
    addressPrefixes: [
      spokeAddressPrefix
    ]
    subnets: [
      {
        name: privateEndpointSubnetName
        addressPrefix: privateEndpointSubnetPrefix
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        name: appSubnetName
        addressPrefix: appSubnetPrefix
        delegation: 'Microsoft.App/environments'
        // Azure reports 'Disabled' on this subnet after the environment is created; match it so
        // the template does not flip the setting back on every run.
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
    peerings: [
      {
        name: spokeToHubPeeringName
        remoteVirtualNetworkResourceId: hubVnet.id
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: false
        allowGatewayTransit: false
        useRemoteGateways: false
        doNotVerifyRemoteGateways: false // matches the value Azure already reports for the existing peering
        // The hub side is deployed by the dedicated module below, scoped to the hub resource group.
        remotePeeringEnabled: false
      }
    ]
    enableTelemetry: false
  }
}

module hubPeering 'modules/hub-peering.bicep' = {
  name: 'hub-peering-${environmentToken}'
  scope: resourceGroup(hubResourceGroupName)
  params: {
    hubVnetName: hubVnetName
    peeringName: hubToSpokePeeringName
    spokeVnetResourceId: spokeVnet.outputs.resourceId
  }
}

// Distributed Private DNS: the zone lives in the workload resource group and is linked to the
// spoke and the hub. Registration is off: records come from the private endpoint zone group.
module sqlPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'dns-sql'
  params: {
    name: sqlPrivateDnsZoneName
    tags: tags
    virtualNetworkLinks: concat([
      {
        // Region in the name: the existing 'vnetlink-spoke' points at the Sweden spoke and cannot be repointed.
        name: 'vnetlink-spoke-${regionToken}'
        virtualNetworkResourceId: spokeVnet.outputs.resourceId
        registrationEnabled: false
      }
    ], linkHubToDns ? [
      {
        name: 'vnetlink-hub'
        virtualNetworkResourceId: hubVnet.id
        registrationEnabled: false
      }
    ] : [])
    enableTelemetry: false
  }
}

// ---------------------------------------------------------------------------
// Azure SQL: private only, Entra-only, backend managed identity is the Entra admin
// ---------------------------------------------------------------------------

module sqlServer 'br/public:avm/res/sql/server:0.22.1' = {
  name: 'sql-server'
  params: {
    name: sqlServerName
    location: location
    tags: tags
    // VERIFY: parameter name and shape (administrators vs administrator) against the module version.
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: backendIdentity.outputs.name
      principalType: 'Application' // required for a user-assigned managed identity
      sid: backendIdentity.outputs.principalId // principalId, not clientId or resourceId
      tenantId: tenant().tenantId
    }
    publicNetworkAccess: 'Disabled'
    minimalTlsVersion: '1.2'
    databases: [
      {
        name: sqlDatabaseName
        availabilityZone: -1
        sku: sqlSku
        maxSizeBytes: sqlMaxSizeBytes
        zoneRedundant: sqlZoneRedundant
        requestedBackupStorageRedundancy: sqlBackupRedundancy
        autoPauseDelay: sqlAutoPauseDelay
      }
    ]
    privateEndpoints: [
      {
        name: sqlPrivateEndpointName
        subnetResourceId: '${spokeVnet.outputs.resourceId}/subnets/${privateEndpointSubnetName}'
        service: 'sqlServer'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: sqlPrivateDnsZone.outputs.resourceId
            }
          ]
        }
        tags: tags
      }
    ]
    enableTelemetry: false
  }
}

// ---------------------------------------------------------------------------
// Container Apps: Consumption only, no zone redundancy, scale to zero
// ---------------------------------------------------------------------------

module containerEnvironment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'container-environment'
  params: {
    name: containerEnvironmentName
    location: location
    tags: tags
    // The subnet ID is derived from the VNet output so the subnet exists (and is delegated) first.
    infrastructureSubnetResourceId: '${spokeVnet.outputs.resourceId}/subnets/${appSubnetName}'
    internal: false // the frontend is the one public workload surface
    // The AVM module defaults to 'Disabled', which blocks the public frontend. Only the frontend app
    // has external ingress; the backend stays internal and SQL stays private.
    publicNetworkAccess: 'Enabled'
    zoneRedundant: acaZoneRedundant
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    // VERIFY: no Log Analytics shared key may be passed as a parameter, so logs go through
    // Azure Monitor diagnostic settings. Confirm this module version supports both settings.
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    diagnosticSettings: [
      {
        workspaceResourceId: logWorkspace.outputs.resourceId
        logCategoriesAndGroups: [
          {
            categoryGroup: 'allLogs'
          }
        ]
      }
    ]
    enableTelemetry: false
  }
}

module backendApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'app-backend'
  params: {
    name: backendAppName
    location: location
    tags: tags
    environmentResourceId: containerEnvironment.outputs.resourceId
    workloadProfileName: 'Consumption'
    activeRevisionsMode: 'Single'
    managedIdentities: {
      userAssignedResourceIds: [
        backendIdentity.outputs.resourceId
      ]
    }
    // Internal ingress only: reachable from the frontend inside the environment.
    ingressExternal: false
    ingressTargetPort: 8080
    ingressTransport: 'auto'
    ingressAllowInsecure: false
    scaleSettings: {
      minReplicas: minReplicas
      maxReplicas: maxReplicas
      rules: [
        {
          name: 'http-requests'
          http: {
            metadata: {
              concurrentRequests: '10'
            }
          }
        }
      ]
    }
    containers: [
      {
        name: 'backend'
        image: backendImage
        resources: {
          cpu: json(backendCpu)
          memory: backendMemory
        }
        env: [
          {
            name: 'ASPNETCORE_ENVIRONMENT'
            value: 'Production'
          }
          {
            // Passwordless: the managed identity authenticates; there is no password in this string.
            name: 'ConnectionStrings__HotelDb'
            value: 'Server=tcp:${sqlServer.outputs.fullyQualifiedDomainName},1433;Database=${sqlDatabaseName};Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
          }
          {
            // Selects the intended identity for DefaultAzureCredential.
            name: 'AZURE_CLIENT_ID'
            value: backendIdentity.outputs.clientId
          }
          {
            // Contains an instrumentation key, which Microsoft documents as an identifier, not a secret.
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.outputs.connectionString
          }
        ]
        probes: [
          {
            // The API opens its port only after the database is initialised on first start.
            type: 'Startup'
            tcpSocket: {
              port: 8080
            }
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 10
          }
        ]
      }
    ]
    enableTelemetry: false
  }
}

module frontendApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'app-frontend'
  params: {
    name: frontendAppName
    location: location
    tags: tags
    environmentResourceId: containerEnvironment.outputs.resourceId
    workloadProfileName: 'Consumption'
    activeRevisionsMode: 'Single'
    managedIdentities: {
      userAssignedResourceIds: [
        frontendIdentity.outputs.resourceId
      ]
    }
    ingressExternal: true
    ingressTargetPort: 8080
    ingressTransport: 'auto'
    ingressAllowInsecure: false
    scaleSettings: {
      minReplicas: minReplicas
      maxReplicas: maxReplicas
      rules: [
        {
          name: 'http-requests'
          http: {
            metadata: {
              concurrentRequests: '10'
            }
          }
        }
      ]
    }
    containers: [
      {
        name: 'frontend'
        image: frontendImage
        resources: {
          cpu: json(frontendCpu)
          memory: frontendMemory
        }
        env: [
          {
            // Internal HTTPS URL of the backend, host and optional port only (the image validates this).
            name: 'BACKEND_URL'
            value: 'https://${backendApp.outputs.fqdn}'
          }
        ]
      }
    ]
    enableTelemetry: false
  }
}

// ---------------------------------------------------------------------------
// Outputs: identifiers and public URLs only, no secrets
// ---------------------------------------------------------------------------

output frontendUrl string = 'https://${frontendApp.outputs.fqdn}'
output spokeVnetResourceId string = spokeVnet.outputs.resourceId
output sqlServerFqdn string = sqlServer.outputs.fullyQualifiedDomainName
output backendIdentityPrincipalId string = backendIdentity.outputs.principalId

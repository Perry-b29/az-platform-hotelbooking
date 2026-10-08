using './main.bicep'

param location = 'polandcentral'
param workloadToken = 'hotelbooking'
param environmentToken = 'test'
param regionToken = 'polandcentral'
param regionShort = 'plc'
param instance = '001'

param hubResourceGroupName = 'rg-platform'
param hubVnetName = 'vnet-hub'
param hubPeeringName = 'peer-hub-to-polandcentral-spoke'
param linkHubToDns = true

param spokeAddressPrefix = '10.30.0.0/16'
param privateEndpointSubnetName = 'snet-private-endpoints'
param privateEndpointSubnetPrefix = '10.30.0.0/24'
param appSubnetPrefix = '10.30.2.0/23'

param backendImage = 'ghcr.io/azureholic/az-platform-engineering-workshop/backend:latest'
param frontendImage = 'ghcr.io/azureholic/az-platform-engineering-workshop/frontend:latest'

param sqlSku = {
  name: 'Basic'
  tier: 'Basic'
  capacity: 5
}
param sqlZoneRedundant = false
param sqlBackupRedundancy = 'Local'
param sqlAutoPauseDelay = -1
param sqlMaxSizeBytes = 2147483648

param backendCpu = '0.5'
param backendMemory = '1Gi'
param frontendCpu = '0.25'
param frontendMemory = '0.5Gi'

param acaZoneRedundant = false
param minReplicas = 0
param maxReplicas = 1

param logRetentionDays = 30

param tags = {
  workload: 'hotelbooking'
  environment: 'test'
  role: 'spoke'
}

using './main.bicep'

param location = 'polandcentral'
param workloadToken = 'hotelbooking'
param environmentToken = 'prod'
param regionToken = 'polandcentral'
param regionShort = 'plc'
param instance = '001'

param hubResourceGroupName = 'rg-platform'
param hubVnetName = 'vnet-hub'
param hubPeeringName = 'peer-hub-to-polandcentral-spoke-prod'
// The hub is already linked to the test zone; a VNet cannot be linked to two zones with the same name.
param linkHubToDns = false

param spokeAddressPrefix = '10.31.0.0/16'
param privateEndpointSubnetName = 'snet-private-endpoints'
param privateEndpointSubnetPrefix = '10.31.0.0/24'
param appSubnetPrefix = '10.31.2.0/23'

param backendImage = 'ghcr.io/azureholic/az-platform-engineering-workshop/backend:latest'
param frontendImage = 'ghcr.io/azureholic/az-platform-engineering-workshop/frontend:latest'

// Basic has no zone redundancy; General Purpose does.
param sqlSku = {
  name: 'GP_Gen5'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 2
}
param sqlZoneRedundant = true
param sqlBackupRedundancy = 'Zone'
param sqlAutoPauseDelay = -1
param sqlMaxSizeBytes = 34359738368

param backendCpu = '0.5'
param backendMemory = '1Gi'
param frontendCpu = '0.25'
param frontendMemory = '0.5Gi'

param acaZoneRedundant = true
param minReplicas = 3
param maxReplicas = 10

param logRetentionDays = 30

param tags = {
  workload: 'hotelbooking'
  environment: 'prod'
  role: 'spoke'
}
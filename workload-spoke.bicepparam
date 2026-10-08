using './workload-spoke.bicep'

param location = 'swedencentral'
param workloadResourceGroupName = 'rg-hotelbooking-test-swedencentral-001'
param hubResourceGroupName = 'rg-platform'
param hubVnetName = 'vnet-hub'
param spokeVnetName = 'vnet-hotelbooking-test-swedencentral-001'
param spokeAddressPrefix = '10.20.0.0/16'
param privateEndpointSubnetPrefix = '10.20.0.0/24'
param tags = {
  workload: 'hotelbooking'
  environment: 'test'
  role: 'spoke'
}

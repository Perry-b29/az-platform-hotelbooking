targetScope = 'subscription'

@description('Azure region for the workload resource group and spoke network.')
param location string = 'swedencentral'

@description('Name of the workload resource group for the test environment.')
@minLength(1)
@maxLength(90)
param workloadResourceGroupName string = 'rg-hotelbooking-test-swedencentral-001'

@description('Name of the existing hub resource group.')
@minLength(1)
@maxLength(90)
param hubResourceGroupName string = 'rg-platform'

@description('Name of the existing hub virtual network.')
@minLength(2)
@maxLength(64)
param hubVnetName string = 'vnet-hub'

@description('Name of the workload spoke virtual network.')
@minLength(2)
@maxLength(64)
param spokeVnetName string = 'vnet-hotelbooking-test-swedencentral-001'

@description('Non-overlapping IPv4 address space for the workload spoke.')
param spokeAddressPrefix string = '10.20.0.0/16'

@description('Address prefix reserved for private endpoints in the workload spoke.')
param privateEndpointSubnetPrefix string = '10.20.0.0/24'

@description('Tags applied to the workload resource group and spoke network.')
param tags object = {
  workload: 'hotelbooking'
  environment: 'test'
  role: 'spoke'
}

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
  scope: resourceGroup(hubResourceGroupName)
}

module workloadResourceGroup 'br/public:avm/res/resources/resource-group:0.4.0' = {
  name: 'workload-resource-group-${uniqueString(subscription().id, workloadResourceGroupName)}'
  params: {
    name: workloadResourceGroupName
    location: location
    tags: tags
    enableTelemetry: false
  }
}

module spokeVnet 'br/public:avm/res/network/virtual-network:0.10.0' = {
  name: 'workload-spoke-vnet-${uniqueString(subscription().id, workloadResourceGroupName)}'
  scope: resourceGroup(workloadResourceGroupName)
  params: {
    name: spokeVnetName
    location: location
    addressPrefixes: [
      spokeAddressPrefix
    ]
    subnets: [
      {
        name: 'snet-private-endpoints'
        addressPrefix: privateEndpointSubnetPrefix
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
    peerings: [
      {
        name: 'peer-spoke-to-hub'
        remoteVirtualNetworkResourceId: hubVnet.id
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: false
        allowGatewayTransit: false
        useRemoteGateways: false
        remotePeeringEnabled: true
        remotePeeringName: 'peer-hub-to-spoke'
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringAllowForwardedTraffic: false
        remotePeeringAllowGatewayTransit: false
        remotePeeringUseRemoteGateways: false
      }
    ]
    tags: tags
    enableTelemetry: false
  }
  dependsOn: [
    workloadResourceGroup
  ]
}

output workloadResourceGroupId string = workloadResourceGroup.outputs.resourceId
output spokeVnetId string = spokeVnet.outputs.resourceId
output spokeAddressSpace string = spokeAddressPrefix

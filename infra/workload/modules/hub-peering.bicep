targetScope = 'resourceGroup'

// Hub side of the spoke peering. main.bicep deploys this module with scope rg-platform,
// so the peering is created on the existing hub VNet without touching anything else in the hub.

@description('Name of the existing hub virtual network.')
@minLength(2)
@maxLength(64)
param hubVnetName string

@description('Name of the peering on the hub VNet.')
@minLength(1)
@maxLength(80)
param peeringName string

@description('Resource ID of the spoke virtual network the hub peers with.')
param spokeVnetResourceId string

module hubPeering 'br/public:avm/res/network/virtual-network/virtual-network-peering:0.2.0' = {
  name: 'hub-peering-${uniqueString(spokeVnetResourceId)}'
  params: {
    name: peeringName
    localVnetName: hubVnetName
    remoteVirtualNetworkResourceId: spokeVnetResourceId
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    doNotVerifyRemoteGateways: false // matches the value Azure already reports for the existing peering
    enableTelemetry: false
  }
}

output peeringResourceId string = hubPeering.outputs.resourceId

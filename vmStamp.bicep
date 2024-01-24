targetScope = 'resourceGroup'

param location string = resourceGroup().location
param vmNames array
param keyVaultName string
param keyVaultRgName string
param automationAccountName string
param automationAccountResourceGroupName string
param vmSize string
param vmDataDiskCount int
param managedIdName string


var clusterRgName = resourceGroup().name
var bootDiagStorageAccountName = toLower(replace('${clusterRgName}diag', '-', ''))

//reference to existing AKV. This is where the local admin user/pass combo is defined as secrets stored as adminUsername and adminPassword.
resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' existing = {
  name: keyVaultName
  scope: resourceGroup('${keyVaultRgName}')
}

//Vm boot diagnostics storage account
resource bootDiagStorageAccount 'Microsoft.Storage/storageAccounts@2021-08-01' = {
  name: bootDiagStorageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}

//PublicIP for the Azure Load Balancer
resource clusterLbIp 'Microsoft.Network/publicIPAddresses@2020-11-01' = {
  name: '${clusterRgName}-LB-IP'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: toLower(clusterRgName)
    }
  }
}

//Azure vNet for the Proxies and LB
resource clusterVNET 'Microsoft.Network/virtualNetworks@2020-11-01' = {
  name: '${clusterRgName}-VNET'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.1.0.0/24'
      ]
    }
    subnets: [
      {
        name: '${clusterRgName}-vSUBNET'
        properties: {
          addressPrefix: '10.1.0.0/24'
          delegations: []
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
    virtualNetworkPeerings: []
    enableDdosProtection: false
  }
}

//Private NAT Subnet within the vNet.
resource clusterSubnet 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' = {
  parent: clusterVNET
  name: '${clusterRgName}-vSUBNET'
  properties: {
    addressPrefix: '10.1.0.0/24'
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

//Network Security Group to limit RDP connections to only Microsoft Corp IPs
resource clusterNSG 'Microsoft.Network/networkSecurityGroups@2020-11-01' = {
  name: '${clusterRgName}-NSG'
  location: location
  properties: {
    securityRules: [
      {
        name: 'ALLOW-RDP-ALL'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: '<source_ip_list>'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
      }
      {
        name: 'ALLOW-HTTPS-ALL'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
      }
    ]
  }
}

//Azure Load Balancer
resource clusterLB 'Microsoft.Network/loadBalancers@2020-11-01' = {
  name: '${clusterRgName}-LB'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: '${clusterRgName}-LBFEConfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: clusterLbIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: '${clusterRgName}-LB-BEAP'
      }
    ]
    loadBalancingRules: [
      {
        name: '${clusterRgName}-LB-TCP-443'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIpConfigurations', '${clusterRgName}-LB', '${clusterRgName}-LBFEConfig')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${clusterRgName}-LB', '${clusterRgName}-LB-TCP')
          }
          frontendPort: 443
          backendPort: 443
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          protocol: 'Tcp'
          enableTcpReset: false
          loadDistribution: 'Default'
          disableOutboundSnat: false
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${clusterRgName}-LB', '${clusterRgName}-LB-BEAP')
          }
        }
      }
    ]
    probes: [
      {
        name: '${clusterRgName}-LB-TCP'
        properties: {
          protocol: 'Tcp'
          port: 443
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
  }
}

//Availability Set for the Proxy VMs.
resource clusterAvSet 'Microsoft.Compute/availabilitySets@2020-12-01' = {
  name: '${clusterRgName}-AVSet'
  location: location
  sku: {
    name: 'Aligned'
  }
  properties: {
    platformUpdateDomainCount: 2
    platformFaultDomainCount: 2
    virtualMachines: []
  }
}

//Proxy VMs
module clusterVM 'vm.bicep' = [for (vm, i) in array(vmNames): {
  name: vm
  params: {
    vmAdminUsername: keyVault.getSecret('adminUsername')
    vmAdminPassword: keyVault.getSecret('adminPassword')
    location: location
    vmName: vm
    clusterNsgId: clusterNSG.id
    clusterSubnetId: clusterSubnet.id
    vmSize: vmSize
    availabilitySetId: clusterAvSet.id
    bootDiagStorageAccount: bootDiagStorageAccount
    vmDataDiskCount: vmDataDiskCount
    automationAccountName: automationAccountName
    automationAccountResourceGroupName: automationAccountResourceGroupName
    managedIdName: managedIdName
  }
}]


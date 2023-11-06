param vmName string
param location string = resourceGroup().location
param availabilitySetId string
param clusterNsgId string
param clusterSubnetId string
param bootDiagStorageAccount object
param vmSize string
param vmDataDiskCount int
param automationAccountName string
param automationAccountResourceGroupName string
param managedIdName string

@secure()
param vmAdminUsername string
@secure()
param vmAdminPassword string

var clusterRgName = resourceGroup().name


resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2022-01-31-preview' existing = {
  name: managedIdName
  scope: resourceGroup('<subscription id>', '<subscrtiption name>)
}


resource clusterVmIp 'Microsoft.Network/publicIPAddresses@2020-11-01' = {
  name: '${vmName}-IP'
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
      domainNameLabel: toLower(vmName)
    }
  }
}

resource clusterVmNic 'Microsoft.Network/networkInterfaces@2020-11-01' = {
  name: '${vmName}-NIC'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: '${vmName}-IPConfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: clusterVmIp.id
          }
          subnet: {
            id: clusterSubnetId
          }
          loadBalancerBackendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${clusterRgName}-LB', '${clusterRgName}-LB-BEAP')
            }
          ]
          primary: true
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    enableAcceleratedNetworking: true
    enableIPForwarding: false
    networkSecurityGroup: {
      id: clusterNsgId
    }
  }
}

resource clusterVm 'Microsoft.Compute/virtualMachines@2021-11-01' = {
  name: vmName
  location: location
  tags: {
    Environment: 'Production'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    availabilitySet: {
      id: availabilitySetId
    }
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-Datacenter'
        version: 'latest'
      }
      osDisk: {
        osType: 'Windows'
        name: '${vmName}-OS'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 127
      }
      dataDisks: [ for (datadisk, i) in range(1,vmDataDiskCount): {
          lun: i
          name: '${vmName}-DATA${i}'
          createOption: 'Empty'
          caching: 'ReadOnly'
          writeAcceleratorEnabled: false
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          diskSizeGB: 1023
          toBeDetached: false
        }]
    }
    osProfile: {
      computerName: vmName
      adminUsername: vmAdminUsername
      adminPassword: vmAdminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false
        patchSettings: {
          patchMode: 'Manual'
          assessmentMode: 'ImageDefault'
        }
      }
      secrets: []
      allowExtensionOperations: true
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: clusterVmNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: bootDiagStorageAccount.properties.primaryEndpoints.blob
      }
    }
  }
}

//Azure KeyVault Extension registration
module azKeyVaultExtension 'vmKeyVaultExt.bicep' = {
  dependsOn: [
    clusterVm
  ]
  name: '${vmName}-MicrosoftAzureKeyvault'
  params: {
    vmName: vmName
    location: location
  }
}

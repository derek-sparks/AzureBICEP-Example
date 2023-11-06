param vmName string
param location string = resourceGroup().location

resource azKeyVaultExtension 'Microsoft.Compute/virtualMachines/extensions@2022-03-01' = {
  name: '${vmName}/Microsoft.Azure.KeyVault'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.KeyVault'
    type: 'KeyVaultForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      secretsManagementSettings: {
          pollingIntervalInS: '3600'
          certificateStoreName: 'MY'
          certificateStoreLocation: 'LocalMachine'
          observedCertificates: [
            '<fqdn_observed_cert>'
          ]
      }
    }
  }
}

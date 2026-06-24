using '../main.bicep'

param clusterType = 'prod'
param location = 'eastasia'
param projectName = 'visign'

// Prod vẫn mạnh hơn dev nhưng không ép Availability Zone
param aksNodeVMSize = 'Standard_B2s_v2'
param aksNodeCount = 2
param aksAutoScaleMin = 2
param aksAutoScaleMax = 3
param aksAvailabilityZones = []

param acrSku = 'Basic'

param postgresAdminLogin = 'visignadmin'
param postgresAdminPassword = ''

// Prod vẫn bật HA, nhưng dùng SameZone thay vì ZoneRedundant
param postgresHighAvailability = true
param postgresHighAvailabilityMode = 'SameZone'

param kvSoftDeleteDays = 90

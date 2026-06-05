// PROD CLUSTER
// 1 AKS cluster riêng biệt cho production
// namespace: visign
//
// Deploy:
//   az deployment sub create `
//     --location eastasia `
//     --template-file infra/bicep/main.bicep `
//     --parameters infra/bicep/parameters/prod.bicepparam `
//     --parameters postgresAdminPassword="<PROD_POSTGRES_PASSWORD>"

using '../main.bicep'

param clusterType = 'prod'
param location = 'eastasia'
param projectName = 'visign'

// Cost-saving PROD:
// dùng VM giống DEV để tiết kiệm chi phí,
// nhưng vẫn giữ tối thiểu 2 nodes để có HA cơ bản.
param aksNodeVMSize = 'Standard_B2s'
param aksNodeCount = 2
param aksAutoScaleMin = 2
param aksAutoScaleMax = 3

// Nếu region/subscription hỗ trợ Availability Zones thì dùng ['2', '3'].
// Nếu deploy lỗi do region không hỗ trợ zone hoặc quota thấp thì đổi về [].
param aksAvailabilityZones = ['2', '3']

// Có thể dùng Basic để tiết kiệm.
// Nếu muốn gần production hơn thì để Standard.
param acrSku = 'Basic'

param postgresAdminLogin = 'visignadmin'
param postgresAdminPassword = '' // Pass via CLI, không hardcode password

// Điểm khác biệt chính của PROD so với DEV:
// bật HA cho PostgreSQL.
// Lưu ý: HA database sẽ tăng chi phí đáng kể.
param postgresHighAvailability = true

param kvSoftDeleteDays = 90

# Visign DevOps Deployment Guide

README này mô tả quy trình triển khai hệ thống Visign lên Azure bằng Bicep, AKS, ACR, Azure Key Vault, GitHub Actions, ArgoCD và GitOps.

Hệ thống gồm:

```text
visign-web  : Next.js application
visign-ai   : FastAPI AI service
database    : Azure PostgreSQL Flexible Server
registry    : Azure Container Registry
runtime     : Azure Kubernetes Service
gitops      : ArgoCD + ApplicationSet + Helm values
```

---

## 1. Tổng quan kiến trúc triển khai

### 1.1. Repository

```text
visign-uit/ci-workflow-of-visign
```

Chứa source code ứng dụng:

```text
visign/      Next.js web app
ai-model/    FastAPI AI service
.github/     GitHub Actions caller workflows
```

```text
visign-uit/visign-gitops
```

Chứa hạ tầng và GitOps manifests:

```text
infra/bicep/                         Azure infrastructure as code
appsets/                             ArgoCD AppProjects/ApplicationSets
bootstrap/argocd/root-app.yaml       ArgoCD root app
platform/charts/app-service/         Helm chart dùng chung cho web/ai
platform/charts/cluster-addons/      ClusterIssuer + CSI RBAC
projects/visign/environments/dev/    Dev values
projects/visign/environments/prod/   Prod values
```

---

## 2. Mô phỏng luồng CI/CD

### 2.1. Luồng DEV

```text
Developer push code vào branch dev
        ↓
GitHub Actions CI - Web / CI - AI
        ↓
Lint/Test/Build Docker image
        ↓
Push image vào Azure Container Registry dev
        ↓
Workflow tạo Pull Request sang repo visign-gitops
        ↓
Merge PR GitOps update image tag dev
        ↓
ArgoCD auto-sync DEV
        ↓
AKS dev chạy image mới
        ↓
https://dev.visign-uit.id.vn
```

DEV được cấu hình auto-sync:

```text
visign-ai-dev   Automated sync
visign-web-dev  Automated sync
```

### 2.2. Luồng PROD

```text
DEV đã test ổn
        ↓
Tạo PR từ dev vào main của repo app
        ↓
Merge main
        ↓
GitHub Actions build prod image
        ↓
Push image vào ACR prod
        ↓
Workflow tạo PR GitOps update prod values
        ↓
Merge GitOps PR
        ↓
ArgoCD PROD manual sync
        ↓
https://prod.visign-uit.id.vn
```

PROD nên manual sync, không auto-sync.

---

## 3. Prerequisites

Cài các công cụ sau trên máy local:

```text
Azure CLI
Bicep CLI
kubectl
Helm
ArgoCD CLI
Git
PowerShell
```

Kiểm tra:

```powershell
az version
az bicep version
kubectl version --client
helm version
argocd version --client
git --version
```

Đăng nhập Azure:

```powershell
az login
az account show
```

Kiểm tra subscription hiện tại:

```powershell
az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
```

Nếu subscription có policy giới hạn region, kiểm tra region được phép:

```powershell
az policy assignment list `
  --query "[?name=='sys.regionrestriction'].{id:id, scope:scope, parameters:parameters}" `
  -o json
```

Chỉ deploy vào region có trong `listOfAllowedLocations`.

---

## 4. Deploy hạ tầng DEV bằng Bicep

Vào repo GitOps:

Build Bicep:

```powershell
az bicep build --file infra/bicep/main.bicep
```

Deploy DEV:

```powershell
az deployment sub create `
  --location eastasia `
  --name visign-dev-infra `
  --template-file infra/bicep/main.bicep `
  --parameters infra/bicep/parameters/dev.bicepparam `
  postgresAdminPassword="<DEV_POSTGRES_PASSWORD>"
```

Sau khi deploy, lấy outputs:

```powershell
az deployment sub show `
  --name visign-dev-infra `
  --query properties.outputs
```

Gán biến DEV theo output thực tế:

```powershell
$DEV_RG="visign-dev-rg"
$DEV_AKS="aks-visign-dev"
$DEV_ACR_LOGIN_SERVER="<DEV_ACR_LOGIN_SERVER>"
$DEV_KEYVAULT="<DEV_KEYVAULT_NAME>"
$DEV_POSTGRES_HOST="<DEV_POSTGRES_HOST>"
$DEV_CICD_CLIENT_ID="<DEV_CICD_CLIENT_ID>"
```

Lấy tenant/subscription:

```powershell
$TENANT_ID = az account show --query tenantId -o tsv
$SUBSCRIPTION_ID = az account show --query id -o tsv

$TENANT_ID
$SUBSCRIPTION_ID
```

---

## 5. Cấu hình GitHub Actions OIDC cho DEV

Tạo federated credential cho GitHub Actions branch `dev`:

```powershell
az identity federated-credential create `
  --name visign-dev-branch `
  --identity-name visign-dev-cicd-identity `
  --resource-group $DEV_RG `
  --issuer "https://token.actions.githubusercontent.com" `
  --subject "repo:visign-uit/ci-workflow-of-visign:ref:refs/heads/dev" `
  --audience "api://AzureADTokenExchange"
```

Kiểm tra ACR ID:

```powershell
$DEV_ACR_NAME = ($DEV_ACR_LOGIN_SERVER -replace ".azurecr.io","")

$DEV_ACR_ID = az acr show `
  --name $DEV_ACR_NAME `
  --resource-group $DEV_RG `
  --query id `
  -o tsv
```

Kiểm tra role AcrPush:

```powershell
az role assignment list `
  --assignee $DEV_CICD_CLIENT_ID `
  --scope $DEV_ACR_ID `
  -o table
```

Nếu chưa có `AcrPush`, gán:

```powershell
az role assignment create `
  --assignee $DEV_CICD_CLIENT_ID `
  --role AcrPush `
  --scope $DEV_ACR_ID
```

---

## 6. Cấu hình GitHub Secrets cho repo app

Vào repo:

```text
visign-uit/ci-workflow-of-visign
```

Đi tới:

```text
Settings → Secrets and variables → Actions → New repository secret
```

Tạo các secrets cho DEV:

```text
NONPROD_ACR_LOGIN_SERVER=<DEV_ACR_LOGIN_SERVER>
AZURE_CLIENT_ID=<DEV_CICD_CLIENT_ID>
AZURE_TENANT_ID=<TENANT_ID>
AZURE_SUBSCRIPTION_ID=<SUBSCRIPTION_ID>
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=<DEV_CLERK_PUBLISHABLE_KEY>
GITOPS_TOKEN=<GITHUB_PAT_HAS_WRITE_ACCESS_TO_VISIGN_GITOPS>
```

Lưu ý:

```text
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY cần trong GitHub Actions vì Next.js cần biến public này ở build time.
CLERK_SECRET_KEY không để trong GitHub Actions nếu chỉ cần runtime, nên lưu trong Azure Key Vault.
```

Nếu GitHub PAT từng bị lộ, revoke ngay và tạo token mới.

---

## 7. Cấu hình Azure Key Vault DEV

Gán quyền cho user hiện tại để set secret:

```powershell
$OBJECT_ID = az ad signed-in-user show --query id -o tsv

$KV_SCOPE = az keyvault show `
  --name $DEV_KEYVAULT `
  --resource-group $DEV_RG `
  --query id `
  -o tsv

az role assignment create `
  --assignee $OBJECT_ID `
  --role "Key Vault Secrets Officer" `
  --scope $KV_SCOPE
```

Đợi RBAC propagate:

```powershell
Start-Sleep -Seconds 120
```

Tạo `DATABASE_URL`:

```powershell
$POSTGRES_PASSWORD = Read-Host "Enter DEV PostgreSQL admin password"
$ENCODED_PASSWORD = [System.Uri]::EscapeDataString($POSTGRES_PASSWORD)

$DEV_DATABASE_URL = "postgresql://visignadmin:$($ENCODED_PASSWORD)@$($DEV_POSTGRES_HOST):5432/visign_db?sslmode=require"
```

Set secrets:

```powershell
az keyvault secret set `
  --vault-name $DEV_KEYVAULT `
  --name "DATABASE-URL" `
  --value $DEV_DATABASE_URL

az keyvault secret set `
  --vault-name $DEV_KEYVAULT `
  --name "CLERK-SECRET-KEY" `
  --value "<DEV_CLERK_SECRET_KEY>"

az keyvault secret set `
  --vault-name $DEV_KEYVAULT `
  --name "CLERK-PUBLISHABLE-KEY" `
  --value "<DEV_CLERK_PUBLISHABLE_KEY>"

az keyvault secret set `
  --vault-name $DEV_KEYVAULT `
  --name "OPENAI-API-KEY" `
  --value "<OPENAI_API_KEY>"
```

Kiểm tra:

```powershell
az keyvault secret list `
  --vault-name $DEV_KEYVAULT `
  --query "[].name" `
  -o table
```

Cần thấy:

```text
DATABASE-URL
CLERK-SECRET-KEY
CLERK-PUBLISHABLE-KEY
OPENAI-API-KEY
```

---

## 8. Cập nhật GitOps values DEV

Lấy CSI client ID:

```powershell
$DEV_CSI_CLIENT_ID = az aks show `
  --resource-group $DEV_RG `
  --name $DEV_AKS `
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId `
  -o tsv

$DEV_CSI_CLIENT_ID
```

Mở file:

```text
projects/visign/environments/dev/web.values.yaml
```

Cập nhật các giá trị:

```text
image.repository                  = <DEV_ACR_LOGIN_SERVER>/visign-web
image.tag                         = dev-placeholder
keyVault.keyVaultName             = <DEV_KEYVAULT>
keyVault.tenantId                 = <TENANT_ID>
keyVault.userAssignedIdentityID   = <DEV_CSI_CLIENT_ID>
migration.image.repository        = <DEV_ACR_LOGIN_SERVER>/visign-web-migrator
migration.image.tag               = dev-placeholder
migration.enabled                 = true
migration.args                    = ["run", "db:bootstrap"]
```

Mở file:

```text
projects/visign/environments/dev/ai.values.yaml
```

Cập nhật:

```text
image.repository = <DEV_ACR_LOGIN_SERVER>/visign-ai
image.tag        = dev-placeholder
```

Commit:

```powershell
git add projects/visign/environments/dev/web.values.yaml projects/visign/environments/dev/ai.values.yaml
git commit -m "chore(dev): configure environment values"
git push origin main
```

---

## 9. Kết nối kubectl vào AKS DEV

Gán quyền AKS RBAC Cluster Admin cho user hiện tại:

```powershell
$AKS_ID = az aks show `
  --resource-group $DEV_RG `
  --name $DEV_AKS `
  --query id `
  -o tsv

$USER_OBJECT_ID = az ad signed-in-user show --query id -o tsv

az role assignment create `
  --assignee $USER_OBJECT_ID `
  --role "Azure Kubernetes Service RBAC Cluster Admin" `
  --scope $AKS_ID
```

Lấy kubeconfig:

```powershell
az aks get-credentials `
  --resource-group $DEV_RG `
  --name $DEV_AKS `
  --context aks-visign-dev `
  --overwrite-existing
```

Chuyển context:

```powershell
kubectl config use-context aks-visign-dev
kubectl get nodes
```

---

## 10. Cài ArgoCD trên DEV cluster

Tạo namespace:

```powershell
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
```

Cài ArgoCD:

```powershell
kubectl apply -n argocd `
  --server-side `
  --force-conflicts `
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Nếu thiếu ApplicationSet CRD:

```powershell
kubectl get crd | Select-String "applicationsets"
```

Nếu chưa có, cài bằng `create`:

```powershell
kubectl create -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml
```

Không nên dùng `kubectl apply` cho CRD này nếu gặp lỗi annotation quá dài.

Đợi ArgoCD Running:

```powershell
kubectl get pods -n argocd
```

---

## 11. Mở ArgoCD UI và login CLI

Port-forward:

```powershell
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Mở:

```text
https://127.0.0.1:8080
```

Mở PowerShell khác, lấy password:

```powershell
$ARGOCD_PASS = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$ARGOCD_PASS = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ARGOCD_PASS))
$ARGOCD_PASS
```

Login CLI:

```powershell
argocd login 127.0.0.1:8080 `
  --username admin `
  --password $ARGOCD_PASS `
  --insecure `
  --grpc-web
```

---

## 12. Add GitOps repo credentials vào ArgoCD

Nếu `visign-gitops` là private, thêm repo credentials:

```powershell
$GITHUB_TOKEN = Read-Host "Paste GitHub PAT"

argocd repocreds add https://github.com/visign-uit `
  --username "<GITHUB_USERNAME>" `
  --password $GITHUB_TOKEN `
  --upsert `
  --grpc-web
```

Kiểm tra:

```powershell
argocd repocreds list --grpc-web
argocd repo list --grpc-web
```

Nếu cần add repo cụ thể:

```powershell
argocd repo add https://github.com/visign-uit/visign-gitops `
  --username "<GITHUB_USERNAME>" `
  --password $GITHUB_TOKEN `
  --upsert `
  --grpc-web
```

---

## 13. Register AKS DEV vào ArgoCD

AppSet dùng cluster name:

```text
aks-visign-dev
```

Register cluster:

```powershell
argocd cluster add aks-visign-dev --name aks-visign-dev --grpc-web
```

Kiểm tra:

```powershell
argocd cluster list --grpc-web
```

---

## 14. Bootstrap root app

Trong repo `visign-gitops`:

```powershell
kubectl config use-context aks-visign-dev
kubectl apply -f bootstrap/argocd/root-app.yaml
```

Root app sẽ đọc repo GitOps và tạo:

```text
AppProjects
ApplicationSets
Applications
```

Kiểm tra:

```powershell
kubectl get appprojects -n argocd
kubectl get applicationsets.argoproj.io -n argocd
kubectl get applications -n argocd
```

---

## 15. Cài và quản lý ingress-nginx bằng ArgoCD

Tạo ApplicationSet ingress-nginx dev:

```text
appsets/applications/appset-ingress-nginx-dev.yaml
```

Sau đó commit/push:

```powershell
git add appsets/applications/appset-ingress-nginx-dev.yaml appsets/projects/appproject-platform.yaml
git commit -m "chore(dev): manage ingress nginx with ArgoCD"
git push origin main
```

Sync root-app:

```powershell
argocd app sync root-app --grpc-web
```

Kiểm tra app mới:

```powershell
kubectl get applications -n argocd
```

Sync ingress-nginx nếu cần:

```powershell
argocd app sync ingress-nginx-dev --grpc-web
```

Kiểm tra service:

```powershell
kubectl get svc -n ingress-nginx
kubectl describe svc ingress-nginx-controller -n ingress-nginx
```

Cần thấy annotation:

```text
service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz
```

Lấy public IP:

```powershell
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

---

## 16. Cài cert-manager

Cài cert-manager bằng Helm:

```powershell
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager `
  --namespace cert-manager `
  --create-namespace `
  --set crds.enabled=true
```

Kiểm tra:

```powershell
kubectl get pods -n cert-manager
```

Sau đó sync cluster-addons:

```powershell
argocd app sync cluster-addons-dev --grpc-web
```

Kiểm tra ClusterIssuer:

```powershell
kubectl get clusterissuer
```

---

## 17. Kiểm tra Key Vault CSI driver

AKS Bicep đã bật Key Vault CSI addon. Kiểm tra:

```powershell
kubectl get pods -n kube-system | Select-String "secrets-store"
```

Nếu thấy `aks-secrets-store-csi-driver` là ổn.

---

## 18. Trỏ DNS DEV

Lấy ingress public IP:

```powershell
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

Tạo DNS record:

```text
Type: A
Name: dev
Value: <INGRESS_PUBLIC_IP>
```

Kiểm tra:

```powershell
nslookup dev.visign-uit.id.vn
```

Kết quả phải trả về `<INGRESS_PUBLIC_IP>`.

Test HTTP:

```powershell
curl.exe -I http://dev.visign-uit.id.vn --connect-timeout 10
```

Nếu trả về `308 Permanent Redirect` là bình thường.

---

## 19. CI/CD DEV: build image và tạo GitOps PR

Trong repo app:

```powershell
cd "D:\NT114 - Đồ án chuyên ngành\Repo của Vân (visign-dev và visign workflow)\ci-workflow-of-visign"

git checkout dev
git add .
git commit -m "feat: deploy dev"
git push origin dev
```

Vào GitHub Actions kiểm tra:

```text
CI - Web
CI - AI
```

Sau khi workflow pass, kiểm tra image trong ACR:

```powershell
az acr repository show-tags `
  --name <DEV_ACR_NAME> `
  --repository visign-web `
  -o table

az acr repository show-tags `
  --name <DEV_ACR_NAME> `
  --repository visign-ai `
  -o table

az acr repository show-tags `
  --name <DEV_ACR_NAME> `
  --repository visign-web-migrator `
  -o table
```

Vào repo GitOps:

```text
visign-uit/visign-gitops → Pull requests
```

Merge PR update tag dev.

Nếu có conflict giữa tag cũ và tag mới, giữ tag mới nhất từ PR mới nhất.

---

## 20. ArgoCD deploy Web/AI DEV

Vì DEV có auto-sync nên sau khi merge GitOps PR, ArgoCD sẽ tự deploy.

Kiểm tra:

```powershell
kubectl get applications -n argocd
```

Nếu cần sync thủ công:

```powershell
argocd app sync visign-ai-dev --grpc-web
argocd app sync visign-web-dev --grpc-web
```

Kiểm tra image:

```powershell
kubectl get deploy visign-ai -n visign -o jsonpath="{.spec.template.spec.containers[0].image}"
kubectl get deploy visign-web -n visign -o jsonpath="{.spec.template.spec.containers[0].image}"
```

Kiểm tra pod:

```powershell
kubectl get pods -n visign -o wide
```

---

## 21. Bootstrap database DEV

Lần deploy đầu tiên cần migration job chạy:

```text
npm run db:bootstrap
```

Job này thực hiện:

```text
db:push       tạo/cập nhật schema
db:seed-demo  seed dữ liệu courses/units/lessons/challenges/challengeOptions
```

Kiểm tra job:

```powershell
kubectl get jobs -n visign
```

Nếu job còn tồn tại:

```powershell
kubectl logs job/<JOB_NAME> -n visign -f
```

Kỳ vọng:

```text
Changes applied
Seeding Vietnamese Sign Language database...
Found 285 signs in CSV
Seeding completed successfully
```

Nếu job đã `Succeeded` và bị xóa bởi ArgoCD hook, `kubectl get jobs` có thể trả:

```text
No resources found in visign namespace
```

Điều này là bình thường nếu ArgoCD báo sync thành công.

---

## 22. Kiểm tra HTTPS DEV

Kiểm tra certificate:

```powershell
kubectl get certificate -n visign
```

Nếu certificate đang invalid, xóa cert/order/challenge cũ:

```powershell
kubectl delete challenge -n visign --all
kubectl delete order -n visign --all
kubectl delete certificate visign-tls-dev -n visign
kubectl delete secret visign-tls-dev -n visign --ignore-not-found
```

Theo dõi:

```powershell
kubectl get certificate -n visign -w
```

Test HTTPS:

```powershell
curl.exe -I https://dev.visign-uit.id.vn --connect-timeout 10
```

Kỳ vọng:

```text
HTTP/1.1 200 OK
```

Mở trình duyệt:

```text
https://dev.visign-uit.id.vn
```

---

## 23. Tắt bootstrap migration sau khi DEV đã có dữ liệu

Sau khi trang đã có course/lesson/challenge, tắt migration để deploy sau không chạy bootstrap lại.

Mở:

```text
projects/visign/environments/dev/web.values.yaml
```

Đổi:

```text
migration.enabled = false
```

Commit/push:

```powershell
git add projects/visign/environments/dev/web.values.yaml
git commit -m "chore(dev): disable bootstrap migration"
git push origin main
```

ArgoCD DEV sẽ auto-sync.

Kiểm tra:

```powershell
kubectl get applications -n argocd
```

---

## 24. Checklist hoàn tất DEV

DEV hoàn tất khi:

```text
GitHub Actions CI - Web pass
GitHub Actions CI - AI pass
ACR có image tag dev-<sha>
GitOps PR update tag đã merge
ArgoCD app Synced/Healthy
visign-web pod Running
visign-ai pod Running
Ingress có public IP
DNS dev.visign-uit.id.vn trỏ đúng IP
Certificate READY=True
curl HTTPS trả 200 OK
Website hiển thị dữ liệu demo
migration.enabled đã tắt sau bootstrap
```

---

# PROD Deployment

## 25. Deploy hạ tầng PROD

Deploy prod bằng Bicep:

```powershell
az deployment sub create `
  --location <ALLOWED_REGION> `
  --name visign-prod-infra `
  --template-file infra/bicep/main.bicep `
  --parameters infra/bicep/parameters/prod.bicepparam `
  postgresAdminPassword="<PROD_POSTGRES_PASSWORD>"
```

Lấy outputs:

```powershell
az deployment sub show `
  --name visign-prod-infra `
  --query properties.outputs
```

Gán biến:

```powershell
$PROD_RG="<PROD_RESOURCE_GROUP>"
$PROD_AKS="aks-visign-prod"
$PROD_ACR_LOGIN_SERVER="<PROD_ACR_LOGIN_SERVER>"
$PROD_KEYVAULT="<PROD_KEYVAULT_NAME>"
$PROD_POSTGRES_HOST="<PROD_POSTGRES_HOST>"
$PROD_CICD_CLIENT_ID="<PROD_CICD_CLIENT_ID>"
```

---

## 26. Cấu hình GitHub OIDC cho PROD

Tạo federated credential cho branch `main`:

```powershell
az identity federated-credential create `
  --name visign-prod-main `
  --identity-name visign-prod-cicd-identity `
  --resource-group $PROD_RG `
  --issuer "https://token.actions.githubusercontent.com" `
  --subject "repo:visign-uit/ci-workflow-of-visign:ref:refs/heads/main" `
  --audience "api://AzureADTokenExchange"
```

Gán AcrPush:

```powershell
$PROD_ACR_NAME = ($PROD_ACR_LOGIN_SERVER -replace ".azurecr.io","")

$PROD_ACR_ID = az acr show `
  --name $PROD_ACR_NAME `
  --resource-group $PROD_RG `
  --query id `
  -o tsv

az role assignment create `
  --assignee $PROD_CICD_CLIENT_ID `
  --role AcrPush `
  --scope $PROD_ACR_ID
```

---

## 27. Cấu hình GitHub Secrets PROD

Trong repo app, thêm/cập nhật:

```text
PROD_ACR_LOGIN_SERVER=<PROD_ACR_LOGIN_SERVER>
PROD_AZURE_CLIENT_ID=<PROD_CICD_CLIENT_ID>
AZURE_TENANT_ID=<TENANT_ID>
AZURE_SUBSCRIPTION_ID=<SUBSCRIPTION_ID>
GITOPS_TOKEN=<GITHUB_PAT_HAS_WRITE_ACCESS_TO_VISIGN_GITOPS>
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=<PROD_CLERK_PUBLISHABLE_KEY>
```

Nếu workflow hiện dùng chung `AZURE_CLIENT_ID`, nên refactor để phân biệt:

```text
dev  → NONPROD_AZURE_CLIENT_ID
main → PROD_AZURE_CLIENT_ID
```

---

## 28. Cấu hình Key Vault PROD

Gán quyền set secret:

```powershell
$OBJECT_ID = az ad signed-in-user show --query id -o tsv

$PROD_KV_SCOPE = az keyvault show `
  --name $PROD_KEYVAULT `
  --resource-group $PROD_RG `
  --query id `
  -o tsv

az role assignment create `
  --assignee $OBJECT_ID `
  --role "Key Vault Secrets Officer" `
  --scope $PROD_KV_SCOPE
```

Đợi:

```powershell
Start-Sleep -Seconds 120
```

Set secrets:

```powershell
$PROD_POSTGRES_PASSWORD = Read-Host "Enter PROD PostgreSQL admin password"
$ENCODED_PROD_PASSWORD = [System.Uri]::EscapeDataString($PROD_POSTGRES_PASSWORD)

$PROD_DATABASE_URL = "postgresql://visignadmin:$($ENCODED_PROD_PASSWORD)@$($PROD_POSTGRES_HOST):5432/visign_db?sslmode=require"

az keyvault secret set `
  --vault-name $PROD_KEYVAULT `
  --name "DATABASE-URL" `
  --value $PROD_DATABASE_URL

az keyvault secret set `
  --vault-name $PROD_KEYVAULT `
  --name "CLERK-SECRET-KEY" `
  --value "<PROD_CLERK_SECRET_KEY>"

az keyvault secret set `
  --vault-name $PROD_KEYVAULT `
  --name "CLERK-PUBLISHABLE-KEY" `
  --value "<PROD_CLERK_PUBLISHABLE_KEY>"

az keyvault secret set `
  --vault-name $PROD_KEYVAULT `
  --name "OPENAI-API-KEY" `
  --value "<OPENAI_API_KEY>"
```

---

## 29. Register AKS PROD vào ArgoCD

Lấy kubeconfig prod:

```powershell
az aks get-credentials `
  --resource-group $PROD_RG `
  --name $PROD_AKS `
  --context aks-visign-prod `
  --overwrite-existing
```

Register cluster prod vào ArgoCD:

```powershell
argocd cluster add aks-visign-prod --name aks-visign-prod --grpc-web
```

Kiểm tra:

```powershell
argocd cluster list --grpc-web
```

---

## 30. Enable PROD ApplicationSets

Nếu các file prod đang `.disabled`, bật lại:

```powershell
git mv appsets/applications/appset-ingress-nginx-prod.yaml.disabled appsets/applications/appset-ingress-nginx-prod.yaml
```

Commit:

```powershell
git add appsets/applications/appset-ingress-nginx-prod.yaml
git commit -m "chore(prod): enable ingress nginx appset"
git push origin main
```

Sync root-app:

```powershell
argocd app sync root-app --grpc-web
```

Kiểm tra app prod:

```powershell
kubectl get applications -n argocd
```

---

## 31. Cập nhật GitOps values PROD

Lấy CSI client ID prod:

```powershell
$PROD_CSI_CLIENT_ID = az aks show `
  --resource-group $PROD_RG `
  --name $PROD_AKS `
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId `
  -o tsv
```

Cập nhật:

```text
projects/visign/environments/prod/web.values.yaml
projects/visign/environments/prod/ai.values.yaml
```

Các giá trị cần đúng:

```text
prod ACR login server
prod Key Vault name
tenant ID
prod CSI client ID
prod domain: prod.visign-uit.id.vn
migration.enabled = true cho lần bootstrap đầu
migration.args = ["run", "db:bootstrap"]
```

Commit/push GitOps.

---

## 32. DNS và HTTPS PROD

Sau khi ingress-nginx prod có public IP:

```powershell
kubectl config use-context aks-visign-prod
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

Tạo DNS:

```text
Type: A
Name: prod
Value: <PROD_INGRESS_PUBLIC_IP>
```

Kiểm tra:

```powershell
nslookup prod.visign-uit.id.vn
curl.exe -I http://prod.visign-uit.id.vn --connect-timeout 10
```

Theo dõi certificate prod:

```powershell
kubectl get certificate -n visign -w
```

---

## 33. Deploy PROD app

Tạo PR từ `dev` vào `main` trong repo app:

```text
visign-uit/ci-workflow-of-visign
```

Sau khi merge vào `main`, GitHub Actions sẽ:

```text
build prod image
push image vào prod ACR
tạo PR GitOps update prod values
```

Merge PR GitOps prod.

Prod không auto-sync, nên sync thủ công:

```powershell
argocd app sync visign-ai-prod --grpc-web
argocd app sync visign-web-prod --grpc-web
```

Kiểm tra image prod:

```powershell
kubectl get deploy visign-ai -n visign -o jsonpath="{.spec.template.spec.containers[0].image}"
kubectl get deploy visign-web -n visign -o jsonpath="{.spec.template.spec.containers[0].image}"
```

---

## 34. Bootstrap database PROD

Lần đầu prod cần:

```text
migration.enabled = true
migration.args = ["run", "db:bootstrap"]
```

Theo dõi job:

```powershell
kubectl get jobs -n visign
kubectl logs job/<PROD_BOOTSTRAP_JOB_NAME> -n visign -f
```

Sau khi bootstrap thành công và website prod có dữ liệu, tắt migration:

```text
migration.enabled = false
```

Commit/push GitOps và manual sync prod.

---

## 35. Checklist hoàn tất PROD

PROD hoàn tất khi:

```text
prod infra deploy thành công
prod Key Vault có secrets
prod cluster registered vào ArgoCD
prod ingress-nginx Synced/Healthy
prod cert-manager OK
prod DNS trỏ đúng public IP
prod certificate READY=True
prod web/ai Synced/Healthy
prod pods Running
curl https://prod.visign-uit.id.vn trả 200 OK
website prod hiển thị dữ liệu demo
migration.enabled đã tắt sau bootstrap
```

---

# Troubleshooting

## Azure policy chặn region

Lỗi:

```text
RequestDisallowedByAzure
```

Kiểm tra allowed regions:

```powershell
az policy assignment list `
  --query "[?name=='sys.regionrestriction'].{parameters:parameters}" `
  -o json
```

## Bicep scope sai

Nếu `targetScope = 'subscription'`, dùng:

```powershell
az deployment sub create
```

Không dùng:

```powershell
az deployment group create
```

## Key Vault Forbidden

Gán:

```powershell
az role assignment create `
  --assignee <OBJECT_ID> `
  --role "Key Vault Secrets Officer" `
  --scope <KEYVAULT_ID>
```

## kubectl Forbidden

Gán:

```powershell
az role assignment create `
  --assignee <USER_OBJECT_ID> `
  --role "Azure Kubernetes Service RBAC Cluster Admin" `
  --scope <AKS_ID>
```

## ingress-nginx timeout dù DNS đúng

Kiểm tra annotation:

```powershell
kubectl describe svc ingress-nginx-controller -n ingress-nginx
```

Cần có:

```text
service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz
```

## cert-manager invalid

Kiểm tra HTTP trước:

```powershell
curl.exe -I http://dev.visign-uit.id.vn --connect-timeout 10
```

Sau đó xóa cert/order/challenge cũ:

```powershell
kubectl delete challenge -n visign --all
kubectl delete order -n visign --all
kubectl delete certificate visign-tls-dev -n visign
kubectl delete secret visign-tls-dev -n visign --ignore-not-found
```

## ArgoCD repo authentication failed

Thêm repo credentials:

```powershell
argocd repocreds add https://github.com/visign-uit `
  --username "<GITHUB_USERNAME>" `
  --password "<GITHUB_PAT>" `
  --upsert `
  --grpc-web
```

## GitOps PR update tag rỗng

Trong workflow update GitOps, cần export biến trước khi dùng `yq strenv`:

```text
export IMAGE_TAG=...
```

## Helm template bị formatter sửa `{{ }}` thành `{ { } }`

Tắt format on save cho YAML trong VS Code workspace.

## Seed dùng Neon driver

Seed script phải dùng DB connection chung cho Azure PostgreSQL, không dùng Neon HTTP driver.

## Bootstrap job seed xong nhưng vẫn Running

Đóng PostgreSQL connection sau khi seed để Node process thoát.

---

# Final result

Sau khi hoàn tất, hệ thống DEV/PROD chạy theo mô hình:

```text
GitHub Actions build image
→ ACR
→ GitOps PR update tag
→ ArgoCD sync
→ AKS rollout
→ Ingress HTTPS domain
```

DEV dùng auto-sync để triển khai nhanh.

PROD dùng PR + manual sync để kiểm soát production.

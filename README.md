# eks-terraform-lab

GitOps alapú Kubernetes labor AWS EKS-en, Terraform + ArgoCD segítségével.

## Architektúra áttekintés

```
GitHub Repo (forrás)
       │
       ▼
  Terraform
  ├── VPC (private/public subnetek, NAT gateway)
  ├── EKS Cluster (eks-lab-cluster)
  └── ArgoCD (Helm via Terraform)
             │
             ▼ (GitOps szinkronizáció)
     ┌───────┴────────┐
     │                │
  platform/         apps/
  ingress-nginx     microservice
  (NLB)             (nginx demo)
```

## Projekt struktúra

```
eks-terraform-lab/
├── apps/
│   └── microservice/
│       ├── deployment.yaml     # nginx demo app, 2 replika
│       ├── ingress.yaml
│       ├── namespace.yaml      # "demo" namespace
│       └── service.yaml
├── infra/
│   └── terraform/
│       └── main.tf             # AWS infrastruktúra (EKS, VPC, ArgoCD)
└── platform/
    ├── argocd/
    │   ├── bootstrap-apps.yaml     # ArgoCD Application -> apps/microservice
    │   └── bootstrap-platform.yaml # ArgoCD Application -> platform/ingress
    └── ingress/
        └── ingress-nginx.yaml      # ingress-nginx Helm chart (AWS NLB)
```

## AWS vs Azure összehasonlítás

| Azure (eredeti) | AWS (jelenlegi) |
|---|---|
| `azurerm` provider | `aws` provider |
| Resource Group | VPC (hasonló szerepkör) |
| AKS Cluster | EKS Cluster |
| SystemAssigned Identity | IAM Role (cluster + node group) |
| `Standard_B2s` VM | `t3.small` EC2 |
| Azure Load Balancer | AWS Network Load Balancer (NLB) |

A Kubernetes-szintű fájlok (manifesztek, ArgoCD Applications, Helm chart-ok) **platformfüggetlenek** – változtatás nélkül működnek AWS-en is.

---

## Előfeltételek

Az alábbi eszközök szükségesek a projekt futtatásához:

| Eszköz | Minimális verzió | Telepítés |
|---|---|---|
| [git](https://git-scm.com/) | 2.x | `winget install Git.Git` |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | 2.x | `winget install Amazon.AWSCLI` |
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.3 | `winget install Hashicorp.Terraform` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.28+ | `winget install Kubernetes.kubectl` |

Ellenőrzés:
```powershell
git --version
aws --version
terraform --version
kubectl version --client
```

---

## AWS IAM felhasználó létrehozása

> Root account access key-t soha ne használj. Mindig dedikált IAM felhasználót hozz létre.

### Lépések az AWS Console-ban

1. Nyisd meg az **IAM** szolgáltatást
2. **Users** → **Create user**
3. **User name:** `terraform-eks-lab`
4. **Permissions:** → **Attach policies directly** → `AdministratorAccess` *(labor célra)*
5. **Tags** hozzáadása (lásd lent)
6. **Create user** → kattints a felhasználóra → **Security credentials** → **Create access key**
7. Use case: **Command Line Interface (CLI)** → pipáld be a figyelmeztetést → **Create access key**
8. **Másold ki vagy töltsd le a CSV-t** – a Secret Access Key csak egyszer látható!

### Kötelező tag-ek (AWS best practice)

Minden erőforrást (IAM user, EKS cluster, VPC, stb.) tag-elj következetesen:

| Key | Value |
|---|---|
| `Project` | `eks-terraform-lab` |
| `Environment` | `dev` |
| `ManagedBy` | `terraform` |
| `Owner` | `<a te neved>` |
| `CostCenter` | `lab` |

> A Terraform által létrehozott erőforrások automatikusan öröklik ezeket a tageket – a `main.tf`-ben a provider szintű `default_tags` blokkal lehet globálisan beállítani.

---

## AWS credentials beállítása

### Opció 1 – `aws configure` (lokális fejlesztéshez)

```powershell
aws configure
```

Bekéri:
- **AWS Access Key ID** – az IAM felhasználó access key-je
- **AWS Secret Access Key** – a hozzá tartozó titkos kulcs
- **Default region** – pl. `eu-west-1`
- **Default output format** – `json`

A kulcsok el lesznek mentve: `C:\Users\<felhasználó>\.aws\credentials`

### Opció 2 – Környezeti változók (CI/CD-hez)

```powershell
$env:AWS_ACCESS_KEY_ID     = "AKIA..."
$env:AWS_SECRET_ACCESS_KEY = "xxxxxxxxxxxxxxxx"
$env:AWS_DEFAULT_REGION    = "eu-west-1"
```

Ez csak az aktuális PowerShell session-ben él.

### Opció 3 – IAM Identity Center / SSO (céges környezethez)

```powershell
aws configure sso
```

### Ellenőrzés

```powershell
aws sts get-caller-identity
```

Sikeres kimenet:
```json
{
    "UserId": "AIDA****************",
    "Account": "************",
    "Arn": "arn:aws:iam::************:user/terraform-eks-lab"
}
```

---

## Telepítés – lépésről lépésre

### ✅ 0. Git repo beállítása

`.gitignore` létrehozása (Terraform state és credentials kizárása):

```powershell
@"
# Terraform
.terraform/
*.tfstate
*.tfstate.backup
*.tfvars
.terraform.lock.hcl

# AWS
.aws/

# OS
.DS_Store
Thumbs.db
"@ | Out-File -Encoding utf8 .gitignore
```

`.gitattributes` létrehozása (LF line endings kényszerítése YAML/Terraform fájloknál):

```
* text=auto eol=lf
*.tf    text eol=lf
*.yaml  text eol=lf
*.yml   text eol=lf
*.sh    text eol=lf
*.md    text eol=lf
```

Repo inicializálása és push:

```powershell
git init
git rm --cached -r .   # line ending újraindexelés
git add .
git commit -m "initial: eks-terraform-lab AWS EKS GitOps setup"
git branch -M main
git remote add origin https://github.com/SNprogSN/eks-terraform-lab.git
git push -u origin main
```

### ✅ 1. AWS credentials beállítása

```powershell
aws configure
# AWS Access Key ID:     <IAM user access key>
# AWS Secret Access Key: <titkos kulcs>
# Default region name:   eu-west-1
# Default output format: json
```

Ellenőrzés – sikeres output példa:

```json
{
    "UserId": "AIDA****************",
    "Account": "************",
    "Arn": "arn:aws:iam::************:user/terraform-eks-lab"
}
```

### 2. Terraform inicializálás

```powershell
cd infra\terraform
terraform init
```

Letölti az összes providert és modult:
- `hashicorp/aws`
- `terraform-aws-modules/vpc/aws`
- `terraform-aws-modules/eks/aws`
- `hashicorp/helm`
- `gavinbunney/kubectl`

### 3. Tervezett változások megtekintése

```powershell
terraform plan
```

### 4. Infrastruktúra felépítése

```powershell
terraform apply
```

> Az EKS cluster létrehozása ~10–15 percet vesz igénybe.

### 5. kubectl konfigurálása

```powershell
aws eks update-kubeconfig --region eu-west-1 --name eks-lab-cluster
```

Ez a parancs a `terraform apply` outputjában is megjelenik automatikusan.

### 6. ArgoCD elérése

```powershell
# Admin jelszó lekérése
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | % { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }

# Port-forward az ArgoCD UI-hoz
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Ezután elérhető: `https://localhost:8080` (user: `admin`)

---

## Terraform outputs

| Output | Leírás |
|---|---|
| `cluster_name` | Az EKS cluster neve |
| `cluster_endpoint` | Az API szerver URL-je |
| `configure_kubectl` | Másolható kubectl konfigurálási parancs |

---

## GitOps munkafolyamat

Az ArgoCD a `https://github.com/SNprogSN/aks-gitops-lab` repót figyeli.

- **bootstrap-apps** → szinkronizálja az `apps/microservice` mappát a `demo` namespace-be
- **bootstrap-platform** → szinkronizálja a `platform/ingress` mappát, telepíti az ingress-nginx-et

Minden `main` ágra pusholt változás automatikusan érvényesül a clusteren (`selfHeal: true`, `prune: true`).

---

## Infrastruktúra eltávolítása

```powershell
cd infra\terraform
terraform destroy
```

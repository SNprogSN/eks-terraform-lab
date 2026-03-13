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
- **Default region** – pl. `eu-north-1`
- **Default output format** – `json`

A kulcsok el lesznek mentve: `C:\Users\<felhasználó>\.aws\credentials`

### Opció 2 – Környezeti változók (CI/CD-hez)

```powershell
$env:AWS_ACCESS_KEY_ID     = "AKIA..."
$env:AWS_SECRET_ACCESS_KEY = "xxxxxxxxxxxxxxxx"
$env:AWS_DEFAULT_REGION    = "eu-north-1"
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
*.tfstate.*
terraform.tfstate.lock.info
# .terraform.lock.hcl NE legyen kizárva – rögzíti a provider verziókat!

# Graphviz generált fájlok
*.dot
*.svg

# Audit snapshot fájlok (érzékeny AWS adatok)
scripts/audit-*.json

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
# Default region name:   eu-north-1
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

### ✅ 2. Terraform inicializálás

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

### ✅ 3. Tervezett változások megtekintése

```powershell
terraform plan
```

### ✅ 4. Infrastruktúra felépítése

```powershell
terraform apply
```

> Az EKS cluster létrehozása ~10–15 percet vesz igénybe.

> **Ismert hiba:** Ha `Kubernetes cluster unreachable` hibát kapsz a Helm providernél, győződj meg róla, hogy a `main.tf`-ben az EKS modulban szerepel az `enable_cluster_creator_admin_permissions = true` beállítás, és a provider `exec` alapú auth-ot használ (nem `token`-t). Részletek a `main.tf`-ben.

> **Ismert hiba – 504 Gateway Timeout az ingress-nginx mögötti pod-oknál:** Az EKS modul alapértelmezett node security group szabályai csak az `1025–65535` ephemeral portokon engedik a node→node forgalmat. Ha a backend pod alacsony porton hallgat (pl. `80`), az ingress-nginx controller nem tudja elérni – 504-et ad vissza. **Javítás:** a `main.tf` `node_security_group_additional_rules` blokkjában egy `ingress_self_all` rule engedélyezi az összes node→node forgalmat. Ez már szerepel a konfigurációban.

### ✅ 5. kubectl konfigurálása

```powershell
aws eks update-kubeconfig --region eu-north-1 --name eks-lab-cluster
```

Ez a parancs a `terraform apply` outputjában is megjelenik automatikusan.

### ✅ 6. ArgoCD elérése

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

Az ArgoCD a `https://github.com/SNprogSN/eks-terraform-lab` repót figyeli.

- **bootstrap-apps** → szinkronizálja az `apps/microservice` mappát a `demo` namespace-be
- **bootstrap-platform** → szinkronizálja a `platform/ingress` mappát, telepíti az ingress-nginx-et

Minden `main` ágra pusholt változás automatikusan érvényesül a clusteren (`selfHeal: true`, `prune: true`).

---

## Terraform dependency gráf

A resource-ok közötti függőségek vizualizálásához:

```powershell
# Graphviz telepítése (egyszer szükséges)
winget install graphviz

# Gráf generálása és megnyitása
cd infra\terraform
terraform graph | Out-File -Encoding ascii graph.dot
& "C:\Program Files\Graphviz\bin\dot.exe" -Tsvg graph.dot -o graph.svg
Invoke-Item graph.svg
```

---

## Infrastruktúra eltávolítása

> **Ismert hiba – `terraform destroy` több menetben szükséges (`ResourceInUseException: Cluster has nodegroups attached`):** Az EKS modul néha párhuzamosan hoz létre két node group-ot (pl. egy korábbi félbemaradt apply után). Az egyik Terraform state-ben van, a másik "árva" marad. A destroy az állami node group-ot törli, de az AWS API még az árva miatt nem engedi a cluster törlését. **Javítás:**
> 1. `aws eks list-nodegroups --cluster-name eks-lab-cluster --region eu-north-1` – keress árva node group-ot
> 2. `aws eks delete-nodegroup --cluster-name eks-lab-cluster --nodegroup-name <ARV_NEVE> --region eu-north-1`
> 3. Várj ~5 percet, majd futtasd újra: `terraform destroy -auto-approve`



```powershell
cd infra\terraform
terraform destroy
```

---

## Költségbecslés – eu-north-1

### Összetevők (alapjáraton, 2 node)

| Erőforrás | Ár/óra | Megjegyzés |
|---|---|---|
| EKS Control Plane | $0.100 | fix, futó clusternél mindig |
| 2× t3.small EC2 | $0.047 | $0.0236/instance |
| NAT Gateway | $0.048 | + $0.048/GB adat |
| EBS (2× 20GB GP3) | $0.003 | ~$3.80/hó összesen |
| **ÖSSZESEN** | **~$0.198/óra** | |

### Alapjárat (desired=2 node)

| Időszak | Költség |
|---|---|
| Óra | ~$0.20 |
| Nap | ~$4.75 |
| Hét | ~$33 |
| Hónap | ~$145 |

### Skálázva (max=3 node)

| Időszak | Többletköltség | Összesen |
|---|---|---|
| Óra | +$0.024 | ~$0.22 |
| Nap | +$0.57 | ~$5.32 |
| Hét | +$4 | ~$37 |
| Hónap | +$17 | ~$162 |

### Teljes labor (apppal, NLB-vel)

| Tétel | Kb. ár/hó |
|---|---|
| NLB (ingress-nginx) | +$16 alap + $0.006/LCU-h |
| NAT adat (kifelé ~10GB) | +$0.48 |
| CloudWatch Logs (control plane) | +$1–2 |
| **Teljes labor (apppal)** | **~$160–165/hó** |

### Megtakarítási lehetőségek

| Módszer | Megtakarítás |
|---|---|
| Spot instances (node group-ban) | -60–70% EC2-n |
| 1 éves Reserved | -40% EC2-n |
| desired=1 node (dev-hez) | -$17/hó |
| NAT GW helyett NAT instance | -$25/hó (de karbantartás!) |
| Cluster destroy ha nem kell | EKS $0.10/h is számít |

> **Legfontosabb:** az EKS control plane **$0.10/h = $73/hó** – ez fut akkor is, ha egyetlen pod sincs. Labor esetén érdemes destroy-olni ha nem használod.

---

## AWS audit script

A `scripts/aws-audit.ps1` script snapshotot készít az AWS erőforrásokról. Hasznos destroy előtt és után az ellenőrzéshez.

```powershell
# Destroy előtt (referencia snapshot)
powershell -ExecutionPolicy Bypass -File scripts\aws-audit.ps1 -OutputFile scripts\audit-before-destroy.json

# Destroy után (ellenőrzés)
powershell -ExecutionPolicy Bypass -File scripts\aws-audit.ps1 -OutputFile scripts\audit-after-destroy.json
```

> **Fontos:** Az audit JSON fájlok AWS erőforrás ID-kat és neveket tartalmaznak – a `.gitignore` kizárja őket (`scripts/audit-*.json`). Soha ne commitold őket!

### Cost Explorer – havi költség ellenőrzése

Az audit script automatikusan lekéri az aktuális havi AWS költséget (11. lépés).

#### Mi ez az API?

A `GetCostAndUsage` az **AWS Cost Explorer API**, amely programból (CLI, SDK, CI/CD) lekérdezi az account költségeit.

| Funkció | Ár |
|---|---|
| AWS Cost Explorer web UI | **ingyenes** |
| Cost Explorer API (`aws ce ...`) | **$0.01 / kérés** |

Egy audit futtatás = $0.01 (~4 Ft). Ha naponta egyszer futtatod: ~$0.30/hónap.

#### Teljes összeg – egyetlen lekérdezés

```powershell
aws ce get-cost-and-usage `
    --time-period Start=2026-03-01,End=2026-03-31 `
    --granularity MONTHLY `
    --metrics UnblendedCost
```

#### Szolgáltatásonkénti bontás (FinOps-os módszer)

Ez mutatja meg pontosan, melyik AWS szolgáltatás mennyit költ – DevOps és FinOps csapatok ezt használják:

```powershell
aws ce get-cost-and-usage `
    --time-period Start=2026-03-01,End=2026-03-31 `
    --granularity MONTHLY `
    --metrics UnblendedCost `
    --group-by Type=DIMENSION,Key=SERVICE
```

Tipikus kimenet (labor környezet):

```json
{
  "Groups": [
    { "Keys": ["Amazon Elastic Kubernetes Service"], "Metrics": { "UnblendedCost": { "Amount": "0.20", "Unit": "USD" } } },
    { "Keys": ["Amazon EC2"],                        "Metrics": { "UnblendedCost": { "Amount": "0.85", "Unit": "USD" } } },
    { "Keys": ["Amazon VPC"],                        "Metrics": { "UnblendedCost": { "Amount": "0.11", "Unit": "USD" } } }
  ]
}
```

#### Mikor használják DevOps-ok?

- Napi cost check CI/CD pipeline-ban
- Terraform destroy utáni ellenőrzés (pénzt generál-e még valami?)
- FinOps dashboard adatforrás
- Slack alert ha a cost threshold túllépik

> **Fontos:** A Cost Explorer **globális API** (nem regionális). Új accounton aktiválni kell:
> AWS Console → **Billing** → **Cost Explorer** → **Enable**
> Az adatok az aktiválás után ~24 óra múlva érhetők el.

Ha az audit script futásakor a Cost Explorer még nem aktív, a script nem áll le hibával – egy figyelmeztetést ír ki és folytatja.

Sikeres destroy után csak az AWS default erőforrások maradhatnak:

| Erőforrás | Elvárt érték |
|---|---|
| EKS cluster | 0 |
| EC2 instance | 0 |
| NAT gateway | 0 |
| EBS volume | 0 |
| VPC | 1 (default) |
| Subnet | 3 (default VPC) |
| Security group | 1-4 (default) |

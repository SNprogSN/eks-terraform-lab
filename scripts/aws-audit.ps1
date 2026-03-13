param(
    [string]$Region = "eu-north-1",
    [string]$ClusterName = "eks-lab-cluster",
    [string]$OutputFile = "aws-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
)

$audit = @{}

Write-Host "=== AWS Audit: $Region ===" -ForegroundColor Cyan

# EKS cluster
Write-Host "[1/11] EKS clusters..." -ForegroundColor Yellow
$audit.eks_clusters = aws eks list-clusters --region $Region | ConvertFrom-Json | Select-Object -ExpandProperty clusters

# Node groups
Write-Host "[2/11] EKS node groups..." -ForegroundColor Yellow
$audit.eks_nodegroups = @()
foreach ($cluster in $audit.eks_clusters) {
    $ngs = aws eks list-nodegroups --cluster-name $cluster --region $Region | ConvertFrom-Json | Select-Object -ExpandProperty nodegroups
    $audit.eks_nodegroups += $ngs | ForEach-Object { "$cluster/$_" }
}

# EC2 instances
Write-Host "[3/11] EC2 instances..." -ForegroundColor Yellow
$audit.ec2_instances = aws ec2 describe-instances --region $Region `
    --query "Reservations[*].Instances[*].{Id:InstanceId,State:State.Name,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value}" `
    --output json | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.State -ne "terminated" }

# Load balancers (NLB/ALB)
Write-Host "[4/11] Load balancers..." -ForegroundColor Yellow
$audit.load_balancers = aws elbv2 describe-load-balancers --region $Region `
    --query "LoadBalancers[*].{Name:LoadBalancerName,DNS:DNSName,State:State.Code,Type:Type}" `
    --output json | ConvertFrom-Json

# EBS volumes
Write-Host "[5/11] EBS volumes..." -ForegroundColor Yellow
$audit.ebs_volumes = aws ec2 describe-volumes --region $Region `
    --query "Volumes[*].{Id:VolumeId,Size:Size,State:State,Name:Tags[?Key=='Name']|[0].Value}" `
    --output json | ConvertFrom-Json

# VPCs (nem default)
Write-Host "[6/11] VPCs..." -ForegroundColor Yellow
$audit.vpcs = aws ec2 describe-vpcs --region $Region `
    --query "Vpcs[*].{Id:VpcId,CIDR:CidrBlock,Default:IsDefault,Name:Tags[?Key=='Name']|[0].Value}" `
    --output json | ConvertFrom-Json

# Subnets (nem default VPC-hez tartozók)
Write-Host "[7/11] Subnets..." -ForegroundColor Yellow
$audit.subnets = aws ec2 describe-subnets --region $Region `
    --filters "Name=defaultForAz,Values=false" `
    --query "Subnets[*].{Id:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Name:Tags[?Key=='Name']|[0].Value}" `
    --output json | ConvertFrom-Json

# NAT gateways
Write-Host "[8/11] NAT gateways..." -ForegroundColor Yellow
$audit.nat_gateways = aws ec2 describe-nat-gateways --region $Region `
    --query "NatGateways[?State!='deleted'].{Id:NatGatewayId,State:State,VPC:VpcId}" `
    --output json | ConvertFrom-Json

# Security groups (nem default)
Write-Host "[9/11] Security groups..." -ForegroundColor Yellow
$audit.security_groups = aws ec2 describe-security-groups --region $Region `
    --query "SecurityGroups[?GroupName!='default'].{Id:GroupId,Name:GroupName,VPC:VpcId}" `
    --output json | ConvertFrom-Json

# IAM roles (projekt specifikus)
Write-Host "[10/11] IAM roles (eks-lab)..." -ForegroundColor Yellow
$audit.iam_roles = aws iam list-roles `
    --query "Roles[?contains(RoleName, 'eks-lab') || contains(RoleName, 'eks-lab-cluster')].{Name:RoleName,Arn:Arn}" `
    --output json | ConvertFrom-Json

# Cost Explorer (globális API, us-east-1 – aktiválás szükséges a Billing Console-ban)
Write-Host "[11/11] Cost Explorer (aktuális hónap)..." -ForegroundColor Yellow
$startDate = (Get-Date -Day 1).ToString("yyyy-MM-dd")
$endDate   = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")
$ceRaw = aws ce get-cost-and-usage `
    --time-period Start=$startDate,End=$endDate `
    --granularity MONTHLY `
    --metrics UnblendedCost `
    --output json 2>&1

if ($LASTEXITCODE -eq 0) {
    $ceJson = $ceRaw | ConvertFrom-Json
    $amount  = $ceJson.ResultsByTime[0].Total.UnblendedCost.Amount
    $unit    = $ceJson.ResultsByTime[0].Total.UnblendedCost.Unit
    $audit.cost_current_month = @{ Amount = $amount; Unit = $unit; Period = "$startDate / $endDate" }
    Write-Host "   Aktualis koltseg: $amount $unit" -ForegroundColor Green
} else {
    $audit.cost_current_month = @{ Error = $ceRaw -join " "; Note = "Cost Explorer nincs aktivalva, vagy az adatok meg nem elerhetok (uj account ~24 ora). Aktivalas: AWS Console -> Billing -> Cost Explorer -> Enable." }
    Write-Host "   Cost Explorer nem elerheto: $($ceRaw -join ' ')" -ForegroundColor DarkYellow
    Write-Host "   -> Aktivald: AWS Console > Billing > Cost Explorer > Enable" -ForegroundColor DarkYellow
}

# Összesítés
Write-Host ""
Write-Host "=== ÖSSZESÍTÉS ===" -ForegroundColor Cyan
Write-Host "EKS clusterek:     $($audit.eks_clusters.Count)" -ForegroundColor White
Write-Host "Node groupok:      $($audit.eks_nodegroups.Count)" -ForegroundColor White
Write-Host "EC2 instance-ok:   $($audit.ec2_instances.Count)" -ForegroundColor White
Write-Host "Load balancer-ek:  $($audit.load_balancers.Count)" -ForegroundColor White
Write-Host "EBS volume-ok:     $($audit.ebs_volumes.Count)" -ForegroundColor White
Write-Host "VPC-k:             $($audit.vpcs.Count)" -ForegroundColor White
Write-Host "Subnetek:          $($audit.subnets.Count)" -ForegroundColor White
Write-Host "NAT gateway-ek:    $($audit.nat_gateways.Count)" -ForegroundColor White
Write-Host "Security groupok:  $($audit.security_groups.Count)" -ForegroundColor White
Write-Host "IAM role-ok:       $($audit.iam_roles.Count)" -ForegroundColor White
if ($audit.cost_current_month.Amount) {
    Write-Host "Aktualis koltseg:  $($audit.cost_current_month.Amount) $($audit.cost_current_month.Unit)" -ForegroundColor Green
} else {
    Write-Host "Aktualis koltseg:  N/A (Cost Explorer nem aktiv)" -ForegroundColor DarkYellow
}
Write-Host ""

# Mentés JSON-be
$audit | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 $OutputFile
Write-Host "Audit mentve: $OutputFile" -ForegroundColor Green

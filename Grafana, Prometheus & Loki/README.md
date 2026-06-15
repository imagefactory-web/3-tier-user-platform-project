# Grafana, Prometheus & Loki Observability Stack

This repository contains a PowerShell deployment script for installing an observability stack on an Amazon EKS cluster. It deploys:

- Prometheus kube-prometheus-stack
- Loki log aggregation
- Grafana Alloy
- Grafana dashboarding

## Files

- `deploy.ps1` - main deployment script
- `01-prometheus-values.yaml` - Prometheus Helm values
- `02-loki-values.yaml` - Loki Helm values
- `03-alloy-values.yaml` - Grafana Alloy Helm values
- `04-grafana-values.yaml` - Grafana Helm values
- `05-loki-s3-iam-policy.json` - IAM policy template for Loki S3 access

## Prerequisites

- Windows PowerShell
- `kubectl` installed and configured for the target EKS cluster
- `helm` installed
- AWS CLI installed and configured with credentials
- Access to the EKS cluster and permissions to create namespaces, secrets, Helm releases, S3 buckets, and IAM policies

## Configure before running

Open `deploy.ps1` and update the top variables:

- `$S3_BUCKET` - the S3 bucket name for Loki storage
- `$AWS_REGION` - AWS region for the bucket and cluster
- `$CLUSTER_NAME` - EKS cluster name
- `$MONITORING_NS` - Kubernetes namespace for monitoring components
- `$QA_NS` - application namespace
- `$GRAFANA_ADMIN_PASSWORD` - Grafana admin password
- `$NODE_ROLE_NAME` - IAM node role name used to attach the Loki S3 policy

## Run the deployment script

1. Open PowerShell in this folder.
2. Confirm the script is executable.
3. Run:

```powershell
.\\deploy.ps1
```

4. When prompted, type `y` to proceed.

## Post-deployment

After the deployment finishes, verify:

- Grafana ingress:

```powershell
kubectl get ingress grafana -n monitoring
```

- Grafana login:

  - User: `admin`
  - Password: the value from `$GRAFANA_ADMIN_PASSWORD`

- Prometheus and Loki pods:

```powershell
kubectl get pods -n monitoring -o wide
```

- Logs from Grafana Alloy:

```powershell
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=10
```

## Notes

- `deploy.ps1` patches the bucket name into `05-loki-s3-iam-policy.json` and `02-loki-values.yaml` automatically.
- The AWS Load Balancer Controller may be installed by the script if it is not already present.
- Wait a few minutes for the ALB ingress to become healthy after deployment.

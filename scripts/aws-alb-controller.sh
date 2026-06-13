#!/bin/bash
set -e

AWS_REGION="ap-south-1"
ACCOUNT_ID="213615930222"
CLUSTER_NAME="qa-cluster"
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller"
NAMESPACE="kube-system"

echo "Checking public subnets..."
aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters "Name=tag:kubernetes.io/role/elb,Values=1" \
  --query "Subnets[*].{ID:SubnetId,AZ:AvailabilityZone}" \
  --output table

echo "Checking private subnets..."
aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query "Subnets[*].{ID:SubnetId,AZ:AvailabilityZone}" \
  --output table

echo "Downloading ALB Controller IAM policy..."
curl --ssl-no-revoke -o iam_policy.json \
https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json

echo "Creating IAM policy if not exists..."
aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file://iam_policy.json || true

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

echo "Associating OIDC provider..."
eksctl utils associate-iam-oidc-provider \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER_NAME" \
  --approve

echo "Creating IAM service account..."
eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --namespace="$NAMESPACE" \
  --name="$SERVICE_ACCOUNT_NAME" \
  --attach-policy-arn="$POLICY_ARN" \
  --override-existing-serviceaccounts \
  --region "$AWS_REGION" \
  --approve

echo "Adding Helm repo..."
helm repo add eks https://aws.github.io/eks-charts || true
helm repo update

echo "Installing/upgrading AWS Load Balancer Controller..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n "$NAMESPACE" \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
  --version 1.14.0

echo "Waiting for deployment rollout..."
kubectl rollout status deployment/aws-load-balancer-controller -n "$NAMESPACE" --timeout=180s

echo "Verification..."
kubectl get deployment -n "$NAMESPACE" aws-load-balancer-controller
kubectl get pods -n "$NAMESPACE" | grep aws-load-balancer-controller

echo "Done."

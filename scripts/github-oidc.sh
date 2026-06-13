#!/bin/bash
set -e

ACCOUNT_ID="213615930222"
REGION="ap-south-1"
CLUSTER_NAME="qa-cluster"

ROLE_NAME="GitHubActionsEKSDeployRoleQA"
POLICY_NAME="GitHubActionsEKSDescribeClusterPolicy"
REPO="imagefactory-web/3-tier-user-platform-project"
BRANCH="main"
NAMESPACE="qa"

ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
OIDC_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

echo "Checking AWS login..."
aws sts get-caller-identity

echo "Checking cluster..."
aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "{status:cluster.status,authMode:cluster.accessConfig.authenticationMode}" \
  --output json

echo "Creating GitHub OIDC provider if needed..."
OIDC_EXISTING=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" \
  --output text)

if [ -z "$OIDC_EXISTING" ]; then
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
else
  echo "OIDC provider already exists: $OIDC_EXISTING"
fi

echo "Creating trust policy..."
cat > github-oidc-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "$OIDC_ARN"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:$REPO:ref:refs/heads/$BRANCH"
        }
      }
    }
  ]
}
EOF

echo "Deleting old IAM role if exists..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" || true
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name GitHubActionsEKSDescribeClusterInlinePolicy || true
  aws iam delete-role --role-name "$ROLE_NAME"
fi

echo "Creating IAM role..."
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://github-oidc-trust.json

echo "Creating managed EKS describe policy..."
cat > eks-describe-cluster-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSDescribeCluster",
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster"
      ],
      "Resource": [
        "arn:aws:eks:$REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME"
      ]
    }
  ]
}
EOF

echo "Deleting old IAM policy if exists..."
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  aws iam delete-policy --policy-arn "$POLICY_ARN" || true
fi

echo "Creating IAM policy..."
aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file://eks-describe-cluster-policy.json

echo "Attaching managed policy..."
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN"

AUTH_MODE=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "cluster.accessConfig.authenticationMode" \
  --output text)

if [ "$AUTH_MODE" = "CONFIG_MAP" ]; then
  echo "Updating authentication mode to API_AND_CONFIG_MAP..."
  aws eks update-cluster-config \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --access-config authenticationMode=API_AND_CONFIG_MAP

  aws eks wait cluster-active \
    --name "$CLUSTER_NAME" \
    --region "$REGION"
fi

echo "Recreating EKS access entry for qa-cluster..."
aws eks delete-access-entry \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION" \
  --principal-arn "$ROLE_ARN" || true

sleep 10

aws eks create-access-entry \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION" \
  --principal-arn "$ROLE_ARN"

aws eks associate-access-policy \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION" \
  --principal-arn "$ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces="$NAMESPACE"

echo "Updating kubeconfig..."
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$REGION"

echo "Recreating namespace..."
kubectl delete ns "$NAMESPACE" --ignore-not-found=true
kubectl create ns "$NAMESPACE"

echo "Creating Docker registry secret..."
kubectl create secret docker-registry regcred \
  --docker-username=driveopssurya \
  --docker-password='Amazon@134s' \
  --docker-email=factoryimage2@gmail.com \
  -n "$NAMESPACE"

echo "Verification..."
kubectl get nodes
kubectl get pods -n "$NAMESPACE"

aws eks list-associated-access-policies \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION" \
  --principal-arn "$ROLE_ARN"

echo "Done."

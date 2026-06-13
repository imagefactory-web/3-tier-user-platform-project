#!/bin/bash
set -e

CLUSTER_NAME="qa-cluster1"
AWS_REGION="ap-south-1"
ACCOUNT_ID="213615930222"

NAMESPACE="qa"
SECRET_NAME="qa/mysql-secret"
POLICY_NAME="ESOSecretsManagerQAReadPolicy"

echo "Creating namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Creating mysql-secret.json..."
cat > mysql-secret.json <<EOF
{
  "MYSQL_ROOT_PASSWORD": "rootpass",
  "MYSQL_DATABASE": "test_db",
  "MYSQL_USER": "appuser",
  "MYSQL_PASSWORD": "apppass",
  "DATABASE_URL": "mysql://appuser:apppass@mysql:3306/test_db"
}
EOF

echo "Checking AWS secret status..."

if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  DELETION_DATE=$(aws secretsmanager describe-secret \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" \
    --query "DeletedDate" \
    --output text 2>/dev/null || echo "None")

  if [ "$DELETION_DATE" != "None" ] && [ "$DELETION_DATE" != "null" ]; then
    echo "Secret is scheduled for deletion. Restoring..."
    aws secretsmanager restore-secret \
      --secret-id "$SECRET_NAME" \
      --region "$AWS_REGION"
  fi

  echo "Updating existing AWS secret value..."
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" \
    --secret-string file://mysql-secret.json
else
  echo "Creating new AWS secret..."
  aws secretsmanager create-secret \
    --region "$AWS_REGION" \
    --name "$SECRET_NAME" \
    --description "MySQL credentials for qa namespace" \
    --secret-string file://mysql-secret.json
fi

echo "Associating OIDC provider..."
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --approve

echo "Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io || true
helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace

echo "Waiting for ESO webhook..."
kubectl rollout status deployment/external-secrets-webhook -n external-secrets --timeout=180s || true

echo "Creating IAM policy JSON..."
cat > eso-secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:qa/mysql-secret*"
    }
  ]
}
EOF

echo "Creating IAM policy if not exists..."
aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file://eso-secrets-policy.json || true

POLICY_ARN=$(aws iam list-policies \
  --scope Local \
  --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" \
  --output text)

echo "Policy ARN: $POLICY_ARN"

echo "Creating ESO IAM service account..."
eksctl create iamserviceaccount \
  --name eso-qa-sa \
  --namespace "$NAMESPACE" \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --role-name eso-qa-secrets-role \
  --attach-policy-arn "$POLICY_ARN" \
  --approve \
  --override-existing-serviceaccounts || true

echo "Ensuring EKS nodegroup role has required policies..."

NODEGROUP_NAME=$(aws eks list-nodegroups \
  --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'nodegroups[0]' \
  --output text)

NODE_ROLE_ARN=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --region "$AWS_REGION" \
  --query 'nodegroup.nodeRole' \
  --output text)

NODE_ROLE_NAME=${NODE_ROLE_ARN##*/}

echo "Node Role: $NODE_ROLE_NAME"

aws iam attach-role-policy \
  --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly || true

aws iam attach-role-policy \
  --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy || true

aws iam attach-role-policy \
  --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy || true

echo "Waiting for IAM policy propagation..."
sleep 30

aws iam list-attached-role-policies \
  --role-name "$NODE_ROLE_NAME"

echo "Creating SecretStore..."
cat > secretstore.yaml <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secretsmanager
  namespace: qa
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-south-1
      auth:
        jwt:
          serviceAccountRef:
            name: eso-qa-sa
EOF

kubectl apply -f secretstore.yaml

echo "Creating ExternalSecret..."
cat > externalsecret.yaml <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mysql-external-secret
  namespace: qa
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager
    kind: SecretStore
  target:
    name: mysql-secret
    creationPolicy: Owner
  data:
    - secretKey: MYSQL_ROOT_PASSWORD
      remoteRef:
        key: qa/mysql-secret
        property: MYSQL_ROOT_PASSWORD
    - secretKey: MYSQL_DATABASE
      remoteRef:
        key: qa/mysql-secret
        property: MYSQL_DATABASE
    - secretKey: MYSQL_USER
      remoteRef:
        key: qa/mysql-secret
        property: MYSQL_USER
    - secretKey: MYSQL_PASSWORD
      remoteRef:
        key: qa/mysql-secret
        property: MYSQL_PASSWORD
    - secretKey: DATABASE_URL
      remoteRef:
        key: qa/mysql-secret
        property: DATABASE_URL
EOF

kubectl apply -f externalsecret.yaml

echo "Creating EBS CSI IAM role..."
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve || true

echo "Installing or updating EBS CSI addon..."
aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --region "$AWS_REGION" \
  --service-account-role-arn arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole \
  --resolve-conflicts OVERWRITE || \
aws eks update-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver \
  --region "$AWS_REGION" \
  --service-account-role-arn arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole \
  --resolve-conflicts OVERWRITE

echo "Creating StorageClass..."
cat > storageclass-ebs.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-sc
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  fsType: ext4
EOF

kubectl apply -f storageclass-ebs.yaml

echo "Creating MySQL StatefulSet..."
cat > mysql-statefulset.yaml <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: qa
spec:
  serviceName: mysql
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          args:
            - "--default-authentication-plugin=mysql_native_password"
          ports:
            - containerPort: 3306
          envFrom:
            - secretRef:
                name: mysql-secret
          volumeMounts:
            - name: mysql-storage
              mountPath: /var/lib/mysql
  volumeClaimTemplates:
    - metadata:
        name: mysql-storage
      spec:
        storageClassName: ebs-sc
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 5Gi
EOF

kubectl apply -f mysql-statefulset.yaml

echo "Final verification..."
kubectl get pods -n external-secrets
kubectl get secretstore -n qa
kubectl get externalsecret -n qa
kubectl get secret mysql-secret -n qa
kubectl get pods -n kube-system | grep ebs || true
kubectl get pods -n qa

echo "Setup completed."

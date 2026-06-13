# Runbook — EKS QA Cluster, DockerHub, and SonarQube

This runbook documents the steps to create the EKS cluster, prepare DockerHub, run the repository scripts, and set up SonarQube.

Prerequisites
- `aws`, `eksctl`, `kubectl`, `git`, and `docker` installed and configured in your local environment.
- AWS account ID, AWS region, and desired EKS cluster name.
- Docker Hub account (create a repo named `nodejs-app` in your Docker Hub account).

High-level steps
1. Create the EKS cluster (example using `eksctl`):

```bash
eksctl create cluster \
  --name qa-cluster \
  --region ap-south-1 \
  --version 1.33 \
  --nodegroup-name qa-workers \
  --node-type m7i-flex.large \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 8 \
  --managed
```

2. Wait for the cluster to be provisioned. Then update kubeconfig:

```bash
aws eks update-kubeconfig --region ap-south-1 --name qa-cluster
```

3. Create a Docker Hub personal access token (Settings → Account → Security → Personal Access Tokens) and note it.

4. Clone the repo and run scripts:

```bash
git clone https://github.com/imagefactory-web/3-tier-user-platform-project.git
cd 3-tier-user-platform-project/scripts

# Edit scripts/github-oidc.sh and set the following variables at top of file:
# ACCOUNT_ID, REGION, CLUSTER_NAME, DOCKERHUB_USERNAME, DOCKERHUB_PASSWORD, DOCKERHUB_EMAIL

# Then run in sequence:
./github-oidc.sh
./aws-alb-controller.sh
./mysql-and-aws-secrets-setup.sh
```

Notes on `scripts/github-oidc.sh`
- The script previously contained hardcoded Docker Hub credentials. They have been replaced with the variables:
  - `DOCKERHUB_USERNAME`
  - `DOCKERHUB_PASSWORD`
  - `DOCKERHUB_EMAIL` (optional)
- Edit `scripts/github-oidc.sh` and set these variables before running.

Repository secrets (to add in GitHub repository Settings → Secrets → Actions)
- `AWS_ROLE_TO_ASSUME` — e.g. `arn:aws:iam::<<ACCOUNT_ID>>:role/GitHubActionsEKSDeployRoleQA`
- `DOCKERHUB_TOKEN` — Docker Hub personal access token
- `SONAR_HOST_URL` — e.g. `http://<SONAR_PUBLIC_IP>:9000/`
- `SONAR_TOKEN` — SonarQube token

Repository variables (Settings → Variables)
- `DOCKERHUB_REPO` — e.g. `your-handle/nodejs-app`
- `DOCKERHUB_USERNAME`
- `EKS_CLUSTER_NAME`

SonarQube setup (on an EC2 instance)
1. Launch an EC2 instance (Ubuntu) and SSH into it.
2. Install Docker and start it:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
sudo chmod 666 /var/run/docker.sock
```

3. Run SonarQube container:

```bash
docker pull sonarqube:lts-community
docker rm -f sonarqube || true
docker run -d --name sonarqube -p 9000:9000 --restart unless-stopped sonarqube:lts-community
```

4. After SonarQube starts (give it ~30–60s), get the EC2 public IP and access:
   `http://<EC2_PUBLIC_IP>:9000/` (default credentials: `admin` / `admin`).

Create a Sonar token and add it to repository secrets as `SONAR_TOKEN`.

Optional: After running the scripts, verify Kubernetes resources in the `qa` namespace:

```bash
kubectl get nodes
kubectl get pods -n qa
kubectl get svc -n qa
```

Troubleshooting
- If `github-oidc.sh` exits complaining about Docker Hub credentials, set the variables at the top of the script.
- Confirm AWS credentials and permissions before running the scripts.

Contact
- If you want, I can also: add a CI workflow file, or help automate secrets injection. Ask me to proceed.

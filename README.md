# DevSecOps CI/CD Pipeline — Demo & Runbook

> **New to this / no CLI tools on your machine?** Use
> `GETTING-STARTED-GUIDE.md` instead — it does everything through the
> GitHub website and the AWS Console, no local installs required. This
> README is a condensed CLI cheat-sheet for later, once you're
> comfortable and have terminal access.

> **New to this / no local CLI tools / office laptop?** Use
> `GETTING-STARTED-GUIDE.md` instead — it does every step below through
> the AWS Console and GitHub's web UI, no installs required. This file
> is the quick CLI-based reference if you ever get terminal access.

A sample Node.js app + a full GitHub Actions pipeline implementing the
DevSecOps architecture: secret scan → lint/SCA → SAST/IaC/SBOM →
build/sign/push → manual-approval deploy to EKS → DAST → runtime
verification, with fail-fast + email notification.

Everything below is written for **you starting from a bare AWS account**
(no EKS/ECR/CodeArtifact yet). Replace anything in `<ANGLE_BRACKETS>`
with your own values. Region used throughout: `ap-south-1` (Mumbai) —
change it in the workflow's `env.AWS_REGION` if you prefer another.

> ⚠️ **Cost warning**: EKS + its worker nodes + a LoadBalancer cost
> real money per hour. Tear everything down (Step 11) once you're done
> testing.

## Prerequisites (install locally)
- AWS CLI v2, configured with an IAM user that has admin access (`aws configure`)
- `eksctl`, `kubectl`, `helm`
- Docker
- A GitHub repo (push this project into it)

---

## Step 1 — Create the GitHub OIDC trust + IAM role (no long-lived keys)

```bash
# 1a. Register GitHub as an OIDC identity provider (one-time per AWS account)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Create `trust-policy.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_ORG>/<GITHUB_REPO>:*"
        }
      }
    }
  ]
}
```

```bash
aws iam create-role \
  --role-name github-actions-oidc-role \
  --assume-role-policy-document file://trust-policy.json

# Demo-only permissions (scope these down for real use)
aws iam attach-role-policy --role-name github-actions-oidc-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
aws iam attach-role-policy --role-name github-actions-oidc-role \
  --policy-arn arn:aws:iam::aws:policy/AWSCodeArtifactAdminAccess
aws iam attach-role-policy --role-name github-actions-oidc-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

Copy this role's ARN into `AWS_ACCOUNT_ID` and `OIDC_ROLE_NAME` in
`.github/workflows/devsecops-pipeline.yml`.

---

## Step 2 — Create the ECR repository

```bash
aws ecr create-repository \
  --repository-name devsecops-demo-app \
  --region ap-south-1 \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability IMMUTABLE
```

## Step 3 — Create CodeArtifact domain + npm repo

```bash
aws codeartifact create-domain --domain devsecops-demo-domain
aws codeartifact create-repository \
  --domain devsecops-demo-domain --repository npm-store \
  --external-connections public:npmjs
aws codeartifact create-repository \
  --domain devsecops-demo-domain --repository npm-repo \
  --upstreams repositoryName=npm-store
```

## Step 4 — Create the EKS cluster

```bash
eksctl create cluster \
  --name devsecops-demo-cluster \
  --region ap-south-1 \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 2 --nodes-min 1 --nodes-max 3 \
  --managed
```
This takes ~15–20 minutes.

Grant the GitHub Actions role access to the cluster:
```bash
aws eks create-access-entry \
  --cluster-name devsecops-demo-cluster \
  --principal-arn arn:aws:iam::123456789012:role/github-actions-oidc-role

aws eks associate-access-policy \
  --cluster-name devsecops-demo-cluster \
  --principal-arn arn:aws:iam::123456789012:role/github-actions-oidc-role \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

## Step 5 — Install Kyverno (policy-as-code)

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
```

## Step 6 — Install Falco (runtime security)

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco -n falco --create-namespace \
  --set driver.type=ebpf
```

## Step 7 — Enable GuardDuty EKS Protection

```bash
DETECTOR_ID=$(aws guardduty list-detectors --region ap-south-1 --query 'DetectorIds[0]' --output text)
aws guardduty update-detector --detector-id $DETECTOR_ID \
  --features Name=EKS_AUDIT_LOGS,Status=ENABLED
```
(Console names/flags for GuardDuty features occasionally change — double
check under GuardDuty → Settings if this command errors.)

## Step 8 — Enable Amazon Inspector (continuous ECR image scanning)

```bash
aws inspector2 enable --resource-types ECR --region ap-south-1
```
Once enabled, Inspector automatically rescans every image pushed to ECR
— no pipeline step needed for it.

## Step 9 — Set up SonarQube analysis

Easiest path: create a free account at sonarcloud.io, import your GitHub
repo, and generate a token. Update `sonar.organization` in
`sonar-project.properties` with your SonarCloud org key.
(Self-hosting SonarQube on an EC2 instance is the alternative if you need
it fully inside your own AWS account.)

## Step 10 — Configure the GitHub repo

**Secrets** (Settings → Secrets and variables → Actions):
- `SONAR_TOKEN`, `SONAR_HOST_URL` (`https://sonarcloud.io`)
- `MAIL_USERNAME`, `MAIL_PASSWORD` (an app password, not your real password), `NOTIFY_EMAIL`

**Environment** (Settings → Environments → New environment → `production`):
- Add yourself/your team as **Required reviewers** (this is the manual approval gate)
- Set **Wait timer** to `2880` minutes (48 hours)

## Step 11 — Run it

Push this repo to `main` and watch the **Actions** tab. Each job only
starts if the previous one succeeds — a failure anywhere aborts the rest
and triggers the notification email automatically.

**To test the fail-fast behavior on purpose**, try either:
- Add a fake key like `AKIAABCDEFGHIJKLMNOP` to a file → `secret-scan` fails
- Downgrade a dependency to an old vulnerable version → `lint-and-sca` fails

## Step 12 — Tear down when done (avoid AWS charges)

```bash
eksctl delete cluster --name devsecops-demo-cluster --region ap-south-1
aws ecr delete-repository --repository-name devsecops-demo-app --force --region ap-south-1
aws codeartifact delete-domain --domain devsecops-demo-domain
```
# EKS permissions configured

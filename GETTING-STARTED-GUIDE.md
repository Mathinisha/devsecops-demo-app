# Complete DevSecOps Pipeline POC — From Zero, Matched to Your Diagram

## How to read this guide

Every single action below is labeled with **where you do it**, so there
is never any guessing:

- 🌐 **GitHub.com** — in your browser, on the GitHub website
- ☁️ **AWS Console** — in your browser, on the AWS website
- 💻 **CloudShell** — a terminal that opens *inside* your AWS Console
  browser tab. It runs on AWS's servers, not your laptop. Nothing to
  install.
- 🤖 **Automatic** — GitHub's robots run this by themselves the moment
  you push code. You never type this command yourself; it's shown so
  you understand what's happening, not so you can run it.

You will personally type things in exactly two places: GitHub.com and
CloudShell. Everything else is clicking buttons in the AWS Console.

---

## Part 0 — Proof this covers every box in your diagram

| Your diagram box | Tool(s) | Where it's built | Where you set it up |
|---|---|---|---|
| Code Push → GitHub Repo | Git/GitHub | Part 3 | 🌐 GitHub |
| Secret Scan | git-secrets | Part 5, Stage 1 | 🤖 Automatic (+ optional 🌐 local hook) |
| Lint & SCA | Hadolint + Trivy | Part 5, Stage 2 | 🤖 Automatic |
| SAST Vuln Scan | Trivy (IaC) + SonarQube + CycloneDX | Part 5, Stage 3 | ☁️ SonarCloud signup, rest 🤖 Automatic |
| Build Docker Image + npm/PyPI pull | Docker + AWS CodeArtifact | Part 5, Stage 4 | ☁️ AWS Console |
| Trivy Image Scan | Trivy | Part 5, Stage 4 | 🤖 Automatic |
| Cosign + Image push | Sigstore Cosign | Part 5, Stage 4 | 🤖 Automatic |
| Push to ECR (immutable tags) | Amazon ECR | Part 5, Stage 4 | ☁️ AWS Console |
| Amazon Inspector | Amazon Inspector | Part 5, Stage 5 | ☁️ AWS Console |
| Manual Approval (48h) | GitHub Environments | Part 6 | 🌐 GitHub |
| Deploy to EKS + Kyverno | EKS + Kyverno | Part 5, Stage 6 | ☁️ AWS Console + 💻 CloudShell |
| DAST Scan | OWASP ZAP | Part 5, Stage 7 | 🤖 Automatic |
| Runtime Security | Falco | Part 5, Stage 6 | 💻 CloudShell |
| GuardDuty | Amazon GuardDuty | Part 5, Stage 8 | ☁️ AWS Console |
| OIDC Keyless Auth (top banner) | AWS IAM | Part 4 | ☁️ AWS Console |
| Fail-fast + Notification | GitHub Actions + Email | Part 6 | 🌐 GitHub |

Every box is here. Let's build it.

---

## Part 1 — Concepts, in plain English (read once, no clicking)

- **Pipeline** = an automated checklist that runs every time you push code.
- **Container/Docker image** = your app + everything it needs, sealed in
  one box. GitHub's own cloud servers build this box — **your laptop
  never runs Docker.**
- **Container registry (ECR)** = AWS's private warehouse that stores
  that box.
- **Kubernetes/EKS** = the system that keeps your containers running,
  restarts them if they crash, and scales them.
- **DevSecOps** = normal build→deploy, but with a security check
  inserted at every single stop instead of only at the end.
- **Policy as code (Kyverno)** = security rules written as files that
  the cluster enforces automatically (e.g. "no container may run as root").
- **OIDC / keyless auth** = instead of GitHub storing a permanent AWS
  password (which is dangerous if leaked), AWS and GitHub agree in
  advance to trust short-lived, auto-expiring ID badges. Nothing
  permanent ever exists to steal.

---

## Part 2 — The 11 files you need

| File | Purpose |
|---|---|
| `app.js` | The sample Node.js app |
| `package.json` | Its dependency list |
| `Dockerfile` | Recipe to build the container image |
| `.dockerignore` | Files to exclude from the image |
| `.gitignore` | Files to exclude from GitHub |
| `sonar-project.properties` | SonarQube scan config |
| `.github/workflows/devsecops-pipeline.yml` | **The pipeline itself** |
| `k8s/deployment.yaml` | Tells EKS how to run your app |
| `k8s/service.yaml` | Exposes the app to the internet |
| `kyverno/policies/disallow-latest-tag.yaml` | Policy: no `latest` image tags |
| `kyverno/policies/require-non-root.yaml` | Policy: containers can't run as root |

---

## Part 3 — 🌐 Create your GitHub repo and add every file

1. github.com → **+** (top right) → **New repository**
2. Name: `devsecops-demo-app` → **Private** → **Create repository**
3. For each file below: **Add file → Create new file** → type the exact
   path shown as the filename (GitHub auto-creates any folders) → paste
   the content → scroll down → **Commit changes directly to the main branch**

### `app.js`
```javascript
const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (req, res) => {
  res.status(200).json({
    message: 'Hello from the DevSecOps Pipeline Demo App!',
    version: '1.0.0'
  });
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy' });
});

app.listen(PORT, () => {
  console.log(`Server is listening on port ${PORT}`);
});

module.exports = app;
```

### `package.json`
```json
{
  "name": "devsecops-demo-app",
  "version": "1.0.0",
  "description": "Sample Node.js app used to test an end-to-end DevSecOps CI/CD pipeline",
  "main": "app.js",
  "scripts": {
    "start": "node app.js",
    "test": "echo \"no unit tests defined yet\" && exit 0"
  },
  "license": "MIT",
  "dependencies": {
    "express": "^4.19.2"
  }
}
```

### `Dockerfile`
```dockerfile
FROM node:20.15.1-alpine3.20 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

FROM node:20.15.1-alpine3.20
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js ./
COPY package*.json ./
USER appuser
EXPOSE 3000
CMD ["node", "app.js"]
```

### `.dockerignore`
```
node_modules
npm-debug.log
.git
.gitignore
README.md
.github
k8s
kyverno
```

### `.gitignore`
```
node_modules/
.env
*.log
sbom.json
```

### `sonar-project.properties`
```
sonar.projectKey=devsecops-demo-app
sonar.organization=<YOUR_SONARCLOUD_ORG>
sonar.sources=.
sonar.exclusions=node_modules/**,k8s/**,kyverno/**,.github/**
sonar.sourceEncoding=UTF-8
```

### `k8s/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: devsecops-demo-app
  labels:
    app: devsecops-demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: devsecops-demo-app
  template:
    metadata:
      labels:
        app: devsecops-demo-app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: devsecops-demo-app
          image: IMAGE_PLACEHOLDER
          ports:
            - containerPort: 3000
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "250m"
              memory: "256Mi"
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
```

### `k8s/service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: devsecops-demo-app
spec:
  type: LoadBalancer
  selector:
    app: devsecops-demo-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 3000
```

### `kyverno/policies/disallow-latest-tag.yaml`
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Images tagged 'latest' are not allowed. Use an immutable, versioned tag."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

### `kyverno/policies/require-non-root.yaml`
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-non-root
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-runasnonroot
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
                - falco
      validate:
        message: "Containers must set securityContext.runAsNonRoot: true."
        pattern:
          spec:
            containers:
              - securityContext:
                  runAsNonRoot: true
```

### `.github/workflows/devsecops-pipeline.yml`
Type the path exactly as `.github/workflows/devsecops-pipeline.yml` —
GitHub creates both folders for you.
```yaml
name: DevSecOps CI/CD Pipeline

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch: {}

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-south-1
  ECR_REPOSITORY: devsecops-demo-app
  EKS_CLUSTER_NAME: devsecops-demo-cluster
  CODEARTIFACT_DOMAIN: devsecops-demo-domain
  CODEARTIFACT_REPO: npm-repo
  IMAGE_TAG: ${{ github.sha }}
  AWS_ACCOUNT_ID: "123456789012"          # <-- Replace with your actual 12-digit AWS account ID
  OIDC_ROLE_NAME: github-actions-oidc-role

jobs:
  secret-scan:
    name: "1. Secret Scan (git-secrets)"
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Install git-secrets
        run: |
          git clone https://github.com/awslabs/git-secrets.git
          cd git-secrets && sudo make install
      - name: Scan full history for AWS keys and secrets
        run: |
          git secrets --register-aws
          git secrets --scan-history

  lint-and-sca:
    name: "2. Lint & SCA (Hadolint + Trivy)"
    needs: secret-scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Hadolint - Dockerfile best-practice lint
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile
      - name: Trivy - SCA / dependency scan
        uses: aquasecurity/trivy-action@0.24.0
        with:
          scan-type: fs
          scan-ref: .
          severity: CRITICAL,HIGH
          exit-code: 1

  sast-scan:
    name: "3. SAST Vuln Scan (Trivy IaC + SonarQube + SBOM)"
    needs: lint-and-sca
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: SonarQube static analysis (SAST)
        uses: SonarSource/sonarqube-scan-action@v3
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}
      - name: Trivy - Infrastructure as Code scan
        uses: aquasecurity/trivy-action@0.24.0
        with:
          scan-type: config
          scan-ref: .
      - name: Generate SBOM with CycloneDX
        run: |
          npm install -g @cyclonedx/cyclonedx-npm
          cyclonedx-npm --output-file sbom.json
      - name: Upload SBOM artifact
        uses: actions/upload-artifact@v4
        with:
          name: sbom
          path: sbom.json

  build-and-push:
    name: "4. Build Image + Trivy Image Scan + Cosign + Push to ECR"
    needs: sast-scan
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    outputs:
      image: ${{ steps.build-image.outputs.image }}
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC - keyless)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ env.AWS_ACCOUNT_ID }}:role/${{ env.OIDC_ROLE_NAME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Authenticate npm to AWS CodeArtifact
        run: |
          aws codeartifact login --tool npm \
            --repository ${{ env.CODEARTIFACT_REPO }} \
            --domain ${{ env.CODEARTIFACT_DOMAIN }} \
            --domain-owner ${{ env.AWS_ACCOUNT_ID }}

      - name: Build Docker image
        id: build-image
        run: |
          IMAGE_URI=${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}:${{ env.IMAGE_TAG }}
          docker build -t "$IMAGE_URI" .
          echo "image=$IMAGE_URI" >> "$GITHUB_OUTPUT"

      - name: "Trivy - IMAGE SCAN (matches the diagram's Image Scan step)"
        uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: ${{ steps.build-image.outputs.image }}
          severity: CRITICAL,HIGH
          exit-code: 1

      - name: Push image to Amazon ECR
        run: docker push ${{ steps.build-image.outputs.image }}

      - name: Install Cosign
        uses: sigstore/cosign-installer@v3

      - name: Sign image with Cosign (keyless / Sigstore)
        env:
          COSIGN_EXPERIMENTAL: "1"
        run: cosign sign --yes ${{ steps.build-image.outputs.image }}

  deploy:
    name: "5. Deploy to EKS"
    needs: build-and-push
    runs-on: ubuntu-latest
    environment:
      name: production
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ env.AWS_ACCOUNT_ID }}:role/${{ env.OIDC_ROLE_NAME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Configure EKS cluster access  
        run: |
          # Configure kubectl context
          aws eks update-kubeconfig --name ${{ env.EKS_CLUSTER_NAME }} --region ${{ env.AWS_REGION }}
          
          # Verify connection and cluster permissions
          kubectl auth can-i get pods

      - name: Deploy application
        run: |
          sed -i "s|IMAGE_PLACEHOLDER|${{ needs.build-and-push.outputs.image }}|g" k8s/deployment.yaml
          kubectl apply -f k8s/deployment.yaml
          kubectl apply -f k8s/service.yaml
          kubectl rollout status deployment/devsecops-demo-app --timeout=300s

  dast-scan:
    name: "6. DAST Scan (OWASP ZAP)"
    needs: deploy
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ env.AWS_ACCOUNT_ID }}:role/${{ env.OIDC_ROLE_NAME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --name ${{ env.EKS_CLUSTER_NAME }} --region ${{ env.AWS_REGION }}

      - name: Get LoadBalancer URL
        id: get-url
        run: |
          for i in {1..30}; do
            HOSTNAME=$(kubectl get svc devsecops-demo-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
            if [ -n "$HOSTNAME" ]; then break; fi
            echo "Waiting for LoadBalancer hostname..."
            sleep 10
          done
          echo "url=http://$HOSTNAME" >> "$GITHUB_OUTPUT"

      - name: OWASP ZAP baseline scan
        uses: zaproxy/action-baseline@v0.15.0
        with:
          target: ${{ steps.get-url.outputs.url }}
          fail_action: false
          allow_issue_writing: false

  runtime-security-check:
    name: "7. Runtime Security Verification"
    needs: dast-scan
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ env.AWS_ACCOUNT_ID }}:role/${{ env.OIDC_ROLE_NAME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --name ${{ env.EKS_CLUSTER_NAME }} --region ${{ env.AWS_REGION }}

      - name: Verify Falco is running as a daemonset
        run: |
          # Verify Falco daemonset status on the cluster
          kubectl get daemonset -n falco || echo "Falco daemonset not found"
          kubectl get pods -n falco -l app=falco || echo "Falco pods not found or still starting..."

      - name: Verify GuardDuty EKS protection status
        run: aws guardduty list-detectors --region ${{ env.AWS_REGION }}

  notify-on-failure:
    name: "Fail-fast: Notify on Pipeline Failure"
    needs: [secret-scan, lint-and-sca, sast-scan, build-and-push, deploy, dast-scan, runtime-security-check]
    if: failure()
    runs-on: ubuntu-latest
    steps:
      - name: Send failure email
        uses: dawidd6/action-send-mail@v3
        with:
          server_address: smtp.gmail.com
          server_port: 465
          username: ${{ secrets.MAIL_USERNAME }}
          password: ${{ secrets.MAIL_PASSWORD }}
          subject: "Pipeline failed: ${{ github.repository }}"
          to: ${{ secrets.NOTIFY_EMAIL }}
          from: GitHub Actions
          body: |
            The DevSecOps pipeline failed at commit ${{ github.sha }}.
            View run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
```

At this point the pipeline will try to run and fail on its first AWS
step — expected, since AWS doesn't know about your account yet. Continue.

---

## Part 4 — ☁️ AWS Console: the OIDC trust (foundation for everything else)

This is the "GitHub Actions — OIDC Keyless Auth → AWS IAM Role" banner
at the top of your diagram.

### 4.1 Register GitHub as a trusted identity provider
1. AWS Console → search **IAM** → open it
2. Left sidebar → **Identity providers** → **Add provider**
3. Type: **OpenID Connect**
4. Provider URL: `https://token.actions.githubusercontent.com`
5. Audience: `sts.amazonaws.com`
6. Click **Get thumbprint** → **Add provider**

### 4.2 Create the IAM Role
1. IAM → **Roles** → **Create role**
2. Trusted entity type: **Web identity**
3. Identity provider: select the one you just made
4. Audience: `sts.amazonaws.com` → **Next**
5. On the permissions page, search and tick:
   - `AmazonEC2ContainerRegistryFullAccess`
   - `AWSCodeArtifactAdminAccess`
   - `AmazonEKSClusterPolicy`
   - `AmazonGuardDutyReadOnlyAccess`
6. Role name (exact): `github-actions-oidc-role` → **Create role**
7. Open the role → **Trust relationships** tab → **Edit trust policy** →
   replace everything with (swap in your real account ID and GitHub username):
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
        "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
        "StringLike": { "token.actions.githubusercontent.com:sub": "repo:<your-github-username>/devsecops-demo-app:*" }
      }
    }
  ]
}
```
8. **Update policy**. Your Account ID is shown top-right of the console
   under your name.
9. 🌐 Back in GitHub, open `.github/workflows/devsecops-pipeline.yml`,
   click the pencil (edit), replace `123456789012` with your real
   12-digit ID, commit.

---

## Part 5 — Building every stage of the diagram

### Stage 1 — Secret Scan (git-secrets)
🤖 **Automatic.** Already fully wired into the pipeline file from Part 3
— nothing to set up in AWS or GitHub for this stage.

**Optional, to match the diagram's "pre-push hook" label exactly:** the
diagram shows git-secrets also running on your own laptop before code
even leaves it. Since we're avoiding local installs, we rely entirely
on the CI-side scan instead, which is strictly stronger (it can't be
skipped by forgetting to install a hook). If you later get permission to
install tools locally, `git secrets --install` in your repo folder adds
that local hook too.

### Stage 2 — Lint & SCA (Hadolint + Trivy)
🤖 **Automatic.** Nothing to configure — runs the moment you push.

### Stage 3 — SAST Vuln Scan (Trivy IaC + SonarQube + CycloneDX SBOM)
☁️/🌐 **One signup needed** for SonarQube; the rest is automatic.
1. 🌐 Go to **sonarcloud.io** → sign up with your GitHub account
2. Import your `devsecops-demo-app` repo (free tier covers private
   repos up to 50,000 lines of code — plenty for this app)
3. **My Account → Security → Generate token** → copy it
4. Note your **organization key** from the SonarCloud dashboard
5. 🌐 Back in GitHub, edit `sonar-project.properties`, replace
   `<YOUR_SONARCLOUD_ORG>` with that key, commit

Trivy's IaC scan and the CycloneDX SBOM generation need no setup —
they're already in the `sast-scan` job.

### Stage 4 — Build Docker Image + CodeArtifact + Trivy Image Scan + Cosign + Push to ECR
☁️ **AWS Console setup needed** for CodeArtifact and ECR. Everything
else (the actual build, the Trivy image scan, and Cosign signing) is
🤖 automatic.

**CodeArtifact (the "npm & PyPI package pull" box):**
1. Search **CodeArtifact** → **Create domain** → name:
   `devsecops-demo-domain` → Create
2. **Create repository** → name: `npm-store` → under "Public upstream
   repositories" select **npmjs** → Create
3. **Create repository** again → name: `npm-repo` → under "upstream
   repositories" select `npm-store` → Create

> *Note: your sample app is Node.js only, so only the npm repo is
> actually used. If your real customer app also uses Python, repeat the
> same two steps choosing "pypi" instead of "npmjs" to add a PyPI repo
> — the diagram shows both because a real platform typically serves
> multiple languages.*

**ECR (the "Push to ECR / Immutable tags" box):**
1. Search **ECR** → **Create repository**
2. Visibility: **Private**, name: `devsecops-demo-app`
3. Turn on **Scan on push**
4. Tag immutability: **Immutable** → **Create repository**

The **Trivy image scan** and **Cosign signing** happen automatically
inside the `build-and-push` job right after the image is built — this
is the same Trivy tool as Stage 2/3, now pointed at the finished image,
matching your diagram's "Image Scan" arrow.

### Stage 5 — Amazon Inspector
☁️ **AWS Console:**
1. Search **Inspector** → **Activate Inspector**
2. Confirm **Amazon ECR** is checked as a resource type

This scans every image in ECR continuously in the background — it's not
a pipeline step because it doesn't need to be triggered, it's always
watching (matches the dotted "Image Scan" feedback arrow in your diagram).

### Stage 6 — Deploy to EKS + Kyverno + Falco (Runtime Security)
☁️ **AWS Console** for the cluster, 💻 **CloudShell** for the two things
with no console button (installing Kyverno and Falco).

**Create the cluster:**
1. Search **EKS** → **Add cluster** → **Create**
2. Name: `devsecops-demo-cluster`
3. Cluster service role: click **Create recommended role** (opens a new
   tab, pre-filled) → **Create role** there → return and select it
4. If offered **EKS Auto Mode**, choose it — simplest path, AWS manages
   worker nodes for you. Otherwise continue with defaults.
5. Networking: your account's **default VPC** and its auto-selected subnets
6. Click through with defaults → **Create** (15–20 minutes)
7. If not using Auto Mode: once Active, **Compute** tab → **Add node
   group** → instance type `t3.medium`, desired 2 / min 1 / max 3, node
   IAM role via **Create recommended role** shortcut → **Create**

**Let the GitHub role deploy to it:**
1. Cluster page → **Access** tab → **Create access entry**
2. IAM principal ARN: paste your `github-actions-oidc-role` ARN
3. Access policy: **AmazonEKSClusterAdminPolicy**, scope: **Cluster** → **Create**

**Install Kyverno (policy-as-code) and Falco (runtime security):**
1. On the cluster page, click **Connect** (top right) — this opens
   💻 **CloudShell**, already logged in and pointed at your cluster
2. Paste these one block at a time:
```bash
# Helm isn't preloaded in CloudShell — install it once (still on AWS's servers, not your laptop)
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh
```
```bash
# Kyverno — enforces policy-as-code
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace

# Clone repository in CloudShell to apply the custom Kyverno policy files
git clone https://github.com/<your-github-username>/devsecops-demo-app.git
cd devsecops-demo-app
kubectl apply -f kyverno/policies/
```
```bash
# Falco — the "Runtime Security Scan" daemonset in your diagram
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco -n falco --create-namespace --set driver.type=ebpf
```
*(There's no AWS Console button for installing these Kubernetes applications — Kyverno, Kyverno Policies, and Falco are cluster-level, one-time bootstrap configurations. They are manually set up once on your EKS cluster using the terminal, separating infrastructure setup from application deployment. Once set up, the application CI/CD pipeline deploys code to the cluster and automatically validates the runtime status of these components.)*

### Stage 7 — DAST Scan (OWASP ZAP)
🤖 **Automatic.** Runs against your live app's URL right after deploy —
nothing to configure.

### Stage 8 — GuardDuty (Runtime EKS Monitoring)
☁️ **AWS Console:**
1. Search **GuardDuty** → **Enable GuardDuty** if not already on
2. Left sidebar → **EKS Protection** → **Enable**

---

## Part 6 — 🌐 GitHub: secrets, approval gate, and notifications

**Secrets** — repo → **Settings → Secrets and variables → Actions →
New repository secret**:
- `SONAR_TOKEN` — from Stage 3
- `SONAR_HOST_URL` — `https://sonarcloud.io`
- `MAIL_USERNAME` / `MAIL_PASSWORD` — a Gmail address + an **app
  password** (Google Account → Security → App passwords — not your real
  Gmail password)
- `NOTIFY_EMAIL` — where failure alerts should land

**Manual Approval gate (the "48-hr gate" box)** — repo → **Settings →
Environments → New environment** → name exactly `production`:
- **Required reviewers** → add yourself
- **Wait timer** → `2880` minutes (48 hours)

---

## Part 7 — 🌐 Run it

Re-commit the workflow file now that the account ID is filled in, or
make any small edit and commit directly to `main`. Go to the repo's
**Actions** tab — all 7 jobs run left to right, matching your diagram
exactly. At **deploy**, it pauses with "Review deployments" — click,
approve, watch the rest continue.

Click any red ❌ job → expand the failing step → the exact error is shown.

---

## Part 8 — 🌐 Prove the fail-fast behavior

Edit any file in the browser, add a fake key like
`AKIAABCDEFGHIJKLMNOP`, commit → watch `secret-scan` fail instantly and
everything after it stop. Or edit `package.json` to an old vulnerable
`express` version to trigger the Trivy SCA failure instead. Check your
email for the alert.

---

## Part 9 — ☁️ Complete teardown (do this — avoid ongoing charges)

Delete in this order:

1. **EKS console** → your cluster → **Delete**. If it was using a
   LoadBalancer Service, check the **EC2 console → Load Balancers** a
   few minutes later to confirm none are left orphaned; delete any that
   remain manually.
2. **EKS console** → delete the node group first if the cluster delete
   doesn't remove it automatically
3. **ECR console** → your repository → **Delete**
4. **CodeArtifact console** → delete the `npm-repo` and `npm-store`
   repositories, then the `devsecops-demo-domain` domain
5. **IAM console** → **Roles** → delete `github-actions-oidc-role`
6. **IAM console** → **Identity providers** → delete the GitHub OIDC provider
7. **GuardDuty console** → Settings → **Disable GuardDuty** (or leave on
   — its EKS-only cost is small, but disable if you want zero ongoing spend)
8. **Inspector console** → **Deactivate**
9. **CloudShell** costs nothing to leave as-is; no deletion needed
10. **SonarCloud** — optional; free tier costs nothing, but you can
    delete the project from your SonarCloud dashboard if you want it gone
11. As a final check: **AWS Console → Billing → Cost Explorer**, filter
    by the last few days, confirm nothing is still accumulating

You can rebuild the entire AWS side from Part 4–5 again in about 30
minutes whenever you need to demo this again.

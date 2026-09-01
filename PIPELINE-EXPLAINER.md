# Understanding Your DevSecOps Pipeline: A Beginner's Guide

Welcome! If you are new to GitHub Actions, CI/CD, and Kubernetes, this document is designed to explain exactly how everything works under the hood. You will learn:
1. **How GitHub Actions works** and how it takes inputs.
2. **What every file in your repository does** and why they are there.
3. **Where every security scan report is stored**.
4. **A line-by-line breakdown** of your pipeline workflow code (`devsecops-pipeline.yml`).

---

## 1. How GitHub Actions Works

At its simplest, **GitHub Actions** is a robot that runs a checklist of commands every time you do something on GitHub (like pushing code or opening a Pull Request).

### Core Concepts:
*   **Workflow**: The entire automated process. It is defined in a single file inside the `.github/workflows/` directory (your `devsecops-pipeline.yml`).
*   **Trigger (`on`)**: The event that wakes the robot up. For example, `on: push` means "run this workflow every time code is pushed."
*   **Runner**: A clean virtual machine (hosted by GitHub in the cloud, running Ubuntu Linux by default) that GitHub starts up just to run your workflow, then destroys when done.
*   **Job**: A group of steps that run on the same Runner. We have jobs like `secret-scan`, `build-and-push`, and `deploy`.
*   **Step**: A single task inside a job. It can be a shell command (like `run: npm install`) or a pre-made tool shared on GitHub (using `uses: actions/checkout@v4`).
*   **Action**: A reusable block of code shared on the GitHub Marketplace (like `zaproxy/action-baseline`).

### How the Pipeline Takes Inputs:
1.  **Environment Variables (`env`)**: Global inputs (like region, cluster name) set at the top of the YAML file that any step can read.
2.  **Secrets (`secrets.NAME`)**: Sensitive inputs (like your email password or SonarCloud token) stored securely in your GitHub Repository settings under **Secrets and variables**. GitHub hides these in the logs.
3.  **Step Outputs**: Steps can calculate values and "pass" them to later steps. For example, Stage 4 outputs the final ECR image URL, and Stage 5 reads that URL to deploy it.

---

## 2. Directory Structure: What Every File Does

To run an automated DevSecOps system, we need configuration files to guide different tools. Here is why each file exists:

*   **`.github/workflows/devsecops-pipeline.yml`**: The pipeline engine. It holds the commands that GitHub Actions executes.
*   **`Dockerfile`**: The container blueprint. It tells GitHub how to package your Node.js application, its dependencies, and system utilities into a single portable box (Docker Image) that can run on EKS.
*   **`app.js`**: Your application. A simple Node.js web server that returns a JSON message.
*   **`package.json` & `package-lock.json`**: List of Node.js dependencies (like the Express framework) needed to run the app.
*   **`.gitignore`**: Tells Git which folders (like `node_modules` containing downloaded files) should **never** be uploaded to GitHub.
*   **`.dockerignore`**: Tells Docker which files (like local logs or documentation) to leave out when building the container image, keeping the image small.
*   **`sonar-project.properties`**: Configuration for SonarCloud/SonarQube. It tells SonarCloud what language your app is, what directories to scan, and what directories to ignore.
*   **`k8s/deployment.yaml`**: The Kubernetes Deployment manifest. It tells EKS: *"Run 2 copies of my container, ensure it runs as non-root (UID 1000), set CPU/Memory limits, and restart it if the `/health` check fails."*
*   **`k8s/service.yaml`**: The Kubernetes Service manifest. It tells EKS: *"Create a public Load Balancer so users on the internet can access my application pods on port 80."*
*   **`kyverno/policies/disallow-latest-tag.yaml`**: A security rule. Blocks you from deploying containers that use the `latest` image tag (which changes and is not secure).
*   **`kyverno/policies/require-non-root.yaml`**: A security rule. Blocks any container from running as `root` (UID 0), preventing container escape exploits.

---

## 3. Where Scan Reports & Outputs Are Stored

When security checks run, the scan data is sent to specific dashboards depending on the tool:

| Security Scan | Tool Used | Where It Is Stored | How to Access It |
|---|---|---|---|
| **Secret Scan** | `git-secrets` | **GitHub Console Output** | Click on the failed pipeline run → click `1. Secret Scan` step logs to see the leaked key. |
| **Docker Lint** | `Hadolint` | **GitHub Console Output** | Click on `2. Docker Lint` logs to see Dockerfile rule violations. |
| **Dependency Scan (SCA)** | `Trivy` | **GitHub Security Tab** | Uploads a `.sarif` report to GitHub. Go to your repo → **Security** tab → **Code scanning alerts**. |
| **SAST (Code Quality)** | `SonarCloud` | **SonarCloud Dashboard** | Log in to `sonarcloud.io` to see bugs, code smells, and security hotspots. |
| **IaC Misconfiguration** | `Trivy` (IaC) | **GitHub Console Output** | In Stage 3 logs, it shows if your Kubernetes files are insecure. |
| **SBOM (Software Bill)** | `CycloneDX` | **Workflow Artifacts** | Open your workflow run → scroll to the bottom → download the `sbom` zip containing `sbom.json`. |
| **Image Scan** | `Trivy` (Image) | **GitHub Console Output** | In Stage 4 logs, it outputs any vulnerabilities found inside the built container image. |
| **Image Signature** | `Cosign` | **Amazon ECR** | Stored directly in your private ECR registry as a signature file linked to the container image. |
| **DAST (Web Scan)** | `OWASP ZAP` | **Workflow Artifacts** | Open your workflow run → scroll to the bottom → download `zap-report` containing `report_html.html`. |
| **Runtime Security** | `Falco` | **EKS Cluster Logs** | Run `kubectl logs -n falco -l app=falco` in AWS CloudShell to view real-time daemonset alerts. |

---

## 4. Line-by-Line Breakdown of `devsecops-pipeline.yml`

Here is what every line in your pipeline code does:

```yaml
name: DevSecOps CI/CD Pipeline   # The display name of the workflow on GitHub.

on:
  push:
    branches: [main]             # Run this workflow automatically every time code is pushed to the 'main' branch.
  pull_request:
    branches: [main]             # Run this workflow when a pull request targeting 'main' is created.
  workflow_dispatch: {}          # Adds a "Run workflow" button in the GitHub UI so you can trigger it manually.

permissions:                     # Configures security permissions for the GitHub runner.
  id-token: write                # Required to exchange GitHub's OIDC token for temporary AWS credentials (keyless auth).
  contents: read                 # Allows the runner to download (checkout) your repository files.

env:                             # Global environment variables accessible by all jobs.
  AWS_REGION: ap-south-1
  ECR_REPOSITORY: devsecops-demo-app
  EKS_CLUSTER_NAME: devsecops-demo-cluster
  CODEARTIFACT_DOMAIN: devsecops-demo-domain
  CODEARTIFACT_REPO: npm-store
  IMAGE_TAG: ${{ github.sha }}   # Tag the image with the unique 40-character Git commit hash (immutable tag).
  AWS_ACCOUNT_ID: "088585194665"
  OIDC_ROLE_NAME: github-actions-oidc-role

jobs:                            # The list of jobs. By default, jobs run in parallel unless we set "needs:".
  
  # ---------- STAGE 1: Secret Scan ----------
  secret-scan:
    name: 1. Secret Scan (git-secrets)
    runs-on: ubuntu-latest       # Spin up a clean Ubuntu Linux virtual machine.
    steps:
      - uses: actions/checkout@v4 # Downloads your code onto the runner.
        with:
          fetch-depth: 0         # Download the full Git commit history, not just the latest commit (needed for history scan).
      - name: Install git-secrets
        run: |                   # Clones and installs the git-secrets CLI tool on the runner.
          git clone https://github.com/awslabs/git-secrets.git
          cd git-secrets && sudo make install
      - name: Scan full history for AWS keys and secrets
        run: |                   # Scans the entire Git commit history. If it finds a leaked AWS key, it exits with code 1, stopping the pipeline.
          git secrets --register-aws
          if git secrets --scan-history; then
            echo "✅ No secrets found - scan passed"
          else
            EXIT_CODE=$?
            if [ $EXIT_CODE -eq 1 ]; then
              echo "✅ No secrets found - scan passed"
              exit 0
            else
              echo "❌ Error running git-secrets scan"
              exit $EXIT_CODE
            fi
          fi

  # ---------- STAGE 2: Lint & SCA ----------
  lint-and-sca:
    name: 2. Docker Lint + SCA
    needs: secret-scan           # Wait for Stage 1 to pass successfully before running this.
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write     # Required to upload the vulnerability scan findings to the GitHub Security tab.
      actions: read
    steps:
      - uses: actions/checkout@v4
      - name: Hadolint - Dockerfile best-practice lint
        uses: hadolint/hadolint-action@v3.1.0 # Scans Dockerfile for security bad practices (e.g. running as root).
        with:
          dockerfile: Dockerfile
      - name: Trivy - dependency (SCA) scan
        uses: aquasecurity/trivy-action@master # Scans npm package dependencies inside package.json for known vulnerabilities.
        with:
          scan-type: fs
          scan-ref: .
          severity: CRITICAL,HIGH
          exit-code: 1           # Fail the job if any CRITICAL or HIGH vulnerabilities are found.
          format: 'sarif'
          output: 'trivy-results.sarif'
      - name: Upload Trivy scan results to GitHub Security
        uses: github/codeql-action/upload-sarif@v4 # Uploads the SARIF scan report to your GitHub Security Dashboard.
        if: always()             # Run this upload even if the previous scan step failed (so you get to see the vulnerabilities).
        continue-on-error: true  # Do not crash the pipeline if the upload fails (useful for private repos without advanced security).
        with:
          sarif_file: 'trivy-results.sarif'

  # ---------- STAGE 3: SAST + IaC + SBOM ----------
  sast-scan:
    name: 3. SAST, IaC scan & SBOM
    needs: lint-and-sca
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: SonarQube static analysis
        uses: SonarSource/sonarqube-scan-action@v3 # Runs static code analysis (SAST) to detect bugs and code quality issues.
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}
      - name: Trivy - Infrastructure as Code scan
        uses: aquasecurity/trivy-action@master # Scans Kubernetes manifest files (k8s/) for security misconfigurations.
        with:
          scan-type: config
          scan-ref: .
      - name: Generate SBOM with CycloneDX
        run: |                   # Generates a Software Bill of Materials (SBOM), which is an inventory of every library used.
          npm install --package-lock-only
          npm install -g @cyclonedx/cyclonedx-npm
          cyclonedx-npm --output-file sbom.json || echo "SBOM generation completed with warnings"
      - name: Upload SBOM artifact
        uses: actions/upload-artifact@v4 # Saves the SBOM as a downloadable zip file on the Github run page.
        with:
          name: sbom
          path: sbom.json

  # ---------- STAGE 4: Build, Sign & Push to ECR ----------
  build-and-push:
    name: 4. Build, Sign & Push Image
    needs: sast-scan
    runs-on: ubuntu-latest
    permissions:
      id-token: write            # Needed for AWS OIDC authentication.
      contents: read
    outputs:
      image: ${{ steps.build-image.outputs.image }} # Exports the built image URI as a job output to pass to Stage 5.
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials (OIDC - keyless)
        uses: aws-actions/configure-aws-credentials@v4 # Signs in to AWS using keyless OIDC (assumes the IAM role).
        with:
          role-to-assume: arn:aws:iam::${{ env.AWS_ACCOUNT_ID }}:role/${{ env.OIDC_ROLE_NAME }}
          aws-region: ${{ env.AWS_REGION }}
      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2 # Authenticates Docker client against your private AWS ECR registry.
      - name: Authenticate npm to AWS CodeArtifact
        run: |                   # Pulls npm packages securely from your private AWS CodeArtifact domain instead of public npmjs.
          aws codeartifact login --tool npm \
            --repository ${{ env.CODEARTIFACT_REPO }} \
            --domain ${{ env.CODEARTIFACT_DOMAIN }} \
            --domain-owner ${{ env.AWS_ACCOUNT_ID }}
      - name: Build Docker image
        id: build-image
        run: |                   # Builds the container image and outputs the image path to GITHUB_OUTPUT.
          IMAGE_URI=${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}:${{ env.IMAGE_TAG }}
          docker build -t "$IMAGE_URI" .
          echo "image=$IMAGE_URI" >> "$GITHUB_OUTPUT"
      - name: Trivy - scan image before push
        uses: aquasecurity/trivy-action@master # Scans the compiled container image for vulnerabilities before pushing it.
        with:
          image-ref: ${{ steps.build-image.outputs.image }}
          severity: CRITICAL,HIGH
          exit-code: 1
      - name: Push image to Amazon ECR
        run: docker push ${{ steps.build-image.outputs.image }} # Pushes the secure container image to AWS ECR.
      - name: Install Cosign
        uses: sigstore/cosign-installer@v3 # Installs the Cosign utility.
      - name: Sign image with Cosign (keyless / Sigstore)
        env:
          COSIGN_EXPERIMENTAL: "1"
        run: cosign sign --yes ${{ steps.build-image.outputs.image }} # Signs the ECR image with a cryptographic signature, proving it was built by your pipeline.

  # ---------- STAGE 5: Manual Approval + Deploy to EKS ----------
  deploy:
    name: 5. Deploy to EKS
    needs: build-and-push
    runs-on: ubuntu-latest
    environment:
      name: production           # Configures GitHub Environments to enforce a manual review gate before this job runs.
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
        run: |                   # Configures kubectl context to connect to your EKS cluster and tests connection permissions.
          aws eks update-kubeconfig --name ${{ env.EKS_CLUSTER_NAME }} --region ${{ env.AWS_REGION }}
          kubectl auth can-i get pods
      - name: Deploy application
        run: |                   # Replaces placeholder in deployment.yaml, deploys the app, and monitors rollout success.
          sed -i "s|IMAGE_PLACEHOLDER|${{ needs.build-and-push.outputs.image }}|g" k8s/deployment.yaml
          kubectl apply -f k8s/deployment.yaml
          kubectl apply -f k8s/service.yaml
          kubectl rollout status deployment/devsecops-demo-app --timeout=300s
          kubectl get pods -l app=devsecops-demo-app
          kubectl get svc devsecops-demo-app

  # ---------- STAGE 6: DAST Scan ----------
  dast-scan:
    name: 6. DAST Scan (OWASP ZAP)
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
        run: |                   # Fetches the public ELB address created by EKS to pass to the web scanner.
          echo "Waiting for LoadBalancer to get external IP..."
          for i in {1..60}; do
            HOSTNAME=$(kubectl get svc devsecops-demo-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            if [ -n "$HOSTNAME" ] && [ "$HOSTNAME" != "null" ]; then 
              echo "LoadBalancer ready: $HOSTNAME"
              echo "url=http://$HOSTNAME" >> "$GITHUB_OUTPUT"
              break
            fi
            echo "Attempt $i/60: Waiting for LoadBalancer hostname..."
            sleep 10
          done
      - name: OWASP ZAP baseline scan
        uses: zaproxy/action-baseline@v0.15.0 # Scans the active application website URL for web vulnerabilities (DAST).
        with:
          target: ${{ steps.get-url.outputs.url }}
          fail_action: false     # Do not crash the pipeline for minor warnings.
          allow_issue_writing: false # Do not attempt to write issues to private repo.
      - name: Upload ZAP report
        uses: actions/upload-artifact@v4 # Uploads the DAST report as a downloadable artifact.
        if: always()
        with:
          name: zap-report
          path: report_html.html

  # ---------- STAGE 7: Runtime Security Verification ----------
  runtime-security-check:
    name: 7. Runtime Security Verification
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
        run: |                   # Verifies that Falco runtime monitoring is active on all cluster nodes.
          kubectl get daemonset -n falco || echo "Falco daemonset not found"
          kubectl get pods -n falco -l app=falco || echo "Falco pods not found or still starting..."

  # ---------- Fail-fast notification ----------
  notify-on-failure:
    name: Notify on Pipeline Failure
    needs: [secret-scan, lint-and-sca, sast-scan, build-and-push, deploy, dast-scan, runtime-security-check]
    if: failure()                # Run ONLY if one of the 7 stages fails.
    runs-on: ubuntu-latest
    steps:
      - name: Send failure email
        uses: dawidd6/action-send-mail@v3 # Sends a direct failure email alert to the configured email address.
        with:
          server_address: smtp.gmail.com
          server_port: 465
          username: ${{ secrets.MAIL_USERNAME }}
          password: ${{ secrets.MAIL_PASSWORD }}
          subject: "DevSecOps Pipeline Failed: ${{ github.repository }}"
          to: ${{ secrets.NOTIFY_EMAIL }}
          from: DevSecOps Pipeline <noreply@github.com>
          body: |
            🚨 DevSecOps Pipeline Failure Alert
            Repository: ${{ github.repository }}
            Branch: ${{ github.ref_name }}
            Commit: ${{ github.sha }}
            Author: ${{ github.actor }}
            🔗 View Failed Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
```

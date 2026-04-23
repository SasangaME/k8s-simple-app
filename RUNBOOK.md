# Operations runbook

Day-2 procedures for the `k8s-simple-app` EKS deployment. For first-time
setup (Terraform apply, initial image push, manifest apply), see
[README.md](README.md). This document assumes the cluster already exists and
`kubectl` is pointed at it.

> **Context assumed in every command below:**
> - Namespace: `simple-app`
> - Deployment: `simple-app`
> - Container port: `3000` (Service port `80`)
> - ALB Ingress: `simple-app`
> - AWS Load Balancer Controller runs in `kube-system`

## Table of contents

- [Preflight — confirm you're on the right cluster](#preflight--confirm-youre-on-the-right-cluster)
- [Health checks](#health-checks)
- [View logs](#view-logs)
- [Deploy a new version](#deploy-a-new-version)
- [Roll back a deployment](#roll-back-a-deployment)
- [Restart pods without a code change](#restart-pods-without-a-code-change)
- [Scale the application](#scale-the-application)
- [Scale the node group](#scale-the-node-group)
- [Update a ConfigMap value](#update-a-configmap-value)
- [Upgrade the EKS cluster version](#upgrade-the-eks-cluster-version)
- [Upgrade the AWS Load Balancer Controller](#upgrade-the-aws-load-balancer-controller)
- [kubectl debugging cheatsheet](#kubectl-debugging-cheatsheet)
- [Incident playbooks](#incident-playbooks)
- [Teardown](#teardown)

---

## Preflight — confirm you're on the right cluster

Before running anything destructive, always verify context:

```bash
kubectl config current-context
kubectl cluster-info
aws sts get-caller-identity
```

If the context is wrong, re-run:

```bash
aws eks update-kubeconfig --region us-east-1 --name k8s-simple-app-eks
# or: $(cd terraform && terraform output -raw kubeconfig_command)
```

## Health checks

One-liner smoke test after any change:

```bash
ALB=$(kubectl -n simple-app get ingress simple-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -fsS "http://$ALB/healthz" && echo OK
curl -fsS "http://$ALB/" | jq .
curl -fsS "http://$ALB/api/items" | jq .
```

Cluster-side:

```bash
kubectl -n simple-app get pods,svc,ingress,deploy
kubectl -n simple-app get pods -o wide                     # pod IPs + node
kubectl -n simple-app rollout status deploy/simple-app
kubectl -n simple-app top pods                             # needs metrics-server
```

ALB target health (from AWS):

```bash
TG_ARN=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(TargetGroupName, 'simple-app')].TargetGroupArn" \
  --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN"
```

## View logs

```bash
# Stream all pods of the deployment
kubectl -n simple-app logs -l app=simple-app -f --tail=100

# Logs from a previous crashed container
kubectl -n simple-app logs -l app=simple-app --previous

# ALB controller logs (for Ingress issues)
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller -f

# EKS control plane logs (if enabled in Terraform)
aws logs tail /aws/eks/k8s-simple-app-eks/cluster --follow
```

## Deploy a new version

**Preferred — tag by Git SHA, never mutate `:latest`:**

```bash
SHA=$(git rev-parse --short HEAD)
ECR_URL=$(cd terraform && terraform output -raw ecr_repository_url)
REGION=$(cd terraform && terraform output -raw region)

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_URL"

docker build --platform linux/amd64 -t "$ECR_URL:$SHA" app/
docker push "$ECR_URL:$SHA"

kubectl -n simple-app set image deploy/simple-app api="$ECR_URL:$SHA"
kubectl -n simple-app rollout status deploy/simple-app --timeout=5m
```

The rolling update config in [k8s/deployment.yaml](k8s/deployment.yaml)
(`maxSurge=1, maxUnavailable=0`) keeps both replicas serving throughout.

**If the rollout stalls,** the readiness probe is failing on the new pods.
Inspect:

```bash
kubectl -n simple-app describe pod -l app=simple-app | tail -40
kubectl -n simple-app logs -l app=simple-app --tail=200
```

Then roll back (next section) while you fix the image.

## Roll back a deployment

```bash
# See revision history
kubectl -n simple-app rollout history deploy/simple-app

# Roll back to the previous revision
kubectl -n simple-app rollout undo deploy/simple-app

# Or to a specific revision
kubectl -n simple-app rollout undo deploy/simple-app --to-revision=3

# Watch
kubectl -n simple-app rollout status deploy/simple-app
```

`revisionHistoryLimit: 5` in [k8s/deployment.yaml](k8s/deployment.yaml) means
only the last 5 revisions are retained — if you need older, restore from Git.

## Restart pods without a code change

Useful after updating a ConfigMap, or to clear process-local state. `envFrom`
does **not** auto-reload — a restart is required.

```bash
kubectl -n simple-app rollout restart deploy/simple-app
kubectl -n simple-app rollout status deploy/simple-app
```

## Scale the application

```bash
# Temporary / manual
kubectl -n simple-app scale deploy/simple-app --replicas=4

# Permanent — edit replicas in k8s/deployment.yaml, then:
kubectl apply -f k8s/deployment.yaml
```

> Declarative edits win: if you `kubectl scale` but leave `replicas: 2` in
> the YAML, the next `kubectl apply` will scale back down. For anything
> lasting, commit the change.

For autoscaling, add an HPA (not included in this repo):

```bash
kubectl -n simple-app autoscale deploy/simple-app --min=2 --max=6 --cpu-percent=70
kubectl -n simple-app get hpa
```

## Scale the node group

Managed by Terraform. Do **not** change desired count in the AWS console —
it drifts.

```bash
# Edit terraform/variables.tf: node_desired_size / node_min_size / node_max_size
cd terraform
terraform plan
terraform apply
```

Watch nodes join:

```bash
kubectl get nodes -w
```

## Update a ConfigMap value

Changes to env vars require a pod restart — `envFrom` does not hot-reload.

```bash
# Edit k8s/configmap.yaml, then:
kubectl apply -f k8s/configmap.yaml
kubectl -n simple-app rollout restart deploy/simple-app
```

## Upgrade the EKS cluster version

EKS supports in-place minor upgrades (e.g. 1.30 → 1.31), one minor at a time.

1. **Check compatibility** — your local `kubectl` should be within one minor
   of the target. App workloads should be tested against deprecated API
   removals ([Kubernetes changelog](https://kubernetes.io/releases/)).
2. **Bump `cluster_version`** in [terraform/variables.tf](terraform/variables.tf).
3. **Apply:**
   ```bash
   cd terraform
   terraform plan          # expect control-plane + addons + node group changes
   terraform apply
   ```
   Control plane upgrade takes ~20 minutes. Node group upgrade rolls nodes one
   at a time, respecting PodDisruptionBudgets (none are defined for this app —
   add one if availability during upgrades matters).
4. **Verify:**
   ```bash
   kubectl get nodes                                  # all Ready, new version
   kubectl -n simple-app rollout status deploy/simple-app
   curl -fsS "http://$ALB/healthz"
   ```

## Upgrade the AWS Load Balancer Controller

Pinned to `v2.8.1` / chart `1.8.1` in [terraform/alb_controller.tf](terraform/alb_controller.tf).
To upgrade:

1. **Update the IAM policy** — the URL in the `data "http" "alb_iam_policy"`
   block is version-pinned. Bump the version in the URL.
2. **Update the chart version** — change `version = "1.8.1"` on the
   `helm_release`.
3. **Apply:**
   ```bash
   cd terraform
   terraform apply
   ```
4. **Verify Ingress reconciliation still works:**
   ```bash
   kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
   kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
   kubectl -n simple-app describe ingress simple-app   # no stale events
   ```

## kubectl debugging cheatsheet

```bash
# Everything in the namespace
kubectl -n simple-app get all

# Why is this pod unhealthy? (events are at the bottom of the output)
kubectl -n simple-app describe pod -l app=simple-app

# Stream logs from every replica
kubectl -n simple-app logs -l app=simple-app -f --tail=100

# Shell into a running pod (read-only FS — writes must go to /tmp)
kubectl -n simple-app exec -it deploy/simple-app -- sh

# Reach the Service from your laptop without the Ingress
kubectl -n simple-app port-forward svc/simple-app 8080:80
curl http://localhost:8080/healthz

# Watch rollouts and recent events
kubectl -n simple-app rollout status deploy/simple-app
kubectl -n simple-app get events --sort-by=.lastTimestamp

# ALB controller logs (if the Ingress has no hostname)
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller -f

# Copy a file out of a pod (e.g. a heap dump from /tmp)
kubectl -n simple-app cp simple-app-abc123:/tmp/heap.out ./heap.out
```

## Incident playbooks

### Pods in `ImagePullBackOff`

**Diagnose:**
```bash
kubectl -n simple-app describe pod -l app=simple-app | grep -A3 -i events
```

**Common causes:**
- Image placeholder never replaced — the tag still reads
  `ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/...`. Rerun the `sed` step from the
  [README](README.md) or use `kubectl set image`.
- Tag doesn't exist in ECR — `aws ecr describe-images --repository-name k8s-simple-app`.
- Nodes lack ECR pull permission — the EKS module attaches
  `AmazonEC2ContainerRegistryReadOnly` by default; verify the node role.

### Pods `CrashLoopBackOff` immediately on start

**Diagnose:**
```bash
kubectl -n simple-app logs -l app=simple-app --previous
```

**Common causes:**
- **Architecture mismatch** (Apple Silicon dev machines) — verify:
  ```bash
  docker image inspect $ECR_URL:$TAG --format '{{.Architecture}}'
  ```
  If `arm64`, rebuild with `--platform linux/amd64`.
- Missing required env var — check ConfigMap keys match what the app
  reads in [app/src/server.js](app/src/server.js).
- Port collision — app listens on `PORT` env var; Deployment exposes 3000.
  Ensure ConfigMap's `PORT` matches `containerPort`.

### Ingress has no hostname after 5 minutes

**Diagnose:**
```bash
kubectl -n simple-app describe ingress simple-app
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
```

**Common causes:**
- **Subnet tags missing** — public subnets must carry
  `kubernetes.io/role/elb=1` and
  `kubernetes.io/cluster/<cluster-name>=shared`. See
  [terraform/vpc.tf](terraform/vpc.tf).
- **IRSA not bound** — `kubectl -n kube-system describe sa aws-load-balancer-controller`
  must show the `eks.amazonaws.com/role-arn` annotation.
- **Controller not running** — `kubectl -n kube-system get deploy aws-load-balancer-controller`.
- **AWS quota** — you've hit the per-region ALB quota. Check Service Quotas.

### ALB returns 502 / 503 even though pods are healthy

**Diagnose:**
```bash
aws elbv2 describe-target-health --target-group-arn "$TG_ARN"
kubectl -n simple-app get endpoints simple-app
```

**Common causes:**
- Readiness probe failing — pods are `Running` but not in Service endpoints.
  Check `/readyz` (returns 503 for the first 3s after boot by design).
- `target-type: ip` but pod security group blocks the ALB — EKS creates a
  shared node SG that should already permit this; verify no custom SG was
  attached.
- All pods terminated at once (e.g. node drain) — scale up or add a
  PodDisruptionBudget.

### `terraform destroy` hangs on subnets / security groups

An orphan ALB (Ingress not deleted before `terraform destroy`) holds ENIs in
the VPC.

**Fix:**
```bash
# Delete the ALB manually
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='<vpc-id>'].LoadBalancerArn" --output text \
  | xargs -n1 aws elbv2 delete-load-balancer --load-balancer-arn

# Wait ~60 seconds for ENIs to detach, then re-run
cd terraform
terraform destroy
```

Prevention: always run the Ingress delete step in [Teardown](#teardown) first.

### `kubectl` returns `Unauthorized`

Your kubeconfig is stale, pointing at a destroyed cluster, or using an
expired role.

```bash
$(cd terraform && terraform output -raw kubeconfig_command)
aws sts get-caller-identity                        # confirm active AWS identity
kubectl auth can-i get pods -n simple-app
```

### Node `NotReady` or disk pressure

```bash
kubectl describe node <node-name> | tail -40
kubectl top nodes
```

- **Disk pressure** — images / logs filling ephemeral storage. The fastest
  fix is to cycle the node (the ASG will replace it):
  ```bash
  kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
  aws ec2 terminate-instances --instance-ids <i-...>
  ```
- **Persistent `NotReady`** — check kubelet logs on the instance via SSM
  Session Manager, or just terminate the instance and let the ASG replace it.

## Teardown

**Order matters.** Delete the Ingress first so the AWS Load Balancer
Controller removes the ALB + its ENIs before Terraform tries to delete the
subnets and security groups they're attached to.

```bash
# 1. Delete the Ingress (ALB goes away; takes ~30s)
kubectl delete -f k8s/ingress.yaml

# 2. Remove the app (Deployment, Service, ConfigMap, namespace)
kubectl delete namespace simple-app

# 3. Destroy the AWS infrastructure
cd terraform
terraform destroy
```

If you skip step 1, `terraform destroy` hangs for ~20 minutes on
`aws_subnet` / `aws_security_group` deletion. See the
[incident playbook](#terraform-destroy-hangs-on-subnets--security-groups) for
the manual cleanup path.

# Deployment Validation

This document is the mandatory validation checklist to run after deploying the AI Gateway to EKS. Every item must pass before the gateway is considered production-ready.

**Prerequisites:** The EKS cluster exists, kubectl is configured, and `$MASTER_KEY` is set in the shell.

---

## 1. Kubernetes Validation

### 1.1 Namespace and Core Resources

```bash
# Namespace exists and has correct labels
kubectl get namespace ai-gateway -o yaml | grep -E "name:|team:|environment:"

# All deployments are available
kubectl get deployments -n ai-gateway
# Expected: litellm  2/2  2  2

# All pods are running (no CrashLoopBackOff, no Pending)
kubectl get pods -n ai-gateway
# Expected: litellm-XXXX  1/1  Running  0  Xm

# Services exist
kubectl get svc -n ai-gateway
# Expected: litellm  ClusterIP  10.x.x.x  <none>  80/TCP
```

### 1.2 ConfigMap and Secret

```bash
# ConfigMap exists and contains config.yaml
kubectl get configmap litellm-config -n ai-gateway
kubectl describe configmap litellm-config -n ai-gateway | grep -A 5 "model_list"

# Secret exists (do not print the value)
kubectl get secret litellm-secrets -n ai-gateway
# Expected: litellm-secrets  Opaque  1  Xm
```

### 1.3 IRSA and ServiceAccount

```bash
# ServiceAccount has IRSA annotation
kubectl get serviceaccount litellm -n ai-gateway -o yaml | grep role-arn
# Expected: eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/ACTUAL_ROLE

# Confirm the ARN is not a placeholder
kubectl get serviceaccount litellm -n ai-gateway -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
# Must NOT contain "ACCOUNT_ID" or "ROLE_NAME"
```

### 1.4 HPA and PDB

```bash
# HPA is active
kubectl get hpa -n ai-gateway
# Expected: TARGETS shows CPU and Memory metrics (not <unknown>)

# PDB is active
kubectl get pdb -n ai-gateway
# Expected: litellm-pdb  1  2  2  True
```

### 1.5 NetworkPolicy

```bash
# NetworkPolicy documents are applied
kubectl get networkpolicy -n ai-gateway
# Expected: 4 policies (default-deny, allow-kube-system, allow-dns-egress, allow-aws-https-egress)
```

---

## 2. Bedrock Validation

### 2.1 Model Access

```bash
# List accessible foundation models
aws bedrock list-foundation-models \
  --region us-east-1 \
  --query 'modelSummaries[?modelId==`anthropic.claude-3-5-sonnet-20241022-v2:0`].{id:modelId,status:modelLifecycle.status}' \
  --output table

# Direct invocation test (bypasses gateway — tests Bedrock access directly)
aws bedrock-runtime invoke-model \
  --region us-east-1 \
  --model-id anthropic.claude-3-haiku-20240307-v1:0 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":50,"messages":[{"role":"user","content":"Say OK"}]}' \
  --content-type application/json \
  --accept application/json \
  /tmp/bedrock-test.json && cat /tmp/bedrock-test.json
# Expected: {"content":[{"type":"text","text":"OK"}], ...}
```

---

## 3. LiteLLM Gateway Validation

### 3.1 Health Check

```bash
# Port-forward to reach the gateway locally
kubectl port-forward svc/litellm 8080:80 -n ai-gateway &
PF_PID=$!

# Health endpoint
curl -s http://localhost:8080/health | python -m json.tool
# Expected: {"status": "healthy", "litellm_version": "1.88.1"}

# List available models
curl -s -H "Authorization: Bearer $MASTER_KEY" \
  http://localhost:8080/v1/models | python -m json.tool
# Expected: {"object":"list","data":[{"id":"claude-sonnet",...},{"id":"claude-haiku",...}]}
```

### 3.2 Chat Completion — Claude Haiku

```bash
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-haiku",
    "messages": [{"role": "user", "content": "Respond with the single word: WORKING"}],
    "max_tokens": 10
  }' | python -m json.tool
# Expected: choices[0].message.content == "WORKING"
```

### 3.3 Chat Completion — Claude Sonnet

```bash
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet",
    "messages": [{"role": "user", "content": "Respond with the single word: WORKING"}],
    "max_tokens": 10
  }' | python -m json.tool
# Expected: choices[0].message.content == "WORKING"
```

### 3.4 Authentication Enforcement

```bash
# Request without Authorization header should return 401
curl -s -o /dev/null -w "%{http_code}" \
  -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-haiku", "messages": [{"role":"user","content":"test"}]}'
# Expected: 401

# Request with wrong key should return 401
curl -s -o /dev/null -w "%{http_code}" \
  -X POST http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer WRONG_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-haiku", "messages": [{"role":"user","content":"test"}]}'
# Expected: 401

kill $PF_PID
```

---

## 4. Ingress (ALB) Validation

```bash
# Check Ingress has an ADDRESS (ALB provisioned)
kubectl get ingress -n ai-gateway
# Expected: ADDRESS column shows an ALB DNS name (not empty)
# e.g. k8s-aigatew-litellm-abc123.us-east-1.elb.amazonaws.com

# If ADDRESS is empty, check ALB controller logs:
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50

# Test HTTPS through the ALB (replace with your actual domain)
curl -s https://ai-gateway.YOUR_DOMAIN.com/health
# Expected: {"status": "healthy"}
```

---

## 5. Security Validation

```bash
# 5.1 Confirm no static AWS credentials in any environment variable
kubectl exec -n ai-gateway deployment/litellm -- env | grep -E "AWS_ACCESS_KEY|AWS_SECRET"
# Expected: No output (IRSA provides credentials via projected service account token, not env vars)

# 5.2 Confirm IRSA token is mounted
kubectl exec -n ai-gateway deployment/litellm -- ls /var/run/secrets/eks.amazonaws.com/serviceaccount/
# Expected: token  (file present)

# 5.3 Confirm pod runs as non-root
kubectl get pod -n ai-gateway -l app=litellm -o jsonpath='{.items[0].spec.securityContext}'
# Expected: runAsNonRoot:true, runAsUser:1000

# 5.4 Confirm NetworkPolicy is blocking unexpected traffic (requires VPC CNI network policy addon)
# This is a manual verification — attempt a connection from a pod in another namespace
kubectl run test-pod --image=curlimages/curl --rm -it --restart=Never \
  --namespace default -- \
  curl -v http://litellm.ai-gateway.svc.cluster.local/health
# Expected: Connection refused (default-deny policy blocks cross-namespace traffic)
```

---

## 6. Validation Summary

After running all checks, record results in this table:

| Check | Expected | Result | Pass/Fail |
|---|---|---|---|
| Namespace labels | Correct labels | | |
| Deployment replicas | 2/2 available | | |
| Pods running | 1/1 Running, 0 restarts | | |
| ConfigMap present | litellm-config exists | | |
| Secret present | litellm-secrets exists | | |
| IRSA annotation real (not placeholder) | Real ARN | | |
| HPA active | CPU/Memory targets visible | | |
| PDB active | minAvailable satisfied | | |
| Bedrock direct invocation | JSON response received | | |
| Gateway health endpoint | `{"status": "healthy"}` | | |
| Claude Haiku via gateway | "WORKING" response | | |
| Claude Sonnet via gateway | "WORKING" response | | |
| Auth enforcement (no key) | 401 response | | |
| Auth enforcement (wrong key) | 401 response | | |
| ALB provisioned | ADDRESS present | | |
| No static credentials | No AWS_ACCESS_KEY in env | | |

**All 16 checks must pass before the gateway is considered production-ready.**

---

## See Also

- [91-troubleshooting.md](91-troubleshooting.md) — Remediation steps for failed checks
- [93-eks-build-plan.md](93-eks-build-plan.md) — Build plan with detailed deployment steps
- [95-irsa-and-iam-design.md](95-irsa-and-iam-design.md) — IRSA configuration and IAM policy

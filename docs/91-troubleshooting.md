# Troubleshooting

This runbook covers the most common failure modes for the enterprise AI Gateway on Amazon EKS. Each section describes symptoms, diagnosis steps, and remediation.

---

## 1. Pod Failures

### 1.1 CrashLoopBackOff — Config Not Mounted

**Symptom:**
```
kubectl get pods -n ai-gateway
NAME                       READY   STATUS             RESTARTS   AGE
litellm-7d9f6c-xxxxx       0/1     CrashLoopBackOff   5          3m
```

**Diagnosis:**
```bash
kubectl logs -n ai-gateway deployment/litellm --previous
# Look for: "No config file found" or "config.yaml not found" or YAML parse errors
```

**Causes and fixes:**

| Cause | Fix |
|---|---|
| `kubernetes/configmap.yaml` not applied | `kubectl apply -f kubernetes/configmap.yaml` |
| ConfigMap exists but has wrong key name | `kubectl describe configmap litellm-config -n ai-gateway` — key must be `config.yaml` |
| Volume mount path wrong in Deployment | Verify `mountPath: /app/config.yaml` and `subPath: config.yaml` in `kubernetes/deployment.yaml` |
| ConfigMap in wrong namespace | `kubectl get configmap -n ai-gateway` — must be in `ai-gateway` namespace |

### 1.2 CrashLoopBackOff — Master Key Missing

**Symptom:**
```
kubectl logs -n ai-gateway deployment/litellm --previous
# Error: "LITELLM_MASTER_KEY not set" or "master_key is required"
```

**Diagnosis:**
```bash
kubectl get secret litellm-secrets -n ai-gateway
# If not found: the secret has not been created

kubectl exec -n ai-gateway deployment/litellm -- env | grep LITELLM_MASTER_KEY
# Should return a value; if empty, the envFrom reference is broken
```

**Fix:**
```bash
# 1. Retrieve the secret value from Secrets Manager
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id ai-gateway-prod/litellm-secrets \
  --query SecretString --output text)

# 2. Create the Kubernetes Secret
kubectl create secret generic litellm-secrets \
  --from-literal=LITELLM_MASTER_KEY=$(echo $SECRET | python -c "import sys,json; print(json.load(sys.stdin)['LITELLM_MASTER_KEY'])") \
  --namespace ai-gateway

# 3. Restart pods
kubectl rollout restart deployment/litellm -n ai-gateway
```

### 1.3 Pod Pending — Insufficient Resources

**Symptom:**
```
kubectl get pods -n ai-gateway
NAME               READY   STATUS    RESTARTS   AGE
litellm-XXXX       0/1     Pending   0          5m
```

**Diagnosis:**
```bash
kubectl describe pod -n ai-gateway litellm-XXXX
# Look for: "Insufficient cpu" or "Insufficient memory" under Events
```

**Fix:**
- Scale up the node group in the EKS console or via:
  ```bash
  aws eks update-nodegroup-config \
    --cluster-name ai-gateway-prod \
    --nodegroup-name ai-gateway-ng \
    --scaling-config minSize=2,maxSize=5,desiredSize=3
  ```
- Or reduce resource requests in `kubernetes/deployment.yaml` if over-provisioned

---

## 2. ALB / Ingress Issues

### 2.1 Ingress ADDRESS Is Empty

**Symptom:**
```
kubectl get ingress -n ai-gateway
NAME      CLASS   HOSTS                          ADDRESS   PORTS   AGE
litellm   alb     ai-gateway.example.com                   80,443  10m
```

**Diagnosis:**
```bash
# Check AWS Load Balancer Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
# Look for: "InvalidConfigurationRequest", "certificate not found", "subnet not found"
```

**Common causes:**

| Cause | Symptom in logs | Fix |
|---|---|---|
| ALB controller not installed | No controller pods | Install via Helm: `helm install aws-load-balancer-controller eks/aws-load-balancer-controller` |
| Wrong IngressClass | `no matching IngressClass` | Verify `ingressClassName: alb` in `kubernetes/ingress.yaml` |
| ACM cert ARN is placeholder | `certificate not found` | Replace `ACCOUNT_ID` and `CERTIFICATE_ID` in `kubernetes/ingress.yaml` |
| No subnets tagged for ALB | `subnet not found` | Tag VPC subnets: `kubernetes.io/role/elb: 1` for public, `kubernetes.io/role/internal-elb: 1` for private |
| ALB controller lacks IAM permissions | `not authorized to perform: elasticloadbalancing:CreateLoadBalancer` | Attach the ALB controller IAM policy to the controller's service account |

### 2.2 HTTPS Returns SSL Error

**Symptom:**
```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

**Diagnosis:**
- ACM certificate is in `PENDING_VALIDATION` state
- Certificate ARN in Ingress does not match the domain

**Fix:**
```bash
# Check certificate status
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERT_ID \
  --query 'Certificate.Status'
# Must be ISSUED, not PENDING_VALIDATION

# If pending, complete DNS validation
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERT_ID \
  --query 'Certificate.DomainValidationOptions'
# Add the CNAME record shown to your DNS provider
```

---

## 3. IRSA / Authentication Issues

### 3.1 Bedrock Returns AccessDenied

**Symptom:**
```
kubectl logs -n ai-gateway deployment/litellm
# Error: AccessDeniedException: User: arn:aws:sts::ACCOUNT_ID:assumed-role/...
#        is not authorized to perform: bedrock:InvokeModel
```

**Diagnosis:**

```bash
# Step 1: Check if the pod is using IRSA or the node role
kubectl exec -n ai-gateway deployment/litellm -- \
  aws sts get-caller-identity
# Expected: ARN should contain the IRSA role name, not the node instance role name

# Step 2: Check if the ServiceAccount has the correct IRSA annotation
kubectl get serviceaccount litellm -n ai-gateway -o jsonpath='{.metadata.annotations}'
# Expected: {"eks.amazonaws.com/role-arn":"arn:aws:iam::ACCOUNT_ID:role/litellm-bedrock-role"}
```

**Causes and fixes:**

| Cause | Fix |
|---|---|
| ServiceAccount ARN is still a placeholder | Replace `ACCOUNT_ID` and `ROLE_NAME` in `kubernetes/serviceaccount.yaml`, re-apply, restart pods |
| OIDC provider not created for the cluster | Run: `eksctl utils associate-iam-oidc-provider --cluster ai-gateway-prod --approve` |
| Trust relationship in IAM role has wrong OIDC issuer | Update trust relationship to match the cluster's OIDC issuer URL |
| IAM role lacks `bedrock:InvokeModel` permission | Add the Bedrock policy to the role (see [95-irsa-and-iam-design.md](95-irsa-and-iam-design.md)) |
| Bedrock model access not enabled | Enable model access in the Bedrock console → Model access |

### 3.2 Secrets Manager Returns AccessDenied

**Symptom:**
```
kubectl logs -n ai-gateway deployment/litellm
# botocore.exceptions.ClientError: AccessDenied reading secret ai-gateway-prod/litellm-secrets
```

**Fix:**
```bash
# Check the IAM policy attached to the IRSA role
aws iam get-role-policy \
  --role-name litellm-bedrock-role \
  --policy-name LiteLLMBedrockPolicy
# Verify secretsmanager:GetSecretValue is allowed for the correct secret ARN
```

---

## 4. Model Access Issues

### 4.1 Model Not Available in Bedrock

**Symptom:**
```
ValidationException: The model ID you specified is not available in your account
```

**Fix:**
1. Open the AWS Console → Amazon Bedrock → Model access
2. Request access for "Claude 3.5 Sonnet" and "Claude 3 Haiku"
3. Wait for access to be granted (typically instant for Anthropic models in us-east-1)
4. Validate:
   ```bash
   aws bedrock list-foundation-models \
     --region us-east-1 \
     --query 'modelSummaries[?contains(modelId, `claude`)].modelId'
   ```

---

## 5. NetworkPolicy Issues

### 5.1 LiteLLM Cannot Reach Bedrock Endpoint

**Symptom:**
```
kubectl logs -n ai-gateway deployment/litellm
# ConnectTimeout: connecting to bedrock-runtime.us-east-1.amazonaws.com
```

**Diagnosis:**
```bash
# Check if VPC CNI network policy enforcement is enabled
kubectl get daemonset aws-node -n kube-system -o yaml | grep NETWORK_POLICY_ENFORCING_MODE
# If not present or value is "standard", network policies may not be enforced
# This means the NetworkPolicies are loaded but not blocking/allowing traffic

# Test connectivity from a pod in the ai-gateway namespace
kubectl exec -n ai-gateway deployment/litellm -- \
  curl -v https://bedrock-runtime.us-east-1.amazonaws.com/ 2>&1 | head -20
```

**Fix for VPC endpoint (recommended for production):**
```bash
# Create a VPC endpoint for Bedrock Runtime to avoid public internet egress
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-XXXXXXXX \
  --service-name com.amazonaws.us-east-1.bedrock-runtime \
  --vpc-endpoint-type Interface \
  --subnet-ids subnet-XXXXXXXX subnet-YYYYYYYY \
  --security-group-ids sg-XXXXXXXX
```

---

## 6. Health Probe Failures

### 6.1 Readiness Probe Failing — Slow Start

**Symptom:**
```
kubectl describe pod -n ai-gateway litellm-XXXX
# Warning  Unhealthy  Readiness probe failed: Get "http://...:4000/health": dial tcp: connect: connection refused
```

**Cause:** LiteLLM takes several seconds to start (loading config, validating models). The readiness probe fires before the server is ready.

**Fix:** Add a `startupProbe` to `kubernetes/deployment.yaml` to give LiteLLM time to initialise before readiness checks begin:

```yaml
startupProbe:
  httpGet:
    path: /health
    port: 4000
  failureThreshold: 30
  periodSeconds: 5
# This gives LiteLLM 150 seconds (30 × 5s) to start before readiness takes over
```

---

## 7. Quick Diagnostics Script

Run this script for a fast status overview:

```bash
echo "=== Pods ==="
kubectl get pods -n ai-gateway

echo "=== ConfigMap ==="
kubectl get configmap litellm-config -n ai-gateway

echo "=== Secret ==="
kubectl get secret litellm-secrets -n ai-gateway

echo "=== Ingress ==="
kubectl get ingress -n ai-gateway

echo "=== HPA ==="
kubectl get hpa -n ai-gateway

echo "=== Recent Events ==="
kubectl get events -n ai-gateway --sort-by='.lastTimestamp' | tail -20

echo "=== Pod Logs (last 50 lines) ==="
kubectl logs -n ai-gateway deployment/litellm --tail=50
```

---

## See Also

- [90-testing.md](90-testing.md) — Validation checklist to run after deployment
- [95-irsa-and-iam-design.md](95-irsa-and-iam-design.md) — IRSA configuration and IAM policy
- [93-eks-build-plan.md](93-eks-build-plan.md) — Step-by-step build plan with expected outputs

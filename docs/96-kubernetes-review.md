# Kubernetes Manifest Review

**Review Date:** 2026-06-11
**Reviewer Role:** Kubernetes Platform Engineer
**Scope:** `kubernetes/namespace.yaml`, `kubernetes/deployment.yaml`, `kubernetes/service.yaml`, `kubernetes/ingress.yaml`
**Target Environment:** Amazon EKS
**Review Method:** Static analysis of manifest content

---

## Executive Finding

**All four Kubernetes manifest files are empty.**

```
kubernetes/namespace.yaml   — 0 bytes
kubernetes/deployment.yaml  — 0 bytes
kubernetes/service.yaml     — 0 bytes
kubernetes/ingress.yaml     — 0 bytes
```

The files exist in the repository as placeholder stubs. No Kubernetes configuration has been authored. The manifests cannot be applied to a cluster in their current state. All review criteria that depend on manifest content return a finding of **Not Present**.

---

## Deployment Readiness Score

**Score: 10 / 100**

The 10 points are awarded for:
- Correct file naming convention (`namespace`, `deployment`, `service`, `ingress`) — 5 points
- Correct directory structure (`kubernetes/`) — 5 points

All other scoring criteria return zero due to empty file content.

| Category | Max Score | Actual Score | Reason |
|----------|-----------|--------------|--------|
| Namespace definition | 10 | 0 | File empty |
| Deployment configuration | 25 | 0 | File empty |
| Service configuration | 15 | 0 | File empty |
| Ingress configuration | 15 | 0 | File empty |
| Security context | 10 | 0 | File empty |
| Health probes | 10 | 0 | File empty |
| Resource requests/limits | 10 | 0 | File empty |
| File structure and naming | 5 | 5 | Correct |
| Directory organization | 5 | 5 | Correct |
| **Total** | **100** | **10** | |

---

## Findings

### FIND-001 — All manifests are empty (Critical)

**File:** All four files
**Severity:** Critical
**Description:** No Kubernetes manifest content has been authored. The files cannot be applied. `kubectl apply -f kubernetes/` will produce no resources.
**Risk:** The gateway cannot be deployed to any Kubernetes cluster using these manifests.

---

### FIND-002 — Namespace not defined (Critical)

**File:** `kubernetes/namespace.yaml`
**Severity:** Critical
**Description:** No namespace resource is defined. All other manifests will fail to reference a consistent namespace. Workloads will be deployed to the `default` namespace if namespace references are not explicit.

**Expected minimum content:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ai-gateway
  labels:
    app.kubernetes.io/name: ai-gateway
    app.kubernetes.io/managed-by: kubectl
```

---

### FIND-003 — No deployment configuration (Critical)

**File:** `kubernetes/deployment.yaml`
**Severity:** Critical
**Description:** No Deployment resource is defined. LiteLLM cannot be scheduled on the cluster.

**Expected minimum configuration includes:**
- `apiVersion: apps/v1`
- `kind: Deployment`
- Namespace reference (`ai-gateway`)
- Label selectors matching the Service selector
- Container image reference with explicit tag (not `latest`)
- Resource requests and limits
- Liveness and readiness probes
- Security context (`runAsNonRoot: true`, `readOnlyRootFilesystem: true`)
- Environment variable references to Secrets Manager or Kubernetes Secrets

---

### FIND-004 — No Service configuration (High)

**File:** `kubernetes/service.yaml`
**Severity:** High
**Description:** No Service resource is defined. The LiteLLM pods cannot receive traffic from the ALB Target Group or from internal consumers.

**Expected minimum content:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: ai-gateway
spec:
  selector:
    app: litellm
  ports:
    - protocol: TCP
      port: 80
      targetPort: 4000
  type: ClusterIP
```

---

### FIND-005 — No Ingress configuration (High)

**File:** `kubernetes/ingress.yaml`
**Severity:** High
**Description:** No Ingress resource is defined. The AWS Load Balancer Controller cannot provision an ALB for the gateway.

**Expected minimum content for AWS ALB Ingress:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: litellm-ingress
  namespace: ai-gateway
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: <ACM_CERTIFICATE_ARN>
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: litellm
                port:
                  number: 80
```

---

### FIND-006 — No container image specified (Critical)

**File:** `kubernetes/deployment.yaml`
**Severity:** Critical
**Description:** No container image reference exists. A specific LiteLLM image tag must be pinned. Using `latest` is an anti-pattern in production deployments — it produces non-deterministic rollouts and cannot be reliably rolled back.

**Recommended:** `ghcr.io/berriai/litellm:main-v1.x.x` with a pinned semantic version tag.

---

### FIND-007 — No resource requests or limits (High)

**File:** `kubernetes/deployment.yaml`
**Severity:** High
**Description:** No CPU or memory requests/limits are defined. Without requests, the Kubernetes scheduler cannot make informed placement decisions. Without limits, a single pod can consume unbounded node resources, causing node pressure and evictions affecting other workloads.

**Recommended starting values (tune based on observed usage):**
```yaml
resources:
  requests:
    cpu: "250m"
    memory: "512Mi"
  limits:
    cpu: "1000m"
    memory: "1Gi"
```

---

### FIND-008 — No health probes defined (High)

**File:** `kubernetes/deployment.yaml`
**Severity:** High
**Description:** No liveness or readiness probes are defined. Without probes:
- Kubernetes cannot detect a crashed or deadlocked LiteLLM process and will not restart it
- The Service will route traffic to pods that are not yet ready to serve requests, causing request failures during startup and rollout

**Recommended probes for LiteLLM:**
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 4000
  initialDelaySeconds: 30
  periodSeconds: 30
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /health
    port: 4000
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 3
```

---

### FIND-009 — No security context defined (High)

**File:** `kubernetes/deployment.yaml`
**Severity:** High
**Description:** No pod or container security context is defined. Running containers without security constraints violates the principle of least privilege and fails most enterprise security benchmarks (CIS Kubernetes Benchmark, NSA Kubernetes Hardening Guidance).

**Recommended security context:**
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 2000
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
```

---

### FIND-010 — No HorizontalPodAutoscaler defined (Medium)

**File:** Missing — no `hpa.yaml` exists
**Severity:** Medium
**Description:** The architecture documentation references horizontal scaling as a design requirement. No HPA manifest is present in the `kubernetes/` directory. Without HPA, the gateway cannot scale pod count in response to request load.

**Recommended:** Add `kubernetes/hpa.yaml` with CPU utilization target:
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: litellm-hpa
  namespace: ai-gateway
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: litellm
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

## Additional Missing Configurations

Beyond the top 10 findings, the following configurations are absent and should be addressed before production deployment:

| Missing Configuration | Severity | Description |
|-----------------------|----------|-------------|
| ServiceAccount manifest | High | IRSA requires a named Kubernetes ServiceAccount with the `eks.amazonaws.com/role-arn` annotation |
| Pod Disruption Budget | Medium | Prevents all replicas being terminated simultaneously during node drains or cluster upgrades |
| NetworkPolicy | Medium | No network policy restricts pod-to-pod or pod-to-external traffic within the cluster |
| ConfigMap for LiteLLM config | Medium | The `litellm/config.yaml` should be mounted via a ConfigMap rather than baked into the image |
| TopologySpreadConstraints | Medium | Pods should be spread across availability zones to avoid single-AZ failures |
| PodAntiAffinity | Low | Prevents multiple replicas from scheduling on the same node |
| ImagePullPolicy | Low | Should be set to `IfNotPresent` for pinned tags; `Always` for mutable tags |
| TerminationGracePeriodSeconds | Low | Default 30s may be insufficient for in-flight LLM requests; consider 60–120s |

---

## Risks

| Risk | Probability | Impact | Description |
|------|-------------|--------|-------------|
| Deployment failure | Certain | Critical | Manifests cannot be applied in current state |
| Uncontrolled resource consumption | High | High | No limits — single pod can exhaust node resources |
| Traffic routed to unhealthy pods | High | High | No readiness probes — ALB will send traffic before pod is ready |
| Privileged container execution | High | High | No security context — containers may run as root |
| Non-deterministic image versions | High | Medium | No image tag pinned — `latest` produces unpredictable rollout behavior |
| No credential isolation | High | Critical | No ServiceAccount/IRSA configured — Bedrock access will fail |
| Single point of failure | High | High | No HPA or PDB — one pod, no protection from eviction |

---

## Recommended Improvement Priority

**Priority 1 — Required before any cluster deployment:**
1. Author `namespace.yaml` with namespace `ai-gateway` and standard labels
2. Author `deployment.yaml` with pinned image, namespace, selector labels, resource limits, probes, and security context
3. Author `service.yaml` with ClusterIP type, port 4000, and selector matching deployment labels
4. Author `ingress.yaml` with AWS ALB annotations and HTTPS listener
5. Add `serviceaccount.yaml` with IRSA annotation for Bedrock and Secrets Manager access

**Priority 2 — Required before production:**
6. Add `hpa.yaml` for horizontal scaling
7. Add `pdb.yaml` (PodDisruptionBudget) for availability during node maintenance
8. Add `networkpolicy.yaml` to restrict ingress/egress
9. Mount LiteLLM config via ConfigMap rather than environment variables
10. Add `TopologySpreadConstraints` for multi-AZ pod distribution

---

## AWS and EKS Compatibility Notes

The following EKS-specific requirements must be satisfied for a production deployment:

- **AWS Load Balancer Controller** must be installed on the cluster for ALB Ingress to function. The `alb` ingress class annotation will be ignored without this controller.
- **IRSA** (IAM Roles for Service Accounts) requires the EKS cluster to have an OIDC provider configured and a matching IAM role with a trust policy referencing the Kubernetes ServiceAccount.
- **Target type** for ALB must be set to `ip` (not `instance`) when using the AWS CNI with VPC-native pod networking.
- **ACM certificate ARN** must be provided in the Ingress annotation for HTTPS termination at the ALB.
- **Security Group** for the ALB must allow inbound HTTPS (443) from CloudFront or the WAF origin IP ranges.

---

## Summary

The Kubernetes manifests in this repository are empty placeholder files. They establish the correct directory structure and file naming, but contain no deployable configuration. The repository documentation describes a complete architecture, but the Kubernetes layer — the component responsible for actually running LiteLLM on EKS — has not been implemented.

**Authoring the manifests is the highest-priority action required to move this project from documentation to a deployable state.**

All manifest content described in this review (namespace, deployment, service, ingress, HPA, PDB, NetworkPolicy, ServiceAccount) should be authored, tested with `kubectl apply --dry-run=client`, and validated with a tool such as `kubeval` or `kube-score` before cluster deployment.

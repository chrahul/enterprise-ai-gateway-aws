# Install LiteLLM on Amazon EKS

## 4.1 Introduction

### What Are We Going To Do?

In this chapter, we will deploy LiteLLM on the Amazon EKS cluster created in the previous chapter.

By the end of this chapter, we will have:

```text
Amazon EKS
    |
    +-- LiteLLM Pod
```

The AI Gateway will be running, but it will not yet be connected to Amazon Bedrock or any external LLM provider.

## 4.2 What is LiteLLM?

### The Problem

Without LiteLLM:

```text
Application A --> OpenAI

Application B --> Claude

Application C --> Bedrock
```

Every application needs to understand every model provider.

This creates:

- Vendor lock-in
- Duplicate integrations
- Complex maintenance

### The Solution

LiteLLM provides a unified API.

```text
Applications
      |
      v
    LiteLLM
      |
      +---- OpenAI
      +---- Claude
      +---- Bedrock
```

### Why LiteLLM Exists

> LiteLLM exists because without it, every application must integrate separately with every LLM provider.

## 4.3 Architecture After This Chapter

Current Architecture:

```text
Amazon EKS
```

Target Architecture:

```text
Amazon EKS
    |
    +-- LiteLLM Deployment
            |
            +-- LiteLLM Pod
```

## 4.4 Create Kubernetes Namespace

Create:

```text
kubernetes/namespace.yaml
```

Example:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ai-gateway
```

Apply:

```bash
kubectl apply -f kubernetes/namespace.yaml
```

Verify:

```bash
kubectl get ns
```

### Why Namespace Exists

> Namespace exists because without it, all workloads are deployed into the default namespace, making management difficult.

## 4.5 Create LiteLLM Configuration

Create:

```text
litellm/config.yaml
```

Initial version:

```yaml
model_list: []
```

We are only deploying LiteLLM first.

Model integrations will be added later.

## 4.6 Create LiteLLM Deployment

Create:

```text
kubernetes/deployment.yaml
```

Key Concept:

```yaml
replicas: 2
```

Why 2 replicas?

```text
1 Replica = Single Point of Failure

2 Replicas = High Availability
```

### Why Deployment Exists

> Deployment exists because without it, Kubernetes cannot maintain the desired number of running LiteLLM instances.

## 4.7 Create Kubernetes Service

Create:

```text
kubernetes/service.yaml
```

Purpose:

Expose LiteLLM inside the cluster.

### Why Service Exists

> Service exists because without it, pods receive dynamic IP addresses and applications cannot reliably locate them.

## 4.8 Deploy LiteLLM

Deploy resources:

```bash
kubectl apply -f kubernetes/namespace.yaml

kubectl apply -f kubernetes/deployment.yaml

kubectl apply -f kubernetes/service.yaml
```

## 4.9 Verify Deployment

Check Pods:

```bash
kubectl get pods -n ai-gateway
```

Check Deployment:

```bash
kubectl get deployment -n ai-gateway
```

Check Service:

```bash
kubectl get svc -n ai-gateway
```

Expected:

```text
2 Pods

1 Deployment

1 Service
```

## 4.10 Test Self-Healing

Delete a Pod:

```bash
kubectl delete pod <pod-name> -n ai-gateway
```

Observe:

```text
Pod Deleted
      |
      v
Kubernetes Detects Failure
      |
      v
New Pod Created
```

### Why This Matters

> Kubernetes exists because without self-healing, service recovery would require manual intervention.

## 4.11 Summary

At this point:

### Completed

```text
[x] EKS Cluster

[x] Namespace

[x] LiteLLM Deployment

[x] Service

[x] High Availability

[x] Self-Healing
```

### Not Yet Completed

```text
[ ] Amazon Bedrock Integration

[ ] Claude Access

[ ] API Gateway

[ ] OpenAI Integration

[ ] Multi-Model Routing
```

### Current Architecture

```text
EKS Cluster
     |
     +-- LiteLLM
```

### Next Chapter

In the next chapter, we will connect LiteLLM to Amazon Bedrock and invoke Claude through the AI Gateway for the first time.

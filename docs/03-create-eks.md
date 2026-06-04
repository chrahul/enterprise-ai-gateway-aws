# Create Amazon EKS Cluster

This chapter creates the Kubernetes platform that will later host the Enterprise AI Gateway.

We are not installing LiteLLM yet. We are not connecting to Amazon Bedrock yet. We are first creating the compute foundation that will run the gateway.

## 3.1 Why Kubernetes for an AI Gateway?

Problem First

A simple deployment might start with one virtual machine running LiteLLM.

```text
VM
 |
 LiteLLM
```

This approach can work for a quick demo, but it becomes risky for an enterprise AI gateway.

Problems:

- Single point of failure
- Manual scaling
- Difficult upgrades
- Difficult rollback

An AI Gateway is not just another backend service. It becomes the shared entry point for many applications that need model access. If the gateway is unavailable, every application depending on it is affected.

Kubernetes gives us a better operating model.

```text
Kubernetes
 |
 + Multiple LiteLLM Pods
 |
 + Self Healing
 |
 + Scaling
```

Amazon EKS exists because without it, running production-grade AI services becomes operationally difficult.

For this tutorial, EKS gives us the platform where LiteLLM can run, scale and recover like a real enterprise service.

## 3.2 Why Amazon EKS?

Kubernetes has two major parts:

- The control plane
- The worker nodes

The control plane is the brain of the cluster. It decides where workloads run, tracks cluster state and responds when something fails.

### Self Managed Kubernetes

With self managed Kubernetes, you manage:

```text
API Server
etcd
Scheduler
Networking
Certificates
Upgrades
```

This gives full control, but it also creates operational responsibility. You must secure, patch, back up and upgrade the control plane yourself.

### Amazon EKS

With Amazon EKS, AWS manages:

```text
Control Plane
```

You manage:

```text
Worker Nodes
Applications
```

AWS manages the brain. We manage the workers.

That is why EKS is a strong fit for this tutorial. We can focus on deploying the AI Gateway while AWS manages the Kubernetes control plane.

## 3.3 Architecture After This Chapter

At the end of this chapter, the AWS account will contain an EKS cluster and worker nodes.

```text
AWS Account

+-------------+
| Amazon EKS  |
+------+------+
       |
       v
 Worker Nodes
```

At the end of this chapter we will have a working Kubernetes cluster ready to host LiteLLM.

## 3.4 AWS Prerequisites Validation

Before creating the cluster, validate that your local environment is connected to AWS and has the required tools.

Check the active AWS identity:

```bash
aws sts get-caller-identity
```

Why this matters:

This confirms that the AWS CLI is authenticated and shows which AWS account, user or role will create the cluster.

Check `eksctl`:

```bash
eksctl version
```

Why this matters:

`eksctl` is the command-line tool that creates the EKS cluster and supporting AWS resources.

Check `kubectl`:

```bash
kubectl version --client
```

Why this matters:

`kubectl` is used to connect to the Kubernetes cluster after it is created.

If any of these commands fail, return to [02-prerequisites.md](02-prerequisites.md) before continuing.

## 3.5 Create Cluster Configuration File

Create a file named:

```text
eks-cluster.yaml
```

Use the following configuration:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ai-gateway-cluster
  region: us-east-1
  version: "1.30"

managedNodeGroups:
  - name: ai-gateway-workers
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 3
    volumeSize: 20
```

The cluster name is intentionally aligned with the project:

```text
ai-gateway-cluster
```

This makes the AWS resources easier to identify later.

## 3.6 Understanding Every Field

Do not treat the configuration file as copy and paste magic. Each field exists for a reason.

| Field           | Why It Exists           |
| --------------- | ----------------------- |
| name            | Unique cluster identity |
| region          | Deployment location     |
| version         | Kubernetes version      |
| instanceType    | Worker node size        |
| desiredCapacity | Number of workers       |
| volumeSize      | Node storage            |

### What breaks without it?

`name` exists because without a unique cluster identity, it becomes difficult to manage, find and clean up the correct resources.

`region` exists because AWS services are regional. Bedrock model availability, EKS resources and networking must be created in a selected AWS region.

`version` exists because Kubernetes behavior changes between versions. Pinning a version makes the tutorial more predictable.

`instanceType` exists because without sufficient CPU and memory, LiteLLM pods cannot run reliably.

`desiredCapacity` exists because a single worker node creates a fragile platform. Multiple workers make the cluster more resilient for lab testing.

`volumeSize` exists because worker nodes need disk space for container images, logs and runtime data.

## 3.7 Create the Cluster

Create the cluster with:

```bash
eksctl create cluster -f eks-cluster.yaml
```

This command can take several minutes.

Behind the scenes, AWS creates more than just a Kubernetes cluster.

AWS creates:

- VPC
- Subnets
- Route Tables
- Security Groups
- IAM Roles
- Node Groups
- Auto Scaling Groups

This is important to understand. EKS is not a single resource. It is a managed Kubernetes control plane connected to AWS networking, compute and identity resources.

When the command completes, `eksctl` also updates your local kubeconfig so `kubectl` can communicate with the new cluster.

## 3.8 Verify Cluster

After the cluster is created, verify that Kubernetes is reachable.

Check worker nodes:

```bash
kubectl get nodes
```

Expected result:

You should see worker nodes in a `Ready` state.

Check all pods across namespaces:

```bash
kubectl get pods -A
```

Expected result:

You should see system pods running in namespaces such as `kube-system`.

Check cluster information:

```bash
kubectl cluster-info
```

Expected result:

You should see the Kubernetes control plane endpoint and related cluster information.

## 3.9 What We Just Built

At this point, the architecture looks like this:

```text
User
 |
 Nothing Yet
 |
 EKS Cluster Ready
```

We have NOT deployed LiteLLM.

We have NOT deployed Bedrock integration.

We have NOT created API Gateway.

We have only built the platform that will host them.

This distinction matters because EKS is the operating layer. The AI Gateway will be deployed on top of it in the next chapter.

## 3.10 Cost Awareness

### Current Running Costs

After creating the cluster, AWS resources begin generating cost.

Current cost areas:

```text
EKS Control Plane
Worker Nodes
Storage
```

The EKS control plane has an hourly cost. Worker nodes are EC2 instances and are billed based on instance type and runtime. Storage attached to worker nodes also contributes to cost.

Do not leave the cluster running longer than needed for the lab.

## 3.11 Summary

Progress checklist:

```text
[x] EKS Cluster Created

[x] Worker Nodes Running

[x] kubectl Connected

[x] Kubernetes Ready

[ ] LiteLLM Not Yet Installed

[ ] Bedrock Not Yet Connected

[ ] API Gateway Not Yet Created
```

In this chapter, we created the Kubernetes platform for the Enterprise AI Gateway.

In the next chapter, we will install LiteLLM on EKS and bring the AI Gateway layer to life.

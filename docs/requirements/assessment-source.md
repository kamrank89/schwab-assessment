# End-to-End Architecture Write-Up

## GCP Project with Two GKE Clusters, Two Web Applications, Multi-Pod Deployment, and Full Observability

## Assessment Deliverables

- Working cluster with an accessible application endpoint
- Screenshot or export of the Grafana dashboard
- Sample BigQuery queries demonstrating log analysis
- Troubleshooting scenario documenting one issue encountered and how it was resolved

> **Note:** You can skip steps for features that are not available in the GCP free tier.

## 1. Project Structure and Governance

A new GCP project is provisioned following organizational guardrails and landing-zone standards. Key components include:

### Project-Level Configuration

- Resource hierarchy (Folder → Project)
- IAM roles for Dev, Ops, SRE, and CI/CD
- VPC creation with segregated subnets for GKE, load balancers, and monitoring/operations
- Centralized logging and monitoring sinks (Cloud Logging and Cloud Monitoring)

### Networking

- Shared VPC (optional) if the enterprise networking team centrally manages ingress and egress
- Private Service Access for Google APIs
- Cloud NAT for outbound internet egress from clusters
- Firewall rules for cluster node pools and services

## 2. GKE Cluster Architecture

Two Google Kubernetes Engine clusters are deployed to support high availability, environment separation, or region-based redundancy.

### Cluster 1 (Primary Example)

- **Region:** `us-central1`
- **Mode:** GKE Standard or Autopilot, depending on the operational model
- **Node pools:**
  - General-purpose pool for web workloads
  - Optional separate pool for system workloads, such as ingress or a service mesh

### Cluster 2 (Secondary Example)

- **Region:** `us-east1` or another disaster recovery region
- Uses the same node-pool and configuration pattern to maintain symmetry
- Can be used for:
  - Active/active deployment
  - Active/passive failover
  - Blue/green or canary deployments

### Cluster Networking

- VPC-native clusters using alias IP ranges
- Dedicated subnet per cluster, such as `gke-primary-subnet` and `gke-secondary-subnet`
- Cloud DNS for internal and external records
- Internal load balancers for east-west communication

## 3. Application Deployment Design

Two independent web applications are deployed to both clusters.

### Web Application A

- Stateless microservice
- Deployment with multiple pods using a ReplicaSet or Deployment
- Configuration stored in ConfigMaps and Secrets
- Horizontal Pod Autoscaling (HPA) configured based on CPU or custom metrics

### Web Application B

- Stateless application that can use GCP services such as Pub/Sub, Cloud SQL, or Memorystore (Redis)
- Replicated across clusters to ensure resilience

### Ingress and Traffic Distribution

Depending on the global strategy, use a global external HTTPS load balancer:

- Uses Multi-cluster Ingress (MCI) or Multi-cluster Services (MCS)
- Provides a single global IP that routes traffic to the nearest healthy cluster
- Uses health checks to ensure cluster failover

### Inter-Service Communication

- Service mesh (Anthos Service Mesh is optional)
  - Mutual TLS
  - Traffic shaping for canary and blue/green deployments
  - Distributed tracing hooks

## 4. Customer Traffic: End-to-End Flow

The following steps describe how external customer traffic reaches the web applications.

### Step 1: DNS Resolution

- A customer visits `https://www.yourapp.com`.
- Cloud DNS records map the domain to the global load balancer IP.

### Step 2: Global Load Balancer

- The customer's request reaches the Google global load balancer.
- The load balancer performs:
  - SSL termination at the edge
  - URI-based routing, if needed
  - Web Application Firewall (Cloud Armor) threat inspection
  - Geographic load balancing across clusters

### Step 3: Traffic Routing to GKE Clusters

- The load balancer forwards traffic to cluster-specific Network Endpoint Groups (NEGs).
- Multi-cluster Ingress provides:
  - Proximity routing to the closest cluster
  - Failover if a cluster is unavailable

### Step 4: GKE Ingress Controller

- The cluster ingress controller (GKE Ingress, NGINX, or ASM Ingress) receives the request.
- It forwards the request to the appropriate Kubernetes Service.

### Step 5: Service to Pods

- A Kubernetes Service (`ClusterIP`, or `NodePort` behind a NEG) load-balances traffic across multiple pods.
- Pod replicas provide:
  - Resilience
  - Horizontal scaling
  - Rolling updates with zero downtime

### Step 6: Application Response

- The application processes the request.
- The response flows back through the following path:

  `Pods → Service → Ingress → Load Balancer → Customer`

- Latency, logs, and traces are collected automatically.

## 5. Observability: Logging, Monitoring, and Tracing

An end-to-end observability stack is implemented using GCP-native capabilities.

### Cloud Logging

- Container logs collected through the GKE logging agent
- Ingress, load balancer, VPC, and firewall logs
- Centralized logging bucket or export to a SIEM

### Cloud Monitoring

- Metrics for:
  - Pod CPU and memory usage
  - Node health
  - HPA scaling events
  - Ingress and load balancer metrics, including latency, 5xx responses, and request volumes

### Observability with BigQuery and Grafana

- Configure Cloud Logging to export logs to BigQuery.
- Set up log exports for:
  - Application logs
  - GKE cluster logs, including control-plane and node logs
- Use cloud-hosted Grafana.
- Create a Grafana dashboard with at least four panels:
  - Application error rates over time, queried from BigQuery
  - Pod restart counts by namespace
  - Request latency percentiles (p50, p95, and p99)
  - Resource utilization trends (CPU and memory)

### Cloud Trace

- Provides distributed tracing across services
- Shows the latency breakdown for each hop

### Cloud Profiler

- Provides CPU and memory profiling for live applications

### Error Reporting

- Automatically aggregates application exceptions

### Optional Enhancements

- Prometheus and Grafana through Managed Service for Prometheus
- Anthos Service Mesh telemetry
- Uptime checks and synthetic monitoring

## 6. High Availability and Disaster Recovery

- Two GKE clusters provide cross-regional redundancy.
- Multi-cluster Ingress provides automatic failover.
- State can be handled through cross-regional storage services, including:
  - Cloud SQL high availability
  - Memorystore replication
  - Firestore multi-region
- Backups include:
  - Cloud SQL automated backups and point-in-time recovery
  - GKE `etcd` backups
  - Artifact Registry backup policies

## 7. Security

- Workload Identity for secure service-account mapping
- Secrets managed through Secret Manager
- Private GKE clusters (optional)
- Cloud Armor WAF rules
- Binary Authorization for image attestation

## 8. Deliverables

- Infrastructure as Code using Terraform to reproduce the entire setup
- Documentation that includes:
  - Architecture diagram
  - Step-by-step setup instructions
  - BigQuery schema and sample queries used in Grafana
  - Design decisions and rationale

## 9. Summary

This project delivers:

- A new GCP project
- Two GKE clusters for high availability or a multi-region strategy
- Two web applications deployed with scalable, multi-pod replicas
- Global load balancing with intelligent traffic distribution
- Full observability across logs, metrics, traces, and errors
- Built-in security, resilience, and compliance controls

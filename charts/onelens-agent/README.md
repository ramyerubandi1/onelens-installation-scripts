# OneLens Agent Helm Chart

This Helm chart provides the configuration for deploying the OneLens Agent in Kubernetes environments. It builds upon the OneLens Agent Base chart and includes additional components like Prometheus and OpenCost.

## Overview

The OneLens Agent chart serves as a comprehensive solution for deploying and managing OneLens agents in your Kubernetes cluster. This chart handles the deployment, configuration, and service setup required for the agent to operate effectively, along with supporting monitoring and cost analysis tools.

## Versioning

The chart follows semantic versioning (MAJOR.MINOR.PATCH) with additional pre-release identifiers when needed (e.g., `-beta.3`). Version information is maintained in the `Chart.yaml` file.

## Working with the Helm Chart

### Prerequisites

- Helm 3.x installed
- AWS CLI configured with appropriate permissions
- Access to AWS ECR repository

### Dependencies

This chart includes the following dependencies:
- OneLens Agent Base (from ECR)
- Prometheus (from Prometheus Community Helm charts)
- Prometheus OpenCost Exporter (from Prometheus Community Helm charts)

### Installing Dependencies

Before packaging the chart, update the dependencies:

```bash
# Navigate to the chart directory
cd onelens-agent/helm-chart/onelens-agent

# Update dependencies
helm dependency update
```

### Packaging the Chart

To create a packaged version of the chart:

```bash
# Navigate to the chart directory
cd onelens-agent/helm-chart/onelens-agent

# Create a packages directory if it doesn't exist
mkdir -p packages

# Package the chart
helm package . -d packages/
```
> **Note**: This will create a `.tgz` file in the packages directory, e.g., `packages/onelens-agent-0.0.1-beta.5.tgz`.
> After successfully pushing to ECR, you must delete the local package file.

### Publishing to AWS ECR

1. **Login to AWS Public ECR**:

```bash
aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws
```

2. **Push the chart to Public ECR**:

```bash
helm push packages/onelens-agent-<version>.tgz oci://public.ecr.aws/w7k6q5m9/helm-charts
```

Example:
```bash
helm push packages/onelens-agent-0.0.1-beta.4.tgz oci://public.ecr.aws/w7k6q5m9/helm-charts
```

### Pulling the Chart from ECR

To download a chart from Public ECR:

```bash
helm pull oci://public.ecr.aws/w7k6q5m9/helm-charts/onelens-agent --version <version>
```

Example:
```bash
helm pull oci://public.ecr.aws/w7k6q5m9/helm-charts/onelens-agent --version 0.0.1-beta.4
```

## Configuration

The chart can be configured through the `values.yaml` file. Key configuration sections include:

- OneLens Agent settings
- Prometheus configuration
- OpenCost exporter settings

See the `values.yaml` file for detailed configuration options.

## Troubleshooting

- If you encounter a 404 error when pushing, ensure the repository exists in ECR
- Make sure to use the correct path format when pushing to or pulling from ECR
- Verify that you have the necessary permissions to push to and pull from the ECR repository

## Additional Resources

For more information on using Helm, run:
```bash
helm --help
```

For OneLens Agent documentation, visit the OneLens documentation portal.

## Deploying the Chart

### Prerequisites

- Helm 3.x installed
- AWS CLI configured with appropriate permissions
- Access to AWS ECR repository

### Deploying the Chart

Login to AWS ECR:
```bash
aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws
```

Upgrade the chart:
```bash
helm upgrade --install onelens-agent -n onelens-agent --create-namespace oci://public.ecr.aws/w7k6q5m9/helm-charts/onelens-agent --version <chart-version> \
    --set onelens-agent.env.CLUSTER_NAME="<cluster-name>" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId="<cluster-name>" \
    --set onelens-agent.env.TENANT_NAME="<tenant-name>" \
    --set onelens-agent.env.ACCOUNT_ID="<account-id>" \
    --set onelens-agent.env.AWS_CLUSTER_REGION="<aws-cluster-region>" \
    --set onelens-agent.env.S3_BUCKET_NAME="<s3-bucket-name>" \
    --set onelens-agent.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::<account-id>:role/<role-name>" \
    --set onelens-agent.image.tag="<image-version>" 
```

Sample run:
```bash
helm upgrade --install onelens-agent -n onelens-agent --create-namespace oci://public.ecr.aws/w7k6q5m9/helm-charts/onelens-agent --version 0.0.1-beta.5 \
    --set onelens-agent.env.CLUSTER_NAME="prod-ap-south-1-clickhouse-cluster" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId="prod-ap-south-1-clickhouse-cluster" \
    --set onelens-agent.env.TENANT_NAME="dhan" \
    --set onelens-agent.env.ACCOUNT_ID=\"471112871310\" \
    --set onelens-agent.env.AWS_CLUSTER_REGION="ap-south-1" \
    --set onelens-agent.env.S3_BUCKET_NAME="onelens-kubernetes-agent" \
    --set onelens-agent.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::609916866699:role/onelens-kubernetes-agent-role-dhan" \
    --set onelens-agent.image.repository="public.ecr.aws/w7k6q5m9/onelens-agent" \
    --set onelens-agent.image.tag="v0.0.1-beta.5"
```

### Troubleshooting

```bash
Error: 1 error occurred:
        * ConfigMap in version "v1" cannot be handled as a ConfigMap: json: cannot unmarshal number into Go struct field ConfigMap.data of type string
```

This error occurs because the `ACCOUNT_ID` is being set as a number instead of a string.

To fix this, set the `ACCOUNT_ID` as a string:
```bash
--set onelens-agent.env.ACCOUNT_ID=\"471112871310\"
```
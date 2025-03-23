#!/bin/sh
set -eux

# Install dependencies
apk add --no-cache \
    curl \
    tar \
    gzip \
    bash \
    git \
    unzip \
    wget \
    jq \
    less \
    groff \
    python3 \
    py3-pip


RELEASE_VERSION="0.0.1-beta.10"
IMAGE_TAG="v0.0.1-beta.10"
TENANT_NAME="$TENANT_NAME"

# Step 0: Checking prerequisites
echo "Step 0: Checking prerequisites..."



# Define versions
HELM_VERSION="v3.13.2"  # Replace with latest version if needed
KUBECTL_VERSION="v1.28.2"  # Replace with latest version

# Detect architecture
ARCH=$(uname -m)

if [[ "$ARCH" == "x86_64" ]]; then
    ARCH_TYPE="amd64"
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    ARCH_TYPE="arm64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

echo "Detected architecture: $ARCH_TYPE"

# Install Helm
echo "Installing Helm for $ARCH_TYPE..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_TYPE}.tar.gz" -o helm.tar.gz && \
    tar -xzvf helm.tar.gz && \
    mv linux-${ARCH_TYPE}/helm /usr/local/bin/helm && \
    rm -rf linux-${ARCH_TYPE} helm.tar.gz

# Verify Helm installation
helm version

# Install kubectl
echo "Installing kubectl for $ARCH_TYPE..."
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_TYPE}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/kubectl

# Verify kubectl installation
kubectl version --client


# Check for kubectl
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    echo "Ensure version matches your cluster: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi



#The Availability Zone with the most nodes is: $max_zone
max_zone=$(kubectl get nodes --output=json | jq -r '.items | group_by(.metadata.labels["failure-domain.beta.kubernetes.io/zone"]) | map({zone: .[0].metadata.labels["failure-domain.beta.kubernetes.io/zone"], count: length}) | max_by(.count) | .zone')

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account ID: $ACCOUNT_ID"
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)

CLUSTER_NAME=$CLUSTER_NAME

# # Step 2: Generate cluster payload
# PAYLOAD="$CLUSTER_NAME@$ACCOUNT_ID:$REGION@$OIDC_ISSUER"
# echo "Step 2: Generating cluster payload..."
# echo "Generated payload:"
# echo "  $PAYLOAD"
# echo ""
# # Step 3: Prompt user to register payload in Onelens
# # echo "Step 3: Copy the above payload and register it in Onelens."
# # echo "Finally, enter the IAM ARN for the tenant when you are done."
IAM_ARN="arn:aws:iam::609916866699:role/onelens-kubernetes-agent-role-manoj_test_account"
if [ -z "$IAM_ARN" ]; then
    echo "Error: IAM ARN cannot be empty."
    exit 1
fi

#namespace validation
if kubectl get namespace onelens-agent &> /dev/null; then
    echo "Warning: Namespace 'onelens-agent' already exists."
else
    echo "Namespace 'onelens-agent' does not exist. Creating namespace..."
    kubectl create namespace onelens-agent
fi


check_ebs_driver() {
    echo "Checking if EBS CSI driver is installed..."

    # Check if EBS CSI driver pods are running in the kube-system namespace
    if kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver --ignore-not-found | grep -q "ebs-csi"; then
        echo "EBS CSI driver is installed."
    else
        echo "EBS CSI driver is not installed. Exiting..."
        echo "Please install the EBS CSI driver and try again."
        exit 1
    fi
}

PVC_ENABLED=true
echo "Persistent storage for Prometheus is ENABLED by default."



# Step 6: Deploy the Onelens Agent via Helm
echo "Step 6: Deploying Onelens Agent..."

login_to_ecr_public() {
    echo "Logging into AWS ECR Public Registry..."

    if aws ecr-public get-login-password --region us-east-1 | \
       helm registry login -u AWS --password-stdin public.ecr.aws; then
        echo "Successfully logged into the ECR Public Registry."
    else
        echo "Failed to log into the ECR Public Registry. Please check your AWS credentials, region configuration, and Helm installation."
        exit 1
    fi
}


# Deploy the Helm chart
helm upgrade --install onelens-agent -n onelens-agent --create-namespace oci://public.ecr.aws/w7k6q5m9/helm-charts/onelens-agent  --version $RELEASE_VERSION \
    --set onelens-agent.env.CLUSTER_NAME="$CLUSTER_NAME" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId="$CLUSTER_NAME" \
    --set onelens-agent.env.TENANT_NAME="$TENANT_NAME" \
    --set-string onelens-agent.env.ACCOUNT_ID=${ACCOUNT_ID} \
    --set onelens-agent.env.AWS_CLUSTER_REGION="$REGION" \
    --set onelens-agent.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$IAM_ARN" \
    --set onelens-agent.image.repository=public.ecr.aws/w7k6q5m9/onelens-agent \
    --set onelens-agent.image.tag="$IMAGE_TAG" \
    --set onelens-agent.storageClass.az=$max_zone \
    --set prometheus.server.persistentVolume.enabled="$PVC_ENABLED" \
    --wait || { \
    echo "Error: Helm deployment failed."; \
    echo "Possible causes:"; \
    echo "- Insufficient cluster-admin permissions. Grant cluster-admin role and retry."; \
    echo "  Example: kubectl create clusterrolebinding useonelens-agent/r-admin-binding --clusterrole=cluster-admin --user=<your-user>"; \
    echo "- Incorrect IAM ARN. Verify the ARN and permissions with Onelens support."; \
    echo "- Network issues. Ensure cluster nodes can access ECR and S3."; \
    echo "Contact support@astuto.ai for assistance."; \
    exit 1; \
}


# Wait for pods to be ready
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=onelens-agent -n onelens-agent --timeout=300s || {
    echo "Error: Pods failed to become ready within 5 minutes."
    echo "Check pod status: kubectl get pods -n onelens-agent"
    echo "View logs: kubectl logs -n onelens-agent -l app=onelens-agent"
    echo "Possible issues:"
    echo "- Resource limits exceeded. Adjust node resources (min: 0.5 core, 2GB RAM for 100 pods)."
    echo "- ECR access denied. Verify IAM role permissions."
    exit 1
}
echo "Pods to be ready..."

# Installation complete
echo "The installation is complete."
echo "You can verify the deployment by checking the pods in the 'onelens-agent' namespace:"
echo "  kubectl get pods -n onelens-agent"
echo "For support, contact: support@astuto.ai"
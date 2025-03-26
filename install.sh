#!/bin/sh
set -eux  

#Command that client will execute.
# helm repo add onelens https://manoj-astuto.github.io/onelens-charts && \
# helm repo update && \
# helm upgrade --install onelensdeployer onelens/onelensdeployer \
#   --set job.env.SECRET_TOKEN=<hsjdahskjdhasjdhakjsd> \
#   --set job.env.CLUSTER_NAME=main \ 
#   --set job.env.REGION=ap-south-1 \ 
#   --set-string job.env.Account=434916866699
RELEASE_VERSION="0.0.1-beta.10"
IMAGE_TAG="v0.0.1-beta.10"

TIMESTAMP=$(date +"%Y%m%d%H%M%S")
LOG_FILE="/tmp/${Account}_${CLUSTER_NAME}_${TIMESTAMP}.log"
API_URL="https://dev-api.onelens.cloud/"
BEARER_TOKEN="OWMyN2FhZjUtYzljMC00ZWI5LTg1MTgtMWU5NzM0NjllMDU2"

# Capture all script output
exec > >(tee -a "$LOG_FILE") 2>&1

# Function to send logs before exiting
send_logs() {
    echo "Sending logs to API..."
    curl -X POST "$API_URL" \
         -H "Content-Type: application/json" \
         -H "Authorization: Bearer $BEARER_TOKEN" \
         -d "{\"log\": $(jq -Rs . < \"$LOG_FILE\")}" || echo "Failed to send logs"
}

# Trap EXIT and ERR signals to send logs before exiting
trap send_logs EXIT ERR


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


# Step 0: Checking prerequisites
echo "Step 0: Checking prerequisites..."

# Define versions
HELM_VERSION="v3.13.2"  
KUBECTL_VERSION="v1.28.2"  

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
    exit 1
fi

# Namespace validation
if kubectl get namespace onelens-agent &> /dev/null; then
    echo "Warning: Namespace 'onelens-agent' already exists."
else
    echo "Creating namespace 'onelens-agent'..."
    kubectl create namespace onelens-agent
fi

check_ebs_driver() {
    local retries=2
    local count=0

    while [ $count -le $retries ]; do
        echo "Checking if EBS CSI driver is installed (Attempt $((count+1))/$((retries+1)))..."
        
        if kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver --ignore-not-found | grep -q "ebs-csi"; then
            echo "EBS CSI driver is installed."
            return 0
        fi

        if [ $count -eq 0 ]; then
            echo "EBS CSI driver is not installed. Installing..."
            helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver --namespace kube-system --set controller.serviceAccount.create=true
        fi

        if [ $count -lt $retries ]; then
            echo "Retrying in 10 seconds..."
            sleep 10
        fi
        
        count=$((count+1))
    done

    echo "EBS CSI driver installation failed after $((retries+1)) attempts."
    return 1
}

check_ebs_driver 


PVC_ENABLED=true
echo "Persistent storage for Prometheus is ENABLED."

helm repo add onelens https://manoj-astuto.github.io/onelens-charts && \
helm repo update && \
helm upgrade --install onelens-agent -n onelens-agent --create-namespace onelens/onelens-agent --version $RELEASE_VERSION \
    --set onelens-agent.env.CLUSTER_NAME="$CLUSTER_NAME" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId="$CLUSTER_NAME" \
    --set onelens-agent.image.repository=public.ecr.aws/w7k6q5m9/onelens-agent \
    --set onelens-agent.image.tag="$IMAGE_TAG" \
    --set prometheus.server.persistentVolume.enabled="$PVC_ENABLED" \
    --wait || { 
        echo "Error: Helm deployment failed."; 
        exit 1; 
    }

# Wait for pods to be ready
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=onelens-agent -n onelens-agent --timeout=300s || {
    echo "Error: Pods failed to become ready."
    echo "Installation Failed."
    exit 1
}

echo "Installation complete."
echo "To verify deployment: kubectl get pods -n onelens-agent"

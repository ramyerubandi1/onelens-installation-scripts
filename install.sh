#!/bin/sh
set -eux

TIMESTAMP=$(date +"%Y%m%d%H%M%S")
LOG_FILE="/tmp/${ACCOUNT}_${CLUSTER_NAME}_${TIMESTAMP}.log"

# Set default values if variables are not set
: "${RELEASE_VERSION:=0.1.1-beta.2}"
: "${IMAGE_TAG:=v0.1.1-beta.2}"
: "${API_BASE_URL:=dev-api.onelens.cloud}"
: "${TOKEN:=OWMyN2FhZjUtYzljMC00ZWI5LTg1MTgtMWU5NzM0NjllMDU2}"
: "${PVC_ENABLED:=true}"

# Export the variables so they are available in the environment
export RELEASE_VERSION IMAGE_TAG API_BASE_URL TOKEN PVC_ENABLED

# Capture all script output
exec > >(tee "$LOG_FILE") 2>&1

# Function to send logs before exiting
send_logs() {
    echo "Sending logs to API..."
    sleep 2
    curl -X POST "https://$API_BASE_URL/v1/kubernetes/registration" \
        -H "X-Secret-Token: $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
            "registration_id": "$registration_id",
            "cluster_token": "$cluster_token",
            "status": "$(cat "$LOG_FILE")"
        }'
}

# Trap EXIT and ERR signals to send logs before exiting
trap 'send_logs; exit 1' ERR

response=$(curl -X POST \
  https://$API_BASE_URL/v1/kubernetes/registration \
  -H "X-Secret-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "registration_token": "$REGISTRATION_TOKEN",
    "cluster_name": "$CLUSTER_NAME",
    "account_id": "$ACCOUNT",
    "region": "$REGION",
    "agent_version": "$RELEASE_VERSION"
  }')

registration_id=$(echo $response | jq -r '.data.registration_id')
cluster_token=$(echo $response | jq -r '.data.cluster_token')

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
    false
fi

echo "Detected architecture: $ARCH_TYPE"

# Install Helm
echo "Installing Helm for $ARCH_TYPE..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_TYPE}.tar.gz" -o helm.tar.gz && \
    tar -xzvf helm.tar.gz && \
    mv linux-${ARCH_TYPE}/helm /usr/local/bin/helm && \
    rm -rf linux-${ARCH_TYPE} helm.tar.gz

helm version

# Install kubectl
echo "Installing kubectl for $ARCH_TYPE..."
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_TYPE}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/kubectl

kubectl version --client

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    false
fi

# Namespace validation
if kubectl get namespace onelens-agent &> /dev/null; then
    echo "Warning: Namespace 'onelens-agent' already exists."
else
    echo "Creating namespace 'onelens-agent'..."
    kubectl create namespace onelens-agent
fi

check_ebs_driver() {
    local retries=1
    local count=0

    while [ $count -le $retries ]; do
        echo "Checking if EBS CSI driver is installed (Attempt $((count+1))/$((retries+1)))..."
        
        if kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver --ignore-not-found | grep -q "ebs-csi"; then
            echo "EBS CSI driver is installed."
            return 0
        fi

        if [ $count -eq 0 ]; then
            echo "EBS CSI driver is not installed. Installing..."
            helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
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

echo "Persistent storage for Prometheus is ENABLED."

# Get the total number of pods in the cluster
TOTAL_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)

# Check if the command succeeded
if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch pod details. Please check if Kubernetes is running and kubectl is configured correctly." >&2
    false
fi

echo "Total number of pods in the cluster: $TOTAL_PODS"

helm repo add onelens https://manoj-astuto.github.io/onelens-charts && helm repo update

if [ "$TOTAL_PODS" -lt 100 ]; then
    CPU_REQUEST="500m"
    MEMORY_REQUEST="2000Mi"
else
    CPU_REQUEST="1000m"
    MEMORY_REQUEST="4000Mi"
fi

helm upgrade --install onelens-agent -n onelens-agent --create-namespace onelens/onelens-agent \
    --version "$RELEASE_VERSION" \
    --set onelens-agent.env.CLUSTER_NAME="$CLUSTER_NAME" \
    --set onelens-agent.secrets.API_BASE_URL="$API_BASE_URL" \
    --set onelens-agent.secrets.CLUSTER_TOKEN="$cluster_token" \
    --set onelens-agent.secrets.REGISTRATION_ID="$registration_id" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId="$CLUSTER_NAME" \
    --set onelens-agent.image.tag="$IMAGE_TAG" \
    --set prometheus.server.persistentVolume.enabled="$PVC_ENABLED" \
    --set prometheus.server.resources.requests.cpu="$CPU_REQUEST" \
    --set prometheus.server.resources.requests.memory="$MEMORY_REQUEST" \
    --wait || { echo "Error: Helm deployment failed."; false; }

kubectl wait --for=condition=ready pod -l app=onelens-agent -n onelens-agent --timeout=300s || {
    echo "Error: Pods failed to become ready."
    echo "Installation Failed."
    false
}

echo "Installation complete."
curl -X PUT \
  https://$API_BASE_URL/v1/kubernetes/registration \
  -H "X-Secret-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "registration_id": "$registration_id",
    "cluster_token": "$cluster_token",
    "status": "CONNECTED"
  }'

echo "To verify deployment: kubectl get pods -n onelens-agent"

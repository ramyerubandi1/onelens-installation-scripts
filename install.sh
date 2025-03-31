#!/bin/bash
set -ex
trap -p

# Phase 1: Logging Setup
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
LOG_FILE="/tmp/${TIMESTAMP}.log"
touch "$LOG_FILE"
# Capture all script output
exec > >(tee "$LOG_FILE") 2>&1

send_logs() {
    echo "Sending logs to API..."
    echo "***********************************************************************************************"
    sleep 0.1
    cat "$LOG_FILE"
}

# Ensure send_logs runs before exit
trap 'send_logs; exit 1' ERR EXIT

# Phase 2: Environment Variable Setup
: "${RELEASE_VERSION:=0.1.1-beta.2}"
: "${IMAGE_TAG:=latest}"
: "${API_BASE_URL:=https://dev-api.onelens.cloud}"
: "${TOKEN:=OWMyN2FhZjUtYzljMC00ZWI5LTg1MTgtMWU5NzM0NjllMDU2}"
: "${PVC_ENABLED:=true}"

# Export the variables so they are available in the environment
export RELEASE_VERSION IMAGE_TAG API_BASE_URL TOKEN PVC_ENABLED
if [ -z "${REGISTRATION_TOKEN:-}" ]; then
    echo "Error: REGISTRATION_TOKEN is not set"
    exit 1
else
    echo "REGISTRATION_TOKEN is set"
fi

# Phase 3: API Registration
response=$(curl -X POST \
  "$API_BASE_URL/v1/kubernetes/registration" \
  -H "X-Secret-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"registration_token\": \"$REGISTRATION_TOKEN\",
    \"cluster_name\": \"$CLUSTER_NAME\",
    \"account_id\": \"$ACCOUNT\",
    \"region\": \"$REGION\",
    \"agent_version\": \"$RELEASE_VERSION\"
  }")

REGISTRATION_ID=$(echo $response | jq -r '.data.registration_id')
CLUSTER_TOKEN=$(echo $response | jq -r '.data.cluster_token')

if [[ -n "$REGISTRATION_ID" && "$REGISTRATION_ID" != "null" && -n "$CLUSTER_TOKEN" && "$CLUSTER_TOKEN" != "null" ]]; then
    echo "Both REGISTRATION_ID and CLUSTER_TOKEN have values."
else
    echo "One or both of REGISTRATION_ID and CLUSTER_TOKEN are empty or null."
    exit 1
fi
sleep 2

# Phase 4: Prerequisite Checks
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

# Phase 5: Install Helm
echo "Installing Helm for $ARCH_TYPE..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_TYPE}.tar.gz" -o helm.tar.gz && \
    tar -xzvf helm.tar.gz && \
    mv linux-${ARCH_TYPE}/helm /usr/local/bin/helm && \
    rm -rf linux-${ARCH_TYPE} helm.tar.gz

helm version

# Phase 6: Install kubectl
echo "Installing kubectl for $ARCH_TYPE..."
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_TYPE}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/kubectl

kubectl version --client

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    exit 1
fi

# Phase 7: Namespace Validation
if kubectl get namespace onelens-agent &> /dev/null; then
    echo "Warning: Namespace 'onelens-agent' already exists."
else
    echo "Creating namespace 'onelens-agent'..."
    kubectl create namespace onelens-agent || { echo "Error: Failed to create namespace 'onelens-agent'."; exit 1; }
fi

# Phase 8: EBS CSI Driver Check and Installation
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

# Phase 9: Cluster Pod Count and Resource Allocation
TOTAL_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)

if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch pod details. Please check if Kubernetes is running and kubectl is configured correctly." >&2
    exit 1
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

# Phase 10: Helm Deployment
check_var() {
    if [ -z "${!1:-}" ]; then
        echo "Error: $1 is not set"
        exit 1
    fi
}

check_var CLUSTER_TOKEN
check_var REGISTRATION_ID

# # Check if an older version of onelens-agent is already running
# if helm list -n onelens-agent | grep -q "onelens-agent"; then
#     echo "An older version of onelens-agent is already running."
#     CURRENT_VERSION=$(helm get values onelens-agent -n onelens-agent -o json | jq '.["onelens-agent"].image.tag // "unknown"')
#     echo "Current version of onelens-agent: $CURRENT_VERSION"

#     if [ "$CURRENT_VERSION" != "$IMAGE_TAG" ]; then
#         echo "Patching onelens-agent to version $IMAGE_TAG..."
#     else
#         echo "onelens-agent is already at the desired version ($IMAGE_TAG)."
#         exit 1
#     fi
# else
#     echo "No existing onelens-agent release found. Proceeding with installation."
# fi

helm upgrade --install onelens-agent -n onelens-agent --create-namespace onelens/onelens-agent \
    --version "$RELEASE_VERSION" \
    --set onelens-agent.env.CLUSTER_NAME="$CLUSTER_NAME" \
    --set onelens-agent.secrets.API_BASE_URL="$API_BASE_URL" \
    --set onelens-agent.secrets.CLUSTER_TOKEN="$CLUSTER_TOKEN" \
    --set onelens-agent.secrets.REGISTRATION_ID="$REGISTRATION_ID" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId="$CLUSTER_NAME" \
    --set onelens-agent.image.tag="$IMAGE_TAG" \
    --set prometheus.server.persistentVolume.enabled="$PVC_ENABLED" \
    --set prometheus.server.resources.requests.cpu="$CPU_REQUEST" \
    --set prometheus.server.resources.requests.memory="$MEMORY_REQUEST" \
    --wait || { echo "Error: Helm deployment failed."; exit 1; }

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-opencost-exporter -n onelens-agent --timeout=300s || {
    echo "Error: Pods failed to become ready."
    echo "Installation Failed."
    false
}

# Phase 11: Finalization
echo "Installation complete."

echo " Printing $REGISTRATION_ID"
echo "Printing $CLUSTER_TOKEN"
curl -X PUT "$API_BASE_URL/v1/kubernetes/registration" \
    -H "X-Secret-Token: $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"registration_id\": \"$REGISTRATION_ID\",
        \"cluster_token\": \"$CLUSTER_TOKEN\",
        \"status\": \"CONNECTED\"
    }"

echo "To verify deployment: kubectl get pods -n onelens-agent"

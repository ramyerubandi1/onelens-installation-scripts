 #!/bin/bash
 
# Exit on any error
set -e

RELEASE_VERSION="0.0.1-beta.7"
IMAGE_TAG="v0.0.1-beta.10"
TENANT_NAME=$1

# Step 0: Checking prerequisites
echo "Step 0: Checking prerequisites..."
 
# Check for AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI not found. Please install AWS CLI to proceed."
    echo "Install it from: https://aws.amazon.com/cli/"
    echo "Verify with: aws --version"
    exit 
fi
 
# Check for Helm
if ! command -v helm &> /dev/null; then
    echo "Error: Helm not found. Please install Helm version 3 or later."
    echo "Install it from: https://helm.sh/docs/intro/install/"
    echo "Verify with: helm version --short"
    exit 1
fi
 
# Check Helm version (must be v3 or later)
HELM_VERSION=$(helm version --short | cut -d ' ' -f2 | cut -d '+' -f1)
if [[ ! "$HELM_VERSION" =~ ^v3 ]]; then
    echo "Error: Helm version 3 or later is required."
    echo "Current version: $HELM_VERSION"
    echo "Install Helm v3+ from: https://helm.sh/docs/intro/install/"
    exit 1
fi
 
# Check for kubectl
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please install kubectl."
    echo "Ensure version matches your cluster: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi
 
# Check AWS configuration
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Error: AWS CLI is not configured. Please run 'aws configure' to set up your credentials."
    echo "Run: aws configure"
    exit 1
fi
 
# Step 1: Fetching current EKS context
echo "Step 1: Fetching current EKS context..."
CONTEXT=$(kubectl config current-context)
if [ -z "$CONTEXT" ]; then
    echo "Error: No Kubernetes cluster context set. Please set the cluster context using kubectl."
    echo "List contexts: kubectl config get-contexts"
    echo "Set context: kubectl config use-context <cluster-name>"
    echo "Verify: kubectl config current-context"
    exit 1
fi
echo "Current context: $CONTEXT"
 
#The Availability Zone with the most nodes is: $max_zone
max_zone=$(kubectl get nodes --output=json | jq -r '.items | group_by(.metadata.labels["failure-domain.beta.kubernetes.io/zone"]) | map({zone: .[0].metadata.labels["failure-domain.beta.kubernetes.io/zone"], count: length}) | max_by(.count) | .zone')

# Parse cluster information from context
if [[ $CONTEXT =~ arn:aws:eks:([^:]+):([^:]+):cluster/(.+) ]]; then
    REGION=${BASH_REMATCH[1]}
    ACCOUNT_ID=${BASH_REMATCH[2]}
    CLUSTER_NAME=${BASH_REMATCH[3]}
    ESCAPED_ACCOUNT_ID="\"${ACCOUNT_ID}\""
else
    echo "Error: Unable to parse cluster information from context."
    echo "Expected format: arn:aws:eks:<region>:<account-id>:cluster/<cluster-name>"
    echo "Set correct context: kubectl config use-context <cluster-name>"
    exit 1
fi
echo "Cluster: $CLUSTER_NAME (Account: $ACCOUNT_ID, Region: $REGION)"
 
# Get OIDC issuer
OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.identity.oidc.issuer' --output text)
if [ -z "$OIDC_ISSUER" ]; then
    echo "Error: Unable to retrieve OIDC issuer."
    echo "Ensure AWS CLI has permissions to describe the cluster and the cluster name is correct."
    exit 1
fi
 
# Step 2: Generate cluster payload
PAYLOAD="$CLUSTER_NAME@$ACCOUNT_ID:$REGION@$OIDC_ISSUER"
echo "Step 2: Generating cluster payload..."
echo "Generated payload:"
echo "  $PAYLOAD"
echo ""
 
# Step 3: Prompt user to register payload in Onelens
echo "Step 3: Copy the above payload and register it in Onelens."
echo "Finally, enter the IAM ARN for the tenant when you are done."
read -p "IAM ARN: " IAM_ARN
if [ -z "$IAM_ARN" ]; then
    echo "Error: IAM ARN cannot be empty."
    exit 1
fi

#namespace validation
if kubectl get namespace onelens-agent &> /dev/null; then
    echo "Warning: Namespace 'onelens-agent' already exists."
    if kubectl get deployment onelens-agent -n onelens-agent &> /dev/null; then
        echo "Seems like 'onelens-agent' is already deployed."
        echo "We are patching with the latest release."
    else
        echo "This may cause conflicts with the installation."
        read -p "Proceed anyway? (y/n): " PROCEED
        if [ "$PROCEED" != "y" ]; then
            echo "Exiting. Please remove or clean the 'onelens-agent' namespace and rerun the script."
            echo "Delete namespace: kubectl delete namespace onelens-agent"
            exit 1
        fi
    fi
else
    echo "Namespace 'onelens-agent' does not exist. Creating namespace..."
    kubectl create namespace onelens-agent
fi

# Function to cleanup test resources
cleanup_test_resources() {
    echo "Cleaning up test resources..."
    kubectl delete pod permissions-test -n onelens-agent --ignore-not-found
    kubectl delete serviceaccount onelens-agent-sa -n onelens-agent --ignore-not-found
}
cleanup_test_resources
# Function to check S3  access
check_access() {
    local start_time=$(date +%s)
    local end_time=$((start_time + 60))
    local check_interval=3
    
    echo "Creating test service account in onelens-agent namespace..."
    
    # Create service account with the IAM role annotation
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: onelens-agent-sa
  namespace: onelens-agent
  annotations:
    eks.amazonaws.com/role-arn: ${IAM_ARN}
EOF
    
    echo "Creating test pod to verify S3 ..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: permissions-test
  namespace: onelens-agent
spec:
  serviceAccountName: onelens-agent-sa
  containers:
  - name: aws-cli
    image: amazon/aws-cli:latest
    command:
    - /bin/sh
    - -c
    - |
      aws s3 ls s3://onelens-kubernetes-agent/$TENANT_NAME &&
      echo "success" > /tmp/result ||
      echo "failed" > /tmp/result
    volumeMounts:
    - name: result
      mountPath: /tmp
  volumes:
  - name: result
    emptyDir: {}
EOF
 
    echo "Checking S3 access permissions..."
    echo "This will retry for 60 seconds, checking every 3 seconds..."
    
    while [ $(date +%s) -lt $end_time ]; do
        if kubectl wait --for=condition=ready pod/permissions-test -n onelens-agent --timeout=3s &> /dev/null; then
            result=$(kubectl exec -n onelens-agent permissions-test -- cat /tmp/result 2>/dev/null || echo "pending")
            
            if [ "$result" = "success" ]; then
                echo "✓ S3 access verified"
                echo "All required permissions are now available!"
                cleanup_test_resources
                return 0
            elif [ "$result" = "failed" ]; then
                echo "✗ Permission check failed"
                echo "Waiting for permissions to propagate..."
                sleep $check_interval
            fi
        fi
        echo "Waiting for test pod to complete..."
        sleep $check_interval
    done
    
    echo "Error: Failed to verify S3  after 60 seconds."
    echo "Please verify the following:"
    echo "1. The IAM role has the required permissions:"
    echo "   - S3: s3:GetObject, s3:PutObject, s3:ListBucket"
    echo "2. The IAM role trust relationship allows the service account to assume the role"
    echo "3. The OIDC provider is properly configured for the cluster"
    cleanup_test_resources
    exit 1
}
 
# Run the access check
check_access

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

# Step 4: Check for Persistent Volume (PVC) access
PVC_ENABLED=false
echo "Please decide whether you want to enable persistent storage for Prometheus or not."
echo "Options:"
echo "1. Proceed without PV (risk of data loss if Prometheus pod restarts before data export)."
echo "2. Set up PV and retry."
read -p "Enter your choice (1/2): " PVC_CHOICE

if [ "$PVC_CHOICE" = "1" ]; then
    echo "Remember: Data loss will happen if Prometheus pod restarts before data export."
elif [ "$PVC_CHOICE" = "2" ]; then    
    check_ebs_driver
    PVC_ENABLED=true
else
    echo "Invalid choice, exiting."
    exit 1
fi

 

 
# Step 6: Deploy the Onelens Agent via Helm
echo "Step 6: Deploying Onelens Agent..."
 
echo "Checking for system:masters group membership..."
if ! kubectl auth can-i '*' '*' --all-namespaces &> /dev/null; then
    echo "Warning: Limited permissions detected. system:masters group membership is recommended."
    echo "Some helm chart installations might fail without sufficient permissions."
    echo "To get full permissions, contact your cluster administrator to add you to the system:masters group."
    echo "Example command for admin to run:"
    echo "  kubectl edit configmap aws-auth -n kube-system"
    echo "And add your user ARN to the mapUsers section with system:masters group:"
    echo "  mapUsers:"
    echo "    - userarn: arn:aws:iam::<account-id>:user/<username>"
    echo "      username: <username>"
    echo "      groups:"
    echo "        - system:masters"
    read -p "Do you want to proceed anyway? (y/n): " PROCEED
    if [ "$PROCEED" != "y" ]; then
        echo "Installation aborted. Please obtain necessary permissions and try again."
        exit 1
    fi
    echo "Proceeding with limited permissions..."
else
    echo "system:masters group membership verified."
fi

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

login_to_ecr_public

helm repo update
# Deploy the Helm chart
helm upgrade --install onelens-agent -n onelens-agent --create-namespace oci://public.ecr.aws/w7k6q5m9/helm-charts/onelens-agent  --version $RELEASE_VERSION \
    --set onelens-agent.env.CLUSTER_NAME="$CLUSTER_NAME" \
    --set prometheus-opencost-exporter.opencost.exporter.defaultClusterId="$CLUSTER_NAME" \
    --set onelens-agent.env.TENANT_NAME="$TENANT_NAME" \
    --set onelens-agent.env.ACCOUNT_ID=$ESCAPED_ACCOUNT_ID \
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

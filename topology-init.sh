#!/bin/bash
cluster_variable = ""
#Adjust these variables
export SUBNET_ID_1='subnet-0497cdc65a68a3692'
export SUBNET_ID_2='subnet-0873d869ec708ff6e'
export REGION="us-east-1"
export AZ_1="us-east-1a"
export AZ_2="us-east-1b"
export SG_ID="sg-089b10b6c408e6ebe"
##KEYPAIR_NAME is set to the name of your AWS EC2 keypair. This is used to SSH to nodes running k8s.
export KEYPAIR_NAME="balaramesh"
export CLUSTER_NAME="topology"
export WEKA_EMAIL="bala.ramesh@weka.io"
export KUBECONFIG="${HOME}/kube-${CLUSTER_NAME}.yaml"

# wipe screen.
clear

echo "Beginning run"
echo "...\n...\n...\n"

# Check the helm installation.

echo "Checking if Helm is installed..."
command -v helm version --short >/dev/null 2>&1 || { echo >&2 "Helm version 3+ is required but not installed yet... download and install here: https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"; exit; }

# Check the kubectl installation.
echo "Checking if kubectl is installed..."
command -v kubectl version >/dev/null 2>&1 || { echo >&2 "Kubectl is required but not installed yet... download and install: https://kubernetes.io/docs/tasks/tools/"; exit; }

# Check the bliss installation.
echo "Checking if bliss is installed..."
command -v bliss version >/dev/null 2>&1 || { echo >&2 "Bliss is required but not installed yet... download and install: https://github.com/weka/bliss/releases"; exit; }

# Checking if k8s cluster already exists...
echo "Checking if k8s cluster already exists from previous bliss run..."

function check_cluster() {
        echo "Inside check cluster function...."
	command bliss info --cluster-name ${CLUSTER_NAME}
	echo "Does cluster exist? If yes, then enter yes. If no, then enter no."
	read cluster_variable
	
}

check_cluster

if [[ "$cluster_variable" == "yes" ]]; then
	echo "Cluster already exists....proceeding to modify ASG config...."
elif [[ "$cluster_variable" == "no" ]]; then
        echo "Cluster does not exist..provisioning one now..."        
fi


## Deploy k8s cluster if it doesn't exist.

if [[ "$cluster_variable" == "no" ]]; then
	echo "Deploying kubernetes cluster in AWS using bliss...."
	command bliss provision aws-k3s --cluster-name $CLUSTER_NAME \
		--subnet-id $SUBNET_ID_1 \
		--security-groups $SG_ID --region $REGION \
		--no-nodes-setup \
		--ami-id ami-096514dba491a92ff --key-pair-name $KEYPAIR_NAME \
		--iam-profile-arn arn:aws:iam::459693375476:instance-profile/bliss-k3s-instance-profile \
		--tag Owner=$WEKA_EMAIL --tag TTL=2h --tag OwnerService=port \
		--template aws_k3_small --cluster-name $CLUSTER_NAME \
		--ssh-usernames ubuntu
fi

#if [ $? -ne 0 ]; then
#	echo
#	echo "Error occurred during K8s cluster provisioning..."
#	echo
#	exit;
#fi


echo "Modify ASG to include two networks"

command aws autoscaling update-auto-scaling-group --auto-scaling-group-name ${CLUSTER_NAME}-Converged --vpc-zone-identifier ${SUBNET_ID_1},${SUBNET_ID_2}

echo "Wait for ASG to balance itself on two AZs"

sleep 300

echo "Re-deploy kubernetes with bliss"

command bliss provision aws-k3s --cluster-name ${CLUSTER_NAME} --template aws_k3_small --reinstall

echo "Re-deploy complete"

echo "Deploy Weka operator and then install wekaCluster..."

## Install weka operator v1.6.0 and use WEKA image 4.4.5.118-k8s.3 for wekaCluster

command bliss install --cluster-name $CLUSTER_NAME \
	--operator-version v1.6.0 --csi-version 2.7.2 \
	--quay-username=$QUAY_USERNAME --quay-password=$QUAY_PASSWORD \
	--kubeconfig $KUBECONFIG \
	--weka-image quay.io/weka.io/weka-in-container:4.4.5.118-k8s.3 \
	--client-weka-image quay.io/weka.io/weka-in-container:4.4.5.118-k8s.3 2>&1 | tee -a blissout

if [ $? -ne 0 ]; then
        echo
        echo "Error occurred during weka operator install + wekaCluster provisioning..."
        echo
        exit;
fi

echo "Weka operator deployment complete..."

echo "Examining status of pods in weka namespace...Pods should be up and running..."

command kubectl --kubeconfig "${KUBECONFIG}" wait --for=condition=Ready pod --all --timeout=100s --namespace weka-operator-system

if [ $? -ne 0 ]; then
        echo
        echo "Error accessing k8s cluster. Check your KUBECONFIG variable??"
        echo
        exit;
fi

echo "Check status of wekaCluster...It should be in the Ready state..."

command kubectl --kubeconfig "${KUBECONFIG}" get wekacluster --all-namespaces

if [ $? -ne 0 ]; then
        echo
        echo "Error accessing k8s cluster. Check your KUBECONFIG variable??"
        echo
        exit;
fi

echo "Add topology labels to nodes"

command kubectl label node --all topology.kubernetes.io/region=us-east-1

command aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].Instances[].[InstanceId, AvailabilityZone]" --output yaml --auto-scaling-group-names topology-Converged

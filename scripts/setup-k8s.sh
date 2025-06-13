#!/bin/bash
set -e

# Define log file and github directory locations
# and terraform workspace
# Modify these as necessary
GITHUB="/opt/github"
LOG_FILE="$GITHUB/cloud-lab/scripts/setup-k8s.log"
WORKSPACE="k8s"

# Redirect all output (stdout and stderr) to the log file
exec > >(tee "$LOG_FILE") 2>&1

echo "Script started at $(date)"

# Navigate to Terraform directory
cd $GITHUB/cloud-lab/terraform

# Set terraform workspace
terraform workspace select $WORKSPACE

# Apply Terraform infrastructure changes with retries
while ! terraform apply -auto-approve -no-color; do
    echo "Retrying Terraform apply..."
    sleep 60
done

# Navigate to Ansible directory
#cd $GITHUB/cloud-lab/ansible

# Copy the ansible vars file
#if [ -f "vars.yaml.$WORKSPACE" ]; then
#    cp -f vars.yaml.$WORKSPACE vars.yaml
#    echo "Copying vars.yaml.$WORKSPACE to vars.yaml"

#else
#    echo "Warning: vars.yaml.$WORKSPACE does not exist. Skipping copy."
#fi

# Execute Ansible playbooks
#./01-setup-hosts.sh
#./05-update-demo-jumpbox.sh
#./06-setup-demo-jumpbox.sh

echo "Script execution completed successfully at $(date)"


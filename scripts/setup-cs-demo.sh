#!/bin/bash
set -e

# Define log file and github directory locations
# and terraform workspace
# Modify these as necessary
GITHUB="/opt/github"
LOG_FILE="$GITHUB/cloud-lab/scripts/setup-cs-demo.log"
WORKSPACE="se15"

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
cd $GITHUB/cloud-lab/ansible

# Execute Ansible playbooks
./01-setup-hosts.sh
./02-setup-cs-demo.sh

echo "Script execution completed successfully at $(date)"


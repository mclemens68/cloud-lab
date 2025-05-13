#!/bin/bash
set -e

# Define log file and github directory locations
# and terraform workspace
# Modify these as necessary
GITHUB="/opt/github"
LOG_FILE="$GITHUB/cloud-lab/scripts/teardown-demo-jumpbox.log"
WORKSPACE="demo-jumpbox"

# Redirect all output (stdout and stderr) to the log file
exec > >(tee "$LOG_FILE") 2>&1

echo "Script started at $(date)"

# Navigate to Terraform directory
cd $GITHUB/cloud-lab/terraform

# Set terraform workspace
terraform workspace select $WORKSPACE

# Apply Terraform infrastructure changes with retries
while ! terraform destroy -auto-approve -no-color; do
    echo "Retrying Terraform apply..."
    sleep 60
done

echo "Script execution completed successfully at $(date)"


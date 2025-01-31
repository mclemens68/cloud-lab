 #!/bin/bash

# This script can be used to setup and teardown the cloud-lab
# just when needed to save cloud costs. It can be run the
# night before you need the demo env. By default it will spin up
# the lab at 6am, and tear it down at 5pm. Adjust the times as
# needed. If you have the associated cloud accounts onboarded into
# CloudSecure and access to global flow logs granted, there should
# be no need to re-onboard CloudSecure.

# You do need at installed on the MacOS/Linux host where running
# at should exist by defalt on Mac, and on Linux run one of these: 
# sudo apt install at
# sudo yum install at

# Define script directory location
# Modify these as necessary
SCRIPT_DIR="/opt/github/cloud-lab/scripts"

echo "$SCRIPT_DIR/setup-cs-demo.sh" | at 6:00am
echo "$SCRIPT_DIR/teardown-cs-demo.sh" | at 5:00pm

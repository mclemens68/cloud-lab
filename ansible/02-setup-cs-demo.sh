# Run this second to setup the AWS Jump Host. 
# Rerun anytime the local playbooks change to update the files on the jump hosts.
# This will copy the ansible environment to the aws jump host and run it on a cron job
# The azure jump host will be setup as part of the cron job on the aws jump host.
ansible-playbook main.yaml --limit aws_jh_pub --tags aws_jh_pub -i aws.hosts
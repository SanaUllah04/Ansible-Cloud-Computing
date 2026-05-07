# Build a Monitoring Stack with Ansible
Launch two Ubuntu 22.04 EC2 instances. Create or reuse an EC2 Key Pair and save the .pem file locally (e.g. `~/keys/my-ec2-key.pem`).

Adjust `inventory.ini` with the public IPs of the instances and the path to your .pem file.

If using private IPs in a VPC, set `target_server_ip` in `group_vars/all.yml` to the target's private IP and ensure security groups allow traffic between instances on ports 9100/9090/3000.

Run a dry-run: `ansible-playbook playbook.yml --check -i inventory.ini`
Run for real: `ansible-playbook playbook.yml -i inventory.ini`

Note: The included provisioning script (`monitoring/scripts/provision_ec2.sh`) now defaults to AWS region `us-east-2`. You can override this by setting the `AWS_DEFAULT_REGION` environment variable or by entering a different region when prompted.



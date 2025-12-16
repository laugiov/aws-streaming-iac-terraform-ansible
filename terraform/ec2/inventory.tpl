[web]
${web_ip} ansible_user=ubuntu ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

[streamer]
${streamer_ip_priv} ansible_user=ubuntu ansible_ssh_common_args='-o ProxyJump=ubuntu@${web_ip} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

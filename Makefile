# =============================================================================
# AWS Video Streaming Platform - Makefile
# =============================================================================

# Configuration - EDIT BEFORE USE
LAB_ID ?= my-lab-id                         # Unique lab identifier
REGION ?= us-east-1                         # AWS Region
DOMAIN_FQDN ?= my-lab-id.example.com        # Fully qualified domain name
SSH_KEY_BASE = ~/.ssh/myKey-$(LAB_ID)

# Colors
GREEN = \033[0;32m
YELLOW = \033[1;33m
RED = \033[0;31m
BLUE = \033[0;34m
NC = \033[0m

# =============================================================================
# MAIN COMMANDS
# =============================================================================

.PHONY: help
help: ## Display this help
	@echo "$(BLUE)=== AWS Video Streaming Platform ===$(NC)"
	@echo ""
	@echo "$(GREEN)Essential commands:$(NC)"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(YELLOW)%-15s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(GREEN)Configuration:$(NC)"
	@echo "  LAB_ID: $(LAB_ID)"
	@echo "  REGION: $(REGION)"

.PHONY: deploy
deploy: ## Deploy complete infrastructure
	@echo "$(BLUE)🚀 Deploying...$(NC)"
	@./run-all.sh

.PHONY: ssh-keys
ssh-keys: ## Generate SSH keys
	@echo "$(BLUE)🔑 Generating SSH keys...$(NC)"
	@if [ ! -f $(SSH_KEY_BASE) ]; then \
		ssh-keygen -t ed25519 -f $(SSH_KEY_BASE) -N "" -C "$(LAB_ID)@$(shell hostname)"; \
		chmod 600 $(SSH_KEY_BASE); \
		echo "Keys generated: $(SSH_KEY_BASE)"; \
	else \
		echo "Existing keys: $(SSH_KEY_BASE)"; \
	fi

.PHONY: status
status: ## Display service status
	@echo "$(BLUE)📊 Status...$(NC)"
	@WEB_IP=$$(terraform -chdir=terraform/ec2 output -raw web_public_ip 2>/dev/null || echo "N/A"); \
	if [ "$$WEB_IP" != "N/A" ]; then \
		echo "Web: $$WEB_IP"; \
		echo "URL: https://$(DOMAIN_FQDN)"; \
	else \
		echo "Infrastructure not deployed"; \
	fi

.PHONY: logs
logs: ## Display service logs
	@echo "$(BLUE)📋 Service logs...$(NC)"
	@WEB_IP=$$(terraform -chdir=terraform/ec2 output -raw web_public_ip 2>/dev/null || echo "N/A"); \
	STREAMER_IP=$$(terraform -chdir=terraform/ec2 output -raw streamer_private_ip 2>/dev/null || echo "N/A"); \
	if [ "$$WEB_IP" != "N/A" ]; then \
		echo "NGINX logs (Web):"; \
		ssh -i $(SSH_KEY_BASE) ubuntu@$$WEB_IP "sudo journalctl -u nginx --no-pager -n 20" 2>/dev/null || echo "  Logs not accessible"; \
		echo ""; \
		if [ "$$STREAMER_IP" != "N/A" ]; then \
			echo "FFmpeg logs (Streamer):"; \
			ssh -i $(SSH_KEY_BASE) -o ProxyJump=ubuntu@$$WEB_IP ubuntu@$$STREAMER_IP "sudo journalctl -u ffmpeg-streamer --no-pager -n 20" 2>/dev/null || echo "  Logs not accessible"; \
		fi; \
	else \
		echo "Infrastructure not deployed"; \
	fi

.PHONY: ssh-web
ssh-web: ## SSH connection to web server
	@WEB_IP=$$(terraform -chdir=terraform/ec2 output -raw web_public_ip 2>/dev/null || echo "N/A"); \
	if [ "$$WEB_IP" != "N/A" ]; then \
		echo "$(BLUE)🔐 SSH to $$WEB_IP...$(NC)"; \
		ssh -i $(SSH_KEY_BASE) ubuntu@$$WEB_IP; \
	else \
		echo "$(RED)❌ Infrastructure not deployed$(NC)"; \
	fi

.PHONY: ssh-streamer
ssh-streamer: ## SSH connection to streamer server
	@WEB_IP=$$(terraform -chdir=terraform/ec2 output -raw web_public_ip 2>/dev/null || echo "N/A"); \
	STREAMER_IP=$$(terraform -chdir=terraform/ec2 output -raw streamer_private_ip 2>/dev/null || echo "N/A"); \
	if [ "$$WEB_IP" != "N/A" ] && [ "$$STREAMER_IP" != "N/A" ]; then \
		echo "$(BLUE)🔐 SSH to streamer ($$STREAMER_IP) via $$WEB_IP...$(NC)"; \
		ssh -i $(SSH_KEY_BASE) -o ProxyJump=ubuntu@$$WEB_IP ubuntu@$$STREAMER_IP; \
	else \
		echo "$(RED)❌ Infrastructure not deployed$(NC)"; \
	fi

.PHONY: ansible-web
ansible-web: ## Configure web frontend server
	@echo "$(BLUE)🌐 Configuring web server...$(NC)"
	@if [ ! -f ansible/inventory.ini ]; then \
		echo "$(RED)❌ Inventory not found. Run first: make deploy$(NC)"; \
		exit 1; \
	fi
	@cd ansible && ansible-playbook -i inventory.ini web_frontend.yml

.PHONY: ansible-streamer
ansible-streamer: ## Configure streamer server
	@echo "$(BLUE)🎬 Configuring streamer server...$(NC)"
	@if [ ! -f ansible/inventory.ini ]; then \
		echo "$(RED)❌ Inventory not found. Run first: make deploy$(NC)"; \
		exit 1; \
	fi
	@cd ansible && ansible-playbook -i inventory.ini video_streamer.yml

.PHONY: clean
clean: ## Clean temporary files
	@echo "$(BLUE)🧹 Cleaning...$(NC)"
	@find . -name "*.tfstate*" -delete 2>/dev/null || true
	@find . -name ".terraform" -type d -exec rm -rf {} + 2>/dev/null || true
	@find . -name ".terraform.lock.hcl" -delete 2>/dev/null || true
	@rm -f ansible/inventory.ini ansible/group_vars/all.yml 2>/dev/null || true

.PHONY: fmt
fmt: ## Format Terraform code
	@echo "$(BLUE)🎨 Formatting...$(NC)"
	@terraform fmt -recursive terraform/

.PHONY: lint
lint: ## Run TFLint
	@echo "$(BLUE)🔍 Running TFLint...$(NC)"
	@cd terraform && tflint --init && tflint --recursive

.PHONY: security
security: ## Run Checkov for security analysis
	@echo "$(BLUE)🛡️  Security analysis with Checkov...$(NC)"
	@checkov -d terraform/ -o cli --soft-fail || true

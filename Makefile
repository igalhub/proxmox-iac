.PHONY: lint test install-hooks check-hooks

lint:
	@files=$$(find . \( -path './.git' -o -path './.terraform' \) -prune -o -name '*.sh' -print); \
	[ -f hooks/pre-commit ] && files="$$files hooks/pre-commit"; \
	if [ -z "$$files" ]; then echo "No shell scripts found"; else shellcheck $$files; fi
	@if [ -d terraform ]; then terraform -chdir=terraform fmt -check -recursive && terraform -chdir=terraform validate; fi
	@if [ -d ansible ]; then ANSIBLE_ROLES_PATH="$$(pwd)/ansible/roles" ansible-lint ansible/; fi

test:
	@if [ -d landing/tests ] && ls landing/tests/*.py >/dev/null 2>&1; then \
		(cd landing && pytest -q); \
	else \
		echo "No landing/ test suite found"; \
	fi
	@echo "Terraform/Ansible/K8s verification is still terraform plan / ansible-lint / manual cluster checks (see docs/TICKETS.md QA steps per ticket) — PX-032/033/034/035 track automating those."

install-hooks:
	@mkdir -p .git/hooks
	cp hooks/pre-commit .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	@echo "Installed .git/hooks/pre-commit"

check-hooks:
	@if [ ! -x .git/hooks/pre-commit ]; then \
		echo "pre-commit hook missing or not executable — running install-hooks"; \
		$(MAKE) install-hooks; \
	else \
		echo "pre-commit hook OK"; \
	fi

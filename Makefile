.PHONY: lint test install-hooks check-hooks

lint:
	@files=$$(find . \( -path './.git' -o -path './.terraform' \) -prune -o -name '*.sh' -print); \
	[ -f hooks/pre-commit ] && files="$$files hooks/pre-commit"; \
	if [ -z "$$files" ]; then echo "No shell scripts found"; else shellcheck $$files; fi
	@if [ -d terraform ]; then terraform -chdir=terraform fmt -check -recursive && terraform -chdir=terraform validate; fi
	@if [ -d ansible ]; then ansible-lint ansible/; fi

test:
	@echo "No automated test suite yet — verification is terraform plan / ansible-lint / manual cluster checks (see docs/TICKETS.md QA steps per ticket)."

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

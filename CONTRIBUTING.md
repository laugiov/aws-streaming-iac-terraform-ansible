# Contributing to AWS Video Streaming Platform

Thank you for your interest in contributing to this project!

## How to Contribute

### Reporting Issues

If you find a bug or have a feature request, please open an issue on GitHub with:
- A clear description of the problem or feature
- Steps to reproduce (for bugs)
- Expected vs actual behavior
- Your environment (OS, Terraform version, Ansible version, etc.)

### Submitting Changes

1. **Fork the repository** and create your branch from `main`
2. **Make your changes** following the coding standards below
3. **Test your changes** thoroughly
4. **Submit a pull request** with a clear description of the changes

### Coding Standards

#### Terraform
- Run `terraform fmt` before committing
- Run `tflint` to check for issues
- Run `checkov` for security analysis
- Use meaningful resource names with the `mss-lab-` prefix
- Add descriptions to all variables

#### Ansible
- Follow Ansible best practices
- Use meaningful task names
- Test playbooks for idempotence (`changed=0` on re-run)

#### Shell Scripts
- Use `shellcheck` for linting
- Add comments for complex logic
- Use `set -euo pipefail` for error handling

### Pull Request Process

1. Ensure all tests pass
2. Update documentation if needed
3. Add a clear description of your changes
4. Reference any related issues

## Code of Conduct

Please be respectful and constructive in all interactions.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

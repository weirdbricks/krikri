# Crystal Ansible - Ansible-Compatible Automation Tool

**A lightweight automation tool that runs Ansible playbooks - written in Crystal**

[![Status](https://img.shields.io/badge/status-alpha-yellow)](https://github.com/weirdbricks/crystal-ansible)
[![Compatibility](https://img.shields.io/badge/ansible--compatibility-high-brightgreen)](https://github.com/weirdbricks/crystal-ansible)
[![Language](https://img.shields.io/badge/language-Crystal-black)](https://crystal-lang.org)

---

## 📋 Project Overview

Crystal Ansible is an automation tool written in Crystal that provides:
- **Ansible compatibility** - Run existing Ansible playbooks
- **Single binary deployment** - No dependencies, no Python required
- **10 production plugins** - Core modules for system automation
- **Clean codebase** - Written in Crystal for performance and maintainability

---

## ✨ Features

### Core Engine
- ✅ YAML playbook parser (Ansible syntax)
- ✅ Inventory management (INI + YAML)
- ✅ SSH connection pooling
- ✅ Variable substitution `{{ vars }}` with filters
- ✅ Conditionals `when:` (==, !=, <, >, and, or, not, in)
- ✅ Facts gathering (90+ ansible_* variables)
- ✅ Handlers (notify/listen)
- ✅ Check mode `--check` (dry-run)
- ✅ Diff mode `--diff` (show changes)

### Plugins (10 Total)
1. **copy** - File operations
2. **template** - Jinja2 templates
3. **file** - Directory/file management
4. **lineinfile** - Line-by-line file editing
5. **service** - Service control
6. **shell** - Shell commands
7. **command** - Simple execution
8. **apt** - Debian packages
9. **dnf** - RHEL packages
10. **package** - Universal (auto-detects OS)

---

## 🚀 Quick Start

### Prerequisites
- Crystal 1.10+ ([install guide](https://crystal-lang.org/install/))
- libssh2 development headers

### Build & Run

```bash
# Install dependencies
shards install

# Build
./build.sh

# Run a playbook
./bin/crystal-ansible playbook.yml

# With options
./bin/crystal-ansible --check --diff -i inventory.ini playbook.yml
```

---

## 📁 Project Structure

```
crystal-ansible/
├── crystal-play.cr              # Main CLI entry point
├── playbook_parser.cr           # YAML parsing
├── inventory_parser.cr          # Inventory handling
├── task_executor.cr             # Task execution engine
├── ssh_manager.cr               # SSH connection pooling
├── ssh_config.cr                # SSH configuration
├── variable_substitutor.cr      # {{ var }} processing
├── facts_gatherer.cr            # System facts collection
├── base_plugin.cr               # Plugin base class
├── copy.cr                      # File copying
├── template.cr                  # Jinja2 rendering
├── file.cr                      # File management
├── lineinfile.cr                # Line editing
├── service.cr                   # Service control
├── shell.cr                     # Shell execution
├── apt.cr                       # APT packages
├── dnf.cr                       # DNF packages
├── package.cr                   # Universal packages
├── build.sh                     # Build script
└── shard.yml                    # Dependencies
```

---

## 💡 Usage Example

```yaml
- name: Deploy app
  hosts: webservers
  tasks:
    - package:
        name: nginx
        state: present
    - service:
        name: nginx
        state: started
```

Supports standard Ansible playbook syntax. See [Ansible documentation](https://docs.ansible.com/) for playbook reference.

---

## 🎯 Command Reference

```bash
# Basic usage
./bin/crystal-ansible playbook.yml

# With inventory
./bin/crystal-ansible -i inventory.ini playbook.yml

# Dry-run (check mode)
./bin/crystal-ansible --check playbook.yml

# Show changes
./bin/crystal-ansible --diff playbook.yml

# Verbose output
./bin/crystal-ansible -v playbook.yml

# Multiple options
./bin/crystal-ansible --check --diff -i production.ini playbook.yml
```

---

## 🚧 Limitations

See [ROADMAP.md](ROADMAP.md) for the live, detailed tracking of what is implemented, what is not, and what is planned next.

---

## 🤝 Contributing

Contributions welcome! Please:

1. Review the existing code structure
2. Test your changes thoroughly
3. Submit a pull request with clear description

---

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- Inspired by [Ansible](https://www.ansible.com/)
- Built with [Crystal](https://crystal-lang.org/)
- Uses [ssh2.cr](https://github.com/spider-gazelle/ssh2.cr) and [crinja](https://github.com/straight-shoota/crinja)

---

**Crystal Ansible - Ansible-compatible automation in Crystal** 🚀

Run tests
=========

## Install dependencies
```bash
ansible-galaxy install -r ./tests/requirements.yml --roles-path ./tests/roles/
```

## Run tests
```bash
ANSIBLE_CONFIG=./tests/ansible.cfg ansible-playbook tests/test.yml
```

## Run with ansible in docker(docker-in-docker)
### Install dependencies
```bash
./tests/ops/bin/ansible ansible-galaxy install -r ./tests/requirements.yml --roles-path ./tests/roles/
```

### Run tests
```bash
./tests/ops/bin/ansible  ansible-playbook tests/test.yml
```

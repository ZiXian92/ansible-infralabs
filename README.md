# ansible-jenkins-docker

Single Ansible playbook repo that configures a **Jenkins controller** and a
**Docker host** (Podman's Docker-compatible API over **mTLS**) and registers the
host as a **Docker Cloud**. TLS material is pulled from **HashiCorp Vault** at run
time (see [`../vault-infra`](../vault-infra)).

Everything runs inside a **containerised executor** (`quay.io/podman/stable` +
Ansible + Molecule) because Ansible has no native Windows control node. The
executor mounts the host's rootless podman socket rather than nesting its own
podman engine, so everything Molecule creates lands as a **sibling** container on
the real host — see [`../docs/architecture.md`](../docs/architecture.md).

## Layout

```
executor/Containerfile     podman-based executor image (ansible + molecule + hvac)
ansible.cfg
requirements.yml           Galaxy collections
requirements.txt           pip deps (baked into the image)
inventory/                 static inventory + group_vars (env-sourced Vault config)
site.yml                   top-level playbook
roles/
  vault_certs/             retrieves CA/server/client PEMs from Vault (AppRole)
  docker_host/             Podman Docker-API over mTLS on tcp/2376 (podman system service)
  jenkins_controller/      installs/configures Jenkins + plugins + JCasC
  jenkins_docker_cloud/    registers the Docker Cloud (JCasC)
molecule/integration/      hermetic full-stack test: its own disposable Vault,
                           docker-host, and jenkins-controller, provisioned and
                           destroyed every run
tasks.ps1                  build image + run molecule/playbooks in the executor
```

## Prerequisites
- Podman Desktop for Windows; `podman-machine-default` running.
- `../vault-infra` is only needed for a **real** run against actual hosts
  (`site.yml`), which reads its persistent Vault's AppRole creds the same way
  `molecule/integration` reads its own ephemeral ones. The test suite in this repo
  is fully self-contained and does not depend on `../vault-infra` being up.

## Usage
```powershell
./tasks.ps1 build             # build the executor image (needs PyPI + Galaxy access)
./tasks.ps1 test-integration   # full hermetic test: own Vault + docker-host + jenkins-controller
./tasks.ps1 converge           # `molecule converge` (keep the instance up for inspection)
./tasks.ps1 verify             # `molecule verify`
./tasks.ps1 destroy            # `molecule destroy`
./tasks.ps1 shell              # poke around inside the executor
./tasks.ps1 lint               # ansible-lint
```

`molecule/integration` provisions and destroys its own Vault (dev mode), docker-host,
and jenkins-controller every run, on an isolated `iaclab-integration` network — see
[`../docs/architecture.md`](../docs/architecture.md) for the rationale.

## Linux/macOS equivalent (no PowerShell)

`tasks.ps1` is a thin wrapper around one `podman run` of the executor image plus a
`molecule`/`ansible-lint` command inside it. The executor mounts the host's rootless
podman socket (`CONTAINER_HOST`) so everything Molecule creates lands as a sibling
container on the host, not nested, and also mounts `../vault-infra` (at a separate
mount point, same host directory) so `molecule/integration`'s `prepare.yml`/
`destroy.yml` can run Terraform against their own ephemeral Vault sidecar:

```bash
VAULT_INFRA_DIR="$(cd ../vault-infra && pwd)"
RUN_ARGS=(
  -v /run/user/1000/podman/podman.sock:/run/podman/podman.sock:Z
  -e CONTAINER_HOST=unix:///run/podman/podman.sock
  --network iaclab-integration
  -v "$(pwd):/work" -w /work
  -v "$VAULT_INFRA_DIR:/vault-infra" -e HOST_VAULT_INFRA_DIR="$VAULT_INFRA_DIR"
  localhost/infra-lab/ansible-executor:latest
)
```

**build**:
```bash
podman build -t localhost/infra-lab/ansible-executor:latest -f executor/Containerfile .
```

**converge** / **verify** / **destroy** / **lint** / **shell**:
```bash
podman run --rm "${RUN_ARGS[@]}" molecule converge -s integration
# swap for `molecule verify -s integration`, `molecule destroy -s integration`,
# `ansible-lint`, or `bash` (add `-it`) as needed.
```

**test-integration** — fail-safe cleanup even if the test crashes partway through,
matching `tasks.ps1`'s PowerShell `try/finally`:
```bash
trap 'podman run --rm "${RUN_ARGS[@]}" molecule destroy -s integration' EXIT
podman run --rm "${RUN_ARGS[@]}" molecule test --destroy=always -s integration
```

## How Vault retrieval works
- `vault_certs` authenticates to Vault with **AppRole** and reads KV v2 paths
  `secret/jenkins/docker-mtls/{ca,server,client}`.
- The reads are **delegated to the control node** (the executor has `hvac`), then
  the PEMs are copied to the managed host — so targets need no Vault access.
- Which PEMs a host gets is driven by group membership
  (`inventory/group_vars/docker_hosts.yml`, `jenkins_controllers.yml`).

## Status
All four roles are implemented: `vault_certs`, `docker_host` (native Podman mTLS via
`podman system service`), `jenkins_controller` (from-scratch install for real hosts,
guarded by `jenkins_manage_packages`), and `jenkins_docker_cloud` (JCasC Docker Cloud
registration with live reload). See
[`../docs/architecture.md`](../docs/architecture.md#5-roadmap) for what's next.

# role: vault_certs

Retrieves the Docker mTLS material from HashiCorp Vault (KV v2) using **AppRole**
auth and writes the PEMs a host needs. Vault reads are **delegated to the control
node** (the executor has `hvac`), so managed hosts need neither Vault access nor
`hvac`.

## Variables (see `defaults/main.yml`)

| Var | Default | Purpose |
|-----|---------|---------|
| `vault_addr` | `http://vault:8200` | Vault API (from env via group_vars) |
| `vault_role_id` / `vault_secret_id` | `""` | AppRole creds (from env) |
| `vault_kv_mount` | `secret` | KV v2 mount |
| `vault_cert_base` | `jenkins/docker-mtls` | Base KV path |
| `vault_certs_install_ca/server/client` | `true`/`false`/`false` | Which PEMs to write |
| `vault_certs_dir` | `/etc/pki/mtls` | Output directory |

## Outputs (files under `vault_certs_dir`)
- `ca.pem` (when `install_ca`)
- `server-cert.pem`, `server-key.pem` (when `install_server`)
- `client-cert.pem`, `client-key.pem` (when `install_client`)

Group membership decides the set: `docker_hosts` get CA+server, `jenkins_controllers`
get CA+client (see `inventory/group_vars/`).

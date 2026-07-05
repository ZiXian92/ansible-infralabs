# role: docker_host

Turns a host into a Jenkins build agent that exposes the **Docker-compatible API
over mTLS** (via `podman system service`) on `tcp/2376`.

Depends on [`vault_certs`](../vault_certs) for the CA + server cert/key.

**Implemented:** cert retrieval, Podman install (`docker_host_manage_packages`), and a
templated `podman-api-tls` systemd unit that runs `podman system service` with native
mTLS (`--tls-cert`/`--tls-key`/`--tls-client-ca`, Podman 5.7+) on
`docker_host_tls_port`. Cert rotation restarts the service via the `restart docker api`
handler, notified from `vault_certs`'s server-cert copy task.

**Out of scope:** firewall management — test containers don't run firewalld, and on a
real host, network policy for `docker_host_tls_port` is an operator decision.

See [`../../../docs/architecture.md`](../../../docs/architecture.md#25-docker-host--podmans-docker-compatible-api).

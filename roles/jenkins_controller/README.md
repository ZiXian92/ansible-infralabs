# role: jenkins_controller

Installs and configures the Jenkins controller, including the plugins needed for
the Docker Cloud (`docker-plugin`) and JCasC.

Depends on [`vault_certs`](../vault_certs) for the CA + client cert/key used to
authenticate to the Docker host.

**Implemented:**
- Cert retrieval wiring.
- When `jenkins_controller_manage_packages` (default `true`, the real-host path used by
  `site.yml`): Java + Jenkins LTS from the official RPM repo, setup wizard disabled,
  a base JCasC config (local security realm + `jenkins_controller_admin_user`/
  `jenkins_controller_admin_password` — lab-grade, see `defaults/main.yml`), and the plugins in
  `jenkins_controller_plugins`.
- `molecule/integration` sets `jenkins_controller_manage_packages: false` because its
  jenkins-controller platform is built from the official Jenkins container image,
  which already bakes Jenkins, the plugins, and a base JCasC file — that scenario
  only exercises the Docker Cloud registration path.

The Docker Cloud definition itself lives in
[`jenkins_docker_cloud`](../jenkins_docker_cloud).

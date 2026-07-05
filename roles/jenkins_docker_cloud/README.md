# role: jenkins_docker_cloud

Registers the Docker host as a **Docker Cloud** on the Jenkins controller,
connecting to `jenkins_cloud_docker_host_uri` (e.g. `tcp://docker-host:2376`) over
**mTLS** with the client cert/key from Vault. Mechanism: **JCasC** (declarative, in
code).

`jenkins_cloud_docker_host_uri` and `jenkins_cloud_agent_image` have no role
default -- they're deployment-specific, so real runs set them in
`inventory/group_vars/jenkins_controllers.yml` and `molecule/integration`'s
`converge.yml` sets its own play vars.

**Implemented:** slurps the CA/client cert/key already installed by
`jenkins_controller`'s `vault_certs` include, templates an additional JCasC fragment
(`020-docker-cloud.yaml`, merged alongside the base config JCasC already applies)
containing an `x509ClientCert` credential (docker-commons'
`DockerServerCredentials`, JCasC symbol `x509ClientCert`) and the
`jenkins.clouds.docker` block, then reloads JCasC live via
`community.general.jenkins_script` — no controller restart needed.

`molecule/integration`'s `verify.yml` asserts the cloud is registered and that an
actual mTLS handshake to the Docker host succeeds. It deliberately does **not** have
Jenkins launch a real build agent through the cloud (that would add a fourth
container-nesting level) — that path is exercised manually against the real lab.

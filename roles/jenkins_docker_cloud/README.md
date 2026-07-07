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

`molecule/integration`'s `verify.yml` asserts the cloud is registered, that an
actual mTLS handshake to the Docker host succeeds, and that Jenkins can actually
launch a build agent through the cloud: it runs a real Pipeline job with
`agent { label 'docker' }`, waits for the Docker Cloud to provision the agent
container, and asserts the build succeeds with the expected output. `converge.yml`
pre-pulls the agent image (`jenkins_cloud_agent_image`) onto the docker-host itself
first, so the job's own wait window isn't spent on a live Docker Hub pull from a
nested host with less reliable network/DNS egress.

`jenkins_cloud_agent_network` (also no role default) sets `dockerTemplateBase`'s
`network:`. `molecule/integration` sets it to `none`: its docker-host is itself a
Podman container, and agent containers launched on the default bridge network fail
outright there (`netavark: nftables error: "nft" did not return successfully while
applying ruleset` -- the nested host's kernel doesn't expose the NAT/nftables
support netavark needs). The `attach` connector never needs the agent container to
reach out over a network of its own -- Jenkins drives it entirely via `docker exec`
over the already-established mTLS Docker-API connection -- so `none` is both
sufficient and side-steps the nested-networking limitation. A real docker-host
running on an actual machine shouldn't need this override.

<#
.SYNOPSIS
  Build the Ansible/Molecule executor image and run playbooks/tests inside it.
  (Ansible has no native Windows control node, so everything runs in the container.)

.EXAMPLE
  ./tasks.ps1 build             # build the executor image
  ./tasks.ps1 converge          # `molecule converge` (keep the instance for inspection)
  ./tasks.ps1 verify            # `molecule verify`
  ./tasks.ps1 test-integration  # full test with guaranteed cleanup (--destroy=always
                                 # + a PowerShell try/finally fail-safe)
  ./tasks.ps1 destroy           # `molecule destroy`
  ./tasks.ps1 shell             # interactive shell in the executor
  ./tasks.ps1 lint              # ansible-lint

.NOTES
  molecule/integration is a hermetic scenario: it provisions and destroys its own
  Vault, docker-host, and jenkins-controller every run, on an isolated
  `iaclab-integration` network -- kept separate from vault-infra's persistent-Vault
  `iaclab` network, which this repo's tests no longer depend on.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('build', 'converge', 'verify', 'destroy', 'test-integration', 'shell', 'lint')]
  [string]$Action = 'test-integration'
)

$ErrorActionPreference = 'Stop'
$root          = $PSScriptRoot
$image         = 'localhost/infra-lab/ansible-executor:latest'
$network       = 'iaclab-integration'
$podmanSocket  = '/run/user/1000/podman/podman.sock'
$vaultInfraWin = (Resolve-Path (Join-Path $root '..\vault-infra')).Path

# HOST_VAULT_INFRA_DIR is used by prepare.yml/destroy.yml as the bind-mount SOURCE
# for a *sibling* terraform container, launched via `podman run` issued from
# *inside* the executor (the Linux podman client, over CONTAINER_HOST) -- not the
# Windows podman.exe client this script itself uses. The Windows client has
# special-case handling that lets it accept a raw "F:\..." path for -v (that's how
# the executor's own mounts below work), but the Linux client does not: it just
# splits "-v SRC:DST" on ':', so a raw Windows drive-letter path ("F:\...") is
# ambiguous with that separator ("invalid option type" from podman). Podman
# Desktop's WSL2 machine already auto-mounts Windows drives at /mnt/<drive>/...
# (standard WSL behavior), which has no colons and works from the Linux client --
# so translate to that form here instead of passing the Windows path through.
$vaultInfraDir = '/mnt/' + $vaultInfraWin.Substring(0, 1).ToLower() + ($vaultInfraWin.Substring(2) -replace '\\', '/')

function Initialize-ScenarioNetwork {
  # The executor itself must join this network to run (delegated Vault reads,
  # reaching Molecule-created platforms by name), but molecule/integration's own
  # prepare.yml -- which normally creates it -- only runs *inside* the executor.
  # Create it here first so `podman run --network ...` for the executor itself
  # doesn't fail with "network not found" on a completely fresh environment.
  podman network exists $network 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "==> Creating network '$network'" -ForegroundColor Cyan
    podman network create $network | Out-Null
  }
}

function Remove-ScenarioNetwork {
  # destroy.yml also tries to remove this network, but that attempt runs *inside*
  # the executor while the executor itself is still attached to it (this whole
  # `podman run` is still in flight) -- `podman network rm` can never succeed
  # under that condition. The removal that actually works has to happen here,
  # after Invoke-Executor's `podman run` has returned and the executor container
  # is gone.
  podman network exists $network 2>$null
  if ($LASTEXITCODE -eq 0) {
    podman network rm $network 2>$null | Out-Null
  }
}

function Invoke-Executor {
  param([string[]]$Cmd, [switch]$Interactive)
  Initialize-ScenarioNetwork
  $runFlags = @('--rm')
  if ($Interactive) { $runFlags += '-it' }
  # Mount the host's rootless podman socket so the executor's own `podman` CLI and
  # Molecule's podman driver both talk to the HOST engine -> everything they create
  # lands as a sibling container, not nested inside the executor. vault-infra is
  # also mounted (at a separate mount point, same host directory) so
  # molecule/integration's prepare.yml/destroy.yml can run Terraform against their
  # own ephemeral Vault sidecar and stage scratch files -- see prepare.yml for why
  # both the executor's own mount and the HOST_VAULT_INFRA_DIR host-path string are
  # needed (sibling containers resolve bind-mount sources against the host, not this
  # container's filesystem).
  $runFlags += @(
    '-v', "$($podmanSocket):/run/podman/podman.sock:Z",
    '-e', 'CONTAINER_HOST=unix:///run/podman/podman.sock',
    '--network', $network,
    '-v', "$($root):/work", '-w', '/work',
    '-v', "$($vaultInfraWin):/vault-infra",
    '-e', "HOST_VAULT_INFRA_DIR=$vaultInfraDir"
  )
  Write-Host "==> [executor] $($Cmd -join ' ')" -ForegroundColor Cyan
  podman run @runFlags $image @Cmd
  if ($LASTEXITCODE -ne 0) { throw "executor command failed: $($Cmd -join ' ')" }
}

switch ($Action) {
  'build' {
    Write-Host "==> Building $image" -ForegroundColor Cyan
    podman build -t $image -f "$root\executor\Containerfile" $root
    if ($LASTEXITCODE -ne 0) { throw "build failed" }
  }
  'converge' { Invoke-Executor -Cmd @('molecule', 'converge', '-s', 'integration') }
  'verify'   { Invoke-Executor -Cmd @('molecule', 'verify', '-s', 'integration') }
  'destroy'  {
    Invoke-Executor -Cmd @('molecule', 'destroy', '-s', 'integration')
    Remove-ScenarioNetwork
  }
  'lint'     { Invoke-Executor -Cmd @('ansible-lint') }
  'shell'    { Invoke-Executor -Cmd @('bash') -Interactive }
  'test-integration' {
    try {
      Invoke-Executor -Cmd @('molecule', 'test', '--destroy=always', '-s', 'integration')
    } finally {
      # Fail-safe in case Molecule itself crashed before its own destroy ran.
      Write-Host "==> [test-integration] fail-safe destroy" -ForegroundColor Yellow
      try {
        Invoke-Executor -Cmd @('molecule', 'destroy', '-s', 'integration')
      } catch {
        Write-Warning "fail-safe destroy also failed: $_"
      }
      Remove-ScenarioNetwork
    }
  }
}

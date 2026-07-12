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
  Vault, docker-host, and jenkins-controller every run -- entirely natively in
  Ansible (community.crypto for certs, raw Vault HTTP API calls for the rest) on
  an isolated `iaclab-integration` network. It has no dependency on vault-infra
  or its Terraform config at all.
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
  # lands as a sibling container, not nested inside the executor.
  $runFlags += @(
    '-v', "$($podmanSocket):/run/podman/podman.sock:Z",
    '-e', 'CONTAINER_HOST=unix:///run/podman/podman.sock',
    '--network', $network,
    '-v', "$($root):/work", '-w', '/work'
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

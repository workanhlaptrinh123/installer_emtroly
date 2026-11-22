function Test-MemberInstallerSettings {
  param([Parameter(Mandatory=$true)][psobject]$Settings)
  if ([string]$Settings.member -cnotmatch '^[a-z][a-z0-9_-]{0,63}$') { throw 'invalid-member' }
  if ([string]::IsNullOrWhiteSpace([string]$Settings.assistant_name)) { throw 'missing-assistant-name' }
  if ([string]$Settings.owner_ids -notmatch '^[1-9][0-9]*(,[1-9][0-9]*)*$') { throw 'invalid-owners' }
  if ([string]$Settings.group_id -notmatch '^-[1-9][0-9]*$') { throw 'invalid-group' }
  if ([string]$Settings.telegram_token -notmatch '^[0-9]{5,}:[A-Za-z0-9_-]{20,}$') { throw 'invalid-telegram-token' }
  if ([string]::IsNullOrWhiteSpace([string]$Settings.ai_api_key)) { throw 'missing-api-key' }
  if ([string]$Settings.model -notin @('gpt-6.2-sol', 'GPT-6.1-terra', 'gpt-6.2-astra')) { throw 'invalid-model' }
  $uri = $null
  if (-not [uri]::TryCreate([string]$Settings.base_url, [UriKind]::Absolute, [ref]$uri) -or
      $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'invalid-base-url' }
  $port = 0
  if (-not [int]::TryParse([string]$Settings.gateway_port, [ref]$port) -or
      ($port -ne 0 -and ($port -lt 1024 -or $port -gt 65000))) { throw 'invalid-port' }
  if (-not [bool]$Settings.accept_full_access) { throw 'full-access-consent-required' }
  if ([bool]$Settings.configure_zalo) {
    $qrOwner = [string]$Settings.qr_owner_id
    if ($qrOwner -notmatch '^[1-9][0-9]*$' -or $qrOwner -notin ([string]$Settings.owner_ids -split ',')) { throw 'invalid-qr-owner' }
  }
}

function Test-MemberInstallerPermissions {
  param(
    [Parameter(Mandatory=$true)][psobject]$Settings,
    [Parameter(Mandatory=$true)][psobject]$Config,
    [Parameter(Mandatory=$true)][psobject]$ApprovalState
  )
  $accountName = [string]$Settings.member
  $telegram = $Config.channels.telegram
  $account = $telegram.accounts.$accountName
  $binding = @($Config.bindings | Where-Object {
    $_.agentId -eq 'main' -and $_.match.channel -eq 'telegram' -and $_.match.accountId -eq $accountName
  })
  if ($binding.Count -ne 1) { throw 'owner-permissions-check-failed' }
  foreach ($owner in ([string]$Settings.owner_ids -split ',')) {
    if ("telegram:$owner" -notin @($Config.commands.ownerAllowFrom) -or
        $owner -notin @($telegram.allowFrom) -or $owner -notin @($account.allowFrom) -or
        $owner -notin @($telegram.execApprovals.approvers) -or $owner -notin @($account.execApprovals.approvers)) {
      throw 'owner-permissions-check-failed'
    }
    foreach ($kind in @('exec', 'plugin')) {
      $policy = $Config.approvals.$kind
      $targets = @($policy.targets | Where-Object {
        $_.channel -eq 'telegram' -and $_.accountId -eq $accountName -and [string]$_.to -eq $owner
      })
      if ($policy.enabled -ne $true -or $policy.mode -ne 'targets' -or
          'main' -notin @($policy.agentFilter) -or $targets.Count -eq 0) {
        throw 'owner-permissions-check-failed'
      }
    }
  }
  foreach ($policy in @($Config.tools.exec, $Config.agents.entries.main.tools.exec)) {
    if ($policy.host -ne 'gateway' -or $policy.mode -ne 'full' -or $policy.strictInlineEval -ne $false) {
      throw 'approval-check-failed'
    }
  }
  $agentApproval = $ApprovalState.file.agents.main
  if ($agentApproval.security -ne 'full' -or $agentApproval.ask -ne 'off' -or
      $agentApproval.askFallback -ne 'full') { throw 'approval-check-failed' }
}

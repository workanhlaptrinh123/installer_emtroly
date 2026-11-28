function Remove-EmTroLyNpmSecrets {
  param(
    [string]$Text = '',
    [string[]]$Secrets = @()
  )
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $clean = [string]$Text
  foreach ($sec in @($Secrets)) {
    if (-not [string]::IsNullOrWhiteSpace($sec) -and $sec.Length -ge 6) {
      $clean = $clean.Replace($sec, '[REDACTED_SECRET]')
    }
  }
  $clean = [regex]::Replace($clean, '[0-9]{5,}:[A-Za-z0-9_-]{20,}', '[REDACTED_TELEGRAM_TOKEN]')
  $clean = [regex]::Replace($clean, 'sk-[A-Za-z0-9_-]{12,}', '[REDACTED_API_KEY]')
  $clean = [regex]::Replace($clean, '("token"\s*:\s*")[0-9a-fA-F]{24,}(")', '$1[REDACTED_GATEWAY_TOKEN]$2')
  return $clean
}

function Test-IsNpmTlsCipherError {
  param([string]$LogText = '')
  if ([string]::IsNullOrWhiteSpace($LogText)) { return $false }
  return ($LogText -match '(?i)ERR_SSL_CIPHER_OPERATION_FAILED|ERR_SSL_DECRYPTION_FAILED_OR_BAD_RECORD_MAC|ERR_SSL_BAD_RECORD_MAC|ossl_gcm_stream_update|ciphercommon_gcm|bad record mac|cipher operation failed|decryption failed|tlsv1 alert|ssl3_get_record|SSL routines')
}

function Test-IsNpmCacheOrTarballCorruptError {
  param([string]$LogText = '')
  if ([string]::IsNullOrWhiteSpace($LogText)) { return $false }
  if (Test-IsNpmTlsCipherError -LogText $LogText) { return $true }
  return ($LogText -match '(?i)EINTEGRITY|sha512-|Z_DATA_ERROR|TAR_BAD_ARCHIVE|unexpected end of file|premature close|zlib|EBADF|ENOENT.*_cacache|corrupted?')
}

function Get-EmTroLyNodeVersionInfo {
  param([string]$VersionText = '')
  $m = [regex]::Match([string]$VersionText, 'v?(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $null }
  return [pscustomobject]@{
    Major = [int]$m.Groups[1].Value
    Minor = [int]$m.Groups[2].Value
    Patch = [int]$m.Groups[3].Value
    Full  = "v$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
  }
}

function Test-EmTroLyPeBinaryFile {
  param([string]$FilePath = '')
  if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
  try {
    $fs = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      if ($fs.Length -lt 64) { return $false }
      $b0 = $fs.ReadByte()
      $b1 = $fs.ReadByte()
      return ($b0 -eq 0x4D -and $b1 -eq 0x5A)
    } finally {
      $fs.Dispose()
    }
  } catch {
    return $false
  }
}

function Get-EmTroLyNodeCandidateMetadata {
  param(
    [Parameter(Mandatory=$true)][string]$NodeExe,
    [Parameter(Mandatory=$true)][string]$NpmCmd,
    [bool]$IsBundled = $false,
    [string]$Origin = 'machine'
  )
  $nodeDir = Split-Path -Parent $NodeExe
  $verText = ''
  $archText = ''
  $archOk = $true

  if (Test-EmTroLyPeBinaryFile -FilePath $NodeExe) {
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $NodeExe
      $psi.Arguments = '-e "console.log(process.versions.node + ''|'' + process.arch)"'
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
      $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
      [void]$psi.EnvironmentVariables.Remove('NODE_OPTIONS')
      $proc = New-Object System.Diagnostics.Process
      $proc.StartInfo = $psi
      [void]$proc.Start()
      $outTask = $proc.StandardOutput.ReadToEndAsync()
      $errTask = $proc.StandardError.ReadToEndAsync()
      if ($proc.WaitForExit(5000)) {
        $proc.WaitForExit()
        if ($proc.ExitCode -eq 0) {
          $probeLine = ($outTask.GetAwaiter().GetResult()).Trim()
          if ($probeLine -match '^(\d+\.\d+\.\d+)\|([A-Za-z0-9_]+)$') {
            $verText = "v$($Matches[1])"
            $archText = $Matches[2].ToLowerInvariant()
          }
        }
      } else {
        try { $proc.Kill() } catch { }
      }
      $proc.Dispose()
    } catch { }

    if (-not $verText) {
      try {
        $psiV = New-Object System.Diagnostics.ProcessStartInfo
        $psiV.FileName = $NodeExe
        $psiV.Arguments = '--version'
        $psiV.UseShellExecute = $false
        $psiV.CreateNoWindow = $true
        $psiV.RedirectStandardOutput = $true
        $psiV.RedirectStandardError = $true
        [void]$psiV.EnvironmentVariables.Remove('NODE_OPTIONS')
        $procV = New-Object System.Diagnostics.Process
        $procV.StartInfo = $psiV
        [void]$procV.Start()
        $outTaskV = $procV.StandardOutput.ReadToEndAsync()
        if ($procV.WaitForExit(5000)) {
          $procV.WaitForExit()
          if ($procV.ExitCode -eq 0) {
            $verText = ($outTaskV.GetAwaiter().GetResult()).Trim()
          }
        } else {
          try { $procV.Kill() } catch { }
        }
        $procV.Dispose()
      } catch { }
    }
  }

  $dirLeaf = Split-Path -Leaf $nodeDir
  if (-not $verText -and $dirLeaf -match 'node-v(\d+\.\d+\.\d+)') {
    $verText = "v$($Matches[1])"
  }
  if (-not $archText -and $dirLeaf -match 'win-(x64|arm64|x86)') {
    $archText = $Matches[1].ToLowerInvariant()
  }
  if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -and $archText -and $archText -ne 'x64') {
    $archOk = $false
  }

  $verInfo = Get-EmTroLyNodeVersionInfo -VersionText $verText
  $major = if ($verInfo) { $verInfo.Major } else { 0 }
  $minor = if ($verInfo) { $verInfo.Minor } else { 0 }
  $isSupportedPrimary = (($major -eq 24 -and $minor -ge 16) -or ($major -eq 26 -and $minor -ge 1) -or ($major -gt 26))
  $isLts = ($major -in @(22, 20)) -and $archOk

  return [pscustomobject]@{
    NodeExe            = $NodeExe
    NpmCmd             = $NpmCmd
    NodeDir            = $nodeDir
    Version            = $(if ($verInfo) { $verInfo.Full } else { $verText })
    Major              = $major
    Minor              = $minor
    Patch              = $(if ($verInfo) { $verInfo.Patch } else { 0 })
    Arch               = $archText
    ArchOk             = $archOk
    IsBundled          = $IsBundled
    IsSupportedPrimary = $isSupportedPrimary
    IsLts              = $isLts
    Origin             = $Origin
  }
}

function Resolve-EmTroLyNodeToolchains {
  param(
    [string]$PayloadRoot = '',
    [string]$OpenClawRoot = '',
    [string]$LocalAppData = ''
  )
  $localBase = if (-not [string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData } else { $env:LOCALAPPDATA }
  $candidatesRaw = New-Object System.Collections.Generic.List[object]

  if ($OpenClawRoot) {
    $instFile = Join-Path $OpenClawRoot 'installer-instance.json'
    if (Test-Path -LiteralPath $instFile -PathType Leaf) {
      try {
        $instObj = [IO.File]::ReadAllText($instFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($instObj -and $instObj.PSObject.Properties['node'] -and $instObj.node) {
          $instNode = [string]$instObj.node
          if (Test-Path -LiteralPath $instNode -PathType Leaf) {
            [void]$candidatesRaw.Add([pscustomobject]@{ Dir = (Split-Path -Parent $instNode); Bundled = $true; Origin = 'instance' })
          }
        }
      } catch { }
    }
  }

  $depBase = if ($localBase) { Join-Path $localBase 'MemberInstaller\dependencies' } else { '' }
  if ($depBase -and (Test-Path -LiteralPath $depBase -PathType Container)) {
    foreach ($d in @(Get-ChildItem -LiteralPath $depBase -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
      [void]$candidatesRaw.Add([pscustomobject]@{ Dir = $d.FullName; Bundled = $true; Origin = 'member-bundled' })
    }
  }

  if ($PayloadRoot -and (Test-Path -LiteralPath $PayloadRoot -PathType Container)) {
    foreach ($sub in @('dependencies', 'native', '.')) {
      $scanDir = if ($sub -eq '.') { $PayloadRoot } else { Join-Path $PayloadRoot $sub }
      if (Test-Path -LiteralPath $scanDir -PathType Container) {
        foreach ($d in @(Get-ChildItem -LiteralPath $scanDir -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
          [void]$candidatesRaw.Add([pscustomobject]@{ Dir = $d.FullName; Bundled = $true; Origin = 'payload-bundled' })
        }
      }
    }
  }

  foreach ($stdDir in @(
    $(if ($env:EMTROLY_IGNORE_SYSTEM_NODE -ne '1' -and $env:ProgramFiles) { Join-Path $env:ProgramFiles 'nodejs' }),
    $(if ($env:EMTROLY_IGNORE_SYSTEM_NODE -ne '1' -and $localBase) { Join-Path $localBase 'Programs\nodejs' })
  )) {
    if ($stdDir -and (Test-Path -LiteralPath $stdDir -PathType Container)) {
      [void]$candidatesRaw.Add([pscustomobject]@{ Dir = $stdDir; Bundled = $false; Origin = 'system-default' })
    }
  }

  if ($env:EMTROLY_IGNORE_SYSTEM_NODE -ne '1' -and $env:APPDATA) {
    $nvmDir = Join-Path $env:APPDATA 'nvm'
    if (Test-Path -LiteralPath $nvmDir -PathType Container) {
      foreach ($nd in @(Get-ChildItem -LiteralPath $nvmDir -Directory -Filter 'v*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        [void]$candidatesRaw.Add([pscustomobject]@{ Dir = $nd.FullName; Bundled = $false; Origin = 'nvm' })
      }
    }
  }

  if ($env:EMTROLY_IGNORE_SYSTEM_NODE -ne '1') {
    foreach ($cmdHit in @(Get-Command node.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
      if ($cmdHit.Source -and $cmdHit.Source -notlike '*\WindowsApps\*') {
        [void]$candidatesRaw.Add([pscustomobject]@{ Dir = (Split-Path -Parent $cmdHit.Source); Bundled = $false; Origin = 'path' })
      }
    }
  }

  $seenDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $resolved = New-Object System.Collections.Generic.List[object]

  foreach ($item in $candidatesRaw) {
    if (-not $item.Dir) { continue }
    $normDir = try { [IO.Path]::GetFullPath($item.Dir).TrimEnd('\') } catch { $item.Dir.TrimEnd('\') }
    if (-not $seenDirs.Add($normDir)) { continue }
    $nodeExeCand = Join-Path $normDir 'node.exe'
    $npmCmdCand = Join-Path $normDir 'npm.cmd'
    if ((Test-Path -LiteralPath $nodeExeCand -PathType Leaf) -and (Test-Path -LiteralPath $npmCmdCand -PathType Leaf)) {
      $meta = Get-EmTroLyNodeCandidateMetadata -NodeExe $nodeExeCand -NpmCmd $npmCmdCand -IsBundled ([bool]$item.Bundled) -Origin ([string]$item.Origin)
      [void]$resolved.Add($meta)
    }
  }

  # Last-resort pair if node.exe and npm.cmd live in separate PATH directories
  if ($resolved.Count -eq 0) {
    $nCmd = @(Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -and $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1)
    $mCmd = @(Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -and $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1)
    if ($nCmd.Count -gt 0 -and $mCmd.Count -gt 0) {
      $meta = Get-EmTroLyNodeCandidateMetadata -NodeExe $nCmd[0].Source -NpmCmd $mCmd[0].Source -IsBundled $false -Origin 'path-split'
      [void]$resolved.Add($meta)
    } elseif ($mCmd.Count -gt 0) {
      $npmDir = Split-Path -Parent $mCmd[0].Source
      $nodeSibling = Join-Path $npmDir 'node.exe'
      $nodePathUse = if (Test-Path -LiteralPath $nodeSibling -PathType Leaf) { $nodeSibling } else { $mCmd[0].Source }
      $meta = Get-EmTroLyNodeCandidateMetadata -NodeExe $nodePathUse -NpmCmd $mCmd[0].Source -IsBundled $false -Origin 'npm-only'
      [void]$resolved.Add($meta)
    }
  }

  $allResolved = $resolved.ToArray()
  $primary = $allResolved | Where-Object { $_.IsBundled -and $_.IsSupportedPrimary } | Select-Object -First 1
  if (-not $primary) { $primary = $allResolved | Where-Object { $_.IsBundled } | Select-Object -First 1 }
  if (-not $primary) { $primary = $allResolved | Where-Object { $_.IsSupportedPrimary } | Select-Object -First 1 }
  if (-not $primary -and $allResolved.Count -gt 0) { $primary = $allResolved[0] }

  $primaryKey = if ($primary) { $primary.NodeExe.ToLowerInvariant() } else { '' }
  $lts = $allResolved | Where-Object { $_.IsBundled -and $_.Major -eq 22 -and $_.ArchOk -and $_.NodeExe.ToLowerInvariant() -ne $primaryKey } | Select-Object -First 1
  if (-not $lts) { $lts = $allResolved | Where-Object { $_.IsBundled -and $_.Major -eq 20 -and $_.ArchOk -and $_.NodeExe.ToLowerInvariant() -ne $primaryKey } | Select-Object -First 1 }
  if (-not $lts) { $lts = $allResolved | Where-Object { $_.Major -eq 22 -and $_.ArchOk -and $_.NodeExe.ToLowerInvariant() -ne $primaryKey } | Select-Object -First 1 }
  if (-not $lts) { $lts = $allResolved | Where-Object { $_.Major -eq 20 -and $_.ArchOk -and $_.NodeExe.ToLowerInvariant() -ne $primaryKey } | Select-Object -First 1 }

  return [pscustomobject]@{
    Primary = $primary
    Lts     = $lts
    All     = $allResolved
  }
}

function Wait-EmTroLyRuntimeProcessesExit {
  param(
    [Parameter(Mandatory=$true)][string]$TargetDir,
    [int]$WaitMs = 5000
  )
  if ([string]::IsNullOrWhiteSpace($TargetDir) -or $env:EMTROLY_SKIP_PROCESS_SWEEP -eq '1') { return }
  $needles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $rawTrim = $TargetDir.Trim().TrimEnd('\')
  if ($rawTrim) { [void]$needles.Add($rawTrim) }
  try {
    $fullTrim = [IO.Path]::GetFullPath($TargetDir).TrimEnd('\')
    if ($fullTrim) { [void]$needles.Add($fullTrim) }
  } catch { }
  if (Test-Path -LiteralPath $TargetDir) {
    try {
      $fso = New-Object -ComObject Scripting.FileSystemObject
      $shortFolder = $fso.GetFolder($TargetDir).ShortPath
      if ($shortFolder) { [void]$needles.Add($shortFolder.TrimEnd('\')) }
    } catch { }
  }
  if ($needles.Count -eq 0) { return }
  $needleList = @($needles)

  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $matching = @()
    try {
      $matching = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe' OR Name = 'npm.cmd'" -ErrorAction SilentlyContinue | Where-Object {
        if (-not $_.ProcessId -or ([int]$_.ProcessId -eq $PID) -or -not $_.CommandLine) { return $false }
        $cmdLineText = [string]$_.CommandLine
        foreach ($ndl in $needleList) {
          if ($cmdLineText.IndexOf($ndl, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
        return $false
      })
    } catch { $matching = @() }
    if ($matching.Count -eq 0) { return }
    if ($sw.ElapsedMilliseconds -ge $WaitMs) {
      foreach ($procItem in $matching) {
        try {
          $pObj = Get-Process -Id ([int]$procItem.ProcessId) -ErrorAction SilentlyContinue
          if ($pObj) {
            Stop-Process -Id ([int]$procItem.ProcessId) -Force -ErrorAction SilentlyContinue
            [void]$pObj.WaitForExit(3000)
          }
        } catch { }
      }
      return
    }
    Start-Sleep -Milliseconds 150
  }
}

function Clear-EmTroLyDirectorySafe {
  param([Parameter(Mandatory=$true)][string]$DirPath)
  if ([string]::IsNullOrWhiteSpace($DirPath) -or -not (Test-Path -LiteralPath $DirPath)) { return }
  try {
    $item = Get-Item -LiteralPath $DirPath -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
  } catch { return }

  $cmdExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\cmd.exe' } else { 'cmd.exe' }
  if (Test-Path -LiteralPath $cmdExe -PathType Leaf) {
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $cmdExe
      $psi.Arguments = '/d /s /c "rmdir /s /q "' + $DirPath + '""'
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
      $proc = [System.Diagnostics.Process]::Start($psi)
      [void]$proc.WaitForExit(20000)
      $proc.Dispose()
    } catch { }
  }
  if (Test-Path -LiteralPath $DirPath) {
    Remove-Item -LiteralPath $DirPath -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Format-EmTroLyCmdArg {
  param([string]$Value = '')
  if ($Value -match '[\r\n\x00]') { throw 'Invalid command argument.' }
  if ($Value.Length -gt 0 -and $Value -notmatch '[\s"&()^%;,=]') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

$script:EmTroLySChannelBridgeCSharp = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace EmTroLy {
  public sealed class NpmSChannelBridge : IDisposable {
    private readonly string _upstreamBase;
    private readonly Uri _upstreamUri;
    private readonly string _fallbackBase;
    private readonly Uri _fallbackUri;
    private readonly bool _allowLocalHttp;
    private readonly string _curlPath;
    private readonly HashSet<string> _allowedHosts;
    private TcpListener _listener;
    private Thread _acceptThread;
    private volatile bool _stopped;
    private int _requestCount;
    private int _curlFallbackCount;
    private int _errorCount;
    private string _lastError = "";

    public int Port { get; private set; }
    public string ProxyUrl { get; private set; }
    public int RequestCount { get { return _requestCount; } }
    public int CurlFallbackCount { get { return _curlFallbackCount; } }
    public int ErrorCount { get { return _errorCount; } }
    public string LastError { get { return _lastError; } }

    public NpmSChannelBridge(string upstreamRegistryUrl, string[] allowedHosts, string curlPath)
      : this(upstreamRegistryUrl, "", allowedHosts, curlPath) {
    }

    public NpmSChannelBridge(string upstreamRegistryUrl, string fallbackRegistryUrl, string[] allowedHosts, string curlPath) {
      _upstreamBase = (upstreamRegistryUrl ?? "").Trim().TrimEnd('/');
      _upstreamUri = new Uri(_upstreamBase + "/");
      _fallbackBase = (fallbackRegistryUrl ?? "").Trim().TrimEnd('/');
      _fallbackUri = !string.IsNullOrWhiteSpace(_fallbackBase) ? new Uri(_fallbackBase + "/") : null;
      _curlPath = curlPath ?? "";
      _allowedHosts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      _allowedHosts.Add("registry.npmjs.org");
      _allowedHosts.Add("registry.npmmirror.com");
      _allowedHosts.Add("cdn.npmmirror.com");
      _allowedHosts.Add("registry.yarnpkg.com");
      if (!string.IsNullOrEmpty(_upstreamUri.Host)) {
        _allowedHosts.Add(_upstreamUri.Host);
      }
      if (_fallbackUri != null && !string.IsNullOrEmpty(_fallbackUri.Host)) {
        _allowedHosts.Add(_fallbackUri.Host);
      }
      if (allowedHosts != null) {
        foreach (string h in allowedHosts) {
          if (!string.IsNullOrWhiteSpace(h)) {
            _allowedHosts.Add(h.Trim());
          }
        }
      }
      bool localUp = string.Equals(_upstreamUri.Scheme, "http", StringComparison.OrdinalIgnoreCase) && IsLoopbackHost(_upstreamUri.Host);
      bool localFb = _fallbackUri != null && string.Equals(_fallbackUri.Scheme, "http", StringComparison.OrdinalIgnoreCase) && IsLoopbackHost(_fallbackUri.Host);
      _allowLocalHttp = localUp || localFb;
    }

    public void Start() {
      if (_listener != null) { return; }
      _stopped = false;
      _listener = new TcpListener(IPAddress.Loopback, 0);
      _listener.Start(64);
      Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
      ProxyUrl = "http://127.0.0.1:" + Port.ToString(CultureInfo.InvariantCulture) + "/";
      _acceptThread = new Thread(AcceptLoop);
      _acceptThread.IsBackground = true;
      _acceptThread.Start();
    }

    public void Dispose() {
      _stopped = true;
      TcpListener lst = _listener;
      _listener = null;
      if (lst != null) {
        try { lst.Stop(); } catch { }
      }
    }

    private static bool IsLoopbackHost(string host) {
      if (string.IsNullOrEmpty(host)) { return false; }
      return string.Equals(host, "127.0.0.1", StringComparison.OrdinalIgnoreCase) ||
             string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase);
    }

    private bool IsAllowedHost(string hostPort) {
      if (string.IsNullOrWhiteSpace(hostPort)) { return false; }
      if (hostPort.IndexOfAny(new char[] { '/', '\\', '@', ' ', '\t', '\r', '\n' }) >= 0) { return false; }
      string host = hostPort;
      int colon = hostPort.IndexOf(':');
      if (colon > 0) {
        string portPart = hostPort.Substring(colon + 1);
        int portNum;
        if (!int.TryParse(portPart, NumberStyles.Integer, CultureInfo.InvariantCulture, out portNum) || portNum < 1 || portNum > 65535) {
          return false;
        }
        host = hostPort.Substring(0, colon);
      }
      if (string.IsNullOrWhiteSpace(host)) { return false; }
      if (_allowedHosts.Contains(host)) { return true; }
      string lower = host.ToLowerInvariant();
      return lower.EndsWith(".npmjs.org") || lower.EndsWith(".npmmirror.com") || lower.EndsWith(".yarnpkg.com");
    }

    private bool IsAllowedSchemeForHost(string scheme, string hostPort) {
      string hostOnly = hostPort;
      int colon = hostPort != null ? hostPort.IndexOf(':') : -1;
      if (colon > 0) { hostOnly = hostPort.Substring(0, colon); }
      if (string.Equals(scheme, "https", StringComparison.OrdinalIgnoreCase)) { return IsAllowedHost(hostPort); }
      if (_allowLocalHttp && string.Equals(scheme, "http", StringComparison.OrdinalIgnoreCase) && IsLoopbackHost(hostOnly)) { return true; }
      return false;
    }

    private void AcceptLoop() {
      while (!_stopped) {
        TcpListener lst = _listener;
        if (lst == null) { break; }
        try {
          TcpClient client = lst.AcceptTcpClient();
          ThreadPool.QueueUserWorkItem(HandleClientWork, client);
        } catch {
          if (_stopped) { break; }
          Thread.Sleep(20);
        }
      }
    }

    private void HandleClientWork(object state) {
      TcpClient client = state as TcpClient;
      if (client == null) { return; }
      HandleClient(client);
    }

    private void HandleClient(TcpClient client) {
      using (client) {
        try {
          client.ReceiveTimeout = 30000;
          client.SendTimeout = 180000;
          NetworkStream ns = client.GetStream();

          byte[] buf = new byte[8192];
          MemoryStream hdrBuf = new MemoryStream();
          int headerEnd = -1;
          while (headerEnd < 0 && hdrBuf.Length < 65536) {
            int read = ns.Read(buf, 0, buf.Length);
            if (read <= 0) { break; }
            hdrBuf.Write(buf, 0, read);
            byte[] cur = hdrBuf.ToArray();
            for (int i = 0; i <= cur.Length - 4; i++) {
              if (cur[i] == 13 && cur[i + 1] == 10 && cur[i + 2] == 13 && cur[i + 3] == 10) {
                headerEnd = i;
                break;
              }
            }
          }
          if (headerEnd < 0) { return; }

          byte[] allRead = hdrBuf.ToArray();
          string headerText = Encoding.ASCII.GetString(allRead, 0, headerEnd);
          string[] headerLines = headerText.Split(new string[] { "\r\n" }, StringSplitOptions.None);
          if (headerLines.Length == 0) { return; }

          string[] reqParts = headerLines[0].Split(' ');
          if (reqParts.Length < 2) {
            SendSimpleResponse(ns, 400, "Bad Request", "Bad HTTP request line.", false);
            return;
          }

          string method = reqParts[0].ToUpperInvariant();
          string target = reqParts[1];
          string acceptHeader = "";
          int reqContentLength = 0;

          for (int i = 1; i < headerLines.Length; i++) {
            int colon = headerLines[i].IndexOf(':');
            if (colon <= 0) { continue; }
            string hName = headerLines[i].Substring(0, colon).Trim();
            string hVal = headerLines[i].Substring(colon + 1).Trim();
            if (string.Equals(hName, "Accept", StringComparison.OrdinalIgnoreCase)) {
              acceptHeader = hVal;
            } else if (string.Equals(hName, "Content-Length", StringComparison.OrdinalIgnoreCase)) {
              int.TryParse(hVal, NumberStyles.Integer, CultureInfo.InvariantCulture, out reqContentLength);
            }
          }

          int alreadyBody = allRead.Length - (headerEnd + 4);
          int remainingBody = reqContentLength - alreadyBody;
          while (remainingBody > 0) {
            int toRead = Math.Min(remainingBody, buf.Length);
            int r = ns.Read(buf, 0, toRead);
            if (r <= 0) { break; }
            remainingBody -= r;
          }

          if (method != "GET" && method != "HEAD") {
            SendSimpleResponse(ns, 405, "Method Not Allowed", "Only GET and HEAD are supported.", method == "HEAD");
            return;
          }

          bool isTarball = false;
          Uri upstreamUri = null;
          string tarballPrefix = "/__tarball__/";
          if (target.StartsWith(tarballPrefix, StringComparison.OrdinalIgnoreCase)) {
            isTarball = true;
            string rest = target.Substring(tarballPrefix.Length);
            int s1 = rest.IndexOf('/');
            if (s1 <= 0) {
              SendSimpleResponse(ns, 400, "Bad Request", "Malformed tarball proxy URL.", method == "HEAD");
              return;
            }
            string scheme = rest.Substring(0, s1).ToLowerInvariant();
            string afterScheme = rest.Substring(s1 + 1);
            int s2 = afterScheme.IndexOf('/');
            if (s2 <= 0) {
              SendSimpleResponse(ns, 400, "Bad Request", "Malformed tarball host path.", method == "HEAD");
              return;
            }
            string host = afterScheme.Substring(0, s2);
            string pathAndQuery = afterScheme.Substring(s2);
            if (!IsAllowedSchemeForHost(scheme, host)) {
              SendSimpleResponse(ns, 403, "Forbidden", "Host not allowed.", method == "HEAD");
              return;
            }
            upstreamUri = new Uri(scheme + "://" + host + pathAndQuery);
          } else {
            string rel = target.StartsWith("/") ? target : "/" + target;
            upstreamUri = new Uri(_upstreamBase + rel);
            if (!IsAllowedSchemeForHost(upstreamUri.Scheme, upstreamUri.Host)) {
              SendSimpleResponse(ns, 403, "Forbidden", "Registry host not allowed.", method == "HEAD");
              return;
            }
          }

          Interlocked.Increment(ref _requestCount);
          if (isTarball && method == "GET") {
            int tbStatus;
            string tbReason;
            string tbContentType;
            long tbLength;
            string tbTempFile = FetchTarballToTempFileWithRetry(upstreamUri, acceptHeader, out tbStatus, out tbReason, out tbContentType, out tbLength);
            try {
              if (tbTempFile != null && File.Exists(tbTempFile)) {
                WriteFileHttpResponse(ns, tbStatus, tbReason, tbContentType, tbTempFile, tbLength);
              } else {
                WriteHttpResponse(ns, tbStatus, tbReason, tbContentType, new byte[0], false);
              }
            } finally {
              if (!string.IsNullOrEmpty(tbTempFile)) {
                try { if (File.Exists(tbTempFile)) { File.Delete(tbTempFile); } } catch { }
              }
            }
            return;
          }

          int statusCode;
          string reason;
          string contentType;
          byte[] bodyBytes;
          FetchWithRetry(method, upstreamUri, isTarball, acceptHeader, out statusCode, out reason, out contentType, out bodyBytes);

          if (!isTarball && statusCode == 200 && bodyBytes != null && bodyBytes.Length > 0) {
            bool looksJson = (!string.IsNullOrEmpty(contentType) && contentType.IndexOf("json", StringComparison.OrdinalIgnoreCase) >= 0) || bodyBytes[0] == (byte)'{';
            if (looksJson) {
              string jsonText = Encoding.UTF8.GetString(bodyBytes);
              string proxyNoSlash = ProxyUrl.TrimEnd('/');
              string rewritten = RewritePackumentJson(jsonText, proxyNoSlash);
              bodyBytes = Encoding.UTF8.GetBytes(rewritten);
              if (string.IsNullOrEmpty(contentType)) {
                contentType = "application/json; charset=utf-8";
              }
            }
          }

          WriteHttpResponse(ns, statusCode, reason, contentType, bodyBytes ?? new byte[0], method == "HEAD");
        } catch (Exception ex) {
          Interlocked.Increment(ref _errorCount);
          _lastError = ex.Message;
          try {
            if (client.Connected) {
              SendSimpleResponse(client.GetStream(), 502, "Bad Gateway", "Upstream SChannel fetch failed: " + ex.Message, false);
            }
          } catch { }
        }
      }
    }

    private string RewritePackumentJson(string jsonText, string proxyNoSlash) {
      Regex rx = new Regex(
        "\"tarball\"\\s*:\\s*\"(https?)(?::\\/\\/|:\\/\\/)([^\"\\/\\\\\\s]+)((?:\\/|\\\\\\/)[^\"]*)\"",
        RegexOptions.IgnoreCase
      );
      return rx.Replace(jsonText, delegate(Match m) {
        string scheme = m.Groups[1].Value.ToLowerInvariant();
        string host = m.Groups[2].Value;
        string path = m.Groups[3].Value.Replace("\\/", "/");
        if (!IsAllowedSchemeForHost(scheme, host)) {
          return m.Value;
        }
        return "\"tarball\":\"" + proxyNoSlash + "/__tarball__/" + scheme + "/" + host + path + "\"";
      });
    }

    private void FetchWithRetry(string method, Uri uri, bool isTarball, string acceptHeader, out int statusCode, out string reason, out string contentType, out byte[] bodyBytes) {
      Exception lastEx = null;
      bool canCurl = !string.IsNullOrEmpty(_curlPath) && File.Exists(_curlPath);
      int maxAttempts = canCurl ? 4 : 3;

      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          if (attempt >= 3 && canCurl) {
            Interlocked.Increment(ref _curlFallbackCount);
            FetchViaCurl(method, uri, isTarball, acceptHeader, attempt >= 4, out statusCode, out reason, out contentType, out bodyBytes);
          } else {
            FetchViaHttpWebRequest(method, uri, isTarball, acceptHeader, out statusCode, out reason, out contentType, out bodyBytes);
          }
          return;
        } catch (Exception ex) {
          lastEx = ex;
          _lastError = ex.Message;
          if (attempt < maxAttempts) {
            Thread.Sleep(250 * attempt);
          }
        }
      }
      if (_fallbackUri != null && !string.Equals(_fallbackUri.Authority, uri.Authority, StringComparison.OrdinalIgnoreCase)) {
        string fbPrefix = _fallbackUri.AbsolutePath.TrimEnd('/');
        string fbUrl = _fallbackUri.Scheme + "://" + _fallbackUri.Authority + fbPrefix + uri.PathAndQuery;
        Uri fbUri = new Uri(fbUrl);
        if (IsAllowedSchemeForHost(fbUri.Scheme, fbUri.Authority)) {
          for (int fbAttempt = 1; fbAttempt <= 2; fbAttempt++) {
            try {
              if (fbAttempt == 2 && canCurl) {
                Interlocked.Increment(ref _curlFallbackCount);
                FetchViaCurl(method, fbUri, isTarball, acceptHeader, false, out statusCode, out reason, out contentType, out bodyBytes);
              } else {
                FetchViaHttpWebRequest(method, fbUri, isTarball, acceptHeader, out statusCode, out reason, out contentType, out bodyBytes);
              }
              return;
            } catch (Exception fbEx) {
              lastEx = fbEx;
              _lastError = fbEx.Message;
            }
          }
        }
      }
      throw new IOException("All upstream SChannel attempts failed for " + uri.AbsoluteUri + ": " + (lastEx != null ? lastEx.Message : "unknown"));
    }

    private void FetchViaHttpWebRequest(string method, Uri startUri, bool isTarball, string acceptHeader, out int statusCode, out string reason, out string contentType, out byte[] bodyBytes) {
      try {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)12288;
      } catch {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
      }
      ServicePointManager.DefaultConnectionLimit = 32;
      ServicePointManager.Expect100Continue = false;

      Uri curUri = startUri;
      for (int hop = 0; hop <= 5; hop++) {
        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(curUri);
        req.Method = method;
        req.AllowAutoRedirect = false;
        req.KeepAlive = !IsLoopbackHost(curUri.Host);
        req.Timeout = 90000;
        req.ReadWriteTimeout = 90000;
        req.UserAgent = "npm/11 node/v24 emtroly-schannel-bridge";
        if (!isTarball) {
          req.Accept = !string.IsNullOrWhiteSpace(acceptHeader) ? acceptHeader : "application/vnd.npm.install-v1+json, application/json";
          req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
        } else {
          req.Accept = "*/*";
          req.AutomaticDecompression = DecompressionMethods.None;
        }

        try {
          using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse()) {
            int code = (int)resp.StatusCode;
            if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
              string loc = resp.Headers["Location"];
              if (string.IsNullOrWhiteSpace(loc)) {
                throw new IOException("Redirect response missing Location header.");
              }
              Uri nextUri = new Uri(curUri, loc);
              if (!IsAllowedSchemeForHost(nextUri.Scheme, nextUri.Host)) {
                throw new InvalidOperationException("Blocked redirect to disallowed upstream host: " + nextUri.AbsoluteUri);
              }
              curUri = nextUri;
              continue;
            }
            statusCode = code;
            reason = string.IsNullOrEmpty(resp.StatusDescription) ? "OK" : resp.StatusDescription;
            contentType = string.IsNullOrEmpty(resp.ContentType) ? "application/octet-stream" : resp.ContentType;
            if (method == "HEAD") {
              bodyBytes = new byte[0];
              return;
            }
            long expectedLen = resp.ContentLength;
            using (Stream rs = resp.GetResponseStream()) {
              MemoryStream ms = new MemoryStream();
              if (rs != null) {
                byte[] chunk = new byte[32768];
                int n;
                while ((n = rs.Read(chunk, 0, chunk.Length)) > 0) {
                  ms.Write(chunk, 0, n);
                }
              }
              byte[] result = ms.ToArray();
              if (expectedLen >= 0 && result.Length != expectedLen) {
                throw new IOException("Truncated upstream body: expected " + expectedLen + " bytes, got " + result.Length + ".");
              }
              bodyBytes = result;
              return;
            }
          }
        } catch (WebException wex) {
          HttpWebResponse errResp = wex.Response as HttpWebResponse;
          if (errResp != null) {
            using (errResp) {
              int errCode = (int)errResp.StatusCode;
              if (errCode < 500) {
                statusCode = errCode;
                reason = string.IsNullOrEmpty(errResp.StatusDescription) ? "Status" : errResp.StatusDescription;
                contentType = string.IsNullOrEmpty(errResp.ContentType) ? "application/json" : errResp.ContentType;
                if (method == "HEAD") {
                  bodyBytes = new byte[0];
                  return;
                }
                using (Stream es = errResp.GetResponseStream()) {
                  MemoryStream ems = new MemoryStream();
                  if (es != null) { es.CopyTo(ems); }
                  bodyBytes = ems.ToArray();
                  return;
                }
              }
            }
          }
          throw;
        }
      }
      throw new IOException("Too many redirects fetching " + startUri.AbsoluteUri);
    }

    private static string QuoteCurlArg(string val) {
      if (string.IsNullOrEmpty(val)) { return "\"\""; }
      string s = Regex.Replace(val, @"(\\*)" + "\"", "$1$1\\\"");
      s = Regex.Replace(s, @"(\\+)$", "$1$1");
      return "\"" + s + "\"";
    }

    private void FetchViaCurl(string method, Uri uri, bool isTarball, string acceptHeader, bool forceIpv4, out int statusCode, out string reason, out string contentType, out byte[] bodyBytes) {
      string tmpDir = Path.GetTempPath();
      string stamp = Guid.NewGuid().ToString("N");
      string hdrFile = Path.Combine(tmpDir, "emtroly-cb-" + stamp + ".hdr");
      string bodyFile = Path.Combine(tmpDir, "emtroly-cb-" + stamp + ".body");
      try {
        List<string> args = new List<string>();
        args.Add("--silent");
        args.Add("--show-error");
        args.Add("--location");
        args.Add("--max-redirs"); args.Add("5");
        args.Add("--http1.1");
        args.Add("--connect-timeout"); args.Add("20");
        args.Add("--max-time"); args.Add("180");
        if (string.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase)) {
          args.Add("--proto"); args.Add("=https");
          args.Add("--proto-redir"); args.Add("=https");
        }
        if (forceIpv4) { args.Add("--ipv4"); }
        if (!isTarball) { args.Add("--compressed"); }
        if (method == "HEAD") { args.Add("-I"); }
        args.Add("-A"); args.Add("npm/11 node/v24 emtroly-curl-schannel");
        if (!isTarball && !string.IsNullOrWhiteSpace(acceptHeader)) {
          string cleanAccept = acceptHeader.Replace("\r", " ").Replace("\n", " ").Trim();
          args.Add("-H"); args.Add("Accept: " + cleanAccept);
        }
        args.Add("-D"); args.Add(hdrFile);
        args.Add("-o"); args.Add(bodyFile);
        args.Add(uri.AbsoluteUri);

        StringBuilder argLine = new StringBuilder();
        for (int i = 0; i < args.Count; i++) {
          if (i > 0) { argLine.Append(' '); }
          argLine.Append(QuoteCurlArg(args[i]));
        }

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = _curlPath;
        psi.Arguments = argLine.ToString();
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        string stderrText = "";
        int ec;
        using (Process p = Process.Start(psi)) {
          string sErr = p.StandardError.ReadToEnd();
          p.StandardOutput.ReadToEnd();
          if (!p.WaitForExit(190000)) {
            try { p.Kill(); } catch { }
            throw new IOException("curl.exe timed out");
          }
          ec = p.ExitCode;
          stderrText = (sErr ?? "").Trim();
        }
        if (ec != 0) {
          throw new IOException("curl.exe failed (exit " + ec + "): " + stderrText);
        }

        int finalStatus = 200;
        string finalReason = "OK";
        string finalCt = "application/octet-stream";
        long expectedLen = -1;
        if (File.Exists(hdrFile)) {
          string rawHdr = File.ReadAllText(hdrFile, Encoding.ASCII);
          string[] blocks = Regex.Split(rawHdr.Trim(), @"\r?\n\r?\n");
          if (blocks.Length > 0) {
            string lastBlock = blocks[blocks.Length - 1];
            string[] lines = lastBlock.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
            if (lines.Length > 0) {
              Match sm = Regex.Match(lines[0], @"^HTTP/\S+\s+(\d{3})(?:\s+(.*))?$");
              if (sm.Success) {
                int.TryParse(sm.Groups[1].Value, out finalStatus);
                if (!string.IsNullOrWhiteSpace(sm.Groups[2].Value)) { finalReason = sm.Groups[2].Value.Trim(); }
              }
            }
            for (int li = 1; li < lines.Length; li++) {
              int cPos = lines[li].IndexOf(':');
              if (cPos <= 0) { continue; }
              string k = lines[li].Substring(0, cPos).Trim();
              string v = lines[li].Substring(cPos + 1).Trim();
              if (string.Equals(k, "Content-Type", StringComparison.OrdinalIgnoreCase)) { finalCt = v; }
              else if (string.Equals(k, "Content-Length", StringComparison.OrdinalIgnoreCase)) { long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out expectedLen); }
            }
          }
        }
        byte[] result = (method != "HEAD" && File.Exists(bodyFile)) ? File.ReadAllBytes(bodyFile) : new byte[0];
        if (method != "HEAD" && isTarball && expectedLen >= 0 && result.Length != expectedLen) {
          throw new IOException("curl.exe truncated tarball: expected " + expectedLen + ", got " + result.Length);
        }
        if (finalStatus >= 500) {
          throw new IOException("Upstream HTTP " + finalStatus);
        }
        statusCode = finalStatus;
        reason = finalReason;
        contentType = finalCt;
        bodyBytes = result;
      } finally {
        try { if (File.Exists(hdrFile)) { File.Delete(hdrFile); } } catch { }
        try { if (File.Exists(bodyFile)) { File.Delete(bodyFile); } } catch { }
      }
    }

    private string FetchTarballToTempFileWithRetry(Uri uri, string acceptHeader, out int statusCode, out string reason, out string contentType, out long totalLength) {
      string tmpFile = Path.Combine(Path.GetTempPath(), "emtroly-npm-tb-" + Guid.NewGuid().ToString("N") + ".tgz");
      Exception lastEx = null;
      bool canCurl = !string.IsNullOrEmpty(_curlPath) && File.Exists(_curlPath);
      int maxAttempts = canCurl ? 4 : 3;

      try {
        for (int attempt = 1; attempt <= maxAttempts; attempt++) {
          try {
            if (attempt >= 3 && canCurl) {
              Interlocked.Increment(ref _curlFallbackCount);
              FetchTarballToFileViaCurl(uri, tmpFile, attempt >= 4, out statusCode, out reason, out contentType, out totalLength);
            } else {
              FetchTarballToFileViaHttpWebRequest(uri, tmpFile, out statusCode, out reason, out contentType, out totalLength);
            }
            return tmpFile;
          } catch (Exception ex) {
            lastEx = ex;
            _lastError = ex.Message;
            if (attempt < maxAttempts) {
              Thread.Sleep(250 * Math.Min(4, attempt));
            }
          }
        }

        if (_fallbackUri != null && !string.Equals(_fallbackUri.Authority, uri.Authority, StringComparison.OrdinalIgnoreCase)) {
          try { if (File.Exists(tmpFile)) { File.Delete(tmpFile); } } catch { }
          string fbPrefix = _fallbackUri.AbsolutePath.TrimEnd('/');
          string fbUrl = _fallbackUri.Scheme + "://" + _fallbackUri.Authority + fbPrefix + uri.PathAndQuery;
          Uri fbUri = new Uri(fbUrl);
          if (IsAllowedSchemeForHost(fbUri.Scheme, fbUri.Authority)) {
            for (int fbAttempt = 1; fbAttempt <= 2; fbAttempt++) {
              try {
                if (fbAttempt == 2 && canCurl) {
                  Interlocked.Increment(ref _curlFallbackCount);
                  FetchTarballToFileViaCurl(fbUri, tmpFile, false, out statusCode, out reason, out contentType, out totalLength);
                } else {
                  FetchTarballToFileViaHttpWebRequest(fbUri, tmpFile, out statusCode, out reason, out contentType, out totalLength);
                }
                return tmpFile;
              } catch (Exception fbEx) {
                lastEx = fbEx;
                _lastError = fbEx.Message;
              }
            }
          }
        }
      } catch {
        try { if (File.Exists(tmpFile)) { File.Delete(tmpFile); } } catch { }
        throw;
      }

      try { if (File.Exists(tmpFile)) { File.Delete(tmpFile); } } catch { }
      throw new IOException("All upstream SChannel tarball attempts failed for " + uri.AbsoluteUri + ": " + (lastEx != null ? lastEx.Message : "unknown"));
    }

    private void FetchTarballToFileViaHttpWebRequest(Uri startUri, string destFile, out int statusCode, out string reason, out string contentType, out long totalLength) {
      try {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)12288;
      } catch {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
      }
      ServicePointManager.DefaultConnectionLimit = 32;
      ServicePointManager.Expect100Continue = false;

      long existingOffset = 0;
      if (File.Exists(destFile)) {
        try { existingOffset = new FileInfo(destFile).Length; } catch { existingOffset = 0; }
      }

      Uri curUri = startUri;
      for (int hop = 0; hop <= 5; hop++) {
        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(curUri);
        req.Method = "GET";
        req.AllowAutoRedirect = false;
        req.KeepAlive = !IsLoopbackHost(curUri.Host);
        req.Timeout = 45000;
        req.ReadWriteTimeout = 90000;
        req.UserAgent = "npm/11 node/v24 emtroly-schannel-bridge";
        req.Accept = "*/*";
        req.AutomaticDecompression = DecompressionMethods.None;
        if (existingOffset > 0) {
          req.AddRange(existingOffset);
        }

        try {
          using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse()) {
            int code = (int)resp.StatusCode;
            if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
              string loc = resp.Headers["Location"];
              if (string.IsNullOrWhiteSpace(loc)) {
                throw new IOException("Redirect response missing Location header.");
              }
              Uri nextUri = new Uri(curUri, loc);
              if (!IsAllowedSchemeForHost(nextUri.Scheme, nextUri.Host)) {
                throw new InvalidOperationException("Blocked redirect to disallowed upstream host: " + nextUri.AbsoluteUri);
              }
              curUri = nextUri;
              continue;
            }

            bool isPartial = (code == 206 && existingOffset > 0);
            long contentLen = resp.ContentLength;
            long expectedFinalLen = -1;
            if (isPartial) {
              if (contentLen >= 0) {
                expectedFinalLen = existingOffset + contentLen;
              }
            } else {
              existingOffset = 0;
              expectedFinalLen = contentLen;
            }

            using (Stream rs = resp.GetResponseStream())
            using (FileStream fs = new FileStream(destFile, isPartial ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read, 65536)) {
              if (rs != null) {
                byte[] chunk = new byte[65536];
                int n;
                while ((n = rs.Read(chunk, 0, chunk.Length)) > 0) {
                  fs.Write(chunk, 0, n);
                }
              }
              fs.Flush();
            }

            long actualLen = new FileInfo(destFile).Length;
            if (expectedFinalLen >= 0 && actualLen != expectedFinalLen) {
              throw new IOException("Truncated upstream tarball: expected " + expectedFinalLen + " bytes, got " + actualLen + ".");
            }

            statusCode = 200;
            reason = "OK";
            contentType = string.IsNullOrEmpty(resp.ContentType) ? "application/octet-stream" : resp.ContentType;
            totalLength = actualLen;
            return;
          }
        } catch (WebException wex) {
          HttpWebResponse errResp = wex.Response as HttpWebResponse;
          if (errResp != null) {
            using (errResp) {
              int errCode = (int)errResp.StatusCode;
              if (errCode == 416 && existingOffset > 0) {
                try { if (File.Exists(destFile)) { File.Delete(destFile); } } catch { }
                throw new IOException("Range 416 reset; retrying full tarball.");
              }
              if (errCode < 500) {
                try { if (File.Exists(destFile)) { File.Delete(destFile); } } catch { }
                using (Stream es = errResp.GetResponseStream())
                using (FileStream efs = new FileStream(destFile, FileMode.Create, FileAccess.Write, FileShare.Read)) {
                  if (es != null) { es.CopyTo(efs); }
                }
                statusCode = errCode;
                reason = string.IsNullOrEmpty(errResp.StatusDescription) ? "Status" : errResp.StatusDescription;
                contentType = string.IsNullOrEmpty(errResp.ContentType) ? "application/json" : errResp.ContentType;
                totalLength = File.Exists(destFile) ? new FileInfo(destFile).Length : 0;
                return;
              }
            }
          }
          throw;
        }
      }
      throw new IOException("Too many redirects fetching tarball " + startUri.AbsoluteUri);
    }

    private void FetchTarballToFileViaCurl(Uri uri, string destFile, bool forceIpv4, out int statusCode, out string reason, out string contentType, out long totalLength) {
      string hdrFile = Path.Combine(Path.GetTempPath(), "emtroly-cb-" + Guid.NewGuid().ToString("N") + ".hdr");
      try {
        long existingLen = File.Exists(destFile) ? new FileInfo(destFile).Length : 0;
        for (int curlMode = (existingLen > 0 ? 0 : 1); curlMode <= 1; curlMode++) {
          bool useContinue = (curlMode == 0 && existingLen > 0);
          if (!useContinue && File.Exists(destFile)) {
            try { File.Delete(destFile); } catch { }
          }
          if (File.Exists(hdrFile)) {
            try { File.Delete(hdrFile); } catch { }
          }

          List<string> args = new List<string>();
          args.Add("--silent");
          args.Add("--show-error");
          args.Add("--location");
          args.Add("--max-redirs"); args.Add("5");
          args.Add("--http1.1");
          args.Add("--connect-timeout"); args.Add("25");
          args.Add("--max-time"); args.Add("420");
          if (string.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase)) {
            args.Add("--proto"); args.Add("=https");
            args.Add("--proto-redir"); args.Add("=https");
          }
          if (forceIpv4) { args.Add("--ipv4"); }
          if (useContinue) { args.Add("-C"); args.Add("-"); }
          args.Add("-A"); args.Add("npm/11 node/v24 emtroly-curl-schannel");
          args.Add("-D"); args.Add(hdrFile);
          args.Add("-o"); args.Add(destFile);
          args.Add(uri.AbsoluteUri);

          StringBuilder argLine = new StringBuilder();
          for (int i = 0; i < args.Count; i++) {
            if (i > 0) { argLine.Append(' '); }
            argLine.Append(QuoteCurlArg(args[i]));
          }

          ProcessStartInfo psi = new ProcessStartInfo();
          psi.FileName = _curlPath;
          psi.Arguments = argLine.ToString();
          psi.UseShellExecute = false;
          psi.CreateNoWindow = true;
          psi.RedirectStandardOutput = true;
          psi.RedirectStandardError = true;
          int ec;
          string stderrText = "";
          using (Process p = Process.Start(psi)) {
            string sErr = p.StandardError.ReadToEnd();
            p.StandardOutput.ReadToEnd();
            if (!p.WaitForExit(430000)) {
              try { p.Kill(); } catch { }
              throw new IOException("curl.exe tarball timed out");
            }
            ec = p.ExitCode;
            stderrText = (sErr ?? "").Trim();
          }

          if (ec != 0) {
            if (useContinue) { continue; }
            throw new IOException("curl.exe failed (exit " + ec + "): " + stderrText);
          }

          int finalStatus = 200;
          string finalReason = "OK";
          string finalCt = "application/octet-stream";
          long hdrContentLen = -1;
          if (File.Exists(hdrFile)) {
            string rawHdr = File.ReadAllText(hdrFile, Encoding.ASCII);
            string[] blocks = Regex.Split(rawHdr.Trim(), @"\r?\n\r?\n");
            if (blocks.Length > 0) {
              string lastBlock = blocks[blocks.Length - 1];
              string[] lines = lastBlock.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
              if (lines.Length > 0) {
                Match sm = Regex.Match(lines[0], @"^HTTP/\S+\s+(\d{3})(?:\s+(.*))?$");
                if (sm.Success) {
                  int.TryParse(sm.Groups[1].Value, out finalStatus);
                  if (!string.IsNullOrWhiteSpace(sm.Groups[2].Value)) { finalReason = sm.Groups[2].Value.Trim(); }
                }
              }
              for (int li = 1; li < lines.Length; li++) {
                int cPos = lines[li].IndexOf(':');
                if (cPos <= 0) { continue; }
                string k = lines[li].Substring(0, cPos).Trim();
                string v = lines[li].Substring(cPos + 1).Trim();
                if (string.Equals(k, "Content-Type", StringComparison.OrdinalIgnoreCase)) { finalCt = v; }
                else if (string.Equals(k, "Content-Length", StringComparison.OrdinalIgnoreCase)) { long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out hdrContentLen); }
              }
            }
          }

          if (useContinue && finalStatus != 206) {
            continue;
          }
          if (finalStatus >= 500) {
            throw new IOException("Upstream HTTP " + finalStatus);
          }

          long actualLen = File.Exists(destFile) ? new FileInfo(destFile).Length : 0;
          long expectedTotal = (useContinue && finalStatus == 206 && hdrContentLen >= 0) ? (existingLen + hdrContentLen) : hdrContentLen;
          if (expectedTotal >= 0 && actualLen != expectedTotal) {
            if (useContinue) { continue; }
            throw new IOException("curl.exe truncated tarball: expected " + expectedTotal + ", got " + actualLen);
          }

          statusCode = (finalStatus == 206) ? 200 : finalStatus;
          reason = (finalStatus == 206) ? "OK" : finalReason;
          contentType = finalCt;
          totalLength = actualLen;
          return;
        }
        throw new IOException("curl.exe tarball download did not complete");
      } finally {
        try { if (File.Exists(hdrFile)) { File.Delete(hdrFile); } } catch { }
      }
    }

    private static void WriteFileHttpResponse(NetworkStream ns, int code, string reason, string contentType, string filePath, long fileLength) {
      string safeReason = string.IsNullOrWhiteSpace(reason) ? "OK" : Regex.Replace(reason, @"[\r\n]+", " ").Trim();
      string safeCt = string.IsNullOrWhiteSpace(contentType) ? "application/octet-stream" : Regex.Replace(contentType, @"[\r\n]+", " ").Trim();
      StringBuilder sb = new StringBuilder();
      sb.Append("HTTP/1.1 ").Append(code.ToString(CultureInfo.InvariantCulture)).Append(' ').Append(safeReason).Append("\r\n");
      sb.Append("Content-Type: ").Append(safeCt).Append("\r\n");
      sb.Append("Content-Length: ").Append(fileLength.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
      sb.Append("Cache-Control: no-store\r\n");
      sb.Append("Connection: close\r\n\r\n");
      byte[] hdr = Encoding.ASCII.GetBytes(sb.ToString());
      ns.Write(hdr, 0, hdr.Length);
      if (fileLength > 0 && File.Exists(filePath)) {
        using (FileStream fs = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 65536)) {
          byte[] chunk = new byte[65536];
          int n;
          while ((n = fs.Read(chunk, 0, chunk.Length)) > 0) {
            ns.Write(chunk, 0, n);
          }
        }
      }
      ns.Flush();
    }

    private static void SendSimpleResponse(NetworkStream ns, int code, string reason, string msg, bool headOnly) {
      byte[] body = Encoding.UTF8.GetBytes(msg ?? "");
      WriteHttpResponse(ns, code, reason, "text/plain; charset=utf-8", body, headOnly);
    }

    private static void WriteHttpResponse(NetworkStream ns, int code, string reason, string contentType, byte[] body, bool headOnly) {
      string safeReason = string.IsNullOrWhiteSpace(reason) ? "OK" : Regex.Replace(reason, @"[\r\n]+", " ").Trim();
      string safeCt = string.IsNullOrWhiteSpace(contentType) ? "application/octet-stream" : Regex.Replace(contentType, @"[\r\n]+", " ").Trim();
      StringBuilder sb = new StringBuilder();
      sb.Append("HTTP/1.1 ").Append(code.ToString(CultureInfo.InvariantCulture)).Append(' ').Append(safeReason).Append("\r\n");
      sb.Append("Content-Type: ").Append(safeCt).Append("\r\n");
      sb.Append("Content-Length: ").Append(body.Length.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
      sb.Append("Cache-Control: no-store\r\n");
      sb.Append("Connection: close\r\n\r\n");
      byte[] hdr = Encoding.ASCII.GetBytes(sb.ToString());
      ns.Write(hdr, 0, hdr.Length);
      if (!headOnly && body.Length > 0) {
        ns.Write(body, 0, body.Length);
      }
      ns.Flush();
    }
  }
}
'@

function Start-EmTroLyNpmSChannelBridge {
  param(
    [Parameter(Mandatory=$true)][string]$UpstreamRegistryUrl,
    [string]$FallbackRegistryUrl = '',
    [string[]]$AllowedHosts = @()
  )
  try {
    if (-not ('EmTroLy.NpmSChannelBridge' -as [type])) {
      Add-Type -TypeDefinition $script:EmTroLySChannelBridgeCSharp -Language CSharp -ErrorAction Stop | Out-Null
    }
    $curlExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\curl.exe' } else { 'curl.exe' }
    $bridge = New-Object EmTroLy.NpmSChannelBridge($UpstreamRegistryUrl, $FallbackRegistryUrl, [string[]]$AllowedHosts, $curlExe)
    $bridge.Start()
    return $bridge
  } catch {
    return $null
  }
}

function Invoke-EmTroLyNpmAttempt {
  param(
    [Parameter(Mandatory=$true)][string]$NodeExe,
    [Parameter(Mandatory=$true)][string]$NpmCmd,
    [Parameter(Mandatory=$true)][string[]]$NpmArguments,
    [Parameter(Mandatory=$true)][string]$WorkingDir,
    [Parameter(Mandatory=$true)][string]$AttemptLogFile,
    [string]$SummaryLogFile = '',
    [Parameter(Mandatory=$true)][string]$NpmCacheDir,
    [Parameter(Mandatory=$true)][string]$NpmrcPath,
    [Parameter(Mandatory=$true)][string]$RegistryUrl,
    [string]$FallbackRegistryUrl = '',
    [int]$MaxSockets = 2,
    [int]$FetchRetries = 5,
    [string]$NodeOptions = '',
    [string]$OpenSslIa32Cap = '',
    [string]$AttemptLabel = 'attempt',
    [int]$AttemptNumber = 1,
    [string]$RuntimeCleanupDir = '',
    [int]$TimeoutSeconds = 900,
    [string[]]$SecretsToRedact = @(),
    [switch]$UseSChannelBridge,
    [string[]]$AllowedBridgeHosts = @()
  )
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $AttemptLogFile))
  [void][IO.Directory]::CreateDirectory($NpmCacheDir)
  $npmrcDir = Split-Path -Parent $NpmrcPath
  if ($npmrcDir) { [void][IO.Directory]::CreateDirectory($npmrcDir) }

  $bridge = $null
  $effectiveRegistry = $RegistryUrl
  if ($UseSChannelBridge) {
    $bridge = Start-EmTroLyNpmSChannelBridge -UpstreamRegistryUrl $RegistryUrl -FallbackRegistryUrl $FallbackRegistryUrl -AllowedHosts $AllowedBridgeHosts
    if (-not $bridge) {
      if (-not [string]::IsNullOrWhiteSpace($FallbackRegistryUrl)) {
        $effectiveRegistry = $FallbackRegistryUrl
      }
    } else {
      $effectiveRegistry = $bridge.ProxyUrl
    }
  }

  $retryMinTimeout = if ($FetchRetries -le 2) { 500 } else { 1500 }
  $retryMaxTimeout = if ($FetchRetries -le 2) { 2000 } else { 10000 }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  # Strictly enforce npm integrity verification and TLS certificate validation.
  $npmrcContent = @(
    "registry=$effectiveRegistry",
    "maxsockets=$MaxSockets",
    "fetch-retries=$FetchRetries",
    "fetch-retry-mintimeout=$retryMinTimeout",
    "fetch-retry-maxtimeout=$retryMaxTimeout",
    'fetch-timeout=900000',
    'audit=false',
    'fund=false'
  ) -join "`n"
  [IO.File]::WriteAllText($NpmrcPath, ($npmrcContent + "`n"), $utf8NoBom)

  $nodeDir = Split-Path -Parent $NodeExe
  $cmdExe = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\cmd.exe' } else { 'cmd.exe' }
  $quotedCmd = Format-EmTroLyCmdArg -Value $NpmCmd
  $quotedArgs = @($NpmArguments | ForEach-Object { Format-EmTroLyCmdArg -Value ([string]$_) })
  $innerCmd = $quotedCmd + ' ' + ($quotedArgs -join ' ')

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $cmdExe
  $psi.Arguments = '/d /s /c "' + $innerCmd + '"'
  $psi.WorkingDirectory = $WorkingDir
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

  $curPath = if ($psi.EnvironmentVariables.ContainsKey('PATH')) { $psi.EnvironmentVariables['PATH'] } else { $env:Path }
  if ($nodeDir) {
    $psi.EnvironmentVariables['PATH'] = ($nodeDir + ';' + $curPath).TrimEnd(';')
  }
  $psi.EnvironmentVariables['NPM_CONFIG_CACHE'] = $NpmCacheDir
  $psi.EnvironmentVariables['NPM_CONFIG_USERCONFIG'] = $NpmrcPath
  $psi.EnvironmentVariables['NPM_CONFIG_MAXSOCKETS'] = [string]$MaxSockets
  $psi.EnvironmentVariables['NPM_CONFIG_UPDATE_NOTIFIER'] = 'false'
  $psi.EnvironmentVariables['NO_COLOR'] = '1'
  foreach ($rmVar in @('NPM_CONFIG_PREFIX', 'NPM_CONFIG_REGISTRY', 'NODE_OPTIONS', 'OPENSSL_ia32cap', 'NODE_TLS_REJECT_UNAUTHORIZED')) {
    [void]$psi.EnvironmentVariables.Remove($rmVar)
  }
  if ($UseSChannelBridge) {
    $psi.EnvironmentVariables['NPM_CONFIG_REGISTRY'] = $effectiveRegistry
  }
  if (-not [string]::IsNullOrWhiteSpace($OpenSslIa32Cap)) {
    $psi.EnvironmentVariables['OPENSSL_ia32cap'] = $OpenSslIa32Cap
  }
  if (-not [string]::IsNullOrWhiteSpace($NodeOptions)) {
    $psi.EnvironmentVariables['NODE_OPTIONS'] = $NodeOptions
  }

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $exitCode = 1
  $timedOut = $false
  $rawOut = ''
  $rawErr = ''
  try {
    [void]$proc.Start()
    try { $proc.StandardInput.Close() } catch { }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
      $timedOut = $true
      $exitCode = 124
      try {
        $taskkill = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\taskkill.exe' } else { 'taskkill.exe' }
        $tkPsi = New-Object System.Diagnostics.ProcessStartInfo
        $tkPsi.FileName = $taskkill
        $tkPsi.Arguments = "/PID $($proc.Id) /T /F"
        $tkPsi.UseShellExecute = $false
        $tkPsi.CreateNoWindow = $true
        $tkProc = [System.Diagnostics.Process]::Start($tkPsi)
        [void]$tkProc.WaitForExit(3000)
        $tkProc.Dispose()
      } catch { }
      try { $proc.Kill() } catch { }
      try { [void]$proc.WaitForExit(5000) } catch { }
    } else {
      $proc.WaitForExit()
      $exitCode = [int]$proc.ExitCode
    }
    try { if ($outTask.Wait(5000)) { $rawOut = $outTask.Result } } catch { }
    try { if ($errTask.Wait(5000)) { $rawErr = $errTask.Result } } catch { }
  } finally {
    $proc.Dispose()
    if ($bridge) {
      $bridgeReqCount = $bridge.RequestCount
      $bridgeCurlCount = $bridge.CurlFallbackCount
      $bridgeErrCount = $bridge.ErrorCount
      $bridgeLastErr = $bridge.LastError
      try { $bridge.Dispose() } catch { }
    }
  }

  if ($RuntimeCleanupDir) {
    Wait-EmTroLyRuntimeProcessesExit -TargetDir $RuntimeCleanupDir -WaitMs 5000
  }

  $combined = ($rawOut + "`r`n" + $rawErr).Trim()
  if ($timedOut -and $combined -notmatch 'timed out') {
    $combined = ($combined + "`r`nnpm process timed out after $TimeoutSeconds seconds.").Trim()
  }
  if ($UseSChannelBridge -and $bridgeLastErr -and $exitCode -ne 0) {
    $combined = ($combined + "`r`nschannel-bridge error: $bridgeLastErr").Trim()
  }
  $safeCombined = Remove-EmTroLyNpmSecrets -Text $combined -Secrets $SecretsToRedact
  $bridgeLine = if ($UseSChannelBridge) {
    "schannel_bridge=true upstream=$RegistryUrl local=$effectiveRegistry requests=$bridgeReqCount curl_fallbacks=$bridgeCurlCount errors=$bridgeErrCount"
  } else {
    'schannel_bridge=false'
  }
  $header = @(
    "attempt=$AttemptNumber label=$AttemptLabel exit=$exitCode",
    "node=$NodeExe npm=$NpmCmd",
    "registry=$RegistryUrl maxsockets=$MaxSockets fetch_retries=$FetchRetries",
    $bridgeLine,
    "cache=$NpmCacheDir",
    "OPENSSL_ia32cap=$(if ($OpenSslIa32Cap) { $OpenSslIa32Cap } else { '<unset>' })",
    "NODE_OPTIONS=$(if ($NodeOptions) { $NodeOptions } else { '<unset>' })",
    '------------------------------------------------------------'
  ) -join "`r`n"
  $attemptBody = ($header + "`r`n" + $safeCombined).TrimEnd() + "`r`n"
  [IO.File]::WriteAllText($AttemptLogFile, $attemptBody, $utf8NoBom)

  if ($SummaryLogFile) {
    try {
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $SummaryLogFile))
      [IO.File]::AppendAllText($SummaryLogFile, ($attemptBody + "`r`n"), $utf8NoBom)
    } catch { }
  }

  return [pscustomobject]@{
    AttemptNumber  = $AttemptNumber
    Label          = $AttemptLabel
    ExitCode       = $exitCode
    TimedOut       = $timedOut
    Output         = $safeCombined
    LogFile        = $AttemptLogFile
    Registry       = $RegistryUrl
    MaxSockets     = $MaxSockets
    NodeExe        = $NodeExe
    NpmCmd         = $NpmCmd
    CacheDir       = $NpmCacheDir
    NodeOptions    = $NodeOptions
    OpenSslIa32Cap = $OpenSslIa32Cap
    UsedBridge     = [bool]$UseSChannelBridge
  }
}

function Test-OpenClawRuntimeArtifacts {
  param([Parameter(Mandatory=$true)][string]$RuntimeDir)
  $pkgJson = Join-Path $RuntimeDir 'node_modules\openclaw\package.json'
  $binCmd = Join-Path $RuntimeDir 'node_modules\.bin\openclaw.cmd'
  $missing = @()
  if (-not (Test-Path -LiteralPath $pkgJson -PathType Leaf) -or (Get-Item -LiteralPath $pkgJson -ErrorAction SilentlyContinue).Length -le 0) {
    $missing += $pkgJson
  }
  if (-not (Test-Path -LiteralPath $binCmd -PathType Leaf) -or (Get-Item -LiteralPath $binCmd -ErrorAction SilentlyContinue).Length -le 0) {
    $missing += $binCmd
  }
  return [pscustomobject]@{
    Ok              = ($missing.Count -eq 0)
    Missing         = $missing
    PackageJsonPath = $pkgJson
    OpenClawCmdPath = $binCmd
  }
}

function New-EmTroLyNpmRetryPlan {
  param(
    [Parameter(Mandatory=$true)]$Toolchains,
    [string]$PrimaryRegistry = 'https://registry.npmjs.org/',
    [string]$FallbackRegistry = 'https://registry.npmmirror.com/',
    [bool]$IsTlsError = $false
  )
  $primaryTc = $Toolchains.Primary
  $ltsTc = $Toolchains.Lts
  $chaChaStrict = '--tls-max-v1.2 --tls-cipher-list=ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:DHE-RSA-CHACHA20-POLY1305:!AESGCM:!GCM'
  $chaChaCompat = '--tls-max-v1.2 --tls-cipher-list=ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DEFAULT'

  $plan = New-Object System.Collections.Generic.List[object]
  $retryToolchain = if ($ltsTc) { $ltsTc } else { $primaryTc }
  if ($IsTlsError) {
    $ltsNote = if ($ltsTc) { " + Node $($ltsTc.Version) LTS" } else { '' }
    [void]$plan.Add([pscustomobject]@{
      Label             = 'tls-single-retry-schannel'
      Toolchain         = $retryToolchain
      Registry          = $PrimaryRegistry
      FallbackRegistry  = $FallbackRegistry
      MaxSockets        = 1
      FetchRetries      = 3
      OpenSslIa32Cap    = '~0x200000200000000'
      NodeOptions       = $chaChaStrict
      UseSChannelBridge = $true
      StatusMessage     = "Lỗi giải mã TLS/OpenSSL — đang thử lại 1 lần duy nhất qua cầu nối HTTPS Windows SChannel$ltsNote (TLS 1.2 / ChaCha20, maxsockets=1)..."
    })
  } else {
    [void]$plan.Add([pscustomobject]@{
      Label             = 'single-retry-schannel'
      Toolchain         = $retryToolchain
      Registry          = $PrimaryRegistry
      FallbackRegistry  = $FallbackRegistry
      MaxSockets        = 1
      FetchRetries      = 3
      OpenSslIa32Cap    = ''
      NodeOptions       = ''
      UseSChannelBridge = $true
      StatusMessage     = 'Tải gói OpenClaw tạm gián đoạn — đang thử lại 1 lần qua cầu nối HTTPS Windows SChannel (maxsockets=1)...'
    })
  }
  return $plan.ToArray()
}

function Invoke-EmTroLyNpmPackageWithTlsRetry {
  param(
    [Parameter(Mandatory=$true)][string]$PrefixDir,
    [Parameter(Mandatory=$true)][string[]]$Packages,
    [Parameter(Mandatory=$true)][string]$CacheRootDir,
    [Parameter(Mandatory=$true)][string]$LogsDir,
    [string]$PayloadRoot = '',
    [string]$OpenClawRoot = '',
    [string]$PrimaryRegistry = 'https://registry.npmjs.org/',
    [string]$FallbackRegistry = 'https://registry.npmmirror.com/',
    [int]$MaxSocketsInitial = 2,
    [int]$RetryDelayBaseSeconds = 2,
    [string[]]$ExtraNpmFlags = @(),
    [string]$LogFilePrefix = 'npm-install',
    [string[]]$SecretsToRedact = @(),
    $StatusCallback = $null,
    $LogCallback = $null,
    [switch]$CleanNodeModulesOnFailure,
    $VerifySuccess = $null
  )
  $toolchains = Resolve-EmTroLyNodeToolchains -PayloadRoot $PayloadRoot -OpenClawRoot $OpenClawRoot
  if (-not $toolchains.Primary -or -not $toolchains.Primary.NpmCmd) {
    throw 'npm is unavailable after Node.js installation.'
  }

  [void][IO.Directory]::CreateDirectory($PrefixDir)
  [void][IO.Directory]::CreateDirectory($LogsDir)
  [void][IO.Directory]::CreateDirectory($CacheRootDir)

  $summaryLog = Join-Path $LogsDir ($LogFilePrefix + '.log')
  $isolatedNpmrc = Join-Path $PrefixDir '.npmrc.emtroly'
  $initialSockets = [Math]::Max(1, [Math]::Min(2, $MaxSocketsInitial))

  if (Test-Path -LiteralPath $summaryLog -PathType Leaf) {
    Remove-Item -LiteralPath $summaryLog -Force -ErrorAction SilentlyContinue
  }

  $firstStep = [pscustomobject]@{
    Label             = 'primary-default'
    Toolchain         = $toolchains.Primary
    Registry          = $PrimaryRegistry
    FallbackRegistry  = ''
    MaxSockets        = $initialSockets
    FetchRetries      = 2
    OpenSslIa32Cap    = ''
    NodeOptions       = ''
    UseSChannelBridge = $false
    StatusMessage     = ''
  }

  $allowedBridgeHosts = @()
  foreach ($rUri in @($PrimaryRegistry, $FallbackRegistry)) {
    if (-not [string]::IsNullOrWhiteSpace($rUri)) {
      try { $allowedBridgeHosts += ([uri]$rUri).Host } catch { }
    }
  }

  $queue = New-Object System.Collections.Generic.List[object]
  [void]$queue.Add($firstStep)
  $triedLabels = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $attemptLogs = New-Object System.Collections.Generic.List[string]
  $attempts = New-Object System.Collections.Generic.List[object]
  $planExpandedForTls = $false
  $planExpandedGeneral = $false
  $attemptIndex = 0
  $lastFailureOutput = ''

  try {
    for ($idx = 0; $idx -lt $queue.Count; $idx++) {
      $step = $queue[$idx]
      if (-not $triedLabels.Add($step.Label)) { continue }
      $attemptIndex++

      if ($attemptIndex -gt 1) {
        if ($StatusCallback -and $step.StatusMessage) {
          try { & $StatusCallback $step.StatusMessage } catch { }
        }
        $delayMs = if ($env:EMTROLY_NPM_RETRY_DELAY_MS -match '^[0-9]+$') {
          [int]$env:EMTROLY_NPM_RETRY_DELAY_MS
        } else {
          ($attemptIndex - 1) * $RetryDelayBaseSeconds * 1000
        }
        if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
      }

      $attemptCache = Join-Path $CacheRootDir ("attempt-$attemptIndex")
      $attemptLog = Join-Path $LogsDir ("$LogFilePrefix-attempt-$attemptIndex.log")
      [void]$attemptLogs.Add($attemptLog)

      $stepFetchRetries = if ($step.PSObject.Properties['FetchRetries'] -and $step.FetchRetries) { [int]$step.FetchRetries } else { 5 }
      $stepUseBridge = ($step.PSObject.Properties['UseSChannelBridge'] -and [bool]$step.UseSChannelBridge)
      $stepFallbackReg = if ($step.PSObject.Properties['FallbackRegistry'] -and $step.FallbackRegistry) { [string]$step.FallbackRegistry } else { '' }
      $npmArgs = @('install', '--prefix', $PrefixDir) + $Packages + @('--no-audit', '--no-fund', '--loglevel=error') + $ExtraNpmFlags
      $res = Invoke-EmTroLyNpmAttempt `
        -NodeExe $step.Toolchain.NodeExe `
        -NpmCmd $step.Toolchain.NpmCmd `
        -NpmArguments $npmArgs `
        -WorkingDir $PrefixDir `
        -AttemptLogFile $attemptLog `
        -SummaryLogFile $summaryLog `
        -NpmCacheDir $attemptCache `
        -NpmrcPath $isolatedNpmrc `
        -RegistryUrl $step.Registry `
        -FallbackRegistryUrl $stepFallbackReg `
        -MaxSockets $step.MaxSockets `
        -FetchRetries $stepFetchRetries `
        -NodeOptions $step.NodeOptions `
        -OpenSslIa32Cap $step.OpenSslIa32Cap `
        -AttemptLabel $step.Label `
        -AttemptNumber $attemptIndex `
        -RuntimeCleanupDir $PrefixDir `
        -SecretsToRedact $SecretsToRedact `
        -UseSChannelBridge:$stepUseBridge `
        -AllowedBridgeHosts $allowedBridgeHosts

      [void]$attempts.Add($res)

      if ($res.ExitCode -eq 0) {
        if ($VerifySuccess) {
          $ver = & $VerifySuccess $PrefixDir
          if (-not $ver.Ok) {
            $missingStr = ($ver.Missing -join ', ')
            $verErrMsg = "OpenClaw installation verification failed: missing required package.json or openclaw.cmd ($missingStr)."
            if ($LogCallback) {
              try { & $LogCallback $verErrMsg } catch { }
            }
            $script:LastOpenClawNpmResult = [pscustomobject]@{
              Success            = $false
              VerificationFailed = $true
              MissingArtifacts   = $ver.Missing
              PrimaryNodeExe     = $toolchains.Primary.NodeExe
              UsedNodeExe        = $step.Toolchain.NodeExe
              UsedNpmCmd         = $step.Toolchain.NpmCmd
              Attempts           = $attempts.ToArray()
              LogFiles           = $attemptLogs.ToArray()
              SummaryLogFile     = $summaryLog
              LastOutput         = $res.Output
              ErrorMessage       = $verErrMsg
            }
            throw 'openclaw-npm-verification-failed'
          }
        }
        # Keep winning attempt cache isolated cleanly; remove only failed attempt caches
        for ($cIdx = 1; $cIdx -lt $attemptIndex; $cIdx++) {
          $failedCacheDir = Join-Path $CacheRootDir ("attempt-$cIdx")
          if (Test-Path -LiteralPath $failedCacheDir) {
            Clear-EmTroLyDirectorySafe -DirPath $failedCacheDir
          }
        }
        $script:LastOpenClawNpmResult = [pscustomobject]@{
          Success            = $true
          VerificationFailed = $false
          MissingArtifacts   = @()
          PrimaryNodeExe     = $toolchains.Primary.NodeExe
          UsedNodeExe        = $step.Toolchain.NodeExe
          UsedNpmCmd         = $step.Toolchain.NpmCmd
          Registry           = $step.Registry
          CacheDir           = $attemptCache
          Attempts           = $attempts.ToArray()
          LogFiles           = $attemptLogs.ToArray()
          SummaryLogFile     = $summaryLog
          LastOutput         = $res.Output
        }
        return $script:LastOpenClawNpmResult
      }

      $lastFailureOutput = $res.Output
      $tailLines = @($res.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 20)
      $tailJoined = ($tailLines -join ' | ')
      if ($LogCallback) {
        try {
          & $LogCallback ("npm install attempt $attemptIndex ($($step.Label), registry=$($step.Registry), maxsockets=$($step.MaxSockets)) failed (exit=$($res.ExitCode)): $tailJoined")
        } catch { }
      }

      if ($CleanNodeModulesOnFailure) {
        Wait-EmTroLyRuntimeProcessesExit -TargetDir $PrefixDir -WaitMs 5000
        $partialModules = Join-Path $PrefixDir 'node_modules'
        if (Test-Path -LiteralPath $partialModules) {
          Clear-EmTroLyDirectorySafe -DirPath $partialModules
        }
        $partialLock = Join-Path $PrefixDir 'package-lock.json'
        if (Test-Path -LiteralPath $partialLock -PathType Leaf) {
          Remove-Item -LiteralPath $partialLock -Force -ErrorAction SilentlyContinue
        }
      }

      $isTlsNow = Test-IsNpmTlsCipherError -LogText $res.Output
      $isCorruptNow = Test-IsNpmCacheOrTarballCorruptError -LogText $res.Output
      if ($isCorruptNow -and (Test-Path -LiteralPath $attemptCache)) {
        Clear-EmTroLyDirectorySafe -DirPath $attemptCache
      }

      if ($isTlsNow -and -not $planExpandedForTls) {
        $planExpandedForTls = $true
        $tlsSteps = New-EmTroLyNpmRetryPlan -Toolchains $toolchains -PrimaryRegistry $PrimaryRegistry -FallbackRegistry $FallbackRegistry -IsTlsError $true
        foreach ($ts in $tlsSteps) {
          if (-not $triedLabels.Contains($ts.Label) -and (@($queue | Where-Object { $_.Label -eq $ts.Label }).Count -eq 0)) {
            [void]$queue.Add($ts)
          }
        }
      } elseif (-not $planExpandedGeneral -and -not $planExpandedForTls) {
        $planExpandedGeneral = $true
        $genSteps = New-EmTroLyNpmRetryPlan -Toolchains $toolchains -PrimaryRegistry $PrimaryRegistry -FallbackRegistry $FallbackRegistry -IsTlsError $false
        foreach ($gs in $genSteps) {
          if (-not $triedLabels.Contains($gs.Label) -and (@($queue | Where-Object { $_.Label -eq $gs.Label }).Count -eq 0)) {
            [void]$queue.Add($gs)
          }
        }
      }
    }
  } finally {
    Remove-Item -LiteralPath $isolatedNpmrc -Force -ErrorAction SilentlyContinue
  }

  $script:LastOpenClawNpmResult = [pscustomobject]@{
    Success            = $false
    VerificationFailed = $false
    MissingArtifacts   = @()
    PrimaryNodeExe     = $toolchains.Primary.NodeExe
    UsedNodeExe        = $toolchains.Primary.NodeExe
    UsedNpmCmd         = $toolchains.Primary.NpmCmd
    Attempts           = $attempts.ToArray()
    LogFiles           = $attemptLogs.ToArray()
    SummaryLogFile     = $summaryLog
    LastOutput         = $lastFailureOutput
    IsTlsError         = (Test-IsNpmTlsCipherError -LogText $lastFailureOutput)
  }
  return $script:LastOpenClawNpmResult
}

function Invoke-OpenClawNpmInstall {
  param(
    [Parameter(Mandatory=$true)][string]$RuntimeDir,
    [Parameter(Mandatory=$true)][string]$OpenClawRoot,
    [string]$OpenClawVersion = '2026.11.4',
    [string]$LogsDir = '',
    [string]$NpmCacheRoot = '',
    [string]$PayloadRoot = '',
    [string]$PrimaryRegistry = 'https://registry.npmjs.org/',
    [string]$FallbackRegistry = 'https://registry.npmmirror.com/',
    [int]$MaxSocketsInitial = 2,
    [int]$RetryDelayBaseSeconds = 2,
    [string[]]$SecretsToRedact = @(),
    $StatusCallback = $null,
    $LogCallback = $null
  )
  [void][IO.Directory]::CreateDirectory($RuntimeDir)
  $resolvedLogsDir = if (-not [string]::IsNullOrWhiteSpace($LogsDir)) { $LogsDir } else { Join-Path $OpenClawRoot 'logs' }
  $resolvedCacheRoot = if (-not [string]::IsNullOrWhiteSpace($NpmCacheRoot)) { $NpmCacheRoot } else { Join-Path $OpenClawRoot 'npm-cache' }

  $pkgPath = Join-Path $RuntimeDir 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath -PathType Leaf)) {
    $runtimePackage = @{
      name         = 'member-openclaw-runtime'
      version      = '1.0.0'
      private      = $true
      allowScripts = @{
        '@google/genai'    = $true
        esbuild            = $true
        koffi              = $true
        openclaw           = $true
        protobufjs         = $true
        'tree-sitter-bash' = $true
      }
    }
    [IO.File]::WriteAllText($pkgPath, ($runtimePackage | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  }

  $verifyCb = {
    param([string]$TargetPrefix)
    return (Test-OpenClawRuntimeArtifacts -RuntimeDir $TargetPrefix)
  }

  $res = Invoke-EmTroLyNpmPackageWithTlsRetry `
    -PrefixDir $RuntimeDir `
    -Packages @("openclaw@$OpenClawVersion") `
    -CacheRootDir $resolvedCacheRoot `
    -LogsDir $resolvedLogsDir `
    -PayloadRoot $PayloadRoot `
    -OpenClawRoot $OpenClawRoot `
    -PrimaryRegistry $PrimaryRegistry `
    -FallbackRegistry $FallbackRegistry `
    -MaxSocketsInitial $MaxSocketsInitial `
    -RetryDelayBaseSeconds $RetryDelayBaseSeconds `
    -LogFilePrefix 'npm-install' `
    -SecretsToRedact $SecretsToRedact `
    -StatusCallback $StatusCallback `
    -LogCallback $LogCallback `
    -CleanNodeModulesOnFailure `
    -VerifySuccess $verifyCb

  if (-not $res.Success) {
    throw 'Private OpenClaw installation failed.'
  }

  $artifacts = Test-OpenClawRuntimeArtifacts -RuntimeDir $RuntimeDir
  if (-not $artifacts.Ok) {
    throw 'openclaw-npm-verification-failed'
  }
  return $res
}

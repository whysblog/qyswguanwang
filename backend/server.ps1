[CmdletBinding()]
param(
  [int] $Port = 8081
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dataDir = Join-Path $root 'data'
$appointmentsFile = Join-Path $dataDir 'appointments.json'

if (-not (Test-Path $dataDir)) {
  New-Item -ItemType Directory -Path $dataDir | Out-Null
}

if (-not (Test-Path $appointmentsFile)) {
  '[]' | Set-Content -Encoding UTF8 -Path $appointmentsFile
}

$sessions = @{}

function Write-JsonResponse {
  param(
    [Parameter(Mandatory = $true)] [System.Net.HttpListenerContext] $Context,
    [Parameter(Mandatory = $true)] $Payload,
    [int] $StatusCode = 200
  )

  $json = $Payload | ConvertTo-Json -Depth 8
  $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
  $Context.Response.StatusCode = $StatusCode
  $Context.Response.ContentType = 'application/json; charset=utf-8'
  $Context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
  $Context.Response.ContentLength64 = $buffer.Length
  $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
  $Context.Response.Close()
}

function Write-TextResponse {
  param(
    [Parameter(Mandatory = $true)] [System.Net.HttpListenerContext] $Context,
    [Parameter(Mandatory = $true)] [string] $Text,
    [string] $ContentType = 'text/plain; charset=utf-8',
    [int] $StatusCode = 200
  )

  $buffer = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $Context.Response.StatusCode = $StatusCode
  $Context.Response.ContentType = $ContentType
  $Context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
  $Context.Response.ContentLength64 = $buffer.Length
  $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
  $Context.Response.Close()
}

function Read-JsonBody {
  param([System.Net.HttpListenerRequest] $Request)

  $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
  $body = $reader.ReadToEnd()
  $reader.Close()

  if ([string]::IsNullOrWhiteSpace($body)) {
    return @{}
  }

  try {
    return $body | ConvertFrom-Json
  }
  catch {
    throw '请求体不是有效 JSON。'
  }
}

function Read-Appointments {
  if (-not (Test-Path $appointmentsFile)) {
    return @()
  }

  $raw = Get-Content -Raw -Path $appointmentsFile
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @()
  }

  try {
    $items = $raw | ConvertFrom-Json
    if ($null -eq $items) {
      return @()
    }

    return @($items)
  }
  catch {
    return @()
  }
}

function Save-Appointments {
  param([array] $Items)

  $Items | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $appointmentsFile
}

function New-SessionToken {
  [guid]::NewGuid().ToString('N')
}

function Get-AuthToken {
  param([System.Net.HttpListenerRequest] $Request)

  $cookieHeader = $Request.Headers['Cookie']
  if ([string]::IsNullOrWhiteSpace($cookieHeader)) {
    return $null
  }

  foreach ($part in $cookieHeader.Split(';')) {
    $kv = $part.Trim().Split('=', 2)
    if ($kv.Count -eq 2 -and $kv[0] -eq 'QY_AUTH') {
      return $kv[1]
    }
  }

  return $null
}

function Test-Authorized {
  param([System.Net.HttpListenerRequest] $Request)

  $token = Get-AuthToken -Request $Request
  if ([string]::IsNullOrWhiteSpace($token)) {
    return $false
  }

  if (-not $sessions.ContainsKey($token)) {
    return $false
  }

  $expires = $sessions[$token]
  if ($expires -lt (Get-Date)) {
    $sessions.Remove($token)
    return $false
  }

  return $true
}

function Get-MimeType {
  param([string] $Path)

  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    '.html' { return 'text/html; charset=utf-8' }
    '.css' { return 'text/css; charset=utf-8' }
    '.js' { return 'application/javascript; charset=utf-8' }
    '.json' { return 'application/json; charset=utf-8' }
    '.png' { return 'image/png' }
    '.jpg' { return 'image/jpeg' }
    '.jpeg' { return 'image/jpeg' }
    '.svg' { return 'image/svg+xml' }
    '.ico' { return 'image/x-icon' }
    default { return 'application/octet-stream' }
  }
}

function Write-StaticFile {
  param([System.Net.HttpListenerContext] $Context)

  $relativePath = [System.Uri]::UnescapeDataString($Context.Request.Url.AbsolutePath)

  if ($relativePath -eq '/') {
    $relativePath = '/index.html'
  }

  $trimmed = $relativePath.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
  $combined = Join-Path $root $trimmed
  $fullPath = [System.IO.Path]::GetFullPath($combined)
  $rootPath = [System.IO.Path]::GetFullPath($root)

  if (-not $fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-TextResponse -Context $Context -Text 'Forbidden' -StatusCode 403
    return
  }

  if (-not (Test-Path $fullPath)) {
    Write-TextResponse -Context $Context -Text '404 Not Found' -StatusCode 404
    return
  }

  $bytes = [System.IO.File]::ReadAllBytes($fullPath)
  $Context.Response.StatusCode = 200
  $Context.Response.ContentType = Get-MimeType -Path $fullPath
  $Context.Response.ContentLength64 = $bytes.Length
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Context.Response.Close()
}

function Handle-Api {
  param([System.Net.HttpListenerContext] $Context)

  $request = $Context.Request
  $path = $request.Url.AbsolutePath.ToLowerInvariant()
  $method = $request.HttpMethod.ToUpperInvariant()

  if ($path -eq '/api/login' -and $method -eq 'POST') {
    try {
      $body = Read-JsonBody -Request $request
    }
    catch {
      Write-JsonResponse -Context $Context -Payload @{ success = $false; message = $_.Exception.Message } -StatusCode 400
      return
    }

    if ($body.username -eq 'admin' -and $body.password -eq 'admin123456') {
      $token = New-SessionToken
      $sessions[$token] = (Get-Date).AddHours(12)
      $Context.Response.Headers.Add('Set-Cookie', "QY_AUTH=$token; Path=/; HttpOnly; SameSite=Lax")
      Write-JsonResponse -Context $Context -Payload @{ success = $true; message = '登录成功' }
      return
    }

    Write-JsonResponse -Context $Context -Payload @{ success = $false; message = '账号或密码错误' } -StatusCode 401
    return
  }

  if ($path -eq '/api/logout' -and $method -eq 'POST') {
    $token = Get-AuthToken -Request $request
    if ($token -and $sessions.ContainsKey($token)) {
      $sessions.Remove($token)
    }

    $Context.Response.Headers.Add('Set-Cookie', 'QY_AUTH=; Path=/; HttpOnly; Max-Age=0; SameSite=Lax')
    Write-JsonResponse -Context $Context -Payload @{ success = $true; message = '已退出登录' }
    return
  }

  if ($path -eq '/api/appointments' -and $method -eq 'POST') {
    try {
      $body = Read-JsonBody -Request $request
    }
    catch {
      Write-JsonResponse -Context $Context -Payload @{ success = $false; message = $_.Exception.Message } -StatusCode 400
      return
    }

    $name = [string]$body.name
    $phone = [string]$body.phone
    $studentAge = [string]$body.studentAge
    $message = [string]$body.message

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($phone)) {
      Write-JsonResponse -Context $Context -Payload @{ success = $false; message = '姓名和手机号不能为空' } -StatusCode 400
      return
    }

    $appointments = Read-Appointments
    $newRecord = [ordered]@{
      id = [guid]::NewGuid().ToString('N')
      name = $name.Trim()
      phone = $phone.Trim()
      studentAge = $studentAge.Trim()
      message = $message.Trim()
      createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    $appointments = @($appointments) + $newRecord
    Save-Appointments -Items $appointments

    Write-JsonResponse -Context $Context -Payload @{ success = $true; message = '预约提交成功' }
    return
  }

  if ($path -eq '/api/appointments' -and $method -eq 'GET') {
    if (-not (Test-Authorized -Request $request)) {
      Write-JsonResponse -Context $Context -Payload @{ success = $false; message = '未登录或登录已过期' } -StatusCode 401
      return
    }

    $appointments = Read-Appointments
    $appointments = @($appointments | Sort-Object -Property createdAt -Descending)
    Write-JsonResponse -Context $Context -Payload @{ success = $true; items = $appointments }
    return
  }

  Write-JsonResponse -Context $Context -Payload @{ success = $false; message = 'API 路径不存在' } -StatusCode 404
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host "清研思维 API 服务已启动：http://localhost:$Port" -ForegroundColor Green
Write-Host '按 Ctrl+C 停止服务。' -ForegroundColor Yellow

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()

    try {
      if ($context.Request.Url.AbsolutePath.ToLowerInvariant().StartsWith('/api/')) {
        Handle-Api -Context $context
      }
      else {
        Write-StaticFile -Context $context
      }
    }
    catch {
      if ($context.Response.OutputStream.CanWrite) {
        Write-JsonResponse -Context $context -Payload @{ success = $false; message = '服务器内部错误'; detail = $_.Exception.Message } -StatusCode 500
      }
    }
  }
}
finally {
  if ($listener.IsListening) {
    $listener.Stop()
  }
  $listener.Close()
}

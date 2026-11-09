# Publica o App Frotas em produção (VPS da Hostinger, a mesma do CRM):
#   1. roda os testes (pule com -SemTestes);
#   2. gera o APK apontando para a API de produção (pule com -SemApk);
#   3. envia o ÚLTIMO COMMIT da API para a VPS e sobe com Docker;
#   4. publica o APK em https://<domínio>/app.apk.
#
# Uso:  .\publicar.ps1                 (tudo)
#       .\publicar.ps1 -SemApk         (só a API)
#       .\publicar.ps1 -Configurar     (reenvia .env e a chave do Firebase)
# Só vai o que está commitado: mudanças em andamento ficam na sua máquina
# (o APK, porém, é gerado com o código da pasta, commitado ou não).
param(
  [switch]$SemTestes,
  [switch]$SemApk,
  [switch]$Configurar,
  [string]$Servidor = "crm@187.41.119.191",
  [string]$Chave = "$env:USERPROFILE\.ssh\hostinger-crm",
  [string]$Dominio = "frotas.187-41-119-191.sslip.io",
  # Pooler do Supabase (a conexão direta é só IPv6 e não funciona no Docker).
  [string]$Pooler = "aws-1-sa-east-1.pooler.supabase.com"
)
$ErrorActionPreference = "Stop"
$raiz = $PSScriptRoot
$ssh = @("-i", $Chave, "-o", "StrictHostKeyChecking=accept-new")

function Passo($texto) { Write-Host "`n==> $texto" -ForegroundColor Cyan }
function Checar($oque) { if ($LASTEXITCODE -ne 0) { throw "$oque falhou." } }
function Remoto($comando) { ssh @ssh $Servidor $comando; Checar "Comando na VPS" }

if (git -C $raiz status --porcelain) {
  Write-Host "Aviso: há mudanças não commitadas; elas NÃO vão para a API na VPS." -ForegroundColor Yellow
}
$commit = git -C $raiz log -1 --format="%h %s"
Write-Host "Publicando $commit em $Dominio" -ForegroundColor Cyan

# 1. Testes ----------------------------------------------------------------
if (-not $SemTestes) {
  Passo "Testes da API"
  Push-Location "$raiz\server"; try { dart test; Checar "Testes da API" } finally { Pop-Location }
  Passo "Testes do app"
  Push-Location "$raiz\app"; try { flutter test; Checar "Testes do app" } finally { Pop-Location }
}

# 2. Configuração da VPS (primeira vez ou -Configurar) ---------------------
Remoto "mkdir -p ~/frotas/deploy/secrets"
$temEnv = ssh @ssh $Servidor "test -f ~/frotas/deploy/.env && echo sim"
if ($Configurar -or $temEnv -ne "sim") {
  Passo "Enviando configuração (.env e chave do Firebase)"
  $local = @{}
  foreach ($linha in Get-Content "$raiz\server\.env") {
    if ($linha -match '^\s*([A-Z_]+)\s*=\s*(.*)$') { $local[$matches[1]] = $matches[2].Trim() }
  }
  # Conexão direta (db.<ref>.supabase.co, usuário postgres) -> pooler (usuário postgres.<ref>).
  $db = $local["DATABASE_URL"]
  if ($db -match '^postgres(?:ql)?://postgres:(.+)@db\.([a-z0-9]+)\.supabase\.co:\d+/(\w+)') {
    $db = "postgresql://postgres.$($matches[2]):$($matches[1])@${Pooler}:5432/$($matches[3])?sslmode=require"
  }
  $envProd = @(
    "DATABASE_URL=$db",
    "SUPABASE_URL=$($local['SUPABASE_URL'])",
    "SUPABASE_PUBLISHABLE_KEY=$($local['SUPABASE_PUBLISHABLE_KEY'])",
    "SUPABASE_SECRET_KEY=$($local['SUPABASE_SECRET_KEY'])"
  )
  $firebase = $local["FIREBASE_SERVICE_ACCOUNT"]
  if ($firebase) {
    $arquivo = if ([IO.Path]::IsPathRooted($firebase)) { $firebase } else { Join-Path "$raiz\server" $firebase }
    scp @ssh $arquivo "${Servidor}:frotas/deploy/secrets/firebase.json"; Checar "Envio da chave do Firebase"
    $envProd += "FIREBASE_SERVICE_ACCOUNT=/secrets/firebase.json"
  } else {
    Write-Host "Sem FIREBASE_SERVICE_ACCOUNT no server/.env: a API sobe sem push." -ForegroundColor Yellow
  }
  $tmp = Join-Path $env:TEMP "frotas-env-prod"
  # LF e sem BOM: o arquivo é lido pelo Docker no Linux.
  [IO.File]::WriteAllText($tmp, (($envProd -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
  try { scp @ssh $tmp "${Servidor}:frotas/deploy/.env"; Checar "Envio do .env" } finally { Remove-Item $tmp }
  Remoto "chmod 600 ~/frotas/deploy/.env ~/frotas/deploy/secrets/* 2>/dev/null; true"
}

# 3. APK -------------------------------------------------------------------
if (-not $SemApk) {
  Passo "Gerando o APK (API: https://$Dominio)"
  $dev = Get-Content "$raiz\app\env\dev.json" -Raw | ConvertFrom-Json
  $dev.API_URL = "https://$Dominio"
  $prod = "$raiz\app\env\prod.json"
  [IO.File]::WriteAllText($prod, ($dev | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
  $build = git -C $raiz rev-list --count HEAD   # versionCode sobe a cada commit
  Push-Location "$raiz\app"
  try {
    flutter build apk --release --dart-define-from-file=env/prod.json --build-number=$build
    Checar "Build do APK"
  } finally { Pop-Location }
  $apk = "$raiz\app\build\app\outputs\flutter-apk\app-release.apk"
  scp @ssh $apk "${Servidor}:frotas-app.apk"; Checar "Envio do APK"
}

# 4. API -------------------------------------------------------------------
Passo "Enviando o código da API ($commit)"
$pacote = Join-Path $env:TEMP "frotas-publicar.tar.gz"
git -C $raiz archive --format=tar.gz -o $pacote HEAD server packages deploy pubspec.yaml
Checar "git archive"
try { scp @ssh $pacote "${Servidor}:frotas.tar.gz"; Checar "Envio do código" } finally { Remove-Item $pacote }

# server/ e packages/ são trocadas inteiras; deploy/.env e deploy/secrets ficam.
Remoto ("cd ~/frotas && rm -rf server packages && tar -xzf ~/frotas.tar.gz && rm ~/frotas.tar.gz && " +
  "bash deploy/atualizar.sh $Dominio")

# 5. Conferência de fora ----------------------------------------------------
Passo "Conferindo pela internet"
$ok = $false
for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
  try {
    $r = Invoke-WebRequest "https://$Dominio/health" -UseBasicParsing -TimeoutSec 10
    $ok = $r.StatusCode -eq 200
  } catch { Start-Sleep 3 }   # o certificado HTTPS pode levar alguns segundos na 1ª vez
}
if (-not $ok) { throw "https://$Dominio/health não respondeu. Veja os logs: ssh na VPS e 'cd ~/frotas/deploy && docker compose logs api'." }

Write-Host "`nPronto!" -ForegroundColor Green
Write-Host "  API: https://$Dominio"
if (-not $SemApk) { Write-Host "  APK: https://$Dominio/app.apk  (mande esse link para o grupo)" }

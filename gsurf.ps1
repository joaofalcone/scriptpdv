$serviceName = 'GSurfRSA Listener'

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if (-not $service) {
    Write-Host 'Não há serviço gsurf instalado' -ForegroundColor Yellow
    exit 0
}

if ($service.Status -eq 'Running') {
    Write-Host 'Reiniciando serviço GSurf...' -ForegroundColor Cyan
    Restart-Service -Name $serviceName -Force
}
else {
    Write-Host 'Iniciando serviço GSurf...' -ForegroundColor Cyan
    Start-Service -Name $serviceName
}

Write-Host 'Operação concluída com sucesso.' -ForegroundColor Green

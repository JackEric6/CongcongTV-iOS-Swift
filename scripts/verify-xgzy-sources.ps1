$ErrorActionPreference = 'Stop'

$resourcePath = Join-Path $PSScriptRoot '..\tvbox\Resources\movie2_xgzy_sources.json'
$config = Get-Content -LiteralPath $resourcePath -Raw | ConvertFrom-Json
$sites = @($config.sites)
$keys = @($sites | ForEach-Object { $_.key })

if ($sites.Count -ne 45) {
    throw "源数量错误: $($sites.Count)，预期 45（含瓜子和四个迁移源）"
}
if (($keys | Select-Object -Unique).Count -ne 45) {
    throw '源 key 不唯一'
}
if ($sites[0].key -ne 'xgzy') {
    throw "默认源错误: $($sites[0].key)，预期 xgzy"
}
if (@($sites | Where-Object { $_.type -ne 1 }).Count -ne 0) {
    throw '发现非 CMS type=1 源'
}
if (@($sites | Where-Object { $_.api -match '127\.0\.0\.1|localhost' }).Count -ne 0) {
    throw 'iOS 资源中仍包含 Android 本机代理地址'
}

$requiredSearchKeys = @('guazi', 'jianpian', 'xgzy', 'ffzy', 'bfzy', 'dyttzy', 'lzi', '360zy', 'fhw88', 'cz4k', 'fan_moli')
$missingSearchKeys = @($requiredSearchKeys | Where-Object { $_ -notin $keys })
if ($missingSearchKeys.Count -gt 0) {
    throw "排序栏对应的影视源未配置: $($missingSearchKeys -join ', ')"
}

Write-Output "xgzy sources valid: count=$($sites.Count), uniqueKeys=$((($keys | Select-Object -Unique).Count)), default=$($sites[0].key), type=1, localhost=0"

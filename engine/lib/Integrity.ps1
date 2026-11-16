# ==============================================================================
#   MAIL MOWAFAK  -  Integrity verifier.
#
#   This file holds the public key, the signed manifest and the check routine.
#   It is the trust anchor of the protection scheme: the private key that
#   signed the manifest is NOT distributed with this package.
#
#   The manifest is signed with RSA-2048 / SHA-256 (PKCS#1 v1.5).
#   Every protected file is then re-hashed and compared to the manifest.
# ==============================================================================

$script:ToolBrand = 'Mowafak Store'

# base64 so this file stays free of quoting and here-string hazards
$script:ToolPublicKeyB64 = 'PFJTQUtleVZhbHVlPjxNb2R1bHVzPnRpTVF5UVJ5VjhzZXRkMmJrMmtKOXZvSnhkaXFoT0QwVzlDZDhLRXFoMlR6RVhDMmJtMWxrY3JpdWVTZm5YRnZEVTVQdnRxYkNDaXF3bXo2MFZJZ3FmWFZPWTE1dUFGSUxPL0lURU5hYkRBN0hHN05Uak5ibUtNWXlEYWpOM0dXUHVjR0F4N1lDVkdpVmtIVTZ0Q3BLY1ZFcDkxNDgxcG9UY2s1S05PZXEvcExKTWtEK3NvblhGTzlHTTl4MlFJSU5BZzJlSnppUGlPbHgzUTBwZGlzTlVld2t3Si9HZDdwQXpNU0dvYnhnbnJoNnloRUErU0lneERCcVpjOEVuc3AwYkM2MUJCYjlOZTVwTTBMUGlpV05GRVBCSVNiQW8vMDdkLzNwNWJ1T3hneHErRmpMdzZXVksvZ3YwRWFxZWlaQnlWMHJ0eEpnODQyN2Q5a05zOU5SUT09PC9Nb2R1bHVzPjxFeHBvbmVudD5BUUFCPC9FeHBvbmVudD48L1JTQUtleVZhbHVlPg=='
$script:ToolManifestB64 = 'ew0KICAgICJicmFuZCI6ICAiTW93YWZhayBTdG9yZSIsDQogICAgImxpY2Vuc2VkVG8iOiAgIiIsDQogICAgImNyZWF0ZWRVdGMiOiAgIjIwMjYtMTEtMTZUMDY6Mjc6MTguMTQ3MDc5NVoiLA0KICAgICJhbGdvcml0aG0iOiAgIlJTQS0yMDQ4L1NIQS0yNTYsIFBLQ1MjMSB2MS41IiwNCiAgICAiZmlsZUNvdW50IjogIDIxLA0KICAgICJmaWxlcyI6ICB7DQogICAgICAgICAgICAgICAgICAiU2VuZC1NYWlsLnBzMSI6ICAiOWVjZWUxOTBlOTVjM2VhZTYwZmQ3ZGIwODA4ZjRiZGNmMzY0OTIzZGM5NjI3MmM1NjhkODAwMTM1YzYzYTVmZCIsDQogICAgICAgICAgICAgICAgICAiUkVBRE1FLm1kIjogICIyNTFhZWJjOTY3NDkzNDBlYzQ5Y2IzN2YwNTRlNTQ5NGJmZjdlMTNmZjg1NzM4ZDFiNzJmZmYxZGZiNWYzODAxIiwNCiAgICAgICAgICAgICAgICAgICJsaWIvQ2xpZW50LnBzMSI6ICAiZGFhOTYyZDdiNzIzNTU4ODgyNmEwNDBhN2U2MDY3ZjM1YTk0MzdjYTczOTQzMjQ5YjlkY2ZjYjdjNDRjYzE5NiIsDQogICAgICAgICAgICAgICAgICAibGliL0NvbW1vbi5wczEiOiAgImFlMzY1MmRiNTliNjQyOWE2MzljY2EzYmNkNWIyMTNjMjU0ODQyOTA3YTk1NTljMjAxYzgxN2Y1ZTUzM2Q1OGMiLA0KICAgICAgICAgICAgICAgICAgImxpYi9NZXNzYWdlLnBzMSI6ICAiM2M0YzZmMDIyZmJiNjM3NzU2OTA3MTk0YWQ3Zjk2MTcyZTIxMTE3OTBlYTA5NDU0YzkxZDUxZDFiNzJhYmVkZiIsDQogICAgICAgICAgICAgICAgICAibGliL1ByZWZsaWdodC5wczEiOiAgIjc3Yzc0ZWM5NGI1OTgxNDM0MTg3OTM4OWYwYjAxZWJlODM1ZmMzY2Q3YzAwZDA4MmQ4MDU3MjA4YmJhYjE2ZDAiLA0KICAgICAgICAgICAgICAgICAgImxpYi9Qcm94eS5wczEiOiAgIjFiYzc1NTNjNWNmMDNmYzU0MTZjYTZkZjMzYzZkNDdjMjZiNThjNTljNzZmNTgwZmRkY2Y3ZmU0ZjNiYWVlZWMiLA0KICAgICAgICAgICAgICAgICAgImxpYi9Qcm94eVBvb2wucHMxIjogICJiZWE1NmU1NWUwNWEwZWM3MDljNGEwMTFkMTgwNjQ5MzFkYzg4ZTk3OWU1ZWUwMGI2MzY1NTNmYWI3MGNiMjkyIiwNCiAgICAgICAgICAgICAgICAgICJsaWIvU210cC5wczEiOiAgIjc1YTY1NTE4OWVmNDgxZTE2ODQwN2ZiYjZlZTliYjAxNzU5OTNhMmU1MTNkOGRkNWZlMDFhOTM1N2MyZWQ3YzEiLA0KICAgICAgICAgICAgICAgICAgImxpYi9TdGF0ZS5wczEiOiAgImVlOTNiYmRiMDgwNTNmMDAyNjM4MjFlNWQzYWRkNjYxODQwZTY2MjQ3OWY5MjNhMmJlODAyYWY3MmZkZmFmNWIiLA0KICAgICAgICAgICAgICAgICAgImxpYi9TdXBlcnZpc29yLnBzMSI6ICAiMjJiOGI0ODYwZTNmNTFmMmQ1MDlhYjhkZTExYzViZTI5MDkzNjU2NjNlODM3MWVhZDUyNGZlODY3MmJmNWQ0OCIsDQogICAgICAgICAgICAgICAgICAidGVzdHMvRmFrZVNtdHBTZXJ2ZXIucHMxIjogICJhYmEyMTViM2UyMDM0OGVmZTdiYzcyZDdkZWI3OWRhYmE4MGVhMjA2MTNjNGNjMTkzN2U0NzYyNzU4MGQwMjY4IiwNCiAgICAgICAgICAgICAgICAgICJ0ZXN0cy9GYWtlSHR0cFNlcnZlci5wczEiOiAgIjFiZjAxMDYzOTNkZmQxZjEwYWVmMTllYjQzMWVjMDUzM2Q0YzBhMjQ3NjdmY2ZkNjdiNjJhNzMzZGQ2YWUxYjciLA0KICAgICAgICAgICAgICAgICAgInRlc3RzL1Rlc3QtSW50ZWdyYXRpb24ucHMxIjogICJlMzU2M2QxODY5YWUzODU0MzE1Yzk0ZDRhOGQ5OTM1YzZlNTgzNTdmNWZjMjM5MWVhYjg2ZjVhYmU4MmE1ODdiIiwNCiAgICAgICAgICAgICAgICAgICJ0ZXN0cy9UZXN0LUxhdW5jaGVyLnBzMSI6ICAiMTVkMmI1YzNhNDVkMWNmOWNlNWEzMDhhOTc5MDExOTMwNjEyZjk1ZTFhOTgxMzU3ZWY3ZGM1Y2RhOGUyN2RlMCIsDQogICAgICAgICAgICAgICAgICAidGVzdHMvVGVzdC1Vbml0LnBzMSI6ICAiZjkwMGNiMDk5MTE2ZDkzZTIyYjViNzU5MmU3ZDdjMzM1OWI4OTRhMjRkMDFkN2U4NmRkYWJhNDBhODkzMjJhNCIsDQogICAgICAgICAgICAgICAgICAidG9vbHMvUnVuLU1haWxSb3RhdG9yLnBzMSI6ICAiOTY4OTU2ZGFmMzc4NjhhYTlkYTgwZDc2MTNhODFiNjdiMGNmYjhhY2Q1YmFjMWUwNjNhODIxYzdlY2MwMTAwNyIsDQogICAgICAgICAgICAgICAgICAidG9vbHMvU2VuZC1DYW1wYWlnbi5wczEiOiAgImVlZmVhM2U0YTg5MzY3YmQyNDdlMzg5NGY4ZWJjOTUzMWYxMjAwZTllOGI3OWFiOWU5YTIwMTI4NzFmYWFjYmYiLA0KICAgICAgICAgICAgICAgICAgInRvb2xzL1Rlc3QtUHJveHkucHMxIjogICJiZTFkOGIwMjVjNmM1NzBjNzhkMTBhNTRiYzI0MGZjNzc5ZmNhZTQwN2I3OTQ2NzZkMzU3ZGJhYjVkYmM5MzIwIiwNCiAgICAgICAgICAgICAgICAgICJhc3NldHMvbW93YWZhay1sb2dvLnBuZyI6ICAiZjg1ZDYyZDQ1MGIxOGRkZWExNzgyODJjN2NjYzU3Zjg0NDY3OGU0ZWJjMzQ0ZTE1NDYwZDA1NDFkZjZlZGU5MSIsDQogICAgICAgICAgICAgICAgICAiYXNzZXRzL3Byb2R1Y3QuanNvbiI6ICAiN2Y1YmI5MmZmZTI0MzM3Y2MxZGVmZjQ4ODk4ZDIwNjljOWYxMzliMDA0ZWFlNmQ3OGIyYjQ5M2Q1NGQwN2U0YSINCiAgICAgICAgICAgICAgfQ0KfQ=='
$script:ToolSignatureB64 = 'petSwNunKCI5EUDpXgo70ovtEraDQ8CPcgdKwRUj238Pig29DyGvt+CfrxHLxowchhnpdTKezZq5ffLvkfe8Ki56xe8KCu+pchOBONwTd5eT+YHpNi+45bpQ5St1djaEj1WeoGg29mIyjYCE5p+eEtHRalHQnUjcM68yIwGQkKkM9OYAxNJP/BvskrLBY9ZIQhZFAEbtjI9eyt+wTf139x6VOh+xOGlO8ceBvVom76nDrrveB+4CXebzX+7CgV2FtCt49q43Wq1cc53sMzuIjm4eE48oHnuKtsj7UOmq3/JfeeEqyZl1/e9axht89BDpnbf9FHopjbMR2IprDyRFQw=='

function Test-MailRotatorIntegrity {
    <#
      Verifies the signed manifest and every protected file.
      Returns a result object; on failure the caller must stop the program.
    #>
    [CmdletBinding()]
    param([string]$ProjectRoot = '')

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot = Split-Path -Parent $PSScriptRoot
    }
    $failures = New-Object System.Collections.Generic.List[string]

    $publicKeyXml = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:ToolPublicKeyB64))
    $manifestJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:ToolManifestB64))

    # --- 1. signature over the manifest ---
    $manifestObj = $null
    $sigOk = $false
    try {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString($publicKeyXml)
        $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)
        $sig = [Convert]::FromBase64String($script:ToolSignatureB64)
        $sigOk = $rsa.VerifyData($manifestBytes, $sig,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $rsa.Dispose()
    }
    catch {
        $failures.Add("Signature check could not run: $($_.Exception.Message)")
    }
    if (-not $sigOk -and $failures.Count -eq 0) {
        $failures.Add('The manifest signature is not valid. The manifest was altered.')
    }

    try { $manifestObj = $manifestJson | ConvertFrom-Json } catch { }

    # --- 2. per-file hashes ---
    if ($null -ne $manifestObj) {
        foreach ($prop in $manifestObj.files.PSObject.Properties) {
            $rel = $prop.Name
            $expected = [string]$prop.Value
            $full = Join-Path $ProjectRoot $rel
            if (-not (Test-Path -LiteralPath $full)) {
                $failures.Add("Protected file is missing: $rel")
                continue
            }
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $actual = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
            finally { $sha.Dispose() }
            if ($actual -ne $expected) {
                $failures.Add("Protected file was modified: $rel")
            }
        }
    }

    return [PSCustomObject]@{
        Passed   = ($failures.Count -eq 0)
        Brand    = $script:ToolBrand
        Failures = $failures.ToArray()
        Checked  = if ($null -ne $manifestObj) { $manifestObj.fileCount } else { 0 }
    }
}
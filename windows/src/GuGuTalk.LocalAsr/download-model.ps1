[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CacheDir,
    [Parameter(Mandatory)] [string] $OutDir
)

$ErrorActionPreference = 'Stop'

$AsrModelName = 'sherpa-onnx-streaming-paraformer-bilingual-zh-en'
$PunctuationModelName = 'sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8'
$SemanticModelName = 'distilbert-base-multilingual-cased-onnx-int8'
$AsrRepository = 'csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en'
$AsrRevision = '8e40c43232a1c5c66c82111efc5820d3accca11b'
$PunctuationRepository = 'ranger810/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8'
$PunctuationRevision = '5cccf43af83e4fc50d1d55b8410312e87709be70'
$SemanticRepository = 'onnx-community/distilbert-base-multilingual-cased-ONNX'
$SemanticRevision = '2e7303d946cfc9194a939e02efb46824eb440379'
$PinyinRevision = '923b108dc5d45dee061324c011b478fb649f8b73'
$CmuDictRevision = '74790861f652b15e4ac49015a90074ad62a27690'
$PrimaryHfBaseUrl = if ([string]::IsNullOrWhiteSpace($env:GUGUTALK_HF_BASE_URL)) {
    'https://huggingface.co'
} else {
    $env:GUGUTALK_HF_BASE_URL.TrimEnd('/')
}
$FallbackHfBaseUrl = 'https://hf-mirror.com'

$AsrEncoderSha256 = '81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a'
$AsrDecoderSha256 = 'f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f'
$AsrTokensSha256 = '59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6'
$PunctuationSha256 = '65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1'
$SemanticModelSha256 = '4fa42d6f6e7d00dd734cdff3fd55b446dec3439de3f8c2e1d162e056969be343'
$SemanticVocabSha256 = 'fe0fda7c425b48c516fc8f160d594c8022a0808447475c1a7c6d6479763f310c'
$PinyinSha256 = '621f8ca9eff8519f47e2b17b564fd318161e13bca07eea8c8e04993cd5d3b52e'
$PinyinLicenseSha256 = '9c048697be2502a16e8bcb282d5d465a07295b2def0ffb05a269c5d39dbe1586'
$CmuDictSha256 = '81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22'
$CmuDictLicenseSha256 = 'bd4ce8e44170a5f9f481310ca85c51de3c4f851a65e679b40e603b143bd3542a'

$AsrCacheDir = Join-Path $CacheDir $AsrModelName
$PunctuationCacheDir = Join-Path $CacheDir $PunctuationModelName
$SemanticCacheDir = Join-Path $CacheDir $SemanticModelName
$AsrOutputDir = Join-Path $OutDir $AsrModelName
$PunctuationOutputDir = Join-Path $OutDir $PunctuationModelName
$SemanticOutputDir = Join-Path $OutDir $SemanticModelName

function Test-Hash {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ExpectedSha256,
        [Parameter(Mandatory)] [string] $Label
    )

    if (-not (Test-Path $Path)) { return $false }
    $actual = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256) {
        throw "$Label checksum mismatch: expected $ExpectedSha256, got $actual"
    }
    return $true
}

function Get-VerifiedFile {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Revision,
        [Parameter(Mandatory)] [string] $RemoteName,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $ExpectedSha256,
        [Parameter(Mandatory)] [string] $Label
    )

    if (Test-Hash -Path $OutputPath -ExpectedSha256 $ExpectedSha256 -Label $Label) { return }

    $partial = "$OutputPath.partial"
    $relative = "$Repository/resolve/$Revision/$RemoteName"
    $primaryUrl = "$PrimaryHfBaseUrl/$relative"
    $fallbackUrl = "$FallbackHfBaseUrl/$relative"

    Write-Host "==> Downloading $Label"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $primaryUrl -OutFile $partial
    }
    catch {
        if ($PrimaryHfBaseUrl -eq $FallbackHfBaseUrl) { throw }
        Write-Host '==> Primary model source unavailable; trying verified mirror'
        Invoke-WebRequest -UseBasicParsing -Uri $fallbackUrl -OutFile $partial
    }

    if (-not (Test-Hash -Path $partial -ExpectedSha256 $ExpectedSha256 -Label $Label)) {
        throw "$Label download did not produce a file"
    }
    Move-Item -Force $partial $OutputPath
}

function Get-VerifiedUrl {
    param(
        [Parameter(Mandatory)] [string] $PrimaryUrl,
        [Parameter(Mandatory)] [string] $FallbackUrl,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $ExpectedSha256,
        [Parameter(Mandatory)] [string] $Label
    )

    if (Test-Hash -Path $OutputPath -ExpectedSha256 $ExpectedSha256 -Label $Label) { return }
    $partial = "$OutputPath.partial"
    Write-Host "==> Downloading $Label"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $PrimaryUrl -OutFile $partial
    }
    catch {
        Invoke-WebRequest -UseBasicParsing -Uri $FallbackUrl -OutFile $partial
    }
    if (-not (Test-Hash -Path $partial -ExpectedSha256 $ExpectedSha256 -Label $Label)) {
        throw "$Label download did not produce a file"
    }
    Move-Item -Force $partial $OutputPath
}

function Install-License {
    $licenseCachePath = Join-Path $CacheDir 'Apache-2.0.txt'
    if (-not (Test-Path $licenseCachePath)) {
        $partial = "$licenseCachePath.partial"
        Write-Host '==> Downloading Apache-2.0 license'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://www.apache.org/licenses/LICENSE-2.0.txt' -OutFile $partial
        }
        catch {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.2/LICENSE' -OutFile $partial
        }
        Move-Item -Force $partial $licenseCachePath
    }

    Copy-Item -Force $licenseCachePath (Join-Path $AsrOutputDir 'LICENSE')
    Copy-Item -Force $licenseCachePath (Join-Path $PunctuationOutputDir 'LICENSE')
    Copy-Item -Force $licenseCachePath (Join-Path $SemanticOutputDir 'LICENSE')
}

function Test-InstalledModels {
    $encoderReady = Test-Hash -Path (Join-Path $AsrOutputDir 'encoder.int8.onnx') `
        -ExpectedSha256 $AsrEncoderSha256 -Label 'Paraformer encoder'
    $decoderReady = Test-Hash -Path (Join-Path $AsrOutputDir 'decoder.int8.onnx') `
        -ExpectedSha256 $AsrDecoderSha256 -Label 'Paraformer decoder'
    $tokensReady = Test-Hash -Path (Join-Path $AsrOutputDir 'tokens.txt') `
        -ExpectedSha256 $AsrTokensSha256 -Label 'Paraformer tokens'
    $punctuationReady = Test-Hash -Path (Join-Path $PunctuationOutputDir 'model.int8.onnx') `
        -ExpectedSha256 $PunctuationSha256 -Label 'CT-Transformer punctuation'
    $semanticModelReady = Test-Hash -Path (Join-Path $SemanticOutputDir 'model.int8.onnx') `
        -ExpectedSha256 $SemanticModelSha256 -Label 'Multilingual semantic model'
    $semanticVocabReady = Test-Hash -Path (Join-Path $SemanticOutputDir 'vocab.txt') `
        -ExpectedSha256 $SemanticVocabSha256 -Label 'Multilingual semantic vocabulary'
    $pinyinReady = Test-Hash -Path (Join-Path $SemanticOutputDir 'pinyin.txt') `
        -ExpectedSha256 $PinyinSha256 -Label 'Pinyin pronunciation data'
    $pinyinLicenseReady = Test-Hash -Path (Join-Path $SemanticOutputDir 'PINYIN_LICENSE') `
        -ExpectedSha256 $PinyinLicenseSha256 -Label 'Pinyin data license'
    $cmuDictReady = Test-Hash -Path (Join-Path $SemanticOutputDir 'cmudict.dict') `
        -ExpectedSha256 $CmuDictSha256 -Label 'CMU English pronunciation data'
    $cmuDictLicenseReady = Test-Hash -Path (Join-Path $SemanticOutputDir 'CMUDICT_LICENSE') `
        -ExpectedSha256 $CmuDictLicenseSha256 -Label 'CMUdict license'
    return $encoderReady -and $decoderReady -and $tokensReady -and $punctuationReady `
        -and $semanticModelReady -and $semanticVocabReady -and $pinyinReady -and $pinyinLicenseReady `
        -and $cmuDictReady -and $cmuDictLicenseReady `
        -and (Test-Path (Join-Path $AsrOutputDir 'LICENSE')) `
        -and (Test-Path (Join-Path $PunctuationOutputDir 'LICENSE')) `
        -and (Test-Path (Join-Path $SemanticOutputDir 'LICENSE'))
}

if (Test-InstalledModels) { exit 0 }

foreach ($directory in @($CacheDir, $AsrCacheDir, $PunctuationCacheDir, $SemanticCacheDir, $AsrOutputDir, $PunctuationOutputDir, $SemanticOutputDir)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

Get-VerifiedFile -Repository $AsrRepository -Revision $AsrRevision `
    -RemoteName 'encoder.int8.onnx' -OutputPath (Join-Path $AsrCacheDir 'encoder.int8.onnx') `
    -ExpectedSha256 $AsrEncoderSha256 -Label 'Paraformer encoder'
Get-VerifiedFile -Repository $AsrRepository -Revision $AsrRevision `
    -RemoteName 'decoder.int8.onnx' -OutputPath (Join-Path $AsrCacheDir 'decoder.int8.onnx') `
    -ExpectedSha256 $AsrDecoderSha256 -Label 'Paraformer decoder'
Get-VerifiedFile -Repository $AsrRepository -Revision $AsrRevision `
    -RemoteName 'tokens.txt' -OutputPath (Join-Path $AsrCacheDir 'tokens.txt') `
    -ExpectedSha256 $AsrTokensSha256 -Label 'Paraformer tokens'
Get-VerifiedFile -Repository $PunctuationRepository -Revision $PunctuationRevision `
    -RemoteName 'model.int8.onnx' -OutputPath (Join-Path $PunctuationCacheDir 'model.int8.onnx') `
    -ExpectedSha256 $PunctuationSha256 -Label 'CT-Transformer punctuation'
Get-VerifiedFile -Repository $SemanticRepository -Revision $SemanticRevision `
    -RemoteName 'onnx/model_int8.onnx' -OutputPath (Join-Path $SemanticCacheDir 'model.int8.onnx') `
    -ExpectedSha256 $SemanticModelSha256 -Label 'Multilingual semantic model'
Get-VerifiedFile -Repository $SemanticRepository -Revision $SemanticRevision `
    -RemoteName 'vocab.txt' -OutputPath (Join-Path $SemanticCacheDir 'vocab.txt') `
    -ExpectedSha256 $SemanticVocabSha256 -Label 'Multilingual semantic vocabulary'
Get-VerifiedUrl `
    -PrimaryUrl "https://cdn.jsdelivr.net/gh/mozillazg/pinyin-data@$PinyinRevision/pinyin.txt" `
    -FallbackUrl "https://raw.githubusercontent.com/mozillazg/pinyin-data/$PinyinRevision/pinyin.txt" `
    -OutputPath (Join-Path $SemanticCacheDir 'pinyin.txt') `
    -ExpectedSha256 $PinyinSha256 -Label 'Pinyin pronunciation data'
Get-VerifiedUrl `
    -PrimaryUrl "https://cdn.jsdelivr.net/gh/mozillazg/pinyin-data@$PinyinRevision/LICENSE" `
    -FallbackUrl "https://raw.githubusercontent.com/mozillazg/pinyin-data/$PinyinRevision/LICENSE" `
    -OutputPath (Join-Path $SemanticCacheDir 'PINYIN_LICENSE') `
    -ExpectedSha256 $PinyinLicenseSha256 -Label 'Pinyin data license'
Get-VerifiedUrl `
    -PrimaryUrl "https://cdn.jsdelivr.net/gh/cmusphinx/cmudict@$CmuDictRevision/cmudict.dict" `
    -FallbackUrl "https://raw.githubusercontent.com/cmusphinx/cmudict/$CmuDictRevision/cmudict.dict" `
    -OutputPath (Join-Path $SemanticCacheDir 'cmudict.dict') `
    -ExpectedSha256 $CmuDictSha256 -Label 'CMU English pronunciation data'
Get-VerifiedUrl `
    -PrimaryUrl "https://cdn.jsdelivr.net/gh/cmusphinx/cmudict@$CmuDictRevision/LICENSE" `
    -FallbackUrl "https://raw.githubusercontent.com/cmusphinx/cmudict/$CmuDictRevision/LICENSE" `
    -OutputPath (Join-Path $SemanticCacheDir 'CMUDICT_LICENSE') `
    -ExpectedSha256 $CmuDictLicenseSha256 -Label 'CMUdict license'

Copy-Item -Force (Join-Path $AsrCacheDir 'encoder.int8.onnx') (Join-Path $AsrOutputDir 'encoder.int8.onnx')
Copy-Item -Force (Join-Path $AsrCacheDir 'decoder.int8.onnx') (Join-Path $AsrOutputDir 'decoder.int8.onnx')
Copy-Item -Force (Join-Path $AsrCacheDir 'tokens.txt') (Join-Path $AsrOutputDir 'tokens.txt')
Copy-Item -Force (Join-Path $PunctuationCacheDir 'model.int8.onnx') (Join-Path $PunctuationOutputDir 'model.int8.onnx')
Copy-Item -Force (Join-Path $SemanticCacheDir 'model.int8.onnx') (Join-Path $SemanticOutputDir 'model.int8.onnx')
Copy-Item -Force (Join-Path $SemanticCacheDir 'vocab.txt') (Join-Path $SemanticOutputDir 'vocab.txt')
Copy-Item -Force (Join-Path $SemanticCacheDir 'pinyin.txt') (Join-Path $SemanticOutputDir 'pinyin.txt')
Copy-Item -Force (Join-Path $SemanticCacheDir 'PINYIN_LICENSE') (Join-Path $SemanticOutputDir 'PINYIN_LICENSE')
Copy-Item -Force (Join-Path $SemanticCacheDir 'cmudict.dict') (Join-Path $SemanticOutputDir 'cmudict.dict')
Copy-Item -Force (Join-Path $SemanticCacheDir 'CMUDICT_LICENSE') (Join-Path $SemanticOutputDir 'CMUDICT_LICENSE')
Install-License

if (-not (Test-InstalledModels)) {
    throw "Local streaming ASR model installation failed under $OutDir"
}
Write-Host "==> Local streaming ASR models ready: $OutDir"

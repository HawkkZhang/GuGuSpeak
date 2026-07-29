param(
    [string] $ModelsRoot = "",
    [string] $Configuration = "Debug",
    [string] $RuntimeIdentifier = "win-x64"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..")
$AsrModelName = "sherpa-onnx-streaming-paraformer-bilingual-zh-en"
$PunctuationModelName = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
$SemanticModelName = "distilbert-base-multilingual-cased-onnx-int8"
$AppProject = Join-Path $RepoRoot "src\GuGuTalk.App\GuGuTalk.App.csproj"
$PlatformTarget = if ($RuntimeIdentifier.EndsWith("arm64", [System.StringComparison]::OrdinalIgnoreCase)) { "arm64" } else { "x64" }
$PrimaryHfBaseUrl = if ([string]::IsNullOrWhiteSpace($env:GUGUTALK_HF_BASE_URL)) {
    "https://huggingface.co"
} else {
    $env:GUGUTALK_HF_BASE_URL.TrimEnd('/')
}
$FallbackHfBaseUrl = "https://hf-mirror.com"
$AsrRevision = "8e40c43232a1c5c66c82111efc5820d3accca11b"
$AsrRepository = "csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en"
$SherpaOnnxRuntimeSha256 = "756c938b0f2d14c45c7ad469c6429041d7e905ee6c6ad6049aa67ce937567e97"

if ([string]::IsNullOrWhiteSpace($ModelsRoot)) {
    dotnet build $AppProject -m:1 -c $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed"
    }

    $AppOutputDir = Join-Path $RepoRoot "src\GuGuTalk.App\bin\$Configuration\net8.0-windows\$RuntimeIdentifier"
    $AppModelsRoot = Join-Path $AppOutputDir "models"
    foreach ($RequiredPath in @(
        (Join-Path $AppModelsRoot "$AsrModelName\encoder.int8.onnx"),
        (Join-Path $AppModelsRoot "$AsrModelName\decoder.int8.onnx"),
        (Join-Path $AppModelsRoot "$AsrModelName\tokens.txt"),
        (Join-Path $AppModelsRoot "$PunctuationModelName\model.int8.onnx"),
        (Join-Path $AppModelsRoot "$SemanticModelName\model.int8.onnx"),
        (Join-Path $AppModelsRoot "$SemanticModelName\vocab.txt"),
        (Join-Path $AppModelsRoot "$SemanticModelName\pinyin.txt"),
        (Join-Path $AppModelsRoot "$SemanticModelName\cmudict.dict"),
        (Join-Path $AppModelsRoot "$SemanticModelName\LICENSE"),
        (Join-Path $AppModelsRoot "$SemanticModelName\PINYIN_LICENSE"),
        (Join-Path $AppModelsRoot "$SemanticModelName\CMUDICT_LICENSE"),
        (Join-Path $AppOutputDir "sherpa-onnx.dll"),
        (Join-Path $AppOutputDir "sherpa-onnx-c-api.dll"),
        (Join-Path $AppOutputDir "onnxruntime.dll")
    )) {
        if (!(Test-Path $RequiredPath)) {
            throw "Missing expected app output file: $RequiredPath"
        }
    }

    $OnnxRuntimePath = Join-Path $AppOutputDir "onnxruntime.dll"
    $OnnxRuntimeHash = (Get-FileHash -Algorithm SHA256 $OnnxRuntimePath).Hash.ToLowerInvariant()
    if ($OnnxRuntimeHash -ne $SherpaOnnxRuntimeSha256) {
        throw "Unexpected onnxruntime.dll in app output: expected sherpa runtime $SherpaOnnxRuntimeSha256, got $OnnxRuntimeHash"
    }

    $ModelsRoot = Join-Path $RepoRoot "src\GuGuTalk.LocalAsr\bundled-models"
}

$ModelsRoot = [System.IO.Path]::GetFullPath($ModelsRoot)
$AsrModelDir = Join-Path $ModelsRoot $AsrModelName
$PunctuationModelDir = Join-Path $ModelsRoot $PunctuationModelName
$SemanticModelDir = Join-Path $ModelsRoot $SemanticModelName
foreach ($RequiredPath in @(
    (Join-Path $AsrModelDir "encoder.int8.onnx"),
    (Join-Path $AsrModelDir "decoder.int8.onnx"),
    (Join-Path $AsrModelDir "tokens.txt"),
    (Join-Path $PunctuationModelDir "model.int8.onnx"),
    (Join-Path $SemanticModelDir "model.int8.onnx"),
    (Join-Path $SemanticModelDir "vocab.txt"),
    (Join-Path $SemanticModelDir "pinyin.txt"),
    (Join-Path $SemanticModelDir "cmudict.dict"),
    (Join-Path $SemanticModelDir "LICENSE"),
    (Join-Path $SemanticModelDir "PINYIN_LICENSE"),
    (Join-Path $SemanticModelDir "CMUDICT_LICENSE")
)) {
    if (!(Test-Path $RequiredPath)) {
        throw "Missing local streaming ASR model file: $RequiredPath"
    }
}

$SmokeAudioDir = Join-Path ([System.IO.Path]::GetTempPath()) "gugutalk-local-asr-smoke-audio"
New-Item -ItemType Directory -Force -Path $SmokeAudioDir | Out-Null

function Get-SmokeAudio {
    param(
        [Parameter(Mandatory)] [string] $Filename,
        [Parameter(Mandatory)] [string] $ExpectedSha256
    )

    $outputPath = Join-Path $SmokeAudioDir $Filename
    if (Test-Path $outputPath) {
        $actual = (Get-FileHash -Algorithm SHA256 $outputPath).Hash.ToLowerInvariant()
        if ($actual -eq $ExpectedSha256) { return }
    }

    $partial = "$outputPath.partial"
    $relative = "$AsrRepository/resolve/$AsrRevision/test_wavs/$Filename"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$PrimaryHfBaseUrl/$relative" -OutFile $partial
    }
    catch {
        Invoke-WebRequest -UseBasicParsing -Uri "$FallbackHfBaseUrl/$relative" -OutFile $partial
    }

    $actual = (Get-FileHash -Algorithm SHA256 $partial).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256) {
        throw "Smoke audio checksum mismatch for $Filename`: expected $ExpectedSha256, got $actual"
    }
    Move-Item -Force $partial $outputPath
}

Get-SmokeAudio -Filename "0.wav" -ExpectedSha256 "7d93384ca14702cc584a7a33fe2fed92e89e708549161cb12ea38c916882103b"
Get-SmokeAudio -Filename "1.wav" -ExpectedSha256 "8bfb42c963e623ebab31b81ff4404867d07d3102507c87ac14577c4c61663b8c"

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gugutalk-local-asr-smoke-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempRoot | Out-Null

try {
    $CoreProject = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "src\GuGuTalk.Core\GuGuTalk.Core.csproj"))
    $LocalAsrProject = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "src\GuGuTalk.LocalAsr\GuGuTalk.LocalAsr.csproj"))

    @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <RuntimeIdentifier>$RuntimeIdentifier</RuntimeIdentifier>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="$CoreProject" />
    <ProjectReference Include="$LocalAsrProject" />
  </ItemGroup>
</Project>
"@ | Set-Content -Encoding UTF8 (Join-Path $TempRoot "SmokeLocalAsr.csproj")

    @'
using GuGuTalk.Core.Models;
using GuGuTalk.Core.Services;
using GuGuTalk.LocalAsr;

static (byte[] PcmData, int SampleRate) LoadWavMonoPcm16(string path)
{
    var bytes = File.ReadAllBytes(path);
    if (bytes.Length < 44 ||
        System.Text.Encoding.ASCII.GetString(bytes, 0, 4) != "RIFF" ||
        System.Text.Encoding.ASCII.GetString(bytes, 8, 4) != "WAVE")
    {
        throw new InvalidDataException("Not a WAV file");
    }

    ushort audioFormat = 0;
    ushort channels = 0;
    ushort bitsPerSample = 0;
    int sampleRate = 0;
    int dataOffset = -1;
    int dataSize = 0;
    var offset = 12;

    while (offset + 8 <= bytes.Length)
    {
        var id = System.Text.Encoding.ASCII.GetString(bytes, offset, 4);
        var chunkSize = BitConverter.ToInt32(bytes, offset + 4);
        offset += 8;
        if (offset + chunkSize > bytes.Length) break;

        if (id == "fmt " && chunkSize >= 16)
        {
            audioFormat = BitConverter.ToUInt16(bytes, offset);
            channels = BitConverter.ToUInt16(bytes, offset + 2);
            sampleRate = BitConverter.ToInt32(bytes, offset + 4);
            bitsPerSample = BitConverter.ToUInt16(bytes, offset + 14);
        }
        else if (id == "data")
        {
            dataOffset = offset;
            dataSize = chunkSize;
        }

        offset += chunkSize + (chunkSize & 1);
    }

    if (audioFormat != 1 || channels != 1 || bitsPerSample != 16 || dataOffset < 0)
    {
        throw new InvalidDataException($"Unsupported WAV: format={audioFormat} channels={channels} bits={bitsPerSample}");
    }

    var pcm = new byte[dataSize];
    Buffer.BlockCopy(bytes, dataOffset, pcm, 0, dataSize);
    return (pcm, sampleRate);
}

static bool ContainsPunctuation(string text) => text.IndexOfAny("，。！？；：,.!?;:".ToCharArray()) >= 0;

static async Task<(List<string> Partials, string Final)> DecodeAsync(string wavPath)
{
    await using var provider = new SherpaOnnxProvider();
    var readerTask = Task.Run(async () =>
    {
        var partials = new List<string>();
        string? finalText = null;
        string? failure = null;

        await foreach (var evt in provider.Events.ReadAllAsync())
        {
            switch (evt)
            {
                case TranscriptEvent.PartialTextUpdated partial
                    when !string.IsNullOrWhiteSpace(partial.Text):
                    if (partials.Count == 0 || partials[^1] != partial.Text) partials.Add(partial.Text);
                    break;
                case TranscriptEvent.FinalTextReady ready:
                    finalText = ready.Text;
                    break;
                case TranscriptEvent.SessionFailed failed:
                    failure = failed.Message;
                    break;
                case TranscriptEvent.SessionEnded:
                    if (!string.IsNullOrWhiteSpace(failure)) throw new InvalidOperationException(failure);
                    if (string.IsNullOrWhiteSpace(finalText)) throw new InvalidOperationException("No final text returned");
                    return (partials, finalText.Trim());
            }
        }

        throw new InvalidOperationException("Event stream ended before SessionEnded");
    });

    var config = new RecognitionConfig(
        LanguageCode: "auto",
        SampleRate: 16000,
        Mode: RecognitionMode.Local,
        PartialResultsEnabled: true,
        Endpointing: EndpointingPolicy.Manual,
        DoubaoCredentials: new DoubaoCredentials("", "", "", ""),
        QwenCredentials: new QwenCredentials("", "", ""));

    var wav = LoadWavMonoPcm16(wavPath);
    await provider.StartSessionAsync(config);
    const int chunkBytes = 1600 * 2;
    for (var offset = 0; offset < wav.PcmData.Length; offset += chunkBytes)
    {
        var length = Math.Min(chunkBytes, wav.PcmData.Length - offset);
        var chunk = new byte[length];
        Buffer.BlockCopy(wav.PcmData, offset, chunk, 0, length);
        await provider.SendAudioAsync(new AudioChunk(chunk, wav.SampleRate, 1, 0.5f));
    }
    await provider.FinishAudioAsync();
    return await readerTask.WaitAsync(TimeSpan.FromSeconds(60));
}

var audioRoot = Environment.GetEnvironmentVariable("GUGUTALK_LOCAL_ASR_SMOKE_AUDIO_DIR")
    ?? throw new InvalidOperationException("GUGUTALK_LOCAL_ASR_SMOKE_AUDIO_DIR is not set");

foreach (var name in new[] { "0.wav", "1.wav" })
{
    var result = await DecodeAsync(Path.Combine(audioRoot, name));
    if (result.Partials.Count == 0) throw new InvalidOperationException($"No streaming partial for {name}");
    if (!result.Partials.Any(ContainsPunctuation))
        throw new InvalidOperationException($"No punctuated streaming partial for {name}: {string.Join(" | ", result.Partials)}");
    if (!ContainsPunctuation(result.Final))
        throw new InvalidOperationException($"No punctuation in final text for {name}: {result.Final}");

    if (name == "0.wav" &&
        (!System.Text.RegularExpressions.Regex.IsMatch(result.Final, "[\u4e00-\u9fff]") ||
         !System.Text.RegularExpressions.Regex.IsMatch(result.Final, "[A-Za-z]") ||
         !result.Final.Contains(' ')))
    {
        throw new InvalidOperationException($"Expected mixed Chinese/English final for {name}: {result.Final}");
    }

    Console.WriteLine($"{name}\tpartials={result.Partials.Count}\t{result.Final}");
}

using (var corrector = new PersonalLexiconCorrector())
{
    var meetingTerms = new[] { new PersonalTerm("会议") };
    var meeting = await corrector.CorrectAsync("明天我们开回忆讨论项目", meetingTerms);
    var memory = await corrector.CorrectAsync("这是我童年的回忆", meetingTerms);
    if (meeting != "明天我们开会议讨论项目")
        throw new InvalidOperationException($"Personal lexicon meeting mismatch: {meeting}");
    if (memory != "这是我童年的回忆")
        throw new InvalidOperationException($"Personal lexicon changed valid memory context: {memory}");
    Console.WriteLine($"personal-lexicon\tmeeting={meeting}\tmemory={memory}");
}
'@ | Set-Content -Encoding UTF8 (Join-Path $TempRoot "Program.cs")

    $env:GUGUTALK_LOCAL_ASR_MODEL_DIR = $ModelsRoot
    $env:GUGUTALK_LOCAL_PUNCTUATION_MODEL_DIR = $ModelsRoot
    $env:GUGUTALK_SEMANTIC_MODEL_DIR = $SemanticModelDir
    $env:GUGUTALK_LOCAL_ASR_SMOKE_AUDIO_DIR = $SmokeAudioDir
    dotnet run --project (Join-Path $TempRoot "SmokeLocalAsr.csproj") `
        --property:SkipAsrModelDownload=true `
        --property:EnableWindowsTargeting=true `
        --property:PlatformTarget=$PlatformTarget
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet run failed"
    }
}
finally {
    Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
}

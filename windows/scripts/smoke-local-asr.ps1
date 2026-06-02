param(
    [string] $ModelDir = "",
    [string] $Configuration = "Debug",
    [string] $RuntimeIdentifier = "win-x64"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..")
$ModelName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
$AppProject = Join-Path $RepoRoot "src\GuGuTalk.App\GuGuTalk.App.csproj"

if ([string]::IsNullOrWhiteSpace($ModelDir)) {
    dotnet build $AppProject -m:1 -c $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed"
    }
    $ModelDir = Join-Path $RepoRoot "src\GuGuTalk.App\bin\$Configuration\net8.0-windows\$RuntimeIdentifier\models\$ModelName"
}

$ModelDir = [System.IO.Path]::GetFullPath($ModelDir)
$ModelPath = Join-Path $ModelDir "model.int8.onnx"
$TokensPath = Join-Path $ModelDir "tokens.txt"

if (!(Test-Path $ModelPath) -or !(Test-Path $TokensPath)) {
    throw "Missing SenseVoice model files under $ModelDir"
}

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

static async Task<string> DecodeAsync(string wavPath)
{
    await using var provider = new SherpaOnnxProvider();
    string? finalText = null;
    string? failure = null;

    var readerTask = Task.Run(async () =>
    {
        await foreach (var evt in provider.Events.ReadAllAsync())
        {
            switch (evt)
            {
                case TranscriptEvent.FinalTextReady ready:
                    finalText = ready.Text;
                    break;
                case TranscriptEvent.SessionFailed failed:
                    failure = failed.Message;
                    break;
                case TranscriptEvent.SessionEnded:
                    return;
            }
        }
    });

    var config = new RecognitionConfig(
        LanguageCode: "auto",
        SampleRate: 16000,
        Mode: RecognitionMode.Local,
        PartialResultsEnabled: false,
        Endpointing: EndpointingPolicy.Manual,
        DoubaoCredentials: new DoubaoCredentials("", "", "", ""),
        QwenCredentials: new QwenCredentials("", "", ""));

    var wav = LoadWavMonoPcm16(wavPath);
    await provider.StartSessionAsync(config);
    await provider.SendAudioAsync(new AudioChunk(wav.PcmData, wav.SampleRate, 1, 0.5f));
    await provider.FinishAudioAsync();
    await readerTask.WaitAsync(TimeSpan.FromSeconds(60));

    if (!string.IsNullOrWhiteSpace(failure))
        throw new InvalidOperationException(failure);

    if (string.IsNullOrWhiteSpace(finalText))
        throw new InvalidOperationException("No final text returned");

    return finalText.Trim();
}

var modelDir = Environment.GetEnvironmentVariable("GUGUTALK_LOCAL_ASR_MODEL_DIR")
    ?? throw new InvalidOperationException("GUGUTALK_LOCAL_ASR_MODEL_DIR is not set");

foreach (var name in new[] { "zh.wav", "en.wav" })
{
    var wav = Path.Combine(modelDir, "test_wavs", name);
    var text = await DecodeAsync(wav);
    Console.WriteLine($"{name}`t{text}");
}
'@ | Set-Content -Encoding UTF8 (Join-Path $TempRoot "Program.cs")

    $env:GUGUTALK_LOCAL_ASR_MODEL_DIR = $ModelDir
    dotnet run --project (Join-Path $TempRoot "SmokeLocalAsr.csproj") --property:SkipAsrModelDownload=true
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet run failed"
    }
}
finally {
    Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
}

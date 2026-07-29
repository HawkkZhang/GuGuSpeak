using GuGuTalk.Core.Services;
using System.Text.Json;
using Xunit;

namespace GuGuTalk.Core.Tests;

public class PlaceholderTests
{
    [Fact]
    public void ProjectCompiles()
    {
        Assert.True(true);
    }

    [Theory]
    [InlineData("How are you？thank you，ok！", "How are you?thank you,ok!")]
    [InlineData("你好，今天怎么样？", "你好，今天怎么样？")]
    [InlineData("今天用 OpenAI，效果很好。", "今天用 OpenAI,效果很好。")]
    [InlineData("", "")]
    public void MixedLanguagePunctuationUsesTheExpectedWidth(string input, string expected)
    {
        Assert.Equal(expected, PunctuationTextNormalizer.NormalizeForMixedChineseEnglish(input));
    }

    [Fact]
    public void PhoneticCandidateFinderFindsChineseHomophone()
    {
        var finder = new PhoneticCandidateFinder("""
            U+4F1A: huì  # 会
            U+8BAE: yì  # 议
            U+56DE: huí  # 回
            U+5FC6: yì  # 忆
            """);

        var candidates = finder.Find(
            "明天我们开回忆讨论项目",
            [new GuGuTalk.Core.Models.PersonalTerm("会议")]);

        Assert.Contains(candidates, value => value.Original == "回忆" && value.Replacement == "会议");
    }

    [Fact]
    public void PhoneticCandidateFinderFindsMixedScriptBrandName()
    {
        var finder = new PhoneticCandidateFinder("U+5495: gū  # 咕");

        var candidates = finder.Find(
            "打开咕咕 Talk",
            [new GuGuTalk.Core.Models.PersonalTerm("GuGuTalk")]);

        Assert.Contains(candidates, value => value.Original == "咕咕 Talk" && value.Replacement == "GuGuTalk");
    }

    [Fact]
    public void PhoneticCandidateFinderFindsEnglishNearPronunciation()
    {
        var finder = new PhoneticCandidateFinder("", """
            google G UW1 G AH0 L
            gu G UW1
            talk T AO1 K
            """);

        var candidates = finder.Find(
            "打开 Google Talk 设置",
            [new GuGuTalk.Core.Models.PersonalTerm("GuGuTalk")]);

        Assert.Contains(candidates, value => value.Original == "Google Talk" && value.Replacement == "GuGuTalk");
    }

    [Fact]
    public void PhoneticCandidateFinderHandlesArbitraryMixedTerms()
    {
        var finder = new PhoneticCandidateFinder("""
            U+6263: kòu  # 扣
            U+95EE: wèn  # 问
            U+5F20: zhāng  # 张
            U+601D: sī  # 思
            U+5072: cāi,sī  # 偲
            U+516B: bā  # 八
            U+52A0: jiā  # 加
            U+8BF6: ēi  # 诶
            U+7231: ài  # 爱
            """);

        Assert.Contains(finder.Find(
            "试一下扣问模型",
            [new GuGuTalk.Core.Models.PersonalTerm("Qwen")]),
            value => value.Original == "扣问" && value.Replacement == "Qwen");
        Assert.Contains(finder.Find(
            "联系人张思思",
            [new GuGuTalk.Core.Models.PersonalTerm("张偲偲")]),
            value => value.Original == "张思思" && value.Replacement == "张偲偲");
        Assert.Contains(finder.Find(
            "部署到 K 八 S",
            [new GuGuTalk.Core.Models.PersonalTerm("K8s")]),
            value => value.Original == "K 八 S" && value.Replacement == "K8s");
        Assert.Contains(finder.Find(
            "这个模块用 C 加加写",
            [new GuGuTalk.Core.Models.PersonalTerm("C++")]),
            value => value.Original == "C 加加" && value.Replacement == "C++");
        Assert.Contains(finder.Find(
            "接入诶爱能力",
            [new GuGuTalk.Core.Models.PersonalTerm("AI")]),
            value => value.Original == "诶爱" && value.Replacement == "AI");
        Assert.Contains(finder.Find(
            "接入 Open 诶爱能力",
            [new GuGuTalk.Core.Models.PersonalTerm("OpenAI")]),
            value => value.Original == "Open 诶爱" && value.Replacement == "OpenAI");
    }

    [Fact]
    public void PhoneticCandidateFinderRejectsDifferentEnglishTerm()
    {
        var finder = new PhoneticCandidateFinder("", """
            chrome K R OW1 M
            google G UW1 G AH0 L
            gu G UW1
            talk T AO1 K
            """);

        var candidates = finder.Find(
            "打开 Google Chrome 设置",
            [new GuGuTalk.Core.Models.PersonalTerm("GuGuTalk")]);

        Assert.DoesNotContain(candidates, value => value.Replacement == "GuGuTalk");
    }

    [Fact]
    public void PhoneticCandidateFinderSkipsTermLongerThanTranscript()
    {
        var finder = new PhoneticCandidateFinder("""
            U+77ED: duǎn  # 短
            U+8D85: chāo  # 超
            U+7EA7: jí  # 级
            U+957F: cháng  # 长
            U+4E2A: gè  # 个
            U+6027: xìng  # 性
            U+8BCD: cí  # 词
            """);

        var candidates = finder.Find(
            "短",
            [new GuGuTalk.Core.Models.PersonalTerm("超级长个性词")]);

        Assert.Empty(candidates);
    }

    [Fact]
    public void PersonalTermStoreMigratesLegacyReplacements()
    {
        string directory = Path.Combine(Path.GetTempPath(), "GuGuTalkTests", Guid.NewGuid().ToString("N"));
        string path = Path.Combine(directory, "hotwords.json");
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllText(path, JsonSerializer.Serialize(new[]
            {
                new GuGuTalk.Core.Models.TextReplacement("回忆", "会议")
            }));

            var store = new HotwordStore(path);

            Assert.Single(store.Terms);
            Assert.Equal("会议", store.Terms[0].Text);
            Assert.Equal("回忆", Assert.Single(store.Terms[0].Aliases));
            Assert.Equal("开会议", store.ApplyReplacements("开回忆"));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}

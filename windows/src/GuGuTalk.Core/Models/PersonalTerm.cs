namespace GuGuTalk.Core.Models;

public sealed record PersonalTerm(Guid Id, string Text, IReadOnlyList<string> Aliases)
{
    public PersonalTerm(string text) : this(Guid.NewGuid(), text, Array.Empty<string>()) { }
}

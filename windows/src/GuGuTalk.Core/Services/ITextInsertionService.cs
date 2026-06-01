using GuGuTalk.Core.Models;

namespace GuGuTalk.Core.Services;

public interface ITextInsertionService
{
    InsertionResult Insert(string text, IntPtr targetHwnd = default);
}

using Afterscreen.Protocol;

namespace Afterscreen.Sender.Session;

/// <summary>Mac <c>LinkMenu</c>: answering links, then an unreachable pinned link.</summary>
public static class LinkMenu
{
    public readonly record struct Choice(LinkKind Kind, bool Reachable);

    public static IReadOnlyList<Choice> Choices(IReadOnlyList<LinkKind> available, LinkKind? pinned)
    {
        var list = available.Select(k => new Choice(k, true)).ToList();
        if (pinned is { } p && !available.Contains(p))
            list.Add(new Choice(p, false));
        return list;
    }
}

namespace Afterscreen.Protocol;

public interface IPairingStore
{
    byte[]? Key(string peer);
    bool Save(byte[] key, string peer, string name);
    void Remove(string peer);
    IReadOnlyList<(string Id, string Name)> Pairs { get; }
}

public sealed class MemoryPairingStore : IPairingStore
{
    private readonly Dictionary<string, (byte[] Key, string Name)> _keys = new();
    private readonly object _lock = new();

    public byte[]? Key(string peer)
    {
        lock (_lock)
            return _keys.TryGetValue(peer, out var v) ? v.Key : null;
    }

    public bool Save(byte[] key, string peer, string name)
    {
        lock (_lock)
            _keys[peer] = (key, name);
        return true;
    }

    public void Remove(string peer)
    {
        lock (_lock)
            _keys.Remove(peer);
    }

    public IReadOnlyList<(string Id, string Name)> Pairs
    {
        get
        {
            lock (_lock)
                return _keys.Select(kv => (kv.Key, kv.Value.Name)).OrderBy(p => p.Name).ToList();
        }
    }
}

public sealed class FilePairingStore : IPairingStore
{
    private readonly string _path;
    private readonly object _lock = new();

    public FilePairingStore(string directory)
    {
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, "paired.json");
    }

    public byte[]? Key(string peer)
    {
        lock (_lock)
        {
            var map = Load();
            return map.TryGetValue(peer, out var b64) ? Convert.FromBase64String(b64.Key) : null;
        }
    }

    public bool Save(byte[] key, string peer, string name)
    {
        lock (_lock)
        {
            var map = Load();
            map[peer] = new Entry { Key = Convert.ToBase64String(key), Name = name };
            File.WriteAllText(_path, System.Text.Json.JsonSerializer.Serialize(map));
            return true;
        }
    }

    public void Remove(string peer)
    {
        lock (_lock)
        {
            var map = Load();
            map.Remove(peer);
            File.WriteAllText(_path, System.Text.Json.JsonSerializer.Serialize(map));
        }
    }

    public IReadOnlyList<(string Id, string Name)> Pairs
    {
        get
        {
            lock (_lock)
                return Load().Select(kv => (kv.Key, kv.Value.Name)).OrderBy(p => p.Name).ToList();
        }
    }

    private Dictionary<string, Entry> Load()
    {
        if (!File.Exists(_path))
            return new Dictionary<string, Entry>();
        try
        {
            return System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, Entry>>(File.ReadAllText(_path))
                   ?? new Dictionary<string, Entry>();
        }
        catch
        {
            return new Dictionary<string, Entry>();
        }
    }

    private sealed class Entry
    {
        public string Key { get; set; } = "";
        public string Name { get; set; } = "";
    }
}

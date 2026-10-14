// Shared reader contract; fake builds include this complete state machine.
// No OS imports, file contents or path discovery live here.
using System;
using System.Collections.Generic;
using System.Text;

namespace ShirohaBatch3 {
  public sealed class StreamFact {
    public string Name;
    public long Length, Allocation;
  }
  internal interface IMetadataApi {
    IntPtr OpenRoot(Capture report);
    IntPtr Open(IntPtr parent, string name, bool directory, bool history, Capture report);
    Fact Inspect(Pin pin, Capture report);
    Dictionary<string, ulong> Enumerate(Pin pin, HashSet<string> allowed, Capture report);
    bool Close(IntPtr handle);
    long ElapsedMilliseconds { get; }
  }
  internal static class MetadataContract {
    internal const uint FileAccess = 0x120080u;
    internal const uint DirectoryAccess = FileAccess | 0x21u;
    internal static void Require(bool condition) {
      if (!condition) throw new InvalidOperationException("metadata_denied");
    }
    internal static StreamFact[] ParseStreams(byte[] bytes, int used) {
      Require(bytes != null && used >= 0 && used <= bytes.Length && used <= 65536);
      List<StreamFact> streams = new List<StreamFact>();
      int offset = 0;
      while (offset < used) {
        Require(streams.Count < 16 && used - offset >= 24);
        uint next = BitConverter.ToUInt32(bytes, offset), length = BitConverter.ToUInt32(bytes, offset + 4);
        long size = BitConverter.ToInt64(bytes, offset + 8), allocation = BitConverter.ToInt64(bytes, offset + 16);
        Require(length > 0 && length <= 512 && length % 2 == 0 && length <= used - offset - 24 && size >= 0 && allocation >= 0);
        string name = new UnicodeEncoding(false, false, true).GetString(bytes, offset + 24, (int)length);
        // The sole accepted stream is the unnamed data stream. Unknown names
        // are rejected here and are never opened, printed or read as content.
        Require(name == "::$DATA" && streams.Count == 0);
        streams.Add(new StreamFact { Name = name, Length = size, Allocation = allocation });
        if (next == 0) {
          // A0-only conservative policy, not a promise of all Windows shapes.
          // Inspect only the actual valid length, never unused buffer capacity.
          int end = offset + 24 + (int)length;
          Require(used - end < 8);
          for (int i = end; i < used; ++i) Require(bytes[i] == 0);
          offset = used;
        }
        else {
          Require(next % 8 == 0 && next >= 24 + length && next <= used - offset - 24);
          offset += (int)next;
        }
      }
      return streams.ToArray();
    }
    internal static void CheckStreams(Fact fact) {
      Require(fact.Streams != null);
      if ((fact.Attributes & 0x10) != 0) Require(fact.Streams.Length == 0);
      else Require(fact.Streams.Length == 1 && fact.Streams[0] != null &&
        fact.Streams[0].Name == "::$DATA" && fact.Streams[0].Length == fact.Length && fact.Streams[0].Allocation >= 0);
    }
    internal static void ParseDirectoryPage(byte[] bytes, HashSet<string> allowed, Dictionary<string, ulong> names) {
      Require(bytes != null && bytes.Length == 65536);
      int offset = 0;
      for (int entry = 0; ; ++entry) {
        Require(entry < 16 && offset >= 0 && offset <= bytes.Length - 104);
        uint next = BitConverter.ToUInt32(bytes, offset), length = BitConverter.ToUInt32(bytes, offset + 60);
        Require(length > 0 && length % 2 == 0 && length <= 128 && length <= bytes.Length - offset - 104);
        string name = new UnicodeEncoding(false, false, true).GetString(bytes, offset + 104, (int)length);
        if (name != "." && name != "..") {
          Require(allowed.Contains(name) && names.Count < 12 && !names.ContainsKey(name));
          names.Add(name, BitConverter.ToUInt64(bytes, offset + 96));
        }
        if (next == 0) break;
        Require(next >= 104 + length && next % 8 == 0 && next <= bytes.Length - offset - 104);
        offset += (int)next;
      }
    }
    internal static bool Same(Fact a, Fact b) {
      if (a == null || b == null || a.Streams == null || b.Streams == null) return false;
      if (a.Name != b.Name || a.FileId != b.FileId || a.Volume != b.Volume || a.FileSystem != b.FileSystem ||
          a.DriveType != b.DriveType || a.OwnerSid != b.OwnerSid || a.Dacl != b.Dacl ||
          a.Attributes != b.Attributes || a.ReparseTag != b.ReparseTag || a.Links != b.Links ||
          a.Length != b.Length || a.Created != b.Created || a.LastWrite != b.LastWrite || a.Changed != b.Changed ||
          a.OwnerMatches != b.OwnerMatches || a.RecipeMatches != b.RecipeMatches || a.Streams.Length != b.Streams.Length) return false;
      for (int i = 0; i < a.Streams.Length; ++i)
        if (a.Streams[i].Name != b.Streams[i].Name || a.Streams[i].Length != b.Streams[i].Length ||
            a.Streams[i].Allocation != b.Streams[i].Allocation) return false;
      return true;
    }
    internal static void CheckNames(Pin parent, Dictionary<string, string> layout, Dictionary<string, Pin> pins,
        IMetadataApi api, Capture report) {
      HashSet<string> allowed = new HashSet<string>(StringComparer.Ordinal);
      string prefix = parent.Name + "/";
      foreach (string path in layout.Keys) {
        if (path.StartsWith(prefix, StringComparison.Ordinal)) {
          string leaf = path.Substring(prefix.Length); if (leaf.IndexOf('/') < 0) allowed.Add(leaf);
        }
      }
      Dictionary<string, ulong> names = api.Enumerate(parent, allowed, report);
      Require(names != null && names.Count == allowed.Count);
      foreach (KeyValuePair<string, ulong> item in names) Require(allowed.Contains(item.Key));
      foreach (string leaf in allowed) {
        Require(names.ContainsKey(leaf));
        Pin child;
        if (pins.TryGetValue(prefix + leaf, out child)) Require(names[leaf] == Convert.ToUInt64(child.Initial.FileId, 16));
      }
    }
    internal static Capture Read(string[] history, long[] lengths, IMetadataApi api, Capture report) {
      Require(history != null && history.Length == 2 && history[0] != history[1] && lengths != null && lengths.Length == 2);
      foreach (string name in history) Require(name != null && System.Text.RegularExpressions.Regex.IsMatch(name, @"^~tmp-[0-9a-f]{16}-[0-9a-f]{8}\z"));
      foreach (long size in lengths) Require(size > 0 && size <= 65536);
      Dictionary<string, string> layout = new Dictionary<string, string>(StringComparer.Ordinal);
      List<string> order = new List<string>();
      foreach (string name in new string[] { "Shiroha", "Shiroha/external", "Shiroha/external/app", "Shiroha/external/app/trust", "Shiroha/external/app/state", "Shiroha/external/discovery", "Shiroha/external/exchange", "Shiroha/external/bridge" }) {
        layout.Add(name, "directory"); order.Add(name);
      }
      foreach (string name in new string[] { "Shiroha/external/runtime.lock", "Shiroha/external/bridge/client.lock" }) { layout.Add(name, "lock"); order.Add(name); }
      foreach (string name in history) { string path = "Shiroha/external/app/state/" + name; layout.Add(path, "history"); order.Add(path); }
      PinOwner owned = new PinOwner();
      Dictionary<string, Pin> pins = new Dictionary<string, Pin>(StringComparer.Ordinal);
      Func<IntPtr, bool> close = api.Close;
      string stage = "root_open";
      try {
        Pin root = owned.Reserve("."); root.Handle = api.OpenRoot(report);
        stage = "root_query"; root.Initial = api.Inspect(root, report); pins.Add(".", root);
        Require(root.Initial.FileSystem == "NTFS" && root.Initial.DriveType == 3 && root.Initial.ReparseTag == 0 &&
          (root.Initial.Attributes & 0x410) == 0x10 && root.Initial.FileId != "0000000000000000");
        foreach (string path in order) {
          stage = "deadline"; Require(api.ElapsedMilliseconds < 30000 && !report.CloseUnknown);
          string kind = layout[path]; int slash = path.LastIndexOf('/');
          string parent = slash < 0 ? "." : path.Substring(0, slash), leaf = slash < 0 ? path : path.Substring(slash + 1);
          Pin pin = owned.Reserve(path);
          stage = "object_open"; pin.Handle = api.Open(pins[parent].Handle, leaf, kind == "directory", kind == "history", report);
          stage = "object_query"; pin.Initial = api.Inspect(pin, report); pins.Add(path, pin);
          Fact fact = pin.Initial;
          Require(fact.Name == path && fact.FileSystem == "NTFS" && fact.DriveType == 3 && fact.ReparseTag == 0 &&
            (fact.Attributes & 0x400) == 0 && fact.FileId != "0000000000000000" && fact.Volume == root.Initial.Volume &&
            ((fact.Attributes & 0x10) != 0) == (kind == "directory") && fact.OwnerMatches &&
            (path == "Shiroha" || fact.RecipeMatches) && (kind == "directory" || fact.Links == 1));
          foreach (Pin prior in pins.Values) if (prior != pin) Require(prior.Initial.Volume != fact.Volume || prior.Initial.FileId != fact.FileId);
          stage = "streams"; CheckStreams(fact);
          if (kind == "lock") Require(fact.Length == 0);
          if (kind == "history") Require(fact.Length == lengths[Array.IndexOf(history, leaf)]);
          if (kind == "directory") { stage = "enumeration"; CheckNames(pin, layout, pins, api, report); }
        }
        for (int i = 0; i < owned.Count; ++i) {
          stage = "deadline"; Require(api.ElapsedMilliseconds < 30000);
          Pin pin = owned.At(i);
          stage = "second_query"; Fact after = api.Inspect(pin, report);
          Require(Same(pin.Initial, after));
          if (pin.Name != ".") { stage = "streams"; CheckStreams(after); }
          if (pin.Name != "." && (after.Attributes & 0x10) != 0) {
            stage = "second_enumeration"; CheckNames(pin, layout, pins, api, report);
          }
          report.Facts.Add(after);
        }
      } catch {
        report.Fail(stage); report.Facts.Clear(); throw;
      } finally { owned.Close(close, report); }
      if (report.CloseUnknown || api.ElapsedMilliseconds >= 30000) {
        report.Fail(report.CloseUnknown ? "close" : "deadline"); report.Facts.Clear();
        throw new InvalidOperationException("capture_incomplete");
      }
      return report;
    }
  }
}

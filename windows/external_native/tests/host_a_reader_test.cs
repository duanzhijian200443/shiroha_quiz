// Whole reader state machine + parsers. Every handle and metadata fact is fake.
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Text;
using ShirohaBatch3;

static class ReaderTest {
  static readonly string[] History = { "~tmp-0123456789abcdef-01234567", "~tmp-0123456789abcdef-89abcdef" };
  static readonly long[] Lengths = { 128, 160 };
  static int cases;
  static void Check(bool value) { if (!value) throw new Exception("fake assertion"); }
  static void Reject(Action action) { ++cases; bool denied = false; try { action(); } catch (InvalidOperationException) { denied = true; } Check(denied); }
  sealed class Fake : IMetadataApi {
    internal readonly List<string> Names = new List<string> { ".", "Shiroha", "Shiroha/external", "Shiroha/external/app", "Shiroha/external/app/trust", "Shiroha/external/app/state", "Shiroha/external/discovery", "Shiroha/external/exchange", "Shiroha/external/bridge", "Shiroha/external/runtime.lock", "Shiroha/external/bridge/client.lock", "Shiroha/external/app/state/" + History[0], "Shiroha/external/app/state/" + History[1] };
    internal int Operation, FailureAt = -1, Opened, Closed;
    internal string Mutation;
    internal bool FailClose;
    internal readonly HashSet<long> Live = new HashSet<long>();
    readonly Dictionary<string, int> queries = new Dictionary<string, int>();
    public long ElapsedMilliseconds { get { return Mutation == "deadline" ? 30000 : 0; } }
    void Step() { if (Operation++ == FailureAt) throw new InvalidOperationException("injected_access_query_or_sharing_failure"); }
    IntPtr Acquire(string name, Capture report) {
      ++report.OpenAttempts; Step(); int id = Names.IndexOf(name) + 1; Check(id > 0);
      ++Opened; Check(Live.Add(id)); return new IntPtr(id);
    }
    public IntPtr OpenRoot(Capture report) { return Acquire(".", report); }
    public IntPtr Open(IntPtr parent, string name, bool directory, bool history, Capture report) {
      Check(Live.Contains(parent.ToInt64()));
      string path = Names[(int)parent.ToInt64() - 1]; path = path == "." ? name : path + "/" + name;
      bool isFile = path.EndsWith(".lock") || path.Contains("~tmp-");
      Check(directory != isFile && history == path.Contains("~tmp-"));
      return Acquire(path, report);
    }
    public Fact Inspect(Pin pin, Capture report) {
      ++report.QueryAttempts; Step(); Check(Live.Contains(pin.Handle.ToInt64()));
      int count; queries.TryGetValue(pin.Name, out count); queries[pin.Name] = ++count;
      bool directory = pin.Handle.ToInt64() <= 9;
      long length = pin.Name.EndsWith(History[0]) ? Lengths[0] : pin.Name.EndsWith(History[1]) ? Lengths[1] : 0;
      Fact fact = new Fact { Name = pin.Name, Volume = "0000002a", FileId = pin.Handle.ToInt64().ToString("x16"),
        FileSystem = "NTFS", DriveType = 3, Attributes = directory ? 16u : 32u, ReparseTag = 0, Links = 1,
        Length = length, Created = 1, LastWrite = 2, Changed = 3, OwnerSid = "synthetic", Dacl = "synthetic",
        OwnerMatches = true, RecipeMatches = true,
        Streams = directory ? new StreamFact[0] : new[] { new StreamFact { Name = "::$DATA", Length = length, Allocation = 4096 } } };
      if (pin.Name != ".") ++report.StreamAttempts;
      if (pin.Name.EndsWith(History[0])) {
        if (Mutation == "ads") fact.Streams = new[] { new StreamFact { Name = ":unknown:$DATA", Length = 1 } };
        if (Mutation == "streams_missing") fact.Streams = null;
        if (Mutation == "stream_size") fact.Streams[0].Length++;
        if (Mutation == "alias") fact.FileId = "0000000000000001";
        if (Mutation == "length") fact.Length++;
        if (Mutation == "security") fact.RecipeMatches = false;
        if (count == 2) {
          if (Mutation == "id_drift") fact.FileId = "0000000000000080";
          if (Mutation == "time_drift") fact.Changed++;
          if (Mutation == "allocation_drift") fact.Streams[0].Allocation++;
          if (Mutation == "filesystem_drift") fact.FileSystem = "other";
          if (Mutation == "late_ads") fact.Streams = new[] { new StreamFact { Name = ":unknown:$DATA", Length = 1 } };
        }
      }
      return fact;
    }
    public Dictionary<string, ulong> Enumerate(Pin pin, HashSet<string> allowed, Capture report) {
      Check(pin.Name != "."); ++report.EnumerationAttempts; Step();
      Dictionary<string, ulong> names = new Dictionary<string, ulong>(StringComparer.Ordinal);
      string prefix = pin.Name + "/";
      foreach (string path in Names) {
        if (!path.StartsWith(prefix, StringComparison.Ordinal)) continue;
        string leaf = path.Substring(prefix.Length); if (leaf.Contains("/")) continue;
        byte[] page = DirectoryPage(leaf, (ulong)(Names.IndexOf(path) + 1));
        MetadataContract.ParseDirectoryPage(page, allowed, names);
      }
      if (Mutation == "unknown" && pin.Name == "Shiroha/external/app/state") names.Add("associations.bin", 99);
      if (Mutation == "missing" && pin.Name == "Shiroha/external/app/state") names.Clear();
      if (Mutation == "enumeration_id" && pin.Name == "Shiroha/external/app/state") names[History[0]] = 99;
      return names;
    }
    public bool Close(IntPtr handle) { Check(Live.Remove(handle.ToInt64())); ++Closed; return !FailClose; }
  }
  static byte[] DirectoryPage(string name, ulong id) {
    byte[] page = new byte[65536], text = Encoding.Unicode.GetBytes(name);
    Array.Copy(BitConverter.GetBytes((uint)text.Length), 0, page, 60, 4);
    Array.Copy(BitConverter.GetBytes(id), 0, page, 96, 8); Array.Copy(text, 0, page, 104, text.Length); return page;
  }
  static byte[] StreamPage(string name, long length) {
    byte[] text = Encoding.Unicode.GetBytes(name), page = new byte[24 + text.Length];
    Array.Copy(BitConverter.GetBytes((uint)text.Length), 0, page, 4, 4);
    Array.Copy(BitConverter.GetBytes(length), 0, page, 8, 8);
    Array.Copy(BitConverter.GetBytes(4096L), 0, page, 16, 8); Array.Copy(text, 0, page, 24, text.Length); return page;
  }
  static void Main() {
    Check(typeof(MetadataContract).Assembly.GetType("ShirohaBatch3.MetadataReader") == null);
    foreach (Type type in typeof(MetadataContract).Assembly.GetTypes())
      foreach (MethodInfo method in type.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static | BindingFlags.Instance))
        Check((method.Attributes & MethodAttributes.PinvokeImpl) == 0);
    Check((MetadataContract.FileAccess & 1u) == 0 && MetadataContract.FileAccess == 0x120080u && MetadataContract.DirectoryAccess == 0x1200a1u);
    Fake ok = new Fake(); Capture full = MetadataContract.Read(History, Lengths, ok, new Capture()); ++cases;
    Check(full.Facts.Count == 13 && ok.Opened == 13 && ok.Closed == 13 && full.QueryAttempts == 26 && full.StreamAttempts == 24 && full.EnumerationAttempts == 16 && full.FirstFailure == null);
    int operations = ok.Operation;
    for (int i = 0; i < operations; ++i) {
      foreach (bool closeFailure in new[] { false, true }) {
        Fake fake = new Fake { FailureAt = i, FailClose = closeFailure }; Capture report = new Capture();
        Reject(delegate { MetadataContract.Read(History, Lengths, fake, report); });
        Check(fake.Opened == fake.Closed && fake.Live.Count == 0 && report.FirstFailure != null && report.FirstFailure != "close" && report.Facts.Count == 0);
      }
    }
    foreach (string mutation in new[] { "ads", "streams_missing", "stream_size", "alias", "length", "security", "id_drift", "time_drift", "allocation_drift", "filesystem_drift", "late_ads", "unknown", "missing", "enumeration_id", "deadline" }) {
      Fake fake = new Fake { Mutation = mutation, FailClose = true }; Capture report = new Capture();
      Reject(delegate { MetadataContract.Read(History, Lengths, fake, report); });
      Check(fake.Opened == fake.Closed && report.FirstFailure != "close" && report.Facts.Count == 0);
      if (mutation == "unknown") Check(fake.Opened == 6); // No unknown/history object opened.
    }
    Fake close = new Fake { FailClose = true }; Capture closeReport = new Capture();
    Reject(delegate { MetadataContract.Read(History, Lengths, close, closeReport); });
    Check(closeReport.FirstFailure == "close" && closeReport.CloseAttempts == 13 && closeReport.Facts.Count == 0);
    byte[] stream = StreamPage("::$DATA", 128);
    Check(MetadataContract.ParseStreams(stream, stream.Length)[0].Length == 128); ++cases;
    Check(MetadataContract.ParseStreams(new byte[0], 0).Length == 0); ++cases;
    foreach (string name in new[] { ":ads:$DATA", ":Zone.Identifier:$DATA", "::$INDEX_ALLOCATION", "::$data" }) {
      byte[] bad = StreamPage(name, 0); Reject(delegate { MetadataContract.ParseStreams(bad, bad.Length); });
    }
    for (int n = 1; n < stream.Length; ++n) { int used = n; Reject(delegate { MetadataContract.ParseStreams(stream, used); }); }
    byte[] invalidNext = (byte[])stream.Clone(); invalidNext[0] = 24;
    Reject(delegate { MetadataContract.ParseStreams(invalidNext, invalidNext.Length); });
    // A0-only final-record policy: exact end or 1–7 zero bytes, never nonzero.
    for (int tail = 0; tail <= 7; ++tail) {
      byte[] padded = new byte[stream.Length + tail]; Array.Copy(stream, padded, stream.Length);
      Check(MetadataContract.ParseStreams(padded, padded.Length)[0].Length == 128); ++cases;
      for (int i = 0; i < tail; ++i) {
        byte[] bad = (byte[])padded.Clone(); bad[stream.Length + i] = 1;
        Reject(delegate { MetadataContract.ParseStreams(bad, bad.Length); });
      }
      if (tail != 0) {
        byte[] bad = (byte[])padded.Clone();
        for (int i = stream.Length; i < bad.Length; ++i) bad[i] = 0xff;
        Reject(delegate { MetadataContract.ParseStreams(bad, bad.Length); });
      }
      // Nonzero capacity bytes beyond the actual returned length are not input.
      byte[] capacity = new byte[65537]; Array.Copy(padded, capacity, padded.Length);
      for (int i = padded.Length; i < capacity.Length; ++i) capacity[i] = 0xff;
      Check(MetadataContract.ParseStreams(capacity, padded.Length)[0].Length == 128); ++cases;
    }
    byte[] excess = new byte[stream.Length + 8]; Array.Copy(stream, excess, stream.Length);
    Reject(delegate { MetadataContract.ParseStreams(excess, excess.Length); });
    Reject(delegate { MetadataContract.ParseStreams(null, 0); });
    Reject(delegate { MetadataContract.ParseStreams(stream, -1); }); // Unknown valid length denies.
    Reject(delegate { MetadataContract.ParseStreams(stream, stream.Length + 1); });
    byte[] large = new byte[65537]; Array.Copy(stream, large, stream.Length);
    Reject(delegate { MetadataContract.ParseStreams(large, 65537); });
    Reject(delegate { MetadataContract.ParseStreams(large, 65536); }); // In-range count, unexplained tail.
    Check(MetadataContract.ParseStreams(large, 0).Length == 0); ++cases;
    // Preserve nonterminal alignment/offset checks; a second stream still denies.
    foreach (uint next in new uint[] { 1, 24, 32, 38, 39, 41, 48, UInt32.MaxValue }) {
      byte[] bad = new byte[64]; Array.Copy(stream, bad, stream.Length);
      Array.Copy(BitConverter.GetBytes(next), 0, bad, 0, 4);
      Reject(delegate { MetadataContract.ParseStreams(bad, bad.Length); });
    }
    foreach (byte padding in new byte[] { 0, 0xff }) {
      byte[] chained = new byte[40 + stream.Length]; Array.Copy(stream, chained, stream.Length);
      Array.Copy(BitConverter.GetBytes(40u), 0, chained, 0, 4);
      chained[38] = padding; chained[39] = padding; Array.Copy(stream, 0, chained, 40, stream.Length);
      Reject(delegate { MetadataContract.ParseStreams(chained, chained.Length); });
    }
    byte[] negative = StreamPage("::$DATA", -1); Reject(delegate { MetadataContract.ParseStreams(negative, negative.Length); });
    HashSet<string> allowed = new HashSet<string>(new[] { "known" }, StringComparer.Ordinal);
    Dictionary<string, ulong> names = new Dictionary<string, ulong>();
    byte[] valid = DirectoryPage("known", 10); MetadataContract.ParseDirectoryPage(valid, allowed, names); ++cases;
    Check(names["known"] == 10);
    Reject(delegate { MetadataContract.ParseDirectoryPage(valid, allowed, names); });
    Reject(delegate { MetadataContract.ParseDirectoryPage(DirectoryPage("unknown", 2), allowed, new Dictionary<string, ulong>()); });
    valid[60] = 3; Reject(delegate { MetadataContract.ParseDirectoryPage(valid, allowed, new Dictionary<string, ulong>()); });
    valid = DirectoryPage("known", 10); valid[0] = 1; Reject(delegate { MetadataContract.ParseDirectoryPage(valid, allowed, new Dictionary<string, ulong>()); });
    Console.WriteLine("PASS: " + cases + " fake-only reader/parser cases; exact parent binding, ADS, two snapshots, all open/query/enumeration failures, close/first-failure preservation; no P/Invoke");
  }
}

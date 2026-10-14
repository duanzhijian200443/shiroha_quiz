// Future read-only metadata capture; compile in L0, invoke ONLY by separate grant.
// No production DLL, content read, create disposition, ACL write or cleanup API.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace ShirohaBatch3 {
  public sealed class Fact {
    public string Name, Volume, FileId, FileSystem, OwnerSid, Dacl;
    public uint DriveType, Attributes, ReparseTag, Links;
    public long Length, Created, LastWrite, Changed;
    public bool OwnerMatches, RecipeMatches;
  }
  public sealed class Capture {
    public readonly List<Fact> Facts = new List<Fact>();
    public int OpenAttempts, QueryAttempts, SecurityAttempts, EnumerationAttempts, CloseAttempts;
    public bool CloseUnknown;
  }
  sealed class Pin { public string Name; public IntPtr Handle; public Fact Initial; }
  // Allocate every ownership slot before OS access. Reserve precedes Open, so
  // an exception after handle transfer cannot strand it outside cleanup.
  sealed class PinOwner {
    internal const int Capacity = 13;
    readonly Pin[] pins = new Pin[Capacity];
    int count;
    bool closed;
    internal PinOwner() { for (int i = 0; i < pins.Length; ++i) pins[i] = new Pin(); }
    internal int Count { get { return count; } }
    internal Pin At(int index) { return pins[index]; }
    internal Pin Reserve(string name) {
      if (closed || count == Capacity) throw new InvalidOperationException("pin_budget");
      Pin pin = pins[count++]; pin.Name = name; return pin;
    }
    internal void Close(Func<IntPtr, bool> close, Capture report) {
      if (closed) return;
      closed = true;
      for (int i = count - 1; i >= 0; --i) {
        IntPtr handle = pins[i].Handle; pins[i].Handle = IntPtr.Zero;
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) continue;
        ++report.CloseAttempts;
        try { if (!close(handle)) report.CloseUnknown = true; }
        catch { report.CloseUnknown = true; } // Preserve the original failure.
      }
    }
  }
#if !SHIROHA_METADATA_FAKE_ONLY
  public static class MetadataReader {
    [StructLayout(LayoutKind.Sequential)] struct UnicodeName { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes {
      public uint Length; public IntPtr Root, Name; public uint Flags; public IntPtr Security, Qos;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoStatus { public IntPtr Status; public UIntPtr Information; }
    [StructLayout(LayoutKind.Sequential)] struct Info {
      public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
      public uint Volume, SizeHigh, SizeLow, Links, IdHigh, IdLow;
    }
    [StructLayout(LayoutKind.Sequential)] struct BasicInfo {
      public long Created, Accessed, Written, Changed; public uint Attributes;
    }
    [StructLayout(LayoutKind.Sequential)] struct TagInfo { public uint Attributes, Tag; }
    [DllImport("ntdll.dll")] static extern int NtCreateFile(out IntPtr file, uint access, ref ObjectAttributes attributes,
      out IoStatus io, IntPtr allocation, uint flags, uint share, uint disposition, uint options, IntPtr ea, uint eaLength);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr file);
    [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr file);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr file, out Info info);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandleEx(IntPtr file, int kind, IntPtr data, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetVolumeInformationByHandleW(
      IntPtr file, IntPtr name, uint nameSize, out uint volume, out uint maxName, out uint flags, StringBuilder fs, uint fsSize);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFinalPathNameByHandleW(IntPtr file, StringBuilder path, uint size, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern uint GetDriveTypeW(string root);
    [DllImport("advapi32.dll")] static extern uint GetSecurityInfo(IntPtr file, int type, uint flags,
      out IntPtr owner, IntPtr group, out IntPtr dacl, IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll")] static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(ref Guid folder, uint flags, IntPtr token, out IntPtr path);

    static void Require(bool condition) { if (!condition) throw new InvalidOperationException("metadata_denied"); }
    static IntPtr Open(IntPtr parent, string name, bool directory, bool history, Capture report) {
      IntPtr chars = Marshal.StringToHGlobalUni(name), unicode = IntPtr.Zero, acquired = IntPtr.Zero;
      try {
        Require(name.Length > 0 && name.Length <= 32760);
        UnicodeName value = new UnicodeName { Length = checked((ushort)(name.Length * 2)), MaximumLength = checked((ushort)(name.Length * 2)), Buffer = chars };
        unicode = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeName)));
        Marshal.StructureToPtr(value, unicode, false);
        ObjectAttributes attr = new ObjectAttributes { Length = (uint)Marshal.SizeOf(typeof(ObjectAttributes)), Root = parent, Name = unicode, Flags = 0x1040 };
        IoStatus io;
        // FILE_OPEN only. Files have attributes/security rights, NEVER READ_DATA.
        // Directories need LIST_DIRECTORY/TRAVERSE. All pins deny delete sharing;
        // history pins also deny write sharing for this capture's lifetime.
        ++report.OpenAttempts;
        int status = NtCreateFile(out acquired, 0x120080u | (directory ? 0x21u : 0u), ref attr, out io,
          IntPtr.Zero, 0, history ? 1u : 3u, 1, 0x200020u | (directory ? 0u : 0x40u), IntPtr.Zero, 0);
        Require(status == 0 && io.Status == IntPtr.Zero && io.Information.ToUInt64() == 1 && acquired != IntPtr.Zero && acquired != new IntPtr(-1));
        IntPtr result = acquired; acquired = IntPtr.Zero; return result;
      } finally {
        if (acquired != IntPtr.Zero && acquired != new IntPtr(-1)) { ++report.CloseAttempts; if (!CloseHandle(acquired)) report.CloseUnknown = true; }
        if (unicode != IntPtr.Zero) Marshal.FreeHGlobal(unicode);
        Marshal.FreeHGlobal(chars);
      }
    }
    static T Query<T>(IntPtr handle, int kind) where T : struct {
      IntPtr memory = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(T)));
      try { Require(GetFileInformationByHandleEx(handle, kind, memory, (uint)Marshal.SizeOf(typeof(T)))); return (T)Marshal.PtrToStructure(memory, typeof(T)); }
      finally { Marshal.FreeHGlobal(memory); }
    }
    static Fact Inspect(Pin pin, string sid, Capture report) {
      ++report.QueryAttempts;
      Info info = new Info(); Require(GetFileType(pin.Handle) == 1 && GetFileInformationByHandle(pin.Handle, out info));
      BasicInfo basic = Query<BasicInfo>(pin.Handle, 0); TagInfo tag = Query<TagInfo>(pin.Handle, 9);
      StringBuilder fs = new StringBuilder(32); uint volume, maxName, flags;
      Require(GetVolumeInformationByHandleW(pin.Handle, IntPtr.Zero, 0, out volume, out maxName, out flags, fs, 32));
      StringBuilder path = new StringBuilder(32768); uint length = GetFinalPathNameByHandleW(pin.Handle, path, 32768, 1);
      Require(length > 0 && length < 32768 && path.ToString().StartsWith(@"\\?\Volume{", StringComparison.Ordinal));
      int end = path.ToString().IndexOf(@"}\", StringComparison.Ordinal); Require(end >= 0);
      uint drive = GetDriveTypeW(path.ToString().Substring(0, end + 2));
      IntPtr owner, dacl, descriptor = IntPtr.Zero;
      ++report.SecurityAttempts;
      try {
        Require(GetSecurityInfo(pin.Handle, 1, 5, out owner, IntPtr.Zero, out dacl, IntPtr.Zero, out descriptor) == 0 && descriptor != IntPtr.Zero);
        uint size = GetSecurityDescriptorLength(descriptor); Require(size > 0 && size <= 65536);
        byte[] bytes = new byte[size]; Marshal.Copy(descriptor, bytes, 0, (int)size);
        RawSecurityDescriptor security = new RawSecurityDescriptor(bytes, 0); Require(security.Owner != null);
        bool directory = (info.Attributes & 0x10) != 0;
        bool recipe = false;
        if (security.DiscretionaryAcl != null && security.DiscretionaryAcl.Count == 1 &&
            (security.ControlFlags & ControlFlags.DiscretionaryAclPresent) != 0 &&
            (security.ControlFlags & ControlFlags.DiscretionaryAclProtected) != 0) {
          CommonAce ace = security.DiscretionaryAcl[0] as CommonAce;
          recipe = ace != null && !ace.IsCallback && ace.AceQualifier == AceQualifier.AccessAllowed &&
            ace.SecurityIdentifier.Value == sid && ace.AccessMask == 0x1f01ff &&
            ace.AceFlags == (directory ? (AceFlags.ObjectInherit | AceFlags.ContainerInherit) : AceFlags.None);
        }
        Require(volume == info.Volume && basic.Attributes == info.Attributes && tag.Attributes == info.Attributes);
        return new Fact { Name = pin.Name, Volume = volume.ToString("x8"), FileId = (((ulong)info.IdHigh << 32) | info.IdLow).ToString("x16"),
          FileSystem = fs.ToString(), DriveType = drive, Attributes = info.Attributes, ReparseTag = tag.Tag, Links = info.Links,
          Length = checked((long)(((ulong)info.SizeHigh << 32) | info.SizeLow)), Created = basic.Created, LastWrite = basic.Written, Changed = basic.Changed,
          OwnerSid = security.Owner.Value, Dacl = security.GetSddlForm(AccessControlSections.Access), OwnerMatches = security.Owner.Value == sid, RecipeMatches = recipe };
      } finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
    }
    static Dictionary<string, ulong> Enumerate(Pin pin, HashSet<string> allowed, Capture report) {
      Dictionary<string, ulong> names = new Dictionary<string, ulong>(StringComparer.Ordinal);
      IntPtr buffer = Marshal.AllocHGlobal(65536);
      try {
        // At most two data pages plus a terminal query; overfull/unknown denies.
        for (int page = 0; page < 3; ++page) {
          ++report.EnumerationAttempts;
          if (!GetFileInformationByHandleEx(pin.Handle, page == 0 ? 11 : 10, buffer, 65536)) {
            Require(Marshal.GetLastWin32Error() == 18); return names;
          }
          int offset = 0;
          for (int entry = 0; ; ++entry) {
            Require(entry < 16 && offset >= 0 && offset <= 65536 - 104);
            IntPtr record = IntPtr.Add(buffer, offset); int next = Marshal.ReadInt32(record), bytes = Marshal.ReadInt32(record, 60);
            Require(bytes > 0 && bytes % 2 == 0 && bytes <= 128 && bytes <= 65536 - offset - 104);
            string name = Marshal.PtrToStringUni(IntPtr.Add(record, 104), bytes / 2);
            if (name != "." && name != "..") { Require(allowed.Contains(name) && names.Count < 12 && !names.ContainsKey(name)); names.Add(name, unchecked((ulong)Marshal.ReadInt64(record, 96))); }
            if (next == 0) break;
            Require(next >= 104 + bytes && next % 8 == 0 && next <= 65536 - offset - 104); offset += next;
          }
        }
        throw new InvalidOperationException("enumeration_budget");
      } finally { Marshal.FreeHGlobal(buffer); }
    }
    static void CheckNames(Pin parent, Dictionary<string, string> layout, Dictionary<string, Pin> pins, Capture report) {
      HashSet<string> allowed = new HashSet<string>(StringComparer.Ordinal);
      string childPrefix = parent.Name + "/";
      foreach (string path in layout.Keys) {
        if (path.StartsWith(childPrefix, StringComparison.Ordinal)) {
          string leaf = path.Substring(childPrefix.Length); if (leaf.IndexOf('/') < 0) allowed.Add(leaf);
        }
      }
      Dictionary<string, ulong> names = Enumerate(parent, allowed, report);
      string prefix = parent.Name + "/"; int expected = 0;
      foreach (KeyValuePair<string, string> item in layout) {
        if (!item.Key.StartsWith(prefix, StringComparison.Ordinal)) continue;
        string leaf = item.Key.Substring(prefix.Length); if (leaf.IndexOf('/') >= 0) continue;
        ++expected; Require(names.ContainsKey(leaf));
        Pin child; if (pins.TryGetValue(item.Key, out child)) Require(names[leaf] == Convert.ToUInt64(child.Initial.FileId, 16));
      }
      Require(names.Count == expected); // associations.bin and every unknown name deny.
    }
    public static Capture Read(string[] history, long[] expectedLengths) {
      Require(IntPtr.Size == 8 && history != null && history.Length == 2 && history[0] != history[1] &&
        expectedLengths != null && expectedLengths.Length == 2);
      foreach (string name in history) Require(System.Text.RegularExpressions.Regex.IsMatch(name, @"^~tmp-[0-9a-f]{16}-[0-9a-f]{8}\z"));
      foreach (long size in expectedLengths) Require(size > 0 && size <= 65536);
      Dictionary<string, string> layout = new Dictionary<string, string>(StringComparer.Ordinal);
      List<string> order = new List<string>();
      foreach (string name in new string[] {"Shiroha", "Shiroha/external", "Shiroha/external/app", "Shiroha/external/app/trust", "Shiroha/external/app/state", "Shiroha/external/discovery", "Shiroha/external/exchange", "Shiroha/external/bridge"}) { layout.Add(name, "directory"); order.Add(name); }
      layout.Add("Shiroha/external/runtime.lock", "lock"); layout.Add("Shiroha/external/bridge/client.lock", "lock");
      order.Add("Shiroha/external/runtime.lock"); order.Add("Shiroha/external/bridge/client.lock");
      foreach (string name in history) { string path = "Shiroha/external/app/state/" + name; layout.Add(path, "history"); order.Add(path); }
      Capture report = new Capture(); PinOwner owned = new PinOwner(); Dictionary<string, Pin> pins = new Dictionary<string, Pin>(StringComparer.Ordinal);
      Func<IntPtr, bool> close = CloseHandle; // Delegate allocation also precedes OS access.
      Stopwatch timer = Stopwatch.StartNew();
      try {
        string sid; using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) { sid = identity.User.Value; }
        Guid folder = new Guid("f1b32785-6fba-4fcf-9d55-7b8e7f157091"); IntPtr raw = IntPtr.Zero; string local;
        try { Require(SHGetKnownFolderPath(ref folder, 0, IntPtr.Zero, out raw) == 0 && raw != IntPtr.Zero); local = Marshal.PtrToStringUni(raw); }
        finally { if (raw != IntPtr.Zero) Marshal.FreeCoTaskMem(raw); }
        Require(local.Length >= 3 && local[1] == ':' && local[2] == '\\' && local.IndexOf('/') < 0);
        Pin root = owned.Reserve("."); root.Handle = Open(IntPtr.Zero, @"\??\" + local, true, false, report);
        root.Initial = Inspect(root, sid, report); pins.Add(".", root);
        Require(root.Initial.FileSystem == "NTFS" && root.Initial.DriveType == 3 && root.Initial.ReparseTag == 0 &&
          (root.Initial.Attributes & 0x410) == 0x10 && root.Initial.FileId != "0000000000000000");
        foreach (string path in order) {
          KeyValuePair<string, string> item = new KeyValuePair<string, string>(path, layout[path]);
          Require(timer.ElapsedMilliseconds < 30000 && !report.CloseUnknown);
          int slash = item.Key.LastIndexOf('/'); string parentName = slash < 0 ? "." : item.Key.Substring(0, slash);
          string component = slash < 0 ? item.Key : item.Key.Substring(slash + 1);
          Pin pin = owned.Reserve(item.Key);
          pin.Handle = Open(pins[parentName].Handle, component, item.Value == "directory", item.Value == "history", report);
          pin.Initial = Inspect(pin, sid, report); pins.Add(item.Key, pin);
          Require(pin.Initial.FileSystem == "NTFS" && pin.Initial.DriveType == 3 && pin.Initial.ReparseTag == 0 &&
            (pin.Initial.Attributes & 0x400) == 0 && pin.Initial.FileId != "0000000000000000" && pin.Initial.Volume == root.Initial.Volume &&
            ((pin.Initial.Attributes & 0x10) != 0) == (item.Value == "directory") && pin.Initial.OwnerMatches &&
            (item.Key == "Shiroha" || pin.Initial.RecipeMatches) && (item.Value == "directory" || pin.Initial.Links == 1));
          if (item.Value == "lock") Require(pin.Initial.Length == 0);
          if (item.Value == "history") Require(pin.Initial.Length == expectedLengths[Array.IndexOf(history, component)]);
          if (item.Value == "directory") CheckNames(pin, layout, pins, report);
        }
        for (int i = 0; i < owned.Count; ++i) {
          Pin pin = owned.At(i);
          Require(timer.ElapsedMilliseconds < 30000);
          Fact after = Inspect(pin, sid, report); Fact before = pin.Initial;
          Require(after.FileId == before.FileId && after.Volume == before.Volume && after.OwnerSid == before.OwnerSid && after.Dacl == before.Dacl &&
            after.Attributes == before.Attributes && after.ReparseTag == before.ReparseTag && after.Links == before.Links &&
            after.Length == before.Length && after.Created == before.Created && after.LastWrite == before.LastWrite && after.Changed == before.Changed);
          if (pin.Name != "." && (pin.Initial.Attributes & 0x10) != 0) CheckNames(pin, layout, pins, report);
          report.Facts.Add(after);
        }
      } finally {
        owned.Close(close, report);
      }
      Require(!report.CloseUnknown && timer.ElapsedMilliseconds < 30000);
      return report; // Pins are now closed. This report grants NO runtime admission.
    }
  }
#endif
}

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
    public StreamFact[] Streams;
  }
  public sealed class Capture {
    public readonly List<Fact> Facts = new List<Fact>();
    public int OpenAttempts, QueryAttempts, SecurityAttempts, EnumerationAttempts, CloseAttempts;
    public bool CloseUnknown;
    public int StreamAttempts;
    public string FirstFailure;
    internal void Fail(string stage) { if (FirstFailure == null) FirstFailure = stage; }
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
        try { if (!close(handle)) { report.CloseUnknown = true; report.Fail("close"); } }
        catch { report.CloseUnknown = true; report.Fail("close"); } // Preserve the original failure.
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
    [DllImport("ntdll.dll")] static extern int NtQueryInformationFile(IntPtr file, out IoStatus io, IntPtr data, uint size, int kind);
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
        int status = NtCreateFile(out acquired, directory ? MetadataContract.DirectoryAccess : MetadataContract.FileAccess, ref attr, out io,
          IntPtr.Zero, 0, history ? 1u : 3u, 1, 0x200020u | (directory ? 0u : 0x40u), IntPtr.Zero, 0);
        Require(status == 0 && io.Status == IntPtr.Zero && io.Information.ToUInt64() == 1 && acquired != IntPtr.Zero && acquired != new IntPtr(-1));
        IntPtr result = acquired; acquired = IntPtr.Zero; return result;
      } finally {
        if (acquired != IntPtr.Zero && acquired != new IntPtr(-1)) {
          ++report.CloseAttempts;
          try { if (!CloseHandle(acquired)) report.CloseUnknown = true; }
          catch { report.CloseUnknown = true; } // Never mask failed-open evidence.
        }
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
          OwnerSid = security.Owner.Value, Dacl = security.GetSddlForm(AccessControlSections.Access), OwnerMatches = security.Owner.Value == sid, RecipeMatches = recipe, Streams = pin.Name == "." ? new StreamFact[0] : Streams(pin.Handle, report) };
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
          byte[] bytes = new byte[65536]; Marshal.Copy(buffer, bytes, 0, bytes.Length);
          MetadataContract.ParseDirectoryPage(bytes, allowed, names);
        }
        throw new InvalidOperationException("enumeration_budget");
      } finally { Marshal.FreeHGlobal(buffer); }
    }
    static StreamFact[] Streams(IntPtr handle, Capture report) {
      IntPtr buffer = Marshal.AllocHGlobal(65536);
      try {
        ++report.StreamAttempts;
        IoStatus io;
        // One bounded FileStreamInformation query on the already pinned handle.
        // No stream open and no READ_DATA; overflow/unsupported/access denial STOP.
        int status = NtQueryInformationFile(handle, out io, buffer, 65536, 22);
        Require(status == 0 && io.Status == IntPtr.Zero && io.Information.ToUInt64() <= 65536);
        int used = checked((int)io.Information.ToUInt64());
        byte[] bytes = new byte[used]; Marshal.Copy(buffer, bytes, 0, used);
        return MetadataContract.ParseStreams(bytes, used);
      } finally { Marshal.FreeHGlobal(buffer); }
    }
    sealed class NativeApi : IMetadataApi {
      string sid;
      readonly Stopwatch timer = Stopwatch.StartNew();
      internal NativeApi() {
        Require(IntPtr.Size == 8);
      }
      public long ElapsedMilliseconds { get { return timer.ElapsedMilliseconds; } }
      public bool Close(IntPtr handle) { return CloseHandle(handle); }
      public Fact Inspect(Pin pin, Capture report) { return MetadataReader.Inspect(pin, sid, report); }
      public Dictionary<string, ulong> Enumerate(Pin pin, HashSet<string> allowed, Capture report) { return MetadataReader.Enumerate(pin, allowed, report); }
      public IntPtr Open(IntPtr parent, string name, bool directory, bool history, Capture report) { return MetadataReader.Open(parent, name, directory, history, report); }
      public IntPtr OpenRoot(Capture report) {
        // MetadataContract has already allocated/reserved ownership slots.
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) { sid = identity.User.Value; }
        Guid folder = new Guid("f1b32785-6fba-4fcf-9d55-7b8e7f157091"); IntPtr raw = IntPtr.Zero; string local;
        try { Require(SHGetKnownFolderPath(ref folder, 0, IntPtr.Zero, out raw) == 0 && raw != IntPtr.Zero); local = Marshal.PtrToStringUni(raw); }
        finally { if (raw != IntPtr.Zero) Marshal.FreeCoTaskMem(raw); }
        Require(local != null && local.Length >= 3 && local[1] == ':' && local[2] == '\\' && local.IndexOf('/') < 0);
        return MetadataReader.Open(IntPtr.Zero, @"\??\" + local, true, false, report);
      }
    }
    public static Capture Read(string[] history, long[] expectedLengths) {
      Capture report = ReadOutcome(history, expectedLengths);
      Require(report.FirstFailure == null && !report.CloseUnknown);
      return report;
    }
    public static Capture ReadOutcome(string[] history, long[] expectedLengths) {
      Capture report = new Capture();
      try { return MetadataContract.Read(history, expectedLengths, new NativeApi(), report); }
      catch { report.Fail("setup"); report.Facts.Clear(); return report; }
    }
  }
#endif
}

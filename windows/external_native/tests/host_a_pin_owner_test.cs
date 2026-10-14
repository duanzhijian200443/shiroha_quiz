// Shared ownership implementation only; SHIROHA_METADATA_FAKE_ONLY excludes
// MetadataReader and every P/Invoke declaration from this executable.
using System;
using System.Collections.Generic;
using ShirohaBatch3;

static class PinOwnerTest {
  static void Check(bool condition) { if (!condition) throw new Exception("fake assertion"); }
  static void Main() {
    Check(typeof(PinOwner).Assembly.GetType("ShirohaBatch3.MetadataReader") == null);
    foreach (Type type in typeof(PinOwner).Assembly.GetTypes()) {
      foreach (System.Reflection.MethodInfo method in type.GetMethods(System.Reflection.BindingFlags.Public |
          System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.Instance)) {
        Check((method.Attributes & System.Reflection.MethodAttributes.PinvokeImpl) == 0);
      }
    }
    for (int failure = 0; failure < PinOwner.Capacity; ++failure) {
      for (int closeFailure = 0; closeFailure < 3; ++closeFailure) {
        PinOwner owned = new PinOwner(); Capture report = new Capture();
        List<long> closed = new List<long>();
        Exception first = new OutOfMemoryException("synthetic post-open failure"), observed = null;
        Func<IntPtr, bool> close = delegate(IntPtr handle) {
          closed.Add(handle.ToInt64());
          if (closeFailure == 2) throw new Exception("synthetic close failure");
          return closeFailure == 0;
        };
        try {
          try {
            for (int i = 0; i <= failure; ++i) {
              Pin pin = owned.Reserve("synthetic");
              pin.Initial = new Fact();
              pin.Handle = new IntPtr(i + 1); // Fake Open transfers a handle.
              if (i == failure) throw first; // Any next allocation/inspection.
            }
          } finally { owned.Close(close, report); }
        } catch (Exception error) { observed = error; }
        Check(Object.ReferenceEquals(first, observed));
        Check(closed.Count == failure + 1 && report.CloseAttempts == failure + 1);
        Check(report.CloseUnknown == (closeFailure != 0));
        for (int i = 0; i < closed.Count; ++i) Check(closed[i] == failure + 1 - i);
        owned.Close(close, report); // Unknown closes are never retried.
        Check(closed.Count == failure + 1);
      }
    }
    PinOwner full = new PinOwner(); Capture complete = new Capture();
    for (int i = 0; i < PinOwner.Capacity; ++i) full.Reserve("synthetic").Handle = new IntPtr(i + 1);
    bool denied = false;
    try { full.Reserve("extra"); } catch (InvalidOperationException) { denied = true; }
    Check(denied && full.Count == 13);
    full.Close(delegate(IntPtr handle) { return true; }, complete);
    Check(complete.CloseAttempts == 13 && !complete.CloseUnknown);
    PinOwner unopened = new PinOwner(); unopened.Reserve("failed-open");
    unopened.Close(delegate(IntPtr handle) { throw new Exception("zero handle must not close"); }, complete);
    Check(complete.CloseAttempts == 13 && !complete.CloseUnknown);
    Console.WriteLine("PASS: fake-only 13-pin ownership, post-open exceptions, reverse single close and immutable first failure");
  }
}

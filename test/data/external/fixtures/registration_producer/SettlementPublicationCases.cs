using System.Diagnostics;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

internal static class SettlementPublicationCases
{
    internal static int Run(string directory)
    {
        if (!OperatingSystem.IsWindows() || !Directory.Exists(directory) ||
            Directory.EnumerateFileSystemEntries(directory).Any())
            return 64;

        string official = Path.Combine(directory, "link-settlement.json");
        string pending = Path.Combine(directory, "link-settlement.pending");
        using var process = Process.GetCurrentProcess();
        string started = process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString();
        byte[] Receipt(string mode, string runId, string resourceId) =>
            JsonSerializer.SerializeToUtf8Bytes(new
            {
                mode, runId, resourceId, processId = process.Id, processStarted = started
            });

        byte[] oldReceipt = [];
        for (int run = 0; run < 3; run++)
        {
            foreach (string mode in new[] { "enable-proof", "business" })
            {
                oldReceipt = Receipt(mode, $"run-{run}", $"{mode}-{run}");
                LinkAdapterContext.PublishSettlementReceipt(directory, oldReceipt);
                Check(File.ReadAllBytes(official).SequenceEqual(oldReceipt) && !File.Exists(pending),
                    "receipt_not_published");
            }
        }

        byte[] next = Receipt("business", "conflict-run", "conflict-resource");
        using (var reader = new FileStream(official, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            RejectPublication(() => LinkAdapterContext.PublishSettlementReceipt(directory, next));
            Check(File.ReadAllBytes(official).SequenceEqual(oldReceipt), "old_receipt_changed");
            Check(File.ReadAllBytes(pending).SequenceEqual(next), "pending_receipt_changed");
        }

        // Even after the sharing conflict clears, a new call cannot overwrite
        // the original owner's pending evidence.
        RejectPublication(() => LinkAdapterContext.PublishSettlementReceipt(directory,
            Receipt("business", "another-run", "another-resource")));
        Check(File.ReadAllBytes(official).SequenceEqual(oldReceipt), "old_receipt_changed_on_retry");
        Check(File.ReadAllBytes(pending).SequenceEqual(next), "pending_receipt_changed_on_retry");
        Console.WriteLine("PASS: six publications, Windows sharing conflict, pending create-new fence");
        return 0;
    }

    private static void Check(bool condition, string failure)
    {
        if (!condition) throw new InvalidOperationException(failure);
    }

    private static void RejectPublication(Action publish)
    {
        try { publish(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Console.WriteLine($"publication_refused hresult=0x{error.HResult:X8}");
            return;
        }
        throw new InvalidOperationException("expected_publication_refusal");
    }
}

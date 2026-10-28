using System.Runtime.InteropServices;

namespace Shiroha.AndroidDevice;

/// <summary>Cancelable reads of this process's MCP input pipe only.</summary>
internal sealed class WindowsStdioInput : Stream
{
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint GetFileType(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PeekNamedPipe(IntPtr pipe, IntPtr buffer, uint size, IntPtr read, out uint available, IntPtr remaining);
    private readonly IntPtr handle;
    private readonly Stream input;
    internal WindowsStdioInput()
    {
        handle = GetStdHandle(-10);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1) || GetFileType(handle) != 3)
            throw new LinkFailure("stdio_pipe_required");
        input = Console.OpenStandardInput();
    }
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!PeekNamedPipe(handle, IntPtr.Zero, 0, IntPtr.Zero, out uint available, IntPtr.Zero))
            {
                if (Marshal.GetLastWin32Error() == 109) return 0;
                throw new LinkFailure("stdio_unavailable");
            }
            if (available != 0) return input.Read(buffer.Span[..Math.Min(buffer.Length, checked((int)Math.Min(available, int.MaxValue)))]);
            await Task.Delay(10, cancellationToken);
        }
    }
    protected override void Dispose(bool disposing) { if (disposing) input.Dispose(); base.Dispose(disposing); }
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override void Flush() => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}

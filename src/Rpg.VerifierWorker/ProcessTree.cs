using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Rpg.VerifierWorker;

/// <summary>
/// The processes under a root process. On Windows the godot "console" executable is a wrapper that starts the real engine as
/// a child, so measuring only the process the worker started would measure the wrapper. On Linux godot does not fork, so
/// the tree is the process alone. Windows uses a toolhelp snapshot (no extra package); anything it cannot read is skipped.
/// </summary>
internal static class ProcessTree
{
    /// <summary>The root's process id and every descendant's, from one snapshot. Never throws.</summary>
    public static IReadOnlyList<int> Ids(int rootId)
    {
        List<int> ids = [rootId];
        if (!OperatingSystem.IsWindows())
        {
            return ids;
        }

        try
        {
            var parents = Snapshot();
            for (var i = 0; i < ids.Count; i++)
            {
                ids.AddRange(parents.Where(p => p.Value == ids[i] && !ids.Contains(p.Key)).Select(p => p.Key));
            }
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or DllNotFoundException or EntryPointNotFoundException)
        {
            // Measure the root alone.
        }

        return ids;
    }

    /// <summary>CPU time and working set summed over the tree now. Processes that ended since the snapshot are skipped.</summary>
    public static (TimeSpan Cpu, long WorkingSet) Total(int rootId)
    {
        TimeSpan cpu = TimeSpan.Zero;
        long memory = 0;
        foreach (var id in Ids(rootId))
        {
            try
            {
                using var process = Process.GetProcessById(id);
                cpu += process.TotalProcessorTime;
                memory += process.WorkingSet64;
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
            {
                // Gone, or not ours to read.
            }
        }

        return (cpu, memory);
    }

    private static Dictionary<int, int> Snapshot()
    {
        var map = new Dictionary<int, int>();
        var handle = CreateToolhelp32Snapshot(0x2, 0);
        if (handle == nint.Zero || handle == -1)
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }

        try
        {
            var entry = new ProcessEntry32 { Size = (uint)Marshal.SizeOf<ProcessEntry32>() };
            for (var ok = Process32First(handle, ref entry); ok; ok = Process32Next(handle, ref entry))
            {
                map[(int)entry.ProcessId] = (int)entry.ParentProcessId;
            }
        }
        finally
        {
            CloseHandle(handle);
        }

        return map;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public nuint DefaultHeapId;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int PriorityClassBase;
        public uint Flags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string ExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32First(nint snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32Next(nint snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);
}

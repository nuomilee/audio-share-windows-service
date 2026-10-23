// AudioShareService.exe
// Minimal Windows service host for as-cmd.exe (audio-share-plus, v0.6.1).
//
// What it does:
//   * starts as-cmd.exe as a child process, hidden (no console window)
//   * captures its stdout/stderr and writes it to logs\as-cmd-yyyyMMdd.log (UTF-8)
//   * one file per local day, keeps the last N days (default 7) and deletes older ones
//   * restarts the child process if it exits unexpectedly (5s, 10s, 20s ... max 60s)
//
// The log file is opened per line and closed again, so it can be read, copied or deleted
// by any tool while the service keeps running (no dangling handles, no locked files).
//
// Build (no NuGet, no .NET SDK needed):
//   %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:exe /platform:anycpu ^
//       /out:AudioShareService.exe /r:System.ServiceProcess.dll src\AudioShareService.cs
//
// Console mode (for testing without installing the service):
//   AudioShareService.exe --console

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.ServiceProcess;
using System.Text;
using System.Threading;

namespace AudioShareService
{
    internal sealed class Settings
    {
        public string ExePath;
        public string Arguments;
        public string WorkingDirectory;
        public string LogDirectory;
        public int RetainDays = 7;

        public static Settings Load(string baseDir)
        {
            Settings s = new Settings();
            Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string ini = Path.Combine(baseDir, "settings.ini");
            if (File.Exists(ini))
            {
                foreach (string raw in File.ReadAllLines(ini, Encoding.UTF8))
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith("#") || line.StartsWith(";"))
                        continue;
                    int idx = line.IndexOf('=');
                    if (idx <= 0)
                        continue;
                    map[line.Substring(0, idx).Trim()] = line.Substring(idx + 1).Trim();
                }
            }

            string exe = Get(map, "exe", "as-cmd.exe");
            s.ExePath = Path.IsPathRooted(exe) ? exe : Path.Combine(baseDir, exe);

            s.Arguments = Get(map, "args", "--bind=0.0.0.0 --discovery");

            string wd = Get(map, "workdir", ".");
            s.WorkingDirectory = Path.IsPathRooted(wd) ? wd : Path.GetFullPath(Path.Combine(baseDir, wd));

            string ld = Get(map, "logdir", "logs");
            s.LogDirectory = Path.IsPathRooted(ld) ? ld : Path.Combine(baseDir, ld);

            int retain;
            if (int.TryParse(Get(map, "retaindays", "7"), out retain) && retain > 0)
                s.RetainDays = retain;

            return s;
        }

        private static string Get(Dictionary<string, string> map, string key, string fallback)
        {
            string v;
            return map.TryGetValue(key, out v) && v.Length > 0 ? v : fallback;
        }
    }

    internal sealed class DailyLogWriter : IDisposable
    {
        private readonly object gate = new object();
        private readonly string dir;
        private readonly int retainDays;
        private string currentDate;
        private bool disposed;

        public DailyLogWriter(string dir, int retainDays)
        {
            this.dir = dir;
            this.retainDays = retainDays;
            Directory.CreateDirectory(dir);
        }

        public void Info(string message)
        {
            WriteLine(Stamp() + " [service] " + message);
        }

        // Writes a line exactly as the child produced it (it already carries its own timestamp).
        public void AppLine(string line)
        {
            WriteLine(line);
        }

        public void AppErrorLine(string line)
        {
            WriteLine("[stderr] " + line);
        }

        private static string Stamp()
        {
            return "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) + "]";
        }

        private void WriteLine(string line)
        {
            if (disposed)
                return;

            lock (gate)
            {
                if (disposed)
                    return;
                try
                {
                    string today = DateTime.Now.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
                    string path = Path.Combine(dir, "as-cmd-" + today + ".log");

                    if (!string.Equals(currentDate, today, StringComparison.Ordinal))
                    {
                        currentDate = today;
                        Cleanup(today);
                    }

                    bool empty = !File.Exists(path) || new FileInfo(path).Length == 0;

                    // Open per line: never keep a handle on the file, so reading / deleting /
                    // copying the log while the service runs always works.
                    using (FileStream fs = new FileStream(path, FileMode.Append, FileAccess.Write,
                                                          FileShare.ReadWrite | FileShare.Delete))
                    using (StreamWriter sw = new StreamWriter(fs, new UTF8Encoding(false)))
                    {
                        if (empty)
                            sw.Write('\uFEFF'); // UTF-8 BOM, only on a fresh file
                        sw.WriteLine(line);
                    }
                }
                catch
                {
                    // A broken log file must never take the service down.
                }
            }
        }

        // Keeps today plus (retainDays - 1) previous days.
        private void Cleanup(string today)
        {
            try
            {
                DateTime cutoff = DateTime.ParseExact(today, "yyyyMMdd", CultureInfo.InvariantCulture).Date
                                          .AddDays(-(retainDays - 1));
                foreach (string file in Directory.GetFiles(dir, "as-cmd-*.log"))
                {
                    string name = Path.GetFileNameWithoutExtension(file);
                    if (name.Length != "as-cmd-".Length + 8)
                        continue;
                    string datePart = name.Substring("as-cmd-".Length);
                    DateTime d;
                    if (!DateTime.TryParseExact(datePart, "yyyyMMdd", CultureInfo.InvariantCulture,
                                                DateTimeStyles.None, out d))
                        continue;
                    if (d.Date < cutoff)
                    {
                        try { File.Delete(file); } catch { }
                    }
                }
            }
            catch
            {
            }
        }

        public void Dispose()
        {
            lock (gate)
            {
                disposed = true;
            }
        }
    }

    internal sealed class Runner
    {
        private readonly string baseDir;
        private readonly object gate = new object();
        private Settings settings;
        private DailyLogWriter log;
        private Process child;
        private Timer restartTimer;
        private volatile bool stopping;
        private int restartAttempt;

        public Runner(string baseDir)
        {
            this.baseDir = baseDir;
        }

        public void Start()
        {
            settings = Settings.Load(baseDir);
            Directory.CreateDirectory(settings.WorkingDirectory);
            log = new DailyLogWriter(settings.LogDirectory, settings.RetainDays);
            log.Info("starting; exe=" + settings.ExePath + " args=" + settings.Arguments);
            log.Info("base=" + baseDir + " logs=" + settings.LogDirectory + " retain=" + settings.RetainDays + "d");
            Spawn();
        }

        public void Stop()
        {
            stopping = true;
            Timer t = Interlocked.Exchange(ref restartTimer, null);
            if (t != null)
                t.Dispose();

            Process p;
            lock (gate)
            {
                p = child;
                child = null;
            }

            if (p != null)
            {
                try
                {
                    if (!p.HasExited)
                    {
                        if (log != null) log.Info("stopping as-cmd, pid=" + p.Id);
                        p.Kill();
                        if (!p.WaitForExit(5000) && log != null)
                            log.Info("as-cmd did not exit within 5s");
                    }
                }
                catch (Exception ex)
                {
                    if (log != null) log.Info("error stopping as-cmd: " + ex.Message);
                }
                try { p.CancelOutputRead(); } catch { }
                try { p.CancelErrorRead(); } catch { }
                try { p.Dispose(); } catch { }
            }

            if (log != null)
            {
                log.Info("stopped");
                log.Dispose();
                log = null;
            }
        }

        private void Spawn()
        {
            lock (gate)
            {
                if (stopping || child != null)
                    return;

                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo(settings.ExePath, settings.Arguments);
                    psi.WorkingDirectory = settings.WorkingDirectory;
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    psi.RedirectStandardOutput = true;
                    psi.RedirectStandardError = true;
                    // as-cmd writes its console output in the system ANSI code page (GBK on zh-CN).
                    psi.StandardOutputEncoding = Encoding.Default;
                    psi.StandardErrorEncoding = Encoding.Default;

                    Process p = new Process();
                    p.StartInfo = psi;
                    p.EnableRaisingEvents = true;
                    p.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                    {
                        if (e.Data != null && log != null) log.AppLine(e.Data);
                    };
                    p.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                    {
                        if (e.Data != null && log != null) log.AppErrorLine(e.Data);
                    };
                    p.Exited += OnChildExited;

                    p.Start();
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();

                    child = p;
                    restartAttempt = 0;
                    log.Info("as-cmd started, pid=" + p.Id);
                }
                catch (Exception ex)
                {
                    if (log != null) log.Info("failed to start as-cmd: " + ex.Message);
                    child = null;
                    ScheduleRestart();
                }
            }
        }

        private void OnChildExited(object sender, EventArgs e)
        {
            int code = -1;
            try { code = ((Process)sender).ExitCode; } catch { }

            lock (gate)
            {
                if (ReferenceEquals(sender, child))
                    child = null;
            }

            if (stopping)
                return;

            if (log != null)
                log.Info("as-cmd exited unexpectedly, exit code " + code);
            ScheduleRestart();
        }

        private void ScheduleRestart()
        {
            if (stopping)
                return;

            int attempt = Interlocked.Increment(ref restartAttempt);
            int delay = Math.Min(60, 5 * (1 << Math.Min(attempt - 1, 4)));

            if (log != null)
                log.Info("restarting as-cmd in " + delay + "s");

            Timer t = new Timer(delegate { Spawn(); }, null, delay * 1000, Timeout.Infinite);
            Timer old = Interlocked.Exchange(ref restartTimer, t);
            if (old != null)
                old.Dispose();
        }
    }

    internal sealed class AudioShareWindowsService : ServiceBase
    {
        private readonly Runner runner;

        public AudioShareWindowsService(string baseDir)
        {
            runner = new Runner(baseDir);
            ServiceName = "AudioShareServer";
            CanStop = true;
            CanShutdown = true;
            CanPauseAndContinue = false;
            AutoLog = false;
        }

        protected override void OnStart(string[] args)
        {
            runner.Start();
        }

        protected override void OnStop()
        {
            runner.Stop();
        }

        protected override void OnShutdown()
        {
            runner.Stop();
            base.OnShutdown();
        }
    }

    internal static class Program
    {
        private static void Main(string[] args)
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            if (baseDir.EndsWith("\\", StringComparison.Ordinal))
                baseDir = baseDir.Substring(0, baseDir.Length - 1);

            bool console = false;
            foreach (string a in args)
            {
                if (string.Equals(a, "--console", StringComparison.OrdinalIgnoreCase))
                    console = true;
            }

            if (console)
            {
                Runner runner = new Runner(baseDir);
                Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e)
                {
                    e.Cancel = true;
                    runner.Stop();
                    Environment.Exit(0);
                };
                runner.Start();
                Console.WriteLine("as-cmd host running in console mode. Press Enter to stop.");
                Console.ReadLine();
                runner.Stop();
                return;
            }

            ServiceBase.Run(new AudioShareWindowsService(baseDir));
        }
    }
}

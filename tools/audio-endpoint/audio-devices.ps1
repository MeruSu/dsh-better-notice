# audio-devices.ps1 — list the active audio endpoints of this machine.
#
# Prints exactly one line of JSON to stdout and always exits 0. A business
# failure (enumeration failed, COM refused) is reported as ok:false with an
# `error` reason — the caller treats a non-zero exit as "the script could not
# start at all", which never happens here.
#
#   {"ok":true,"asOf":<ms>,"elapsedMs":<ms>,"error":null,
#    "devices":[{"id","name","direction","formFactor","kindGuess","guess","state"}]}
#
# Landmines this file is shaped around (both were hit in this repo):
#   1. `ref PropertyKey` crossing a managed method boundary reads back a zeroed
#      fmtid — keep the property loop inside the method that owns the store.
#   2. Flattening the store reader into the enumeration method silently makes
#      every GetValue return VT_EMPTY with no HRESULT. Hence helper + caller.
# Also: Get-PnpDevice / WMI / SetupAPI are blocked on locked-down hosts, so only
# Core Audio COM (via IMMDeviceEnumerator) is used. No third-party modules.

$ErrorActionPreference = 'Stop'
$startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DeviceList
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(2)] public ushort wReserved1;
        [FieldOffset(4)] public ushort wReserved2;
        [FieldOffset(6)] public ushort wReserved3;
        [FieldOffset(8)] public IntPtr pwszVal;
        [FieldOffset(8)] public int intVal;
        [FieldOffset(8)] public long longVal;
    }

    [DllImport("ole32.dll")]
    static extern int PropVariantClear(ref PropVariant pv);

    [DllImport("ole32.dll")]
    static extern int CoInitializeEx(IntPtr reserved, int coInit);

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IntPtr device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.Interface)] out object iface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint cProps);
        [PreserveSig] int GetAt(uint iProp, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant pv);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant pv);
        [PreserveSig] int Commit();
    }

    static readonly Guid FMTID_DEVICE = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
    static readonly Guid FMTID_ENDPOINT = new Guid("1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E");
    const uint PID_FRIENDLY_NAME = 14;
    const uint PID_FORM_FACTOR = 0;
    const int STGM_READ = 0;
    const int DEVICE_STATE_ACTIVE = 1;

    static string KindOf(int formFactor, bool hasFormFactor, string name)
    {
        if (hasFormFactor)
        {
            if (formFactor == 3 || formFactor == 5) return "headphones";
            if (formFactor == 1 || formFactor == 2) return "speakers";
            return "unknown";
        }
        if (string.IsNullOrEmpty(name)) return "unknown";
        string lowered = name.ToLowerInvariant();
        string[] needles = new string[] { "耳机", "耳麦", "headphone", "headset", "earbud", "airpod", "bluetooth", "蓝牙" };
        foreach (string needle in needles)
        {
            if (lowered.Contains(needle)) return "headphones";
        }
        return "unknown";
    }

    static void ReadStore(IMMDevice device, out string name, out int formFactor, out bool hasFormFactor)
    {
        name = null;
        formFactor = 0;
        hasFormFactor = false;
        IntPtr storePtr;
        int hrOpen = device.OpenPropertyStore(STGM_READ, out storePtr);
        if (hrOpen != 0) return;
        var store = (IPropertyStore)Marshal.GetObjectForIUnknown(storePtr);
        Marshal.Release(storePtr);
        uint count = 0;
        int hrCount = store.GetCount(out count);
        if (hrCount != 0) return;
        for (uint i = 0; i < count; i++)
        {
            PropertyKey key;
            int hk = store.GetAt(i, out key);
            if (hk != 0) continue;
            PropVariant pv;
            int hrValue = store.GetValue(ref key, out pv);
            if (hrValue != 0) continue;
            try
            {
                if (key.fmtid == FMTID_DEVICE && key.pid == PID_FRIENDLY_NAME && pv.vt == 31 && pv.pwszVal != IntPtr.Zero)
                {
                    name = Marshal.PtrToStringUni(pv.pwszVal);
                }
                else if (key.fmtid == FMTID_ENDPOINT && key.pid == PID_FORM_FACTOR && (pv.vt == 19 || pv.vt == 3))
                {
                    formFactor = pv.vt == 19 ? (int)(pv.longVal & 0xFFFFFFFFL) : pv.intVal;
                    hasFormFactor = true;
                }
            }
            finally
            {
                PropVariantClear(ref pv);
            }
        }
    }

    public static List<Dictionary<string, object>> Enumerate()
    {
        var rows = new List<Dictionary<string, object>>();
        var errors = new List<string>();
        CoInitializeEx(IntPtr.Zero, 2);
        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        for (int flow = 0; flow <= 1; flow++)
        {
            IMMDeviceCollection collection;
            int hrEnum = enumerator.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, out collection);
            if (hrEnum != 0 || collection == null)
            {
                errors.Add((flow == 0 ? "render" : "capture") + "=0x" + hrEnum.ToString("X8"));
                continue;
            }
            uint count;
            if (collection.GetCount(out count) != 0) continue;
            for (uint index = 0; index < count; index++)
            {
                IMMDevice device;
                if (collection.Item(index, out device) != 0 || device == null) continue;
                string name;
                int formFactor;
                bool hasFormFactor;
                ReadStore(device, out name, out formFactor, out hasFormFactor);
                string id = null;
                device.GetId(out id);
                string kind = KindOf(formFactor, hasFormFactor, name);
                var row = new Dictionary<string, object>();
                row["id"] = id ?? "";
                row["name"] = name ?? "";
                row["direction"] = flow == 0 ? "render" : "capture";
                row["formFactor"] = hasFormFactor ? (object)formFactor : null;
                row["kindGuess"] = kind;
                row["guess"] = hasFormFactor == false && kind == "headphones";
                row["state"] = hasFormFactor ? "measured" : "unknown";
                rows.Add(row);
            }
        }
        if (errors.Count > 0)
        {
            var row = new Dictionary<string, object>();
            row["id"] = "";
            row["name"] = "";
            row["direction"] = "render";
            row["formFactor"] = null;
            row["kindGuess"] = "unknown";
            row["guess"] = false;
            row["state"] = "unknown";
            row["error"] = "enum-failed:" + string.Join(",", errors.ToArray());
            rows.Add(row);
        }
        return rows;
    }

    public static string EnumerateWithDefault()
    {
        var rows = Enumerate();
        string name = "";
        int formFactor = 0;
        bool hasFormFactor = false;
        try
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IntPtr ptr;
            if (enumerator.GetDefaultAudioEndpoint(0, 0, out ptr) == 0 && ptr != IntPtr.Zero)
            {
                var device = (IMMDevice)Marshal.GetObjectForIUnknown(ptr);
                Marshal.Release(ptr);
                ReadStore(device, out name, out formFactor, out hasFormFactor);
                string defaultId = null;
                device.GetId(out defaultId);
                rows.Add(new Dictionary<string, object> { { "id", defaultId ?? "" }, { "name", name ?? "" },
                    { "direction", "default" }, { "formFactor", hasFormFactor ? (object)formFactor : null },
                    { "kindGuess", KindOf(formFactor, hasFormFactor, name) },
                    { "guess", false }, { "state", hasFormFactor ? "measured" : "unknown" } });
            }
        }
        catch { }
        return RowsToJson(rows);
    }

    static string RowsToJson(List<Dictionary<string, object>> rows)
    {
        var sb = new StringBuilder();
        sb.Append("[");
        for (int i = 0; i < rows.Count; i++)
        {
            if (i > 0) sb.Append(",");
            var row = rows[i];
            if (row.ContainsKey("error"))
            {
                continue;
            }
            sb.Append("{\"id\":\"").Append(Esc((string)row["id"])).Append("\"");
            sb.Append(",\"name\":\"").Append(Esc((string)row["name"])).Append("\"");
            sb.Append(",\"direction\":\"").Append(row["direction"]).Append("\"");
            sb.Append(",\"formFactor\":").Append(row["formFactor"] == null ? "null" : row["formFactor"].ToString());
            sb.Append(",\"kindGuess\":\"").Append(row["kindGuess"]).Append("\"");
            sb.Append(",\"guess\":").Append((bool)row["guess"] ? "true" : "false");
            sb.Append(",\"state\":\"").Append(row["state"]).Append("\"}");
        }
        sb.Append("]");
        return sb.ToString();
    }

    static string Esc(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        var sb = new StringBuilder(s.Length + 8);
        foreach (char c in s)
        {
            if (c == '\\' || c == '"') sb.Append('\\').Append(c);
            else if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
            else sb.Append(c);
        }
        return sb.ToString();
    }
}
'@

Add-Type -TypeDefinition $src -Language CSharp

$devicesJson = '[]'
$errorText = $null
try {
  $devicesJson = [DeviceList]::EnumerateWithDefault()
} catch {
  $errorText = 'enum-failed: ' + $_.Exception.GetType().Name + ': ' + ($_.Exception.Message -replace '\s+', ' ')
}

$elapsedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $startedAt
$asOf = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

$envelope = '{"ok":' + $(if ($null -eq $errorText) { 'true' } else { 'false' }) +
  ',"asOf":' + $asOf +
  ',"elapsedMs":' + $elapsedMs +
  ',"error":' + $(if ($null -eq $errorText) { 'null' } else { '"' + ($errorText -replace '\\', '\\\\' -replace '"', '\"') + '"' }) +
  ',"devices":' + $devicesJson + '}'

[Console]::Out.WriteLine($envelope)
exit 0

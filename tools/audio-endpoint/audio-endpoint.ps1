# audio-endpoint.ps1 - default audio *output* endpoint probe (task-46, Windows only).
#
# Answers "which device is the sound coming out of right now" as ONE JSON object on ONE stdout line.
# Business failures are JSON too, with exit code 0; a non-zero exit code means only that the script
# itself could not run.
#
# Contract (set by lead):
#   { "name": "...", "direction": "render", "kindGuess": "headphones|speakers|unknown",
#     "guess": true|false, "state": "measured|degraded|unknown",
#     "asOf": <unix ms>, "elapsedMs": <int>, "error": null|"<reason>" }
#
# Shape of the solution (why it is split this way):
#   * The C# below is copied verbatim from the read-only probe cangku/tmp/261113_a1e_endpoint-props.ps1,
#     which on this machine repeatedly read 60 properties of the default render endpoint, including
#     PKEY_AudioEndpoint_FormFactor = VT_UI4 value 3 (Headphones) and
#     PKEY_Device_FriendlyName = "耳机 (Baseus Bass BC2 Stereo)".
#   * Everything that turns those raw properties into the contract (mapping, honesty flags, error
#     strings) is plain PowerShell, so it can be reviewed without COM and without Windows.
#
# Two interop landmines measured on this machine (see README):
#   * Passing `ref PropertyKey` across a method boundary made IPropertyStore.GetValue read through a
#     bad pointer and killed the process with 0xC0000005 (not catchable).
#   * Reading a single key of interest first came back VT_EMPTY; walking the store front to back with
#     GetValue on every key is what returns real values. Hence: dump everything, then pick.
#
# No parameters. No third-party dependencies. Windows only (macOS/Linux: planned, see README).

$ErrorActionPreference = 'Stop'
$scriptStarted = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

function Emit-Result {
    param([AllowNull()][string]$Name, [string]$Kind, [bool]$Guess, [string]$State, [AllowNull()][string]$ErrReason)

    $asOf = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $payload = [ordered]@{
        name       = $Name
        direction  = 'render'
        kindGuess  = $Kind
        guess      = $Guess
        state      = $State
        asOf       = $asOf
        elapsedMs  = [int]($asOf - $scriptStarted)
        error      = $(if ($null -eq $ErrReason -or $ErrReason -eq '') { $null } else { $ErrReason })
    }
    Write-Output ($payload | ConvertTo-Json -Compress)
    exit 0
}

$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class EpProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(2)] public ushort wReserved1;
        [FieldOffset(4)] public ushort wReserved2;
        [FieldOffset(6)] public ushort wReserved3;
        [FieldOffset(8)] public IntPtr pwszVal;   // VT_LPWSTR
        [FieldOffset(8)] public IntPtr pUnknown;  // VT_UNKNOWN
        [FieldOffset(8)] public int intVal;       // VT_I4 / VT_BOOL(4 bytes)
        [FieldOffset(8)] public long longVal;
    }

    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant pvar);
    [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr pv, int dwCoInit);

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.Interface)] out object iface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }

    // IPropertyStore vtable order (must be exact): GetCount, GetAt, GetValue, SetValue, Commit.
    // Wrong order yields 0x80004003 (E_POINTER) — checked on every call below.
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint cProps);
        [PreserveSig] int GetAt(uint iProp, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant pv);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant pv);
        [PreserveSig] int Commit();
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

    // Returns one JSON object: { hr, id, count, props:[{fmtid,pid,vt,value}] }
    public static string Dump()
    {
        CoInitializeEx(IntPtr.Zero, 2 /* COINIT_MULTITHREADED */);
        try
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDevice device;
            int hr = enumerator.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out device);
            if (hr != 0 || device == null)
            {
                return "{\"hrEnumerator\":" + hr + ",\"id\":null,\"count\":-1,\"props\":[]}";
            }
            string id = null;
            device.GetId(out id);

            IntPtr storePtr;
            int hrStore = device.OpenPropertyStore(0 /* STGM_READ */, out storePtr);
            var store = (IPropertyStore)Marshal.GetObjectForIUnknown(storePtr);
            Marshal.Release(storePtr);

            uint count = 0;
            int hrCount = store.GetCount(out count);

            var parts = new List<string>();
            for (uint i = 0; i < count; i++)
            {
                PropertyKey key;
                int hrKey = store.GetAt(i, out key);
                if (hrKey != 0) { parts.Add("{\"hrGetAt\":" + hrKey + "}"); continue; }

                PropVariant pv;
                int hrVal = store.GetValue(ref key, out pv);
                string val = null;
                ushort vt = 0;
                if (hrVal == 0)
                {
                    vt = pv.vt;
                    try
                    {
                        if (vt == 31 /* VT_LPWSTR */ && pv.pwszVal != IntPtr.Zero)
                            val = Marshal.PtrToStringUni(pv.pwszVal);
                        else if (vt == 30 /* VT_LPSTR */ && pv.pwszVal != IntPtr.Zero)
                            val = Marshal.PtrToStringAnsi(pv.pwszVal);
                        else if (vt == 3 /* VT_I4 */ || vt == 11 /* VT_BOOL */)
                            val = pv.intVal.ToString();
                        else if (vt == 19 /* VT_UI4 */ || vt == 20 /* VT_I8 */ || vt == 21 /* VT_UI8 */)
                            val = pv.longVal.ToString();
                        else if (vt == 0 /* VT_EMPTY */)
                            val = null;
                        else
                            val = "<vt " + vt + ">";
                    }
                    finally { PropVariantClear(ref pv); }
                }
                parts.Add("{\"fmtid\":\"" + key.fmtid.ToString().ToUpperInvariant()
                    + "\",\"pid\":" + key.pid
                    + ",\"hr\":" + hrVal
                    + ",\"vt\":" + vt
                    + ",\"value\":" + (val == null ? "null" : "\"" + Esc(val) + "\"") + "}");
            }

            return "{\"hrEnumerator\":0,\"hrStore\":" + hrStore + ",\"hrGetCount\":" + hrCount
                + ",\"id\":\"" + Esc(id) + "\",\"count\":" + count
                + ",\"props\":[" + string.Join(",", parts.ToArray()) + "]}";
        }
        catch (Exception ex)
        {
            return "{\"exception\":\"" + Esc(ex.GetType().Name + ": " + ex.Message) + "\",\"props\":[]}";
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
}
catch {
    $msg = ($_.Exception.Message -replace '[\r\n\t]+', ' ' -replace '[\\"]', '')
    Emit-Result -Name $null -Kind 'unknown' -Guess $true -State 'unknown' -ErrReason ('compile-failed:' + $msg)
}

$raw = [EpProbe]::Dump()

$dump = $null
try { $dump = $raw | ConvertFrom-Json } catch { $dump = $null }

if ($null -eq $dump) {
    Emit-Result -Name $null -Kind 'unknown' -Guess $true -State 'unknown' -ErrReason 'probe-failed:unparsable-json'
}
if ($null -ne $dump.exception) {
    Emit-Result -Name $null -Kind 'unknown' -Guess $true -State 'unknown' -ErrReason ('probe-failed:' + $dump.exception)
}

$hrEnumerator = [int]$dump.hrEnumerator
if ($hrEnumerator -ne 0) {
    $reason = if ($hrEnumerator -eq -2147024891) { 'access-denied' } else { 'no-endpoint' }
    Emit-Result -Name $null -Kind 'unknown' -Guess $true -State 'unknown' -ErrReason ($reason + ':hr=0x' + ('{0:X8}' -f $hrEnumerator))
}

$FMT_DEVICE     = 'A45C254E-DF1C-4EFD-8020-67D146A850E0'   # PKEY_Device_*
$FMT_ENDPOINT   = '1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E'   # PKEY_AudioEndpoint_*
$FF_KEY         = $FMT_ENDPOINT + ':0'
$NAME_KEY       = $FMT_DEVICE   + ':14'
$DESC_KEY       = $FMT_DEVICE   + ':2'

$ff = $null
$friendly = $null
$description = $null
foreach ($p in $dump.props) {
    $key = $p.fmtid + ':' + $p.pid
    if ($key -eq $FF_KEY)      { $ff = $p }
    elseif ($key -eq $NAME_KEY)   { $friendly = $p.value }
    elseif ($key -eq $DESC_KEY)   { $description = $p.value }
}

$name = if (-not [string]::IsNullOrEmpty($friendly)) { $friendly } elseif (-not [string]::IsNullOrEmpty($description)) { $description } else { $null }

# FormFactor is authoritative only when the store actually handed us a number.
$formFactor = $null
if ($null -ne $ff -and $ff.hr -eq 0) {
    if ($ff.vt -eq 19 -or $ff.vt -eq 3 -or $ff.vt -eq 11) {
        if ($null -ne $ff.value -and "$($ff.value)" -ne '') {
            $n = 0
            if ([int]::TryParse("$($ff.value)", [ref]$n)) { $formFactor = $n }
        }
    }
}

$kind = 'unknown'
$guess = $true
$state = 'unknown'
$errText = $null

if ($null -ne $formFactor) {
    switch ($formFactor) {
        1 { $kind = 'speakers' }      # Speakers
        2 { $kind = 'speakers' }      # LineLevel
        3 { $kind = 'headphones' }    # Headphones
        5 { $kind = 'headphones' }    # Headset
        default { $kind = 'unknown' } # RemoteNetworkDevice, SPDIF, HDMI, UnknownFormFactor, ...
    }
    $guess = $false                  # the type came from the system, not from us
    $state = 'measured'
}
elseif (-not [string]::IsNullOrEmpty($name)) {
    $lower = $name.ToLowerInvariant()
    $headphoneWords = @('耳机', '头戴', '耳塞', '入耳', 'headphone', 'headset', 'earbud', 'earphone', 'in-ear')
    $speakerWords   = @('音箱', '扬声器', '喇叭', 'soundbar', 'speaker')
    $kind = 'unknown'
    foreach ($w in $headphoneWords) { if ($lower.Contains($w)) { $kind = 'headphones'; break } }
    if ($kind -eq 'unknown') { foreach ($w in $speakerWords) { if ($lower.Contains($w)) { $kind = 'speakers'; break } } }
    $guess = $true                   # heuristic - must be flagged as such
    $state = 'degraded'
}

if ([string]::IsNullOrEmpty($name)) {
    # The endpoint answered but we cannot name it. Say exactly that instead of inventing a name.
    $state = 'unknown'
    $errText = 'no-name'
}

Emit-Result -Name $name -Kind $kind -Guess $guess -State $state -ErrReason $errText
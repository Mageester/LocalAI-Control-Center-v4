#requires -Version 5.1
Set-StrictMode -Version 2.0

function Initialize-LocalAIGgufReader {
    if ('LocalAI.GgufReaderV4' -as [type]) { return }
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

namespace LocalAI {
    public static class GgufReaderV4 {
        const ulong MaxMetadata = 100000;
        const ulong MaxKeyBytes = 1048576;
        const ulong MaxStringBytes = 67108864;
        const ulong MaxArrayItems = 1000000000;
        const int MaxArrayDepth = 4;

        public static Dictionary<string, object> Read(string path) {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new BinaryReader(stream, Encoding.UTF8)) {
                if (stream.Length < 24) throw new InvalidDataException("GGUF header is truncated.");
                if (reader.ReadUInt32() != 0x46554747) throw new InvalidDataException("File is not GGUF.");
                uint version = reader.ReadUInt32();
                if (version != 2 && version != 3) throw new InvalidDataException("Unsupported GGUF version " + version + ".");
                ulong tensorCount = reader.ReadUInt64();
                ulong metadataCount = reader.ReadUInt64();
                if (metadataCount > MaxMetadata) throw new InvalidDataException("GGUF metadata count exceeds safety limit.");
                var result = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                for (ulong i = 0; i < metadataCount; i++) {
                    string key = ReadString(reader, MaxKeyBytes, "key");
                    uint type = reader.ReadUInt32();
                    result[key] = ReadValue(reader, type, 0, true);
                }
                return result;
            }
        }

        static object ReadValue(BinaryReader r, uint type, int depth, bool retain) {
            Require(r, ScalarSize(type));
            switch (type) {
                case 0: return r.ReadByte();
                case 1: return r.ReadSByte();
                case 2: return r.ReadUInt16();
                case 3: return r.ReadInt16();
                case 4: return r.ReadUInt32();
                case 5: return r.ReadInt32();
                case 6: return r.ReadSingle();
                case 7: return r.ReadByte() != 0;
                case 8: return ReadString(r, MaxStringBytes, "string");
                case 9:
                    if (depth >= MaxArrayDepth) throw new InvalidDataException("GGUF array nesting exceeds safety limit.");
                    uint elementType = r.ReadUInt32();
                    ulong count = r.ReadUInt64();
                    if (count > MaxArrayItems) throw new InvalidDataException("GGUF array length exceeds safety limit.");
                    for (ulong i = 0; i < count; i++) ReadValue(r, elementType, depth + 1, false);
                    return "[array:" + count + "]";
                case 10: return r.ReadUInt64();
                case 11: return r.ReadInt64();
                case 12: return r.ReadDouble();
                default: throw new InvalidDataException("Unsupported GGUF metadata type " + type + ".");
            }
        }

        static int ScalarSize(uint type) {
            switch (type) {
                case 0: case 1: case 7: return 1;
                case 2: case 3: return 2;
                case 4: case 5: case 6: return 4;
                case 8: case 9: case 10: case 11: case 12: return 8;
                default: return 0;
            }
        }

        static string ReadString(BinaryReader r, ulong maximum, string label) {
            Require(r, 8);
            ulong length = r.ReadUInt64();
            if (length > maximum) throw new InvalidDataException("GGUF " + label + " length exceeds safety limit.");
            if (length > Int32.MaxValue) throw new InvalidDataException("GGUF " + label + " cannot be represented safely.");
            Require(r, checked((long)length));
            byte[] bytes = r.ReadBytes((int)length);
            if (bytes.Length != (int)length) throw new EndOfStreamException("GGUF " + label + " is truncated.");
            return Encoding.UTF8.GetString(bytes);
        }

        static void Require(BinaryReader r, long bytes) {
            if (bytes < 0 || r.BaseStream.Position > r.BaseStream.Length - bytes)
                throw new EndOfStreamException("GGUF metadata is truncated or declares data beyond the file.");
        }
    }
}
'@
}

function Read-LocalAIGgufMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "GGUF file does not exist: $Path" }
    Initialize-LocalAIGgufReader
    return [LocalAI.GgufReaderV4]::Read((Get-Item -LiteralPath $Path).FullName)
}

function Get-LocalAIGgufValue {
    param([Collections.Generic.Dictionary[string,object]]$Metadata,[string[]]$Keys,$Default=$null)
    foreach($key in $Keys) { if ($Metadata.ContainsKey($key)) { return $Metadata[$key] } }
    return $Default
}

function Get-LocalAIQuantizationFromName {
    param([string]$Name)
    $match=[regex]::Match($Name,'(?i)(?:^|[-_. ])((?:UD-)?(?:IQ|Q|BF|F)\d(?:_[A-Z0-9]+)*)')
    if ($match.Success) { return $match.Groups[1].Value.ToUpperInvariant() }
    return 'Unknown'
}

function Get-LocalAIGgufSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $raw=Read-LocalAIGgufMetadata -Path $Path
    $arch=[string](Get-LocalAIGgufValue $raw @('general.architecture') '')
    if (-not $arch) { throw 'GGUF architecture metadata is missing.' }
    $native=[long](Get-LocalAIGgufValue $raw @("$arch.context_length") 0)
    $template=[string](Get-LocalAIGgufValue $raw @('tokenizer.chat_template') '')
    $name=[string](Get-LocalAIGgufValue $raw @('general.name') ([IO.Path]::GetFileNameWithoutExtension($Path)))
    $fileType=Get-LocalAIGgufValue $raw @('general.file_type') $null
    $quant=Get-LocalAIQuantizationFromName ((Split-Path -Leaf $Path) + ' ' + $name)
    $mtp=[int](Get-LocalAIGgufValue $raw @("$arch.nextn_predict_layers","$arch.nextn_predictor.n_predict") 0)
    $experts=[int](Get-LocalAIGgufValue $raw @("$arch.expert_count","$arch.feed_forward.expert_count") 0)
    $activeExperts=[int](Get-LocalAIGgufValue $raw @("$arch.expert_used_count","$arch.expert_used_count") 0)
    [pscustomobject]@{
        Path=(Get-Item -LiteralPath $Path).FullName
        Architecture=$arch
        Name=$name
        NativeContext=$native
        Quantization=$quant
        FileType=$fileType
        ChatTemplate=$template
        HasChatTemplate=[bool]$template
        SupportsPreserveReasoning=($template -match 'preserve_thinking|supports_preserve_reasoning')
        MtpHeads=$mtp
        ExpertCount=$experts
        ActiveExpertCount=$activeExperts
        Raw=$raw
    }
}

Export-ModuleMember -Function *

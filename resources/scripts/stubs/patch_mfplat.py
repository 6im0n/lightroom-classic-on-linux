#!/usr/bin/env python3
"""
Add MFCreateSampleCopierMFT as a forwarder export to a deployed mfplat.dll.
Forwarder target: mf.MFCreateSampleCopierMFT

Strategy: append a new PE section that contains a brand-new export directory
(replacing the old one in DataDirectory[0]). The new export directory contains
all original exports plus the new MFCreateSampleCopierMFT forwarder.

A "forwarder" export is signaled by having the function's address (the value
in AddressOfFunctions[i]) fall WITHIN the export directory range -- i.e. the
RVA points to a NUL-terminated string of the form "OtherDll.OtherFunc".

made by : sander110419
"""
import sys
import struct
import pefile

INPUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mfplat-input.dll"
OUTPUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/mfplat-output.dll"
NEW_EXPORT_NAME = "MFCreateSampleCopierMFT"
NEW_FORWARDER_TARGET = "mf.MFCreateSampleCopierMFT"

pe = pefile.PE(INPUT, fast_load=False)

# Collect all original exports (name + ordinal + address or forwarder string).
# pefile gives us the symbols list with .name (bytes), .ordinal (int),
# .address (RVA, int), .forwarder (bytes or None).
orig_exports = []
for sym in pe.DIRECTORY_ENTRY_EXPORT.symbols:
    name = sym.name.decode() if sym.name else None
    ordinal = sym.ordinal
    forwarder = sym.forwarder.decode() if sym.forwarder else None
    address = sym.address if not forwarder else None
    orig_exports.append({
        "name": name,
        "ordinal": ordinal,
        "forwarder": forwarder,
        "address": address,
    })

# Module base name string (kept as-is)
orig_dll_name = pe.DIRECTORY_ENTRY_EXPORT.name.decode() if pe.DIRECTORY_ENTRY_EXPORT.name else "mfplat.dll"

print(f"Original DLL name: {orig_dll_name}")
print(f"Original exports: {len(orig_exports)}")
print(f"  Forwarders:    {sum(1 for e in orig_exports if e['forwarder'])}")
print(f"  Real:          {sum(1 for e in orig_exports if not e['forwarder'])}")
print(f"  Named:         {sum(1 for e in orig_exports if e['name'])}")
print(f"  Ord-only:      {sum(1 for e in orig_exports if not e['name'])}")

orig_max_ord = max(e["ordinal"] for e in orig_exports)
orig_base = pe.DIRECTORY_ENTRY_EXPORT.struct.Base
print(f"Ordinal base: {orig_base}, max ordinal: {orig_max_ord}")

# Choose the new export's ordinal: one more than current max.
new_ordinal = orig_max_ord + 1
new_export = {
    "name": NEW_EXPORT_NAME,
    "ordinal": new_ordinal,
    "forwarder": NEW_FORWARDER_TARGET,
    "address": None,
}

all_exports = orig_exports + [new_export]
named_exports = [e for e in all_exports if e["name"]]
# Names must be sorted in ascending ASCII order for binary search lookups.
named_exports_sorted = sorted(named_exports, key=lambda e: e["name"])

# Function table: indexed by (ordinal - base), size = (max_ord - base + 1).
# Entries are RVAs (or 0 if no export at that ordinal).
new_max_ord = max(e["ordinal"] for e in all_exports)
func_table_size = new_max_ord - orig_base + 1
print(f"New ordinal range: {orig_base}..{new_max_ord} ({func_table_size} entries)")

# ---- Build the new section layout. ----
# We need to know section RVA before we can compute strings' RVAs.
# Choose: place new section after the last existing section, aligned to
# SectionAlignment.

sec_align = pe.OPTIONAL_HEADER.SectionAlignment
file_align = pe.OPTIONAL_HEADER.FileAlignment
print(f"SectionAlignment={hex(sec_align)}, FileAlignment={hex(file_align)}")

# Find next available VirtualAddress after last section, and next file offset.
def align_up(n, a):
    return (n + a - 1) & ~(a - 1)

last_sec = max(pe.sections, key=lambda s: s.VirtualAddress)
new_sec_rva = align_up(last_sec.VirtualAddress + last_sec.Misc_VirtualSize, sec_align)
# Place the new section at the end of the file so we don't collide with
# existing (possibly debug) sections that already occupy intermediate offsets.
new_sec_file_off = align_up(len(pe.__data__), file_align)

print(f"New section will sit at RVA 0x{new_sec_rva:x}, file offset 0x{new_sec_file_off:x}")

# ---- Compute layout within the new section. ----
# Offsets within the new section blob:
EXPORT_DIR_SIZE = 40  # IMAGE_EXPORT_DIRECTORY
off_export_dir = 0
off_func_table = EXPORT_DIR_SIZE
off_name_table = off_func_table + func_table_size * 4
off_ord_table  = off_name_table + len(named_exports_sorted) * 4
off_dll_name   = off_ord_table  + len(named_exports_sorted) * 2

# String table starts at off_dll_name. We layout:
#   - DLL name
#   - All export names (named_exports_sorted order)
#   - All forwarder strings (for forwarder exports)
# Each null-terminated.
strings_buf = bytearray()
def add_str(s):
    """Add NUL-terminated string to strings_buf, return offset within strings."""
    off = len(strings_buf)
    strings_buf.extend(s.encode("ascii") + b"\x00")
    return off

dll_name_str_off = add_str(orig_dll_name)
name_str_offs = {}
for e in named_exports_sorted:
    name_str_offs[e["name"]] = add_str(e["name"])

forwarder_str_offs = {}
for e in all_exports:
    if e["forwarder"] and e["forwarder"] not in forwarder_str_offs:
        forwarder_str_offs[e["forwarder"]] = add_str(e["forwarder"])

# String table absolute RVAs
def str_rva(off):
    return new_sec_rva + off_dll_name + off

# Build function table: array of DWORD RVAs, indexed by (ordinal - base)
func_table = [0] * func_table_size
for e in all_exports:
    idx = e["ordinal"] - orig_base
    if e["forwarder"]:
        # Forwarder: address = RVA of the forwarder string (which must lie
        # within the export directory range to be interpreted as forwarder)
        func_table[idx] = str_rva(forwarder_str_offs[e["forwarder"]])
    else:
        func_table[idx] = e["address"]

# Build name pointer table and ordinal table (parallel arrays).
name_ptr_table = []
ord_table = []
for e in named_exports_sorted:
    name_ptr_table.append(str_rva(name_str_offs[e["name"]]))
    ord_table.append(e["ordinal"] - orig_base)  # WORD

# Build IMAGE_EXPORT_DIRECTORY (40 bytes):
#  DWORD Characteristics
#  DWORD TimeDateStamp
#  WORD  MajorVersion
#  WORD  MinorVersion
#  DWORD Name (RVA)
#  DWORD Base
#  DWORD NumberOfFunctions
#  DWORD NumberOfNames
#  DWORD AddressOfFunctions (RVA)
#  DWORD AddressOfNames (RVA)
#  DWORD AddressOfNameOrdinals (RVA)
export_dir = struct.pack(
    "<IIHHIIIIIII",
    0,                                                          # Characteristics
    pe.DIRECTORY_ENTRY_EXPORT.struct.TimeDateStamp,             # TimeDateStamp
    pe.DIRECTORY_ENTRY_EXPORT.struct.MajorVersion,
    pe.DIRECTORY_ENTRY_EXPORT.struct.MinorVersion,
    str_rva(dll_name_str_off),                                  # Name
    orig_base,                                                  # Base
    func_table_size,                                            # NumberOfFunctions
    len(named_exports_sorted),                                  # NumberOfNames
    new_sec_rva + off_func_table,                               # AddressOfFunctions
    new_sec_rva + off_name_table,                               # AddressOfNames
    new_sec_rva + off_ord_table,                                # AddressOfNameOrdinals
)
assert len(export_dir) == 40

# Serialize tables.
func_table_blob = b"".join(struct.pack("<I", r) for r in func_table)
name_table_blob = b"".join(struct.pack("<I", r) for r in name_ptr_table)
ord_table_blob = b"".join(struct.pack("<H", o) for o in ord_table)

section_blob = bytearray()
section_blob.extend(export_dir)
section_blob.extend(func_table_blob)
section_blob.extend(name_table_blob)
section_blob.extend(ord_table_blob)
section_blob.extend(strings_buf)

assert off_func_table == len(export_dir)
assert off_name_table == off_func_table + len(func_table_blob)
assert off_ord_table == off_name_table + len(name_table_blob)
assert off_dll_name == off_ord_table + len(ord_table_blob)

raw_size = align_up(len(section_blob), file_align)
virt_size = len(section_blob)
print(f"New section: virtual_size=0x{virt_size:x}, raw_size=0x{raw_size:x}")

# Total file growth and new export dir RVA / size.
new_export_dir_rva = new_sec_rva + off_export_dir
# The "size" field in DataDirectory[0] must span the export directory + all
# tables + all strings so forwarder address checks work.
new_export_dir_size = virt_size

# ---- Modify the PE in-memory. ----
# 1. Append the new section header to the section table. We must have room.
#    pefile lets us inspect FILE_HEADER.NumberOfSections and headers area.

# Find current section table end (right after the last section header).
section_header_size = 40
section_table_off = pe.FILE_HEADER.get_file_offset() + 20 + pe.FILE_HEADER.SizeOfOptionalHeader
section_table_end = section_table_off + pe.FILE_HEADER.NumberOfSections * section_header_size
print(f"Section table at file off 0x{section_table_off:x}, ends 0x{section_table_end:x}")
# Headers area extends to SizeOfHeaders. Make sure new section header fits.
size_of_headers = pe.OPTIONAL_HEADER.SizeOfHeaders
print(f"SizeOfHeaders=0x{size_of_headers:x}, room for new section header: 0x{size_of_headers - section_table_end:x}")
if size_of_headers - section_table_end < section_header_size:
    raise RuntimeError("No room in PE headers for an additional section header")

# Modify the in-memory PE.
data = bytearray(pe.__data__)

# 2. Increment NumberOfSections in FILE_HEADER.
file_hdr_off = pe.FILE_HEADER.get_file_offset()
nsec_off = file_hdr_off + 2  # NumberOfSections is at FILE_HEADER offset 2
new_nsec = pe.FILE_HEADER.NumberOfSections + 1
struct.pack_into("<H", data, nsec_off, new_nsec)

# 3. Build the new section header.
new_sec_name = b".eexpt2\x00"  # 8 bytes
# Characteristics flags:
#   IMAGE_SCN_CNT_INITIALIZED_DATA (0x00000040)
#   IMAGE_SCN_MEM_READ              (0x40000000)
chars = 0x40000040
new_sec_header = struct.pack(
    "<8sIIIIIIHHI",
    new_sec_name,
    virt_size,             # VirtualSize
    new_sec_rva,           # VirtualAddress
    raw_size,              # SizeOfRawData
    new_sec_file_off,      # PointerToRawData
    0,                     # PointerToRelocations
    0,                     # PointerToLinenumbers
    0,                     # NumberOfRelocations
    0,                     # NumberOfLinenumbers
    chars,                 # Characteristics
)
assert len(new_sec_header) == 40
data[section_table_end:section_table_end + section_header_size] = new_sec_header

# 4. Update DataDirectory[0] (EXPORT) RVA + Size to the new export dir.
#    DataDirectory starts at the optional header offset + 96 (for PE32+) or 92 (PE32).
opt_hdr_off = file_hdr_off + 20
# For PE32+, optional header magic is 0x20b; DataDirectory starts at offset 112.
magic, = struct.unpack_from("<H", data, opt_hdr_off)
if magic == 0x20b:
    data_dir_off = opt_hdr_off + 112
else:
    data_dir_off = opt_hdr_off + 96
print(f"PE magic 0x{magic:x}, DataDirectory at file off 0x{data_dir_off:x}")
# Entry 0 = EXPORT
struct.pack_into("<II", data, data_dir_off, new_export_dir_rva, new_export_dir_size)
print(f"Updated DataDirectory[0] = (RVA=0x{new_export_dir_rva:x}, Size=0x{new_export_dir_size:x})")

# 5. Update OPTIONAL_HEADER.SizeOfImage to cover the new section.
size_of_image_off = opt_hdr_off + 56  # PE32+ offset for SizeOfImage
new_size_of_image = align_up(new_sec_rva + virt_size, sec_align)
struct.pack_into("<I", data, size_of_image_off, new_size_of_image)
print(f"SizeOfImage updated to 0x{new_size_of_image:x}")

# 6. Append the section's raw data at new_sec_file_off, padded to raw_size.
# Pad data to new_sec_file_off if shorter.
while len(data) < new_sec_file_off:
    data.append(0)
data.extend(section_blob)
# Pad to raw_size (file alignment)
while len(data) < new_sec_file_off + raw_size:
    data.append(0)

# 7. Important: zero out the Wine builtin DLL signature at offset 0x40 so wine
#    treats this DLL as native and prefers it over its internal builtin.
struct.pack_into("<16s", data, 0x40, b"\x00" * 16)
print("Zeroed wine-builtin signature at file offset 0x40")

# Write out.
with open(OUTPUT, "wb") as f:
    f.write(data)

print(f"Wrote {OUTPUT} ({len(data)} bytes)")

# ---- Verify with pefile. ----
print("\n=== Verifying with pefile ===")
pe2 = pefile.PE(OUTPUT, fast_load=False)
exports = pe2.DIRECTORY_ENTRY_EXPORT.symbols
print(f"Verified export count: {len(exports)}")
for e in exports:
    if e.name and e.name.decode() == NEW_EXPORT_NAME:
        fw = e.forwarder.decode() if e.forwarder else "<none>"
        print(f"FOUND NEW: {e.name.decode()}  ord={e.ordinal}  forwarder={fw}")
        break
else:
    print(f"ERROR: {NEW_EXPORT_NAME} not in new export list!")
    sys.exit(1)

# Raw APFS Metadata Parsing as a Fast-Scan Path for DiskScope

*Feasibility research — the "nuclear option": bypass per-file syscalls by reading and parsing APFS on-disk metadata directly from the raw block device, the macOS analog of how WizTree/Everything read the NTFS MFT.*

Research date: 2026-06-05. All claims sourced inline; this report deliberately avoids relying on memory.

---

## 1. Executive summary & verdict

**Verdict: NOT worth it as the v2 path for a shippable, "just download and run" consumer Developer-ID app. Optimize the parallel `getattrlistbulk` scan instead.**

The technique is *technically real* — you can walk NXSB → omap → APSB → catalog B-tree and enumerate every `{name, size, timestamps}` from a handful of large reads, exactly like the MFT trick. And critically, the encryption concern, which I expected to be the dealbreaker, is **mostly a non-issue for the common case**: on T2/Apple-Silicon Macs the AES engine sits in the DMA path inside the storage controller and decryption is "completely transparent to accessing disk contents," so a root read of the internal `/dev/rdiskX` returns **plaintext metadata even with FileVault on** (the keys live in the Secure Enclave; you never touch them). Encryption only bites for *software*-encrypted volumes: external FileVault drives and legacy Intel-without-T2 Macs, where raw reads return ciphertext and you'd need the user's password.

So encryption isn't the thing that kills it. **Three other things do, and together they're decisive for a consumer app:**

1. **Root / privileged-helper UX.** Raw `/dev/rdiskX` reads require root. There is no entitlement that gives a normal app raw-device access; you must ship a privileged helper via `SMAppService` (or legacy `SMJobBless`). First-run requires the user to (a) approve a background Login Item and (b) authenticate with an admin password. This destroys the "download and run" UX, and Apple's own Login-Items approval flow has a long history of being flaky. This is strictly worse than the syscall path, which needs at most a one-click Full Disk Access toggle (and often nothing).
2. **Format fragility & maintenance burden.** The on-disk format is versioned and semi-documented; the open-source parsers (`apfs-fuse`, `libfsapfs`) lag macOS releases, break on new APFS versions, and don't fully support T2/hardware-encryption paths or snapshots. You'd be signing up to chase Apple's format changes every macOS cycle — for a *performance optimization*, not a feature.
3. **The payoff is marginal, not 46x.** WizTree's 46x advantage on Windows exists because Windows per-file enumeration (FindFirstFile/FindNextFile) is genuinely slow. DiskScope is *already* at 4.2 s for 1.71M entries using `getattrlistbulk` — a bulk syscall that returns many entries per call. The remaining cost is ~184k directory `openat`s and per-directory syscall overhead, which is attackable by tuning (bigger buffers, better parallelism, fewer opens) without leaving supported API. Raw parsing might get you to sub-second, but the delta is "4.2 s → maybe ~1 s" on top of an already-good number, bought with root, a helper tool, and perpetual format maintenance.

**When it *would* be worth it:** a forensics/pro tool where (a) you can demand admin rights anyway, (b) you control or test the macOS versions you run on, (c) sub-second on huge volumes is a headline feature, and (d) external/legacy software-encrypted volumes are out of scope or you collect passwords. That is a different product than a consumer "download and run" disk-space app.

The rest of this report substantiates each point.

---

## 2. The APFS on-disk walk

Authoritative reference: Apple's **"Apple File System Reference"** PDF (developer.apple.com/support/downloads/Apple-File-System-Reference.pdf). Excellent secondary references: the **libfsapfs** format docs (libyal), Joe T. Sylve's 2022 "APFS Advent Challenge" series, and the `apfsprogs`/`linux-apfs-rw` source.

### 2.1 Object model
APFS objects are either **physical** (addressed by block number), **virtual** (addressed by an object ID that must be resolved through an object map), or **ephemeral** (in-memory/checkpoint). Every object begins with an `obj_phys_t` header (checksum + oid + xid + type/subtype). The container is copy-on-write: nothing is overwritten in place; each transaction (identified by an `xid`) writes new blocks and a new checkpoint.

### 2.2 The minimum read path to enumerate everything

1. **Container superblock (NXSB, `nx_superblock_t`)** — magic `"NXSB"`, lives at block 0, but block 0 may be stale. The *authoritative* superblock is the one with the **highest valid `xid`** in the **checkpoint descriptor area** (`nx_xp_desc_base` / `_blocks`). You scan that ring, validate Fletcher-64 checksums, and pick the newest consistent one. This gives you block size, the container object-map oid (`nx_omap_oid`), and the array of volume oids (`nx_fs_oid[]`).
2. **Container object map (`omap_phys_t` → a B-tree)** — resolves *virtual* oids to physical block addresses (keyed by `{oid, xid}`, value is a block address + flags). You need this to turn each volume's virtual oid into a real block.
3. **Volume superblock (APSB, `apfs_superblock_t`)** — magic `"APSB"`. Key fields: `apfs_omap_oid` (the *volume's* object map) and **`apfs_root_tree_oid`** (the catalog / file-system B-tree, a virtual oid resolved via the volume omap). Also `apfs_extentref_tree_oid` and `apfs_snap_meta_tree_oid`.
4. **Volume object map** → resolve `apfs_root_tree_oid` to the physical root of the catalog tree.
5. **Catalog (file-system) B-tree (`btree_node_phys_t`)** — this single tree holds every inode, directory entry, data-stream, and xattr record for the volume. Walking it leaf-to-leaf in key order **is** the enumeration.

That's it: a few superblock/omap reads plus a streaming traversal of one B-tree. The B-tree leaves are large and laid out for sequential-ish reads, which is exactly why this can beat per-file syscalls.

### 2.3 The records you actually parse

Every catalog key starts with `j_key_t`: an 8-byte `obj_id_and_type` where the **low 60 bits are the object/inode ID** and the **high 4 bits are the record type** (`j_obj_types`, e.g. `APFS_TYPE_INODE`, `APFS_TYPE_DIR_REC`, `APFS_TYPE_DSTREAM`, `APFS_TYPE_XATTR`). So all records for one object cluster together by ID and sort by type — convenient for a streaming walk.

- **Inode record** — key `j_inode_key_t` (just the header); value `j_inode_val_t` (~92 bytes fixed before extended fields). Fields you need: `parent_id`, `create_time`/`mod_time`/`change_time`/`access_time` (nanoseconds since the POSIX epoch), `mode`/`owner`/`group`, and a trailing variable **extended-fields (`xfields`)** blob.
- **Directory entry record** — key `j_drec_hashed_key_t`: parent dir's inode ID in the header, then `name_len_and_hash` (length of the UTF-8 name including the NUL, plus a hash) and the inline `name[]`. Value `j_drec_val_t`: **`file_id`** (the child inode's ID), `date_added`, `flags`. **This is the name→inode edge and the directory→children edge** — to list a directory's children you query all `DIR_REC` records whose key object-ID equals that directory's inode ID; each gives a child name + child inode ID. Reconstructing full paths is just walking these edges (or `parent_id` upward).
- **File size** — *not* simply a top-level field. The reliable value is in the inode's `xfields`, in an `INO_EXT_TYPE_DSTREAM` extended field of type `j_dstream_t`, which carries `size` (logical), `alloc_count` (allocated bytes), etc. `j_inode_val_t` also has `uncompressed_size`, but compressed files store their real size in a `com.apple.decmpfs` xattr / resource fork, so a correct sizer must handle compression. For DiskScope's "size on disk" you'd read `alloc_count` from the dstream xfield; for logical size, `size`. Physical extents live in separate `APFS_TYPE_FILE_EXTENT` records, but you don't need to walk those just to get sizes — the dstream summary suffices.

**Net:** one pass over the catalog B-tree yields, per object, name (from DIR_REC), parent linkage, timestamps and mode (from INODE), and size (from the INODE's DSTREAM xfield). That is precisely DiskScope's `{name, size, type, dates}` tuple. The hard parts are (a) correctly picking the newest valid checkpoint, (b) resolving virtual oids through two omaps, (c) parsing the variable-length xfields, and (d) compression-aware sizing.

### 2.4 Consistency on a *live* mounted volume — read a snapshot

Reading the raw device of a **mounted, actively-written** volume risks a torn/inconsistent view: the kernel may be mid-transaction, and the checkpoint you read can race writers. APFS's COW design mitigates this (old blocks aren't overwritten until reclaimed, and you select the newest *fully-committed* xid), so you generally get *a* consistent past state rather than garbage — but it's not guaranteed stable for the duration of a long walk, and Apple Developer Forums document "transient corruption when reading" mounted volumes.

The clean answer is to **take an APFS snapshot first** and parse that: a snapshot is a read-only, point-in-time, copy-on-write-pinned view (`tmutil localsnapshot`, or the `fs_snapshot_create`/`fsctl` APIs; the catalog reachable via `apfs_snap_meta_tree_oid`). This gives a guaranteed-consistent tree to walk. Costs: creating/mounting a snapshot is itself a privileged operation, snapshots consume space until deleted, and `libfsapfs` explicitly does **not** support snapshots, so you'd implement that traversal yourself.

---

## 3. Existing implementations (library survey, with licenses)

| Project | Author | Language | License | Status / currency | Notes for FFI / reuse |
|---|---|---|---|---|---|
| **libfsapfs** (`libyal/libfsapfs`) | Joachim Metz | C (~92%) + Python (`pyfsapfs`) | **LGPL-3.0-or-later / GPL-3.0** | "experimental," actively maintained (200+ commits, ongoing releases) | The most FFI-friendly: clean C library, read-only, supports password-based encryption, ZLIB/LZVN compression, xattrs. **Does NOT support T2/hardware "encryption," snapshots, or LZFSE.** APFS "version 2" only (v1 unsupported). LGPL is workable for a closed-source app *if* dynamically linked. |
| **apfs-fuse** (`sgan81/apfs-fuse`) | sgan81 | C++ | **GPL-2.0** (bundles LZFSE under its own license) | Last push ~2024-08; open issues through late 2024; community PRs into 2025. Maintenance is slow. | Read-only FUSE driver; supports fusion drives and **software** FileVault (prompts for password / PRK). Firmlinks and some compression unsupported. **GPL-2.0 is a hard blocker for a proprietary app** — you can't statically link it into a closed-source Developer-ID binary. Good as a *reference* only. |
| **apfsprogs** (`linux-apfs/apfsprogs`) | Ernesto A. Fernández | C | **GPL-2.0-or-later** | v0.2.0; active; pairs with `linux-apfs-rw` kernel module | `apfsck` (fsck) is the best *correctness* reference for the format and checkpoint validation. GPL-2.0 — reference only for a closed app. KDE recently picked up APFS support building on this lineage. |
| **linux-apfs-rw** | Ernesto A. Fernández | C (kernel) | GPL-2.0 | Active, experimental write support | Kernel driver; reference only. |
| Paragon APFS / commercial | Paragon, others | closed | proprietary, paid | current | Not reusable; evidence the format is tractable enough to ship commercially with maintenance investment. |

**Licensing bottom line for a proprietary Developer-ID app:** only **libfsapfs (LGPL)** is plausibly linkable, and only if you (a) dynamically link and (b) preserve LGPL obligations. apfs-fuse and apfsprogs are **GPL** — usable as documentation/reference to write your own parser, but not linkable into a closed product. The cleanest path is a from-scratch Swift/C parser using Apple's PDF + these as references; that maximizes the maintenance burden but avoids license entanglement. Note that **none** of the permissively-usable options cover T2/hardware-encryption decryption (you don't need it on internal SSDs — see §4) *or* snapshots (which you do want — §2.4).

---

## 4. Encryption — the expected dealbreaker that mostly isn't (for the common case)

This is the most important and most counterintuitive finding, so it's worth stating precisely.

**APFS volumes are essentially always encrypted at rest on modern Macs.** On a Mac with Apple Silicon or a T2 chip, all APFS volumes are created with a Volume Encryption Key (VEK); the volume and its metadata are encrypted whether or not FileVault is on. With FileVault **off**, the VEK is wrapped by the **hardware UID baked into the Secure Enclave**; with FileVault **on**, it's additionally protected by a KEK derived from the user's password. (Apple Support, "Volume encryption with FileVault in macOS.")

**The decryptor's location is what saves the technique.** On T2/Apple-Silicon, the AES-256 engine "is built into the direct memory access (DMA) path between NAND flash storage and main system memory," and "all data transferred between the main CPU/memory and internal storage passes through an encryption stage in the … SoC." Per The Eclectic Light Company, this hardware encryption is **"completely transparent to accessing disk contents."** Practical consequence:

- On the **internal SSD**, a root read of `/dev/rdiskX` returns **plaintext** — the controller decrypts inline before the bytes ever reach the CPU. **This holds even with FileVault ON**, because FileVault on T2/AS doesn't change *where* decryption happens; it only changes how the VEK is wrapped. The Secure Enclave keys are never exposed and you never need them. So **the catalog B-tree you read off the raw internal device is already cleartext** for any volume the system can currently access (i.e., the user is logged in / volume unlocked).
- This is *better* than the open-source FUSE/Linux story, where "encrypted" means software encryption and you must supply a password — which is exactly why `libfsapfs` lists "T2 encryption" as **unsupported**: on Linux there's no hardware engine to transparently decrypt, so they simply can't read T2-encrypted internal volumes at all. On macOS reading its own internal disk, that whole problem evaporates.

**Where encryption *is* a real showstopper:**
- **External drives** (even on M1+): Apple uses **software** FileVault for external volumes — "M1 Macs don't offer hardware encryption on external storage." Raw reads return **ciphertext**; you'd need the user's password and a full software-decryption path (keybag → KEK → VEK → XTS-AES). Doable (libfsapfs/apfs-fuse do it) but a large, fragile chunk of crypto code.
- **Legacy Intel Macs without a T2**: software FileVault, same ciphertext-on-raw-read story.

**Encryption verdict:** *not* the dealbreaker for the headline use case (scanning the boot/internal Data volume of a modern Mac). It only forces a password-and-software-crypto path for external/legacy software-encrypted volumes — which you could simply fall back to `getattrlistbulk` for. So cross encryption off the "fatal" list, but note it caps the technique to internal storage unless you build (and maintain) a software-decryption stack.

---

## 5. Access & permissions reality — this is a real blocker

**Raw `/dev/rdiskX` / `/dev/diskXsY` reads require root.** There is no TCC entitlement or Full Disk Access toggle that grants a normal, non-root app raw block-device access. Reading the raw device can also trip "Access Removable Media" / Full Disk Access prompts on top of the root requirement.

To get root from a notarized Developer-ID app you must ship a **privileged helper**:
- Modern API: **`SMAppService`** (macOS 13+), helper embedded in the app bundle; legacy: `SMJobBless`. Notarization is required to embed LaunchDaemons.
- **First-run UX:** the user must (1) **approve a background/login item**, then (2) **authenticate with an admin password** to install the daemon (installing a daemon needs root). Apple's own forums document the Login-Items approval pane as historically **broken/confusing** (users who dismiss the notification can't easily re-approve).
- This is a one-time-per-install cost, but it is *exactly* the friction the "just download and run" positioning is trying to avoid. It also raises the app's privilege footprint (a root daemon that reads raw disks is an attack-surface and review liability).

**Honest cross-platform note:** even **WizTree on Windows requires Administrator/UAC** to read the MFT — decline the elevation prompt and it falls back to a slower mode. So "fast raw scan needs elevation" is inherent to the technique on *both* platforms; macOS just makes the elevation heavier (persistent helper + notarization + flaky approval UI) than a single UAC click.

**Snapshot wrinkle:** for a consistent live-volume view you also want to create/mount an APFS snapshot (§2.4), itself privileged — folded into the same helper, but more moving parts.

**Permissions verdict:** for a consumer "download and run" app, the helper-tool requirement is the practical killer. Compare to the status quo: `getattrlistbulk` on the user's own files needs at most a Full Disk Access toggle (and often nothing for user-owned data) — no root, no daemon, no notarized helper.

---

## 6. Fragility & maintenance

The format is **versioned and semi-documented at the edges**, and Apple changes it across macOS releases (object types, new fields, new compression like LZFSE, sealed/Signed System Volume mechanics, snapshot metadata). Evidence from the trackers:

- **apfs-fuse** has a documented history of breaking on new macOS/APFS versions (e.g., "invalid superblock" on Mojave-era images requiring re-calibration), unsupported firmlinks, and incomplete compression support; maintenance has slowed (last significant push ~2024-08). You inherit this treadmill.
- **libfsapfs** is "experimental," v2-only, and explicitly lacks snapshots, LZFSE, and T2 — i.e., it's *behind* current macOS in several respects.
- Apple's reference PDF lags shipping macOS and omits edge details; the community fills gaps by reverse engineering, which is inherently reactive.
- Even Apple's own `fsck_apfs` regularly surfaces checkpoint/`fsroot`-tree consistency issues in the wild, underscoring how much careful validation a correct reader must do (checksum every node, pick the right xid, handle partially-written checkpoints).

**Maintenance verdict:** you'd be committing to chase Apple's on-disk changes **every macOS cycle**, with breakage landing as "the scanner returns garbage/crashes on the new OS" for users — a high-severity failure mode for a *performance* feature. The syscall path, by contrast, is stable supported API: Apple maintains `getattrlistbulk` compatibility for you.

---

## 7. Risk-vs-payoff and final call

**Payoff (optimistic):** ~4.2 s → plausibly sub-second to ~1 s on the internal Data volume, by replacing 184k directory opens + per-dir syscalls with a few large sequential reads and one B-tree walk. Real, but a *single-digit-x* improvement on an already-fast baseline — not WizTree's 46x, because DiskScope isn't starting from Windows' slow per-file enumeration.

**Costs / risks:**
- **UX:** mandatory root via a notarized privileged helper (`SMAppService`), with admin-password + login-item approval on first run, and Apple's flaky approval UI. Kills "download and run."
- **Scope cap:** clean only for **internal** T2/Apple-Silicon volumes (where HW decryption is transparent). External/legacy **software-encrypted** volumes need a full password + XTS-AES software stack or a fallback.
- **Correctness surface:** checkpoint selection, dual omap resolution, xfield parsing, compression-aware sizing, snapshot-for-consistency, Fletcher-64 validation — a lot of code that must be *exactly* right or it silently mis-sizes.
- **Maintenance:** perpetual, reactive format-tracking across macOS releases; permissive libraries (libfsapfs LGPL) lag and don't cover snapshots/T2; the better references are GPL (license-incompatible with a closed app).

**Recommendation: don't build raw APFS parsing for DiskScope v2. Spend the same effort optimizing the parallel `getattrlistbulk` scan**, which is already at 4.2 s and is syscall-bound on directory opens — attackable with:
- larger `getattrlistbulk` buffers (fewer round-trips per directory);
- requesting only the attributes you render (smaller per-entry payloads);
- smarter work-stealing parallelism keyed to directory fan-out, and capping open-FD churn;
- caching/`fseventsd`-style incremental rescans so the *second* scan is near-instant (this likely beats raw parsing on perceived speed without any of the risk).

**Revisit raw APFS only if DiskScope pivots toward a pro/forensics SKU** that can (a) legitimately demand admin rights, (b) pin/test supported macOS versions, (c) treat sub-second-on-huge-volumes as a headline feature, and (d) scope out or password-collect for external/software-encrypted media. In that world the economics flip; for a consumer "download and run" app they don't.

---

## Sources

- Apple, "Apple File System Reference" (PDF) — https://developer.apple.com/support/downloads/Apple-File-System-Reference.pdf
- libyal/libfsapfs (library, format docs, license, feature/limitation list) — https://github.com/libyal/libfsapfs and https://github.com/libyal/libfsapfs/blob/main/documentation/Apple%20File%20System%20(APFS).asciidoc
- sgan81/apfs-fuse (GPL-2.0, software FileVault support, maintenance status) — https://github.com/sgan81/apfs-fuse
- linux-apfs/apfsprogs (Ernesto A. Fernández, GPL-2.0-or-later) — https://github.com/linux-apfs/apfsprogs ; linux-apfs-rw — https://github.com/linux-apfs/linux-apfs-rw
- Joe T. Sylve, "APFS Inode and Directory Records" (2022 APFS Advent Challenge) — https://jtsylve.blog/post/2022/12/16/APFS-Inode-and-Directory-Records
- Apple Support, "Volume encryption with FileVault in macOS" — https://support.apple.com/guide/security/volume-encryption-with-filevault-sec4c6dc1b6e/web
- Apple Support, "The Secure Enclave" / "Hardware security overview" — https://support.apple.com/guide/security/the-secure-enclave-sec59b0b31ff/web , https://support.apple.com/guide/security/hardware-security-overview-secf020d1074/web
- The Eclectic Light Company, "Disk encryption, FileVault and hardware encryption" (transparent HW encryption) — https://eclecticlight.co/2021/08/20/disk-encryption-filevault-and-hardware-encryption/
- The Eclectic Light Company, "FileVault and volume encryption explained" — https://eclecticlight.co/2025/01/10/filevault-and-volume-encryption-explained/
- Apple Developer Documentation, `SMAppService` — https://developer.apple.com/documentation/servicemanagement/smappservice ; theevilbit, "macOS Service Management — The SMAppService API" — https://theevilbit.github.io/posts/smappservice/ ; Apple Developer Forums (privileged helper UX) — https://developer.apple.com/forums/thread/739940
- Michael Tsai, "mount_apfs TCC Bypass and Privilege Escalation" (snapshot mount + FDA/TCC interaction) — https://mjtsai.com/blog/2020/07/03/mount_apfs-tcc-bypass-and-privilege-escalation/
- Apple Developer Forums, "transient corruption when reading" mounted volumes — https://developer.apple.com/forums/thread/112739
- WizTree / antibody-software (MFT read requires Administrator/UAC; technique parity) — https://antibody-software.com/web/software/software/wiztree-finds-the-files-and-folders-using-the-most-disk-space-on-your-hard-drive

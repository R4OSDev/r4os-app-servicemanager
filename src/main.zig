const r4os = @import("r4os");
const std = @import("std");
const checks = r4os.system_update_recovery;

const config_path = "C:\\R4OS\\CONFIG\\SERVICES.R4S";
const service_path_capacity = @sizeOf(@FieldType(r4os.abi.ServiceInventoryRow, "path"));
const endpoint_status_op: u16 = 1;
const endpoint_status_timeout_ms: u64 = 5000;
const endpoint_status_attempts: u32 = 3;

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var sys = r4_app.system();
    const args = trim(zSlice(sys.argsRaw()));
    return run(&sys, args);
}

const Token = struct {
    token: []const u8,
    rest: []const u8,
};

const Action = enum(u8) {
    start,
    stop,
    restart,
    manual,
    auto,
    disable,
    remove,
};

const ConfigReport = struct {
    missing: bool = false,
    lines: u64 = 0,
    loaded: u64 = 0,
    duplicate: u64 = 0,
    invalid: u64 = 0,
    error_code: i32 = 0,
};

fn run(sys: *r4os.r4sys.Context, args: []const u8) i32 {
    if (!sys.hasFn("service_start")) {
        sys.println("SERVMAN: Service API unavailable.");
        return 1;
    }

    if (args.len == 0) {
        return printList(sys);
    }

    const first = takeToken(args) orelse {
        return printList(sys);
    };

    if (tokenEquals(first.token, "/?") or tokenEquals(first.token, "HELP")) {
        printUsage(sys);
        return 0;
    }
    if (tokenEquals(first.token, "LIST")) {
        return printList(sys);
    }
    if (tokenEquals(first.token, "LOAD")) return loadConfigCommand(sys, false);
    if (tokenEquals(first.token, "BOOT")) return bootCommand(sys);
    if (tokenEquals(first.token, "SAVE")) return saveConfigCommand(sys);
    if (tokenEquals(first.token, "CONFIG") or tokenEquals(first.token, "DUMP")) return dumpConfigCommand(sys);
    if (tokenEquals(first.token, "DIAG")) return printDiag(sys);
    if (tokenEquals(first.token, "SELFTEST")) return selfTest(sys);
    if (tokenEquals(first.token, "STATUS")) return commandStatus(sys, first.rest);
    if (tokenEquals(first.token, "START")) return commandOne(sys, first.rest, .start);
    if (tokenEquals(first.token, "STOP")) return commandOne(sys, first.rest, .stop);
    if (tokenEquals(first.token, "RESTART")) return commandOne(sys, first.rest, .restart);
    if (tokenEquals(first.token, "ENABLE") or tokenEquals(first.token, "MANUAL")) return commandOne(sys, first.rest, .manual);
    if (tokenEquals(first.token, "AUTO")) return commandOne(sys, first.rest, .auto);
    if (tokenEquals(first.token, "DISABLE")) return commandOne(sys, first.rest, .disable);
    if (tokenEquals(first.token, "REMOVE")) return commandOne(sys, first.rest, .remove);
    if (tokenEquals(first.token, "INSTALL")) return commandInstall(sys, first.rest);

    printUsage(sys);
    return 1;
}

fn printUsage(sys: *r4os.r4sys.Context) void {
    sys.println("SERVMAN - R4OS Service Manager");
    sys.println("Usage: SERVMAN [LIST|LOAD|BOOT|SAVE|CONFIG|DIAG|SELFTEST]");
    sys.println("       SERVMAN STATUS name");
    sys.println("       SERVMAN START|STOP|RESTART name");
    sys.println("       SERVMAN ENABLE|MANUAL|AUTO|DISABLE name");
    sys.println("       SERVMAN REMOVE name");
    sys.println("       SERVMAN INSTALL name path [/ARGS=x] [/AUTO|/DISABLED] [/DESC=x]");
}

fn printDiag(sys: *r4os.r4sys.Context) i32 {
    sys.println("SERVMAN Diagnose");
    sys.println("  Service-API: OK");
    sys.write("  Config: ");
    sys.println(config_path);

    var count: u32 = 0;
    var auto_count: u32 = 0;
    var manual_count: u32 = 0;
    var disabled_count: u32 = 0;
    var running_count: u32 = 0;
    var failed_count: u32 = 0;
    var endpoint_count: u64 = 0;
    var queue_used: u64 = 0;
    var queue_high: u64 = 0;
    var workers: u64 = 0;
    var max_workers: u64 = 0;
    var open_handles: u64 = 0;
    var busy_rejections: u64 = 0;
    var timeouts: u64 = 0;
    var cancellations: u64 = 0;
    var inventory = readInventory(sys) orelse return 1;
    defer inventory.deinit();
    for (inventory.rows) |detail| {
        count += 1;
        switch (detail.info.start_mode) {
            r4os.abi.service_start_auto => auto_count += 1,
            r4os.abi.service_start_disabled => disabled_count += 1,
            else => manual_count += 1,
        }
        switch (detail.info.state) {
            r4os.abi.service_state_running, r4os.abi.service_state_starting => running_count += 1,
            r4os.abi.service_state_failed => failed_count += 1,
            else => {},
        }
        if ((detail.info.flags & r4os.abi.service_api_flag_endpoint) != 0) endpoint_count += 1;
        queue_used +%= detail.info.queue_used;
        queue_high +%= detail.info.queue_high_water;
        workers +%= detail.info.active_workers;
        if (detail.info.max_active_workers > max_workers) max_workers = detail.info.max_active_workers;
        open_handles +%= detail.info.open_handles;
        busy_rejections +%= detail.info.busy_rejections;
        timeouts +%= detail.info.timeouts;
        cancellations +%= detail.info.cancellations;
    }

    sys.write("  Registered services: ");
    writeUnsigned(sys, count);
    sys.println("");
    sys.write("  Auto: ");
    writeUnsigned(sys, auto_count);
    sys.write("  Manual: ");
    writeUnsigned(sys, manual_count);
    sys.write("  Disabled: ");
    writeUnsigned(sys, disabled_count);
    sys.println("");
    sys.write("  Running/Starting: ");
    writeUnsigned(sys, running_count);
    sys.write("  Failed: ");
    writeUnsigned(sys, failed_count);
    sys.println("");
    sys.write("  Endpoints: ");
    writeUnsigned(sys, endpoint_count);
    sys.write("  QueueUsed: ");
    writeUnsigned(sys, queue_used);
    sys.write("  QueueHigh: ");
    writeUnsigned(sys, queue_high);
    sys.println("");
    sys.write("  Workers: ");
    writeUnsigned(sys, workers);
    sys.write("  MaxWorkers: ");
    writeUnsigned(sys, max_workers);
    sys.write("  OpenHandles: ");
    writeUnsigned(sys, open_handles);
    sys.println("");
    sys.write("  Busy: ");
    writeUnsigned(sys, busy_rejections);
    sys.write("  Timeouts: ");
    writeUnsigned(sys, timeouts);
    sys.write("  Cancels: ");
    writeUnsigned(sys, cancellations);
    sys.println("");
    printConnectivityEndpointDiag(sys);
    return 0;
}

fn printConnectivityEndpointDiag(sys: *r4os.r4sys.Context) void {
    sys.println("  Connectivity endpoints:");
    printConnectivityEndpointLine(sys, "TCPSVC");
    printConnectivityEndpointLine(sys, "FTPSVC");
    printConnectivityEndpointLine(sys, "SSHD");
    printConnectivityEndpointLine(sys, "RDPSVC");
}

fn printConnectivityEndpointLine(sys: *r4os.r4sys.Context, name: [*:0]const u8) void {
    var detail: r4os.abi.ServiceDetail = .{};
    const rc = sys.serviceDetailByName(name, &detail);
    sys.write("    ");
    sys.write(zSlice(name));
    sys.write(": ");
    if (rc != r4os.abi.service_api_result_ok) {
        sys.write("state=");
        sys.write(resultName(rc));
        sys.write(" rc=");
        sys.printI32(rc);
        sys.println("");
        return;
    }
    const endpoint = (detail.info.flags & r4os.abi.service_api_flag_endpoint) != 0;
    const queued = (detail.info.flags & r4os.abi.service_api_flag_queue_backed) != 0;
    sys.write("state=");
    sys.write(serviceStateName(detail.info.state));
    sys.write(" endpoint=");
    sys.write(if (endpoint) "yes" else "no");
    sys.write(" queue=");
    sys.write(if (queued) "yes" else "no");
    sys.write(" q=");
    writeUnsigned(sys, detail.info.queue_used);
    sys.write("/");
    writeUnsigned(sys, detail.info.queue_depth);
    sys.write(" workers=");
    writeUnsigned(sys, detail.info.active_workers);
    sys.write("/");
    writeUnsigned(sys, detail.info.max_active_workers);
    sys.write(" open=");
    writeUnsigned(sys, detail.info.open_handles);
    sys.write(" busy=");
    writeUnsigned(sys, detail.info.busy_rejections);
    sys.write(" timeout=");
    writeUnsigned(sys, detail.info.timeouts);
    sys.write(" cancel=");
    writeUnsigned(sys, detail.info.cancellations);
    const last = spanZ(detail.info.last_error[0..]);
    if (last.len > 0) {
        sys.write(" last=");
        sys.write(last);
    }
    sys.println("");
}

fn selfTest(sys: *r4os.r4sys.Context) i32 {
    sys.println("SERVMAN selftest");
    if (!sys.hasFn("service_start")) return fail(sys, "service-api");
    var info: r4os.abi.ServiceInfo = .{};
    const rc = sys.serviceInfo(0, &info);
    if (rc < 0) return failCode(sys, "service-info", rc);
    var out: [256]u8 = .{0} ** 256;
    var pos: usize = 0;
    if (!append(&out, &pos, "SERVICE;name=TEST;path=C:\\R4OS\\SERVICES\\TEST.R4X;start=manual;enabled=yes\r\n")) return fail(sys, "append");
    var report: ConfigReport = .{};
    parseConfig(sys, out[0..pos], &report, true);
    if (report.lines != 1 or report.invalid != 0) return fail(sys, "parse");
    const rows = sys.allocator().alloc(r4os.abi.ServiceInventoryRow, 300) catch return fail(sys, "selftest-memory");
    defer sys.allocator().free(rows);
    for (rows, 0..) |*row, index| {
        row.* = .{};
        const name = std.fmt.bufPrint(&row.info.name, "T{d:0>4}", .{index}) catch return fail(sys, "test-name");
        row.info.name[name.len] = 0;
        row.info.start_mode = switch (index % 3) {
            0 => r4os.abi.service_start_auto,
            1 => r4os.abi.service_start_manual,
            else => r4os.abi.service_start_disabled,
        };
        @memset(row.path[0..200], 'A');
        @memcpy(row.path[0..3], "C:\\");
        setZ(&row.description, "Größe UTF-8");
    }
    const rendered = renderConfig(sys.allocator(), rows) catch return fail(sys, "test-render");
    defer sys.allocator().free(rendered);
    if (rendered.len <= 4096 or !std.mem.startsWith(u8, rendered, "\xEF\xBB\xBF")) return fail(sys, "large-config");
    var large: ConfigReport = .{};
    parseConfig(sys, rendered, &large, true);
    if (large.lines != 300 or large.invalid != 0) return fail(sys, "large-roundtrip");
    var tiny: [1]u8 = undefined;
    var failing = std.heap.FixedBufferAllocator.init(&tiny);
    if (renderConfig(failing.allocator(), rows)) |unexpected| {
        failing.allocator().free(unexpected);
        return fail(sys, "oom-success");
    } else |err| if (err != error.OutOfMemory) return fail(sys, "oom-code");
    sys.println("SERVMAN large-config: 300 rows, full paths, Unicode, OOM: OK");
    sys.println("SERVMAN selftest: OK");
    return 0;
}

fn commandStatus(sys: *r4os.r4sys.Context, rest: []const u8) i32 {
    const part = takeToken(rest) orelse {
        printUsage(sys);
        return 1;
    };
    var name_z: [r4os.abi.service_name_bytes + 1]u8 = .{0} ** (r4os.abi.service_name_bytes + 1);
    const name_ptr = makeZ(name_z[0..], part.token) orelse return fail(sys, "name-too-long");
    var inventory = readInventory(sys) orelse return 1;
    defer inventory.deinit();
    const detail = findRow(inventory.rows, part.token) orelse {
        printCommandResult(sys, "STATUS", part.token, r4os.abi.service_api_result_not_found);
        return 1;
    };
    printServiceDetail(sys, detail, &detail.process);
    printEndpointStatus(sys, name_ptr);
    return 0;
}

fn commandOne(sys: *r4os.r4sys.Context, rest: []const u8, action: Action) i32 {
    const part = takeToken(rest) orelse {
        printUsage(sys);
        return 1;
    };
    var inventory = readInventory(sys) orelse return 1;
    defer inventory.deinit();
    const row = findRow(inventory.rows, part.token) orelse {
        printCommandResult(sys, actionName(action), part.token, r4os.abi.service_api_result_not_found);
        return 1;
    };
    const rc = controlRow(sys, row, action);
    printCommandResult(sys, actionName(action), part.token, rc);
    if (rc == r4os.abi.service_api_result_self_restart) {
        // Say what to do instead, so the refusal is actionable rather than
        // just a code.
        sys.println("       This command runs inside that service; stopping it");
        sys.println("       would kill this session mid-command.  Run it from the");
        sys.println("       local console, or from a different service/session.");
    }
    if (rc != r4os.abi.service_api_result_ok) return 1;
    if (action == .manual or action == .auto or action == .disable or action == .remove) {
        return if (saveConfig(sys, true)) 0 else 1;
    }
    return 0;
}

fn commandInstall(sys: *r4os.r4sys.Context, rest_raw: []const u8) i32 {
    const name_part = takeToken(rest_raw) orelse {
        printUsage(sys);
        return 1;
    };
    const path_part = takeToken(name_part.rest) orelse {
        printUsage(sys);
        return 1;
    };

    var args_value: [r4os.abi.service_args_bytes]u8 = .{0} ** r4os.abi.service_args_bytes;
    var desc_value: [r4os.abi.service_description_bytes]u8 = .{0} ** r4os.abi.service_description_bytes;
    var mode: u32 = r4os.abi.service_start_manual;
    var rest = path_part.rest;
    while (takeToken(rest)) |part| {
        if (tokenEquals(part.token, "/AUTO")) {
            mode = r4os.abi.service_start_auto;
        } else if (tokenEquals(part.token, "/DISABLED") or tokenEquals(part.token, "/DISABLE")) {
            mode = r4os.abi.service_start_disabled;
        } else if (startsWithIgnoreCase(part.token, "/ARGS=")) {
            setZ(args_value[0..], part.token[6..]);
        } else if (startsWithIgnoreCase(part.token, "/DESC=")) {
            setZ(desc_value[0..], part.token[6..]);
        }
        rest = part.rest;
    }

    var name_z: [r4os.abi.service_name_bytes + 1]u8 = .{0} ** (r4os.abi.service_name_bytes + 1);
    var path_z: [service_path_capacity]u8 = .{0} ** service_path_capacity;
    var args_z: [r4os.abi.service_args_bytes + 1]u8 = .{0} ** (r4os.abi.service_args_bytes + 1);
    var desc_z: [r4os.abi.service_description_bytes + 1]u8 = .{0} ** (r4os.abi.service_description_bytes + 1);
    const name_ptr = makeZ(name_z[0..], name_part.token) orelse return fail(sys, "name-too-long");
    const path_ptr = makeZ(path_z[0..], path_part.token) orelse return fail(sys, "path-too-long");
    const args_ptr = makeZ(args_z[0..], spanZ(args_value[0..])) orelse return fail(sys, "args-too-long");
    const desc_ptr = makeZ(desc_z[0..], spanZ(desc_value[0..])) orelse return fail(sys, "desc-too-long");
    var info: r4os.abi.ServiceInfo = .{};
    const rc = sys.serviceInstall(name_ptr, path_ptr, args_ptr, mode, desc_ptr, &info);
    printCommandResult(sys, "INSTALL", name_part.token, rc);
    if (rc != r4os.abi.service_api_result_ok) return 1;
    return if (saveConfig(sys, true)) 0 else 1;
}

fn loadConfigCommand(sys: *r4os.r4sys.Context, missing_ok: bool) i32 {
    var report: ConfigReport = .{};
    return loadConfig(sys, missing_ok, "LOAD", &report);
}

fn bootCommand(sys: *r4os.r4sys.Context) i32 {
    var report: ConfigReport = .{};
    const load_rc = loadConfig(sys, true, "BOOT", &report);
    if (load_rc != 0 and (report.error_code != 0 or (report.loaded == 0 and report.duplicate == 0))) return load_rc;
    return startAutoServices(sys);
}

fn loadConfig(sys: *r4os.r4sys.Context, missing_ok: bool, label: []const u8, report: *ConfigReport) i32 {
    const bytes = readFileBytes(sys, config_path) catch |err| {
        report.missing = err == error.NotFound;
        if (report.missing and missing_ok) {
            printConfigReport(sys, label, report);
            return 0;
        }
        report.error_code = if (err == error.OutOfMemory) r4os.abi.service_api_result_memory else r4os.abi.service_api_result_config_io;
        sys.write("SERVMAN ");
        sys.write(label);
        sys.write(": config read failed: ");
        sys.println(@errorName(err));
        return 1;
    };
    defer sys.allocator().free(bytes);
    var validation: ConfigReport = .{};
    parseConfig(sys, bytes, &validation, true);
    if (validation.invalid != 0) {
        report.* = validation;
        printConfigReport(sys, label, report);
        return 1;
    }
    parseConfig(sys, bytes, report, false);
    printConfigReport(sys, label, report);
    return if (report.invalid == 0 and report.error_code == 0) 0 else 1;
}

fn saveConfigCommand(sys: *r4os.r4sys.Context) i32 {
    return if (saveConfig(sys, true)) 0 else 1;
}

fn dumpConfigCommand(sys: *r4os.r4sys.Context) i32 {
    var inventory = readInventory(sys) orelse return 1;
    defer inventory.deinit();
    const out = renderConfig(sys.allocator(), inventory.rows) catch return fail(sys, "config-memory");
    defer sys.allocator().free(out);
    const visible = stripBom(out);
    var offset: usize = 0;
    while (offset < visible.len) {
        const end = offset + @min(visible.len - offset, 16384);
        sys.write(visible[offset..end]);
        offset = end;
    }
    if (visible.len == 0 or visible[visible.len - 1] != '\n') sys.println("");
    return 0;
}

fn saveConfig(sys: *r4os.r4sys.Context, verbose: bool) bool {
    var inventory = readInventory(sys) orelse return false;
    defer inventory.deinit();
    const bytes = renderConfig(sys.allocator(), inventory.rows) catch {
        sys.println("SERVMAN SAVE: memory allocation failed; configuration not written.");
        return false;
    };
    defer sys.allocator().free(bytes);
    const old = fingerprint(sys, config_path) catch {
        sys.println("SERVMAN SAVE: original configuration could not be verified.");
        return false;
    };
    var stage_buffer: [64]u8 = undefined;
    var backup_buffer: [64]u8 = undefined;
    const seed: u32 = @truncate(sys.ticks() ^ @intFromPtr(&stage_buffer));
    const files: r4os.app_storage.Files = .{ .sys = sys.* };
    for (0..32) |attempt| {
        const id = (seed +% @as(u32, @intCast(attempt))) & 0xFFFFFF;
        const stage = std.fmt.bufPrintZ(&stage_buffer, "C:\\R4OS\\CONFIG\\SM{X:0>6}.TMP", .{id}) catch return false;
        const backup = std.fmt.bufPrintZ(&backup_buffer, "C:\\R4OS\\CONFIG\\SM{X:0>6}.BAK", .{id}) catch return false;
        var info: r4os.abi.FileInfo = .{};
        const backup_rc = sys.fileInfoRaw(backup, &info);
        if (backup_rc > 0) continue;
        if (backup_rc < 0) return false;
        var writer = switch (files.streamWriter(.{ .ptr = stage, .len = @intCast(stage.len) }, r4os.abi.file_stream_open_create)) {
            .writer => |value| value,
            .failure => |code| {
                if (code == r4os.abi.file_stream_error_exists) continue;
                sys.println("SERVMAN SAVE: stage creation failed.");
                return false;
            },
        };
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = offset + @min(bytes.len - offset, 16384);
            if (writer.write(bytes[offset..end]) != .ok) {
                _ = writer.abort();
                sys.println("SERVMAN SAVE: stage write failed.");
                return false;
            }
            offset = end;
        }
        if (writer.finish() != .ok) {
            _ = writer.abort();
            sys.println("SERVMAN SAVE: stage flush failed.");
            return false;
        }
        const staged = fingerprint(sys, stage) catch {
            sys.println("SERVMAN SAVE: stage verification failed; stage retained.");
            return false;
        };
        if (!staged.exists or staged.size != bytes.len or staged.checksum != checks.checksum(bytes) or !inventoryCurrent(sys, &inventory)) {
            _ = sys.fileDeleteIfMatch(stage, bytes.len, checks.checksum(bytes));
            sys.println("SERVMAN SAVE: changed inventory or incomplete stage; configuration not replaced.");
            return false;
        }
        var flags = r4os.r4sys.file_update_atomic_checked_flag_forward;
        if (old.exists) flags |= r4os.r4sys.file_update_atomic_checked_flag_target_existed | r4os.r4sys.file_update_atomic_checked_flag_old_known;
        const rc = sys.fileUpdateAtomicChecked(config_path, stage, backup, bytes.len, checks.checksum(bytes), old.size, old.checksum, flags);
        if (rc != 0) {
            sys.write("SERVMAN SAVE: atomic replacement not confirmed: ");
            sys.println(r4os.r4sys.fileUpdateAtomicCheckedResultName(rc));
            sys.write("  Stage: ");
            sys.println(stage);
            sys.write("  Backup: ");
            sys.println(backup);
            return false;
        }
        if (old.exists and sys.fileDeleteIfMatch(backup, old.size, old.checksum) < 0) {
            sys.write("SERVMAN SAVE: committed; backup cleanup pending: ");
            sys.println(backup);
        }
        if (verbose) {
            sys.write("SERVMAN SAVE: ");
            writeUnsigned(sys, bytes.len);
            sys.println(" Bytes atomar gespeichert.");
        }
        return true;
    }
    sys.println("SERVMAN SAVE: temporary paths busy.");
    return false;
}

fn readFileBytes(sys: *r4os.r4sys.Context, path: [*:0]const u8) ![]u8 {
    var info: r4os.abi.FileInfo = .{};
    const exists = sys.fileInfoRaw(path, &info);
    if (exists == 0) return error.NotFound;
    if (exists < 0) return error.Read;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(sys.allocator());
    var block: [16384]u8 = undefined;
    while (true) {
        const offset = std.math.cast(u32, bytes.items.len) orelse return error.OffsetRange;
        const raw = sys.fileReadAt(path, offset, &block);
        if (raw < 0 or raw > block.len) return error.Read;
        if (raw == 0) break;
        try bytes.appendSlice(sys.allocator(), block[0..@intCast(raw)]);
    }
    if (bytes.items.len != info.size) return error.Changed;
    var current: r4os.abi.FileInfo = .{};
    if (sys.fileInfoRaw(path, &current) <= 0 or current.size != info.size) return error.Changed;
    return bytes.toOwnedSlice(sys.allocator());
}

const Fingerprint = struct { exists: bool = false, size: u64 = 0, checksum: u32 = checks.checksum(&.{}) };
fn fingerprint(sys: *r4os.r4sys.Context, path: [*:0]const u8) !Fingerprint {
    var info: r4os.abi.FileInfo = .{};
    const exists = sys.fileInfoRaw(path, &info);
    if (exists < 0) return error.Read;
    if (exists == 0) return .{};
    var result: Fingerprint = .{ .exists = true };
    var block: [16384]u8 = undefined;
    while (true) {
        const offset = std.math.cast(u32, result.size) orelse return error.OffsetRange;
        const raw = sys.fileReadAt(path, offset, &block);
        if (raw < 0 or raw > block.len) return error.Read;
        if (raw == 0) return result;
        result.checksum = checks.checksumUpdate(result.checksum, block[0..@intCast(raw)]);
        result.size += @intCast(raw);
    }
}

fn inventoryCurrent(sys: *r4os.r4sys.Context, inventory: *const r4os.app_services.Inventory) bool {
    var cursor: r4os.abi.ServiceInventoryCursor = .{
        .revision = inventory.revision,
        .total = inventory.rows.len,
        .after_id = if (inventory.rows.len == 0) 0 else inventory.rows[inventory.rows.len - 1].registration_id,
        .flags = r4os.abi.service_inventory_dynamic | r4os.abi.service_inventory_end,
    };
    var row: [1]r4os.abi.ServiceInventoryRow = undefined;
    return sys.serviceInventoryPage(&cursor, &row) == 0 and cursor.flags & r4os.abi.service_inventory_end != 0;
}

fn parseConfig(sys: *r4os.r4sys.Context, data_raw: []const u8, report: *ConfigReport, dry_run: bool) void {
    const data = stripBom(data_raw);
    var line_start: usize = 0;
    while (line_start <= data.len) {
        var line_end = line_start;
        while (line_end < data.len and data[line_end] != '\n') : (line_end += 1) {}
        var line = data[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        parseConfigLine(sys, line, report, dry_run);
        if (report.error_code != 0) break;
        if (line_end >= data.len) break;
        line_start = line_end + 1;
    }
}

fn parseConfigLine(sys: *r4os.r4sys.Context, line_raw: []const u8, report: *ConfigReport, dry_run: bool) void {
    const line = trim(line_raw);
    if (line.len == 0 or line[0] == '#') return;
    report.lines += 1;
    if (!startsWithIgnoreCase(line, "SERVICE")) {
        report.invalid += 1;
        return;
    }

    var name_buf: [r4os.abi.service_name_bytes + 1]u8 = .{0} ** (r4os.abi.service_name_bytes + 1);
    var path_buf: [service_path_capacity]u8 = .{0} ** service_path_capacity;
    var args_buf: [r4os.abi.service_args_bytes + 1]u8 = .{0} ** (r4os.abi.service_args_bytes + 1);
    var desc_buf: [r4os.abi.service_description_bytes + 1]u8 = .{0} ** (r4os.abi.service_description_bytes + 1);
    var mode: u32 = r4os.abi.service_start_manual;
    var enabled = true;

    var field_start: usize = 0;
    var first = true;
    while (field_start <= line.len) {
        var field_end = field_start;
        while (field_end < line.len and line[field_end] != ';') : (field_end += 1) {}
        const field = trim(line[field_start..field_end]);
        if (field.len > 0) {
            if (first and tokenEquals(field, "SERVICE")) {
                first = false;
            } else if (indexOf(field, '=')) |eq| {
                const key = trim(field[0..eq]);
                const value = trim(field[eq + 1 ..]);
                if (tokenEquals(key, "name")) {
                    if (!copyZChecked(name_buf[0..], value)) {
                        report.invalid += 1;
                        return;
                    }
                } else if (tokenEquals(key, "path")) {
                    if (!copyZChecked(path_buf[0..], value)) {
                        report.invalid += 1;
                        return;
                    }
                } else if (tokenEquals(key, "args")) {
                    if (!copyZChecked(args_buf[0..], value)) {
                        report.invalid += 1;
                        return;
                    }
                } else if (tokenEquals(key, "description")) {
                    if (!copyZChecked(desc_buf[0..], value)) {
                        report.invalid += 1;
                        return;
                    }
                } else if (tokenEquals(key, "start")) {
                    if (tokenEquals(value, "auto")) mode = r4os.abi.service_start_auto else if (tokenEquals(value, "disabled")) mode = r4os.abi.service_start_disabled else if (tokenEquals(value, "manual")) mode = r4os.abi.service_start_manual else {
                        report.invalid += 1;
                        return;
                    }
                } else if (tokenEquals(key, "enabled")) {
                    if (tokenEquals(value, "yes") or tokenEquals(value, "true") or tokenEquals(value, "on") or tokenEquals(value, "1")) enabled = true else if (tokenEquals(value, "no") or tokenEquals(value, "false") or tokenEquals(value, "off") or tokenEquals(value, "0")) enabled = false else {
                        report.invalid += 1;
                        return;
                    }
                }
                first = false;
            } else {
                report.invalid += 1;
                return;
            }
        }
        if (field_end >= line.len) break;
        field_start = field_end + 1;
    }

    const name = spanZ(name_buf[0..]);
    const path = spanZ(path_buf[0..]);
    if (name.len == 0 or path.len == 0) {
        report.invalid += 1;
        return;
    }
    if (dry_run) return;

    var info: r4os.abi.ServiceInfo = .{};
    const final_mode = if (!enabled) r4os.abi.service_start_disabled else mode;
    const rc = sys.serviceInstall(@ptrCast(name_buf[0..].ptr), @ptrCast(path_buf[0..].ptr), @ptrCast(args_buf[0..].ptr), final_mode, @ptrCast(desc_buf[0..].ptr), &info);
    if (rc == r4os.abi.service_api_result_ok) {
        report.loaded += 1;
    } else if (rc == r4os.abi.service_api_result_duplicate) {
        report.duplicate += 1;
    } else if (rc == r4os.abi.service_api_result_full or rc == r4os.abi.service_api_result_memory or rc == r4os.abi.service_api_result_exhausted) {
        report.error_code = rc;
    } else {
        report.invalid += 1;
    }
}

fn readInventory(sys: *r4os.r4sys.Context) ?r4os.app_services.Inventory {
    return switch (r4os.app_services.readInventory(sys, sys.allocator())) {
        .complete => |inventory| inventory,
        .failure => |rc| {
            sys.write("SERVMAN: service enumeration failed: ");
            sys.println(resultName(rc));
            return null;
        },
    };
}

fn findRow(rows: []const r4os.abi.ServiceInventoryRow, name: []const u8) ?*const r4os.abi.ServiceInventoryRow {
    for (rows) |*row| if (std.ascii.eqlIgnoreCase(spanZ(&row.info.name), name)) return row;
    return null;
}

fn controlRow(sys: *r4os.r4sys.Context, row: *const r4os.abi.ServiceInventoryRow, action: Action) i32 {
    var request: r4os.abi.ServiceControlRequest = .{
        .registration_id = row.registration_id,
        .start_generation = row.start_generation,
        .process = row.process,
    };
    switch (action) {
        .start => request.operation = r4os.abi.service_control_start,
        .stop => {
            request.operation = r4os.abi.service_control_stop;
            request.timeout_ticks = 40;
        },
        .restart => request.operation = r4os.abi.service_control_restart,
        .manual, .auto, .disable => {
            request.operation = r4os.abi.service_control_mode;
            request.mode = switch (action) {
                .manual => r4os.abi.service_start_manual,
                .auto => r4os.abi.service_start_auto,
                else => r4os.abi.service_start_disabled,
            };
        },
        .remove => request.operation = r4os.abi.service_control_remove,
    }
    return sys.serviceControlBound(&request);
}

fn renderConfig(allocator: std.mem.Allocator, rows: []const r4os.abi.ServiceInventoryRow) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\xEF\xBB\xBF# R4OS SERVICES.R4S\r\n# Managed by SERVMAN.R4X\r\n");
    for (rows) |detail| {
        try out.appendSlice(allocator, "SERVICE;name=");
        try out.appendSlice(allocator, spanZ(&detail.info.name));
        try out.appendSlice(allocator, ";path=");
        try out.appendSlice(allocator, spanZ(&detail.path));
        const args = spanZ(detail.args[0..]);
        if (args.len > 0) {
            try out.appendSlice(allocator, ";args=");
            try out.appendSlice(allocator, args);
        }
        try out.appendSlice(allocator, ";start=");
        try out.appendSlice(allocator, serviceStartName(detail.info.start_mode));
        try out.appendSlice(allocator, ";enabled=");
        try out.appendSlice(allocator, if (detail.info.start_mode == r4os.abi.service_start_disabled) "no" else "yes");
        const desc = spanZ(detail.description[0..]);
        if (desc.len > 0) {
            try out.appendSlice(allocator, ";description=");
            try out.appendSlice(allocator, desc);
        }
        try out.appendSlice(allocator, "\r\n");
    }
    return out.toOwnedSlice(allocator);
}

fn printConfigReport(sys: *r4os.r4sys.Context, label: []const u8, report: *const ConfigReport) void {
    sys.write("SERVMAN ");
    sys.write(label);
    sys.write(": lines=");
    writeUnsigned(sys, report.lines);
    sys.write(" loaded=");
    writeUnsigned(sys, report.loaded);
    sys.write(" duplicate=");
    writeUnsigned(sys, report.duplicate);
    sys.write(" invalid=");
    writeUnsigned(sys, report.invalid);
    if (report.missing) sys.write(" missing=yes");
    if (report.error_code != 0) {
        sys.write(" error=");
        sys.write(resultName(report.error_code));
    }
    sys.println("");
}

fn startAutoServices(sys: *r4os.r4sys.Context) i32 {
    var attempted: u32 = 0;
    var started: u32 = 0;
    var failed: u32 = 0;
    var inventory = readInventory(sys) orelse return 1;
    defer inventory.deinit();
    for (inventory.rows) |*detail| {
        if (detail.info.start_mode != r4os.abi.service_start_auto) continue;

        attempted += 1;
        const name = spanZ(detail.info.name[0..]);
        const start_rc = controlRow(sys, detail, .start);
        if (start_rc == r4os.abi.service_api_result_ok) {
            started += 1;
        } else {
            failed += 1;
            printCommandResult(sys, "BOOT", name, start_rc);
        }
    }

    sys.write("SERVMAN BOOT: autostart attempted=");
    writeUnsigned(sys, attempted);
    sys.write(" started=");
    writeUnsigned(sys, started);
    sys.write(" failed=");
    writeUnsigned(sys, failed);
    sys.println("");
    return 0;
}

fn printList(sys: *r4os.r4sys.Context) i32 {
    var inventory = readInventory(sys) orelse return 1;
    defer inventory.deinit();
    sys.println("SERVMAN Services");
    for (inventory.rows) |*detail| printServiceLine(sys, detail);
    if (inventory.rows.len == 0) sys.println("  No registered services.");
    return 0;
}

fn printServiceLine(sys: *r4os.r4sys.Context, detail: *const r4os.abi.ServiceInventoryRow) void {
    sys.write("  ");
    sys.write(spanZ(detail.info.name[0..]));
    sys.write(" state=");
    sys.write(serviceStateName(detail.info.state));
    sys.write(" start=");
    sys.write(serviceStartName(detail.info.start_mode));
    sys.write(" path=");
    sys.write(spanZ(detail.path[0..]));
    if ((detail.info.flags & r4os.abi.service_api_flag_endpoint) != 0) {
        sys.write(" q=");
        writeUnsigned(sys, detail.info.queue_used);
        sys.write("/");
        writeUnsigned(sys, detail.info.queue_depth);
        sys.write(" workers=");
        writeUnsigned(sys, detail.info.active_workers);
    }
    sys.println("");
}

fn printServiceDetail(sys: *r4os.r4sys.Context, detail: *const r4os.abi.ServiceInventoryRow, process: *const r4os.abi.ProgramProcessHandle) void {
    sys.write("Name: ");
    sys.println(spanZ(detail.info.name[0..]));
    sys.write("Status: ");
    sys.println(serviceStateName(detail.info.state));
    sys.write("Start: ");
    sys.println(serviceStartName(detail.info.start_mode));
    sys.write("Instance: ");
    writeUnsigned(sys, detail.info.instance_id);
    sys.println("");
    if (detail.info.instance_id != 0 and process.instance_id == detail.info.instance_id and sys.base.hasDevFn("memory_summary")) {
        var instance: r4os.abi.ProgramInstanceInfo = .{};
        if (sys.programHandleStatus(process, &instance) == 0) {
            sys.write("Memory: ");
            sys.write(memoryProfileName(instance.memory_profile));
            sys.write(" reserveMB=");
            writeUnsigned(sys, instance.memory_reserved_limit / 1024 / 1024);
            sys.write(" commitMB=");
            writeUnsigned(sys, instance.memory_committed_limit / 1024 / 1024);
            sys.write(" usedKB=");
            writeUnsigned(sys, instance.memory_committed_bytes / 1024);
            sys.println("");
        }
    }
    sys.write("ExitCode: ");
    sys.printI32(detail.info.exit_code);
    sys.println("");
    sys.write("Restarts: ");
    writeUnsigned(sys, detail.info.restart_count);
    sys.println("");
    sys.write("Path: ");
    sys.println(spanZ(detail.path[0..]));
    sys.write("Args: ");
    sys.println(spanZ(detail.args[0..]));
    sys.write("Description: ");
    sys.println(spanZ(detail.description[0..]));
    sys.write("LastError: ");
    sys.println(spanZ(detail.info.last_error[0..]));
    if ((detail.info.flags & r4os.abi.service_api_flag_endpoint) != 0) {
        sys.write("EndpointQueue: used=");
        writeUnsigned(sys, detail.info.queue_used);
        sys.write("/");
        writeUnsigned(sys, detail.info.queue_depth);
        sys.write(" high=");
        writeUnsigned(sys, detail.info.queue_high_water);
        sys.write(" workers=");
        writeUnsigned(sys, detail.info.active_workers);
        sys.write("/");
        writeUnsigned(sys, detail.info.max_active_workers);
        sys.write(" open=");
        writeUnsigned(sys, detail.info.open_handles);
        sys.println("");
        sys.write("EndpointErrors: busy=");
        writeUnsigned(sys, detail.info.busy_rejections);
        sys.write(" timeout=");
        writeUnsigned(sys, detail.info.timeouts);
        sys.write(" cancel=");
        writeUnsigned(sys, detail.info.cancellations);
        sys.println("");
    }
}

fn memoryProfileName(profile: u8) []const u8 {
    return switch (profile) {
        r4os.abi.memory_profile_tiny => "tiny",
        r4os.abi.memory_profile_normal => "normal",
        r4os.abi.memory_profile_desktop => "desktop",
        r4os.abi.memory_profile_service => "service",
        r4os.abi.memory_profile_large_service => "large-service",
        r4os.abi.memory_profile_build_tool => "build-tool",
        r4os.abi.memory_profile_browser => "browser",
        r4os.abi.memory_profile_workstation => "workstation",
        else => "unknown",
    };
}

fn printEndpointStatus(sys: *r4os.r4sys.Context, name: [*:0]const u8) void {
    var info: r4os.abi.ServiceInfo = .{};
    const open_rc = sys.serviceOpen(name, &info);
    if (open_rc != r4os.abi.service_api_result_ok or info.handle == 0) return;
    defer _ = sys.serviceClose(info.handle);

    var header: r4os.abi.ServiceMessageHeader = .{};
    var response: [r4os.abi.service_api_max_payload]u8 = undefined;
    var got: i32 = 0;
    var attempt: u32 = 0;
    while (attempt < endpoint_status_attempts) : (attempt += 1) {
        header = .{};
        got = sys.serviceCall(info.handle, endpoint_status_op, "STATUS", &header, response[0..], sys.ticksFromMilliseconds(endpoint_status_timeout_ms));
        if (got > 0 and header.status == r4os.abi.service_api_result_ok) break;
        sys.sleepTicks(sys.ticksFromMilliseconds(50));
    }
    if (got <= 0 or header.status != r4os.abi.service_api_result_ok) return;
    const len: usize = @intCast(got);
    if (!isPrintableEndpointStatus(response[0..len])) return;
    sys.write("Endpoint: ");
    sys.write(response[0..len]);
    sys.println("");
    if (hasEndpointSessionDiagnostics(response[0..len])) {
        sys.write("EndpointSessions: workers=");
        sys.write(if (containsBytes(response[0..len], "workers=") or containsBytes(response[0..len], "worker_started=")) "yes" else "no");
        sys.write(" sessions=");
        sys.write(if (containsBytes(response[0..len], "sessions=") or containsBytes(response[0..len], "session_handles=")) "yes" else "no");
        sys.write(" slow=");
        sys.write(if (containsBytes(response[0..len], "slow=")) "yes" else "no");
        sys.write(" timeouts=");
        sys.write(if (containsBytes(response[0..len], "timeouts=") or containsBytes(response[0..len], "long_req=")) "yes" else "no");
        sys.println("");
    }
}

fn hasEndpointSessionDiagnostics(value: []const u8) bool {
    return containsBytes(value, "workers=") or
        containsBytes(value, "worker_started=") or
        containsBytes(value, "session_handles=") or
        containsBytes(value, "last_worker=");
}

fn isPrintableEndpointStatus(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (ch == '\r' or ch == '\n' or ch == '\t') continue;
        if (ch < 0x20 or ch > 0x7e) return false;
    }
    return true;
}

fn containsBytes(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and haystack[i + j] == needle[j]) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

fn printCommandResult(sys: *r4os.r4sys.Context, action: []const u8, name: []const u8, rc: i32) void {
    sys.write("SERVMAN ");
    sys.write(action);
    sys.write(" ");
    sys.write(name);
    sys.write(": ");
    sys.write(resultName(rc));
    sys.write(" (");
    sys.printI32(rc);
    sys.println(")");
}

fn actionName(action: Action) []const u8 {
    return switch (action) {
        .start => "START",
        .stop => "STOP",
        .restart => "RESTART",
        .manual => "MANUAL",
        .auto => "AUTO",
        .disable => "DISABLE",
        .remove => "REMOVE",
    };
}

fn serviceStateName(raw: u32) []const u8 {
    return switch (raw) {
        r4os.abi.service_state_stopped => "stopped",
        r4os.abi.service_state_starting => "starting",
        r4os.abi.service_state_running => "running",
        r4os.abi.service_state_stopping => "stopping",
        r4os.abi.service_state_failed => "failed",
        r4os.abi.service_state_disabled => "disabled",
        else => "empty",
    };
}

fn serviceStartName(raw: u32) []const u8 {
    return switch (raw) {
        r4os.abi.service_start_auto => "auto",
        r4os.abi.service_start_disabled => "disabled",
        else => "manual",
    };
}

fn resultName(rc: i32) []const u8 {
    return switch (rc) {
        r4os.abi.service_api_result_ok => "OK",
        r4os.abi.service_api_result_memory => "out-of-memory",
        r4os.abi.service_api_result_exhausted => "identity-exhausted",
        r4os.abi.service_api_result_restart => "inventory-changed",
        r4os.abi.service_api_result_invalid => "invalid",
        r4os.abi.service_api_result_not_found => "not-found",
        r4os.abi.service_api_result_not_running => "not-running",
        r4os.abi.service_api_result_no_endpoint => "no-endpoint",
        r4os.abi.service_api_result_payload_too_large => "payload-too-large",
        r4os.abi.service_api_result_buffer_too_small => "buffer-too-small",
        r4os.abi.service_api_result_busy => "busy",
        r4os.abi.service_api_result_timeout => "timeout",
        r4os.abi.service_api_result_bad_handle => "bad-handle",
        r4os.abi.service_api_result_full => "full",
        r4os.abi.service_api_result_bad_op => "bad-op",
        r4os.abi.service_api_result_duplicate => "duplicate",
        r4os.abi.service_api_result_bad_path => "bad-path",
        r4os.abi.service_api_result_config_io => "config-io",
        r4os.abi.service_api_result_running => "running",
        r4os.abi.service_api_result_disabled => "disabled",
        r4os.abi.service_api_result_spawn_failed => "spawn-failed",
        r4os.abi.service_api_result_stop_failed => "stop-failed",
        // 0.60.29: refused because the caller runs inside that very service,
        // e.g. `SERVMAN RESTART SSHD` issued over an SSH session.
        r4os.abi.service_api_result_self_restart => "self-restart-refused",
        else => "unknown",
    };
}

fn fail(sys: *r4os.r4sys.Context, label: []const u8) i32 {
    sys.write("SERVMAN FAILED: ");
    sys.println(label);
    return 1;
}

fn failCode(sys: *r4os.r4sys.Context, label: []const u8, code: i32) i32 {
    sys.write("SERVMAN FAILED: ");
    sys.write(label);
    sys.write(" code=");
    sys.printI32(code);
    sys.println("");
    return 1;
}

fn writeUnsigned(sys: *r4os.r4sys.Context, value: u64) void {
    var tmp: [32]u8 = undefined;
    var n = value;
    var pos: usize = tmp.len;
    if (n == 0) {
        pos -= 1;
        tmp[pos] = '0';
    } else {
        while (n > 0 and pos > 0) {
            pos -= 1;
            tmp[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
    }
    sys.write(tmp[pos..]);
}

fn takeToken(s_raw: []const u8) ?Token {
    const s = trim(s_raw);
    if (s.len == 0) return null;
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t') : (end += 1) {}
    return .{ .token = s[0..end], .rest = trim(s[end..]) };
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    return s[start..end];
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn spanZ(buffer: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return buffer[0..len];
}

fn makeZ(out: []u8, value: []const u8) ?[*:0]const u8 {
    if (out.len == 0 or value.len >= out.len) return null;
    @memset(out, 0);
    if (value.len > 0) @memcpy(out[0..value.len], value);
    return @ptrCast(out.ptr);
}

fn setZ(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const len = @min(out.len - 1, value.len);
    if (len > 0) @memcpy(out[0..len], value[0..len]);
}

fn copyZChecked(out: []u8, value: []const u8) bool {
    if (out.len == 0 or value.len >= out.len) return false;
    @memset(out, 0);
    if (value.len > 0) @memcpy(out[0..value.len], value);
    return true;
}

fn append(out: []u8, pos: *usize, value: []const u8) bool {
    if (pos.* + value.len > out.len) return false;
    if (value.len > 0) @memcpy(out[pos.* .. pos.* + value.len], value);
    pos.* += value.len;
    return true;
}

fn tokenEquals(a: []const u8, b: []const u8) bool {
    return sameBytesIgnoreCase(trimPrefix(a), trimPrefix(b));
}

fn trimPrefix(s: []const u8) []const u8 {
    if (s.len > 0 and (s[0] == '/' or s[0] == '-')) return s[1..];
    return s;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and sameBytesIgnoreCase(s[0..prefix.len], prefix);
}

fn sameBytesIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn stripBom(data: []const u8) []const u8 {
    if (data.len >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) return data[3..];
    return data;
}

fn indexOf(s: []const u8, ch: u8) ?usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == ch) return i;
    }
    return null;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

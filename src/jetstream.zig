// Copyright 2024 oiegrant
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Minimal JetStream bindings for nats.c v3.x.
//!
//! Provides stream creation (idempotent add-or-update) and JetStream
//! publish (synchronous).  Async publish and consumer management are
//! follow-up items.

const std = @import("std");
const nats_c = @import("./nats_c.zig").nats_c;
const Status = @import("./error.zig").Status;
const Error = @import("./error.zig").Error;
const Connection = @import("./connection.zig").Connection;

// ── Stream configuration ───────────────────────────────────────────────────

/// Retention policies (maps to jsRetentionPolicy).
pub const RetentionPolicy = enum(c_uint) {
    limits = 0,
    interest = 1,
    work_queue = 2,
};

/// Storage backends (maps to jsStorageType).
pub const StorageType = enum(c_uint) {
    file = 0,
    memory = 1,
};

/// Discard policies (maps to jsDiscardPolicy).
pub const DiscardPolicy = enum(c_uint) {
    old = 0,
    new = 1,
};

/// Zig-friendly stream configuration.
/// `subjects` must be null-terminated C strings (`[*:0]const u8`).
pub const StreamConfig = struct {
    /// Stream name — alphanumeric and dashes only.
    name: [*:0]const u8,
    /// Subjects this stream captures, e.g. `&.{"markets.*", "markets.>"}`.
    subjects: []const [*:0]const u8,
    /// Maximum age of stored messages in nanoseconds.  0 = unlimited.
    max_age_ns: i64 = 0,
    retention: RetentionPolicy = .limits,
    storage: StorageType = .file,
    /// 0 = unlimited.
    max_msgs: i64 = -1,
    /// 0 = unlimited bytes.
    max_bytes: i64 = -1,
    replicas: i64 = 1,
    discard: DiscardPolicy = .old,
};

// ── JetStream context ──────────────────────────────────────────────────────

/// A JetStream context.  Must not be used after `destroy()`.
pub const JetStream = opaque {
    /// Create a JetStream context from an existing NATS connection.
    /// The context is independent of the connection lifecycle; destroy it
    /// before the connection to avoid use-after-free.
    pub fn init(conn: *Connection) Error!*JetStream {
        var js: *JetStream = undefined;
        var opts: nats_c.jsOptions = undefined;
        _ = nats_c.jsOptions_Init(&opts);
        const status = Status.fromInt(
            nats_c.natsConnection_JetStream(@ptrCast(&js), @ptrCast(conn), &opts),
        );
        return status.toError() orelse js;
    }

    pub fn destroy(self: *JetStream) void {
        nats_c.jsCtx_Destroy(@ptrCast(self));
    }

    // ── Stream management ────────────────────────────────────────────────

    /// Idempotent stream setup: tries to create the stream; if the stream
    /// already exists (`JSStreamNameExistErr`) it updates it instead.
    pub fn ensureStream(self: *JetStream, cfg: StreamConfig) Error!void {
        var c_cfg: nats_c.jsStreamConfig = undefined;
        _ = nats_c.jsStreamConfig_Init(&c_cfg);

        c_cfg.Name = cfg.name;
        // subjects.ptr is [*]const [*:0]const u8.
        // The C field is char** (not const char**), so cast away outer const.
        // Safe: js_AddStream / js_UpdateStream only read the subjects array.
        c_cfg.Subjects = @ptrCast(@constCast(cfg.subjects.ptr));
        c_cfg.SubjectsLen = @intCast(cfg.subjects.len);
        c_cfg.MaxAge = cfg.max_age_ns;
        c_cfg.Retention = @intFromEnum(cfg.retention);
        c_cfg.Storage = @intFromEnum(cfg.storage);
        c_cfg.MaxMsgs = cfg.max_msgs;
        c_cfg.MaxBytes = cfg.max_bytes;
        c_cfg.Replicas = cfg.replicas;
        c_cfg.Discard = @intFromEnum(cfg.discard);

        var err_code: nats_c.jsErrCode = 0;
        var si: ?*nats_c.jsStreamInfo = null;

        var status = Status.fromInt(
            nats_c.js_AddStream(&si, @ptrCast(self), &c_cfg, null, &err_code),
        );
        if (si != null) nats_c.jsStreamInfo_Destroy(si);

        // Stream already exists — update it to apply any config changes.
        if (status != .okay and err_code == nats_c.JSStreamNameExistErr) {
            si = null;
            status = Status.fromInt(
                nats_c.js_UpdateStream(&si, @ptrCast(self), &c_cfg, null, &err_code),
            );
            if (si != null) nats_c.jsStreamInfo_Destroy(si);
        }

        return status.raise();
    }

    // ── Publishing ───────────────────────────────────────────────────────

    /// Synchronous JetStream publish.  Blocks until the server acknowledges
    /// the message (at-least-once delivery guarantee).
    ///
    /// Prefer this for correctness-critical paths (market state updates).
    /// For high-throughput paths where a brief gap is tolerable, use
    /// `publishAsync`.
    pub fn publish(
        self: *JetStream,
        subject: [:0]const u8,
        data: []const u8,
    ) Error!void {
        var ack: ?*nats_c.jsPubAck = null;
        var err_code: nats_c.jsErrCode = 0;
        const status = Status.fromInt(nats_c.js_Publish(
            &ack,
            @ptrCast(self),
            subject.ptr,
            data.ptr,
            @intCast(data.len),
            null,
            &err_code,
        ));
        if (ack != null) nats_c.jsPubAck_Destroy(ack);
        return status.raise();
    }

    /// Wait for all outstanding async JetStream publishes to be acknowledged
    /// by the server.  Call this after a batch of `publishAsync` calls to
    /// ensure at-least-once delivery before the program continues or exits.
    pub fn publishAsyncComplete(self: *JetStream) Error!void {
        const status = Status.fromInt(nats_c.js_PublishAsyncComplete(@ptrCast(self), null));
        return status.raise();
    }

    /// Asynchronous JetStream publish.  Enqueues the message for background
    /// acknowledgment.  Faster than `publish`, but requires the caller to
    /// call `publishAsyncComplete` after the batch to guarantee delivery.
    pub fn publishAsync(
        self: *JetStream,
        subject: [:0]const u8,
        data: []const u8,
    ) Error!void {
        const status = Status.fromInt(nats_c.js_PublishAsync(
            @ptrCast(self),
            subject.ptr,
            data.ptr,
            @intCast(data.len),
            null,
        ));
        return status.raise();
    }
};

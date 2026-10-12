//! mock: working mocks of APIs, built at run time from a model and served in memory, inside the
//! process that uses them.
//!
//! Exported so far: the model types a test builds, mock's own JSON `Value`, and the types of the
//! load report. docs/design.md describes the whole library.

const std = @import("std");
const compile = @import("compile.zig");
const model = @import("model.zig");
const value = @import("value.zig");

pub const Model = model.Model;
pub const Service = model.Service;
pub const Operation = model.Operation;
pub const Parameter = model.Parameter;
pub const Style = model.Style;
pub const RequestBody = model.RequestBody;
pub const Response = model.Response;
pub const Status = model.Status;
pub const Header = model.Header;
pub const MediaContent = model.MediaContent;
pub const Example = model.Example;
pub const Schema = model.Schema;
pub const JsonType = model.JsonType;
pub const TypeSet = model.TypeSet;
pub const Property = model.Property;
pub const Additional = model.Additional;
pub const SecurityScheme = model.SecurityScheme;
pub const Requirement = model.Requirement;
pub const SchemeUse = model.SchemeUse;
pub const Identity = model.Identity;
pub const KeySpec = model.KeySpec;
pub const Alg = model.Alg;
pub const TestUser = model.TestUser;
pub const Client = model.Client;
pub const Defect = model.Defect;
pub const ApiKey = model.ApiKey;

pub const Value = value.Value;
pub const Number = value.Number;
pub const Member = value.Member;

pub const Options = compile.Options;
pub const Diagnostics = compile.Diagnostics;
pub const Refusal = compile.Refusal;

test {
    std.testing.refAllDecls(@This());
    _ = compile;
    _ = model;
    _ = value;
}

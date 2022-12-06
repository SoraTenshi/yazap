const Parser = @This();

const std = @import("std");
const args_context = @import("args_context.zig");
const Arg = @import("Arg.zig");
const Command = @import("Command.zig");
const ErrorBuilder = @import("ErrorBuilder.zig");
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;

const mem = std.mem;
const Allocator = std.mem.Allocator;
const OptionTuple = std.meta.Tuple(&[_]type{ []const u8, ?[]const u8 });
const ArgsContext = args_context.ArgsContext;
const MatchedSubCommand = args_context.MatchedSubCommand;

pub const Error = error{
    UnknownFlag,
    UnknownCommand,
    CommandArgumentNotProvided,
    CommandSubcommandNotProvided,
    FlagValueNotProvided,
    UnneededAttachedValue,
    UnneededEmptyAttachedValue,
    EmptyFlagValueNotAllowed,
    ProvidedValueIsNotValidOption,
    TooFewArgValue,
    TooManyArgValue,
} || Allocator.Error;

const InternalError = error{
    ArgValueNotProvided,
    EmptyArgValueNotAllowed,
} || Error;

const ShortOption = struct {
    name: []const u8,
    value: ?[]const u8,
    cursor: usize,

    pub fn init(name: []const u8, value: ?[]const u8) ShortOption {
        return ShortOption{
            .name = name,
            .value = value,
            .cursor = 0,
        };
    }

    pub fn next(self: *ShortOption) ?*const u8 {
        if (self.isAtEnd()) return null;
        defer self.cursor += 1;

        return &self.name[self.cursor];
    }

    pub fn getValue(self: *ShortOption) ?[]const u8 {
        return (self.value);
    }

    pub fn getRemainTail(self: *ShortOption) ?[]const u8 {
        if (self.isAtEnd()) return null;
        defer self.cursor = self.name.len;

        return self.name[self.cursor..];
    }

    pub fn hasValue(self: *ShortOption) bool {
        if (self.value) |v| {
            return (v.len >= 1);
        } else {
            return false;
        }
    }

    pub fn hasEmptyValue(self: *ShortOption) bool {
        if (self.value) |v| {
            return (v.len == 0);
        } else {
            return false;
        }
    }

    pub fn hasTail(self: *ShortOption) bool {
        return (self.value == null and self.name.len > 1);
    }

    fn isAtEnd(self: *ShortOption) bool {
        return (self.cursor >= self.name.len);
    }
};

allocator: Allocator,
cmd: *const Command,
tokenizer: Tokenizer,
args_ctx: ArgsContext,
err_builder: ErrorBuilder,
cmd_args_idx: usize,
consume_cmd_args: bool,

pub fn init(
    allocator: Allocator,
    tokenizer: Tokenizer,
    command: *const Command,
) Parser {
    return Parser{
        .allocator = allocator,
        .tokenizer = tokenizer,
        .args_ctx = ArgsContext.init(allocator),
        .err_builder = ErrorBuilder.init(),
        .cmd = command,
        .cmd_args_idx = 0,
        .consume_cmd_args = (command.isSettingApplied(.takes_value) and command.countArgs() >= 1),
    };
}

pub fn parse(self: *Parser) Error!ArgsContext {
    errdefer self.args_ctx.deinit();
    self.err_builder.setCmd(self.cmd);

    while (self.tokenizer.nextToken()) |*token| {
        self.err_builder.setProvidedArg(token.value);

        if (mem.eql(u8, token.value, "help") or mem.eql(u8, token.value, "h")) {
            // Check whether help is enabled for `cmd`
            if (self.cmd.isSettingApplied(.enable_help)) {
                try self.args_ctx.putMatchedArg(&Arg.new("help"), .none);
                break;
            } else {
                // Return error?
            }
        }

        if (self.consume_cmd_args) {
            try self.consumeCommandArg(token);
            // Skip current token if it has been consumed otherwise further process it
            if (self.consume_cmd_args) continue;
        }

        if (token.isShortOption() or token.isLongOption()) {
            self.parseOption(token) catch |err| switch (err) {
                InternalError.ArgValueNotProvided => {
                    self.err_builder.setErr(Error.FlagValueNotProvided);
                    return self.err_builder.err;
                },
                InternalError.EmptyArgValueNotAllowed => {
                    self.err_builder.setErr(Error.EmptyFlagValueNotAllowed);
                    return self.err_builder.err;
                },
                else => |e| {
                    self.err_builder.setErr(e);
                    return e;
                },
            };
        } else {
            const subcmd = try self.parseSubCommand(token.value);
            try self.args_ctx.setSubcommand(subcmd);
        }
    }

    if (!(self.args_ctx.isPresent("help"))) {
        if (self.cmd.isSettingApplied(.subcommand_required) and self.args_ctx.subcommand == null) {
            self.err_builder.setErr(Error.CommandSubcommandNotProvided);
            return self.err_builder.err;
        }
    }
    return self.args_ctx;
}

fn consumeCommandArg(self: *Parser, token: *const Token) Error!void {
    // All positional arguments has been consumed
    if (self.cmd_args_idx >= self.cmd.countArgs()) {
        self.consume_cmd_args = false;
        return;
    }

    // Looks like we found a option
    if (token.tag != .some_argument) {
        if (self.cmd.isSettingApplied(.arg_required) and (self.args_ctx.args.count() == 0)) {
            self.err_builder.setErr(Error.CommandArgumentNotProvided);
            return self.err_builder.err;
        } else {
            self.consume_cmd_args = false;
            return;
        }
    }
    const arg = &self.cmd.args.items[self.cmd_args_idx];
    self.cmd_args_idx += 1;

    self.processValue(arg, token.value, false) catch |err| switch (err) {
        InternalError.ArgValueNotProvided,
        InternalError.EmptyArgValueNotAllowed,
        => return,
        else => |e| {
            self.err_builder.setErr(e);
            return e;
        },
    };
}

fn parseOption(self: *Parser, token: *const Token) InternalError!void {
    if (token.isShortOption()) {
        try self.parseShortOption(token);
    } else if (token.isLongOption()) {
        try self.parseLongOption(token);
    }
}

fn parseShortOption(self: *Parser, token: *const Token) InternalError!void {
    const option_tuple = optionTokenToOptionTuple(token);
    var short_option = ShortOption.init(option_tuple[0], option_tuple[1]);

    while (short_option.next()) |option| {
        self.err_builder.setProvidedArg(@as(*const [1]u8, option));

        const arg = self.cmd.findShortOption(option.*) orelse {
            return Error.UnknownFlag;
        };
        self.err_builder.setArg(arg);

        if (!(arg.isSettingApplied(.takes_value))) {
            if (short_option.hasValue()) {
                return Error.UnneededAttachedValue;
            } else if (short_option.hasEmptyValue()) {
                return Error.UnneededEmptyAttachedValue;
            } else {
                try self.args_ctx.putMatchedArg(arg, .none);
                continue;
            }
        }

        const value = short_option.getValue() orelse blk: {
            if (short_option.hasTail()) {
                // Take remain option/tail as value
                //
                // For ex: if -xyz is passed and -x takes value
                // take yz as value even if they are passed as options
                break :blk short_option.getRemainTail();
            } else {
                break :blk null;
            }
        };
        try self.consumeArgValue(arg, value);
    }
}

fn parseLongOption(self: *Parser, token: *const Token) InternalError!void {
    const option_tuple = optionTokenToOptionTuple(token);
    self.err_builder.setProvidedArg(option_tuple[0]);

    const arg = self.cmd.findLongOption(option_tuple[0]) orelse {
        return Error.UnknownFlag;
    };
    self.err_builder.setArg(arg);

    if (!(arg.isSettingApplied(.takes_value))) {
        if (option_tuple[1] != null) {
            return Error.UnneededAttachedValue;
        } else {
            return self.args_ctx.putMatchedArg(arg, .none);
        }
    }
    return self.consumeArgValue(arg, option_tuple[1]);
}

// Converts a option token to a tuple holding a option name and an optional value
//
// --option, -f, -fgh                     => (option, null), (f, null), (fgh, null)
// --option=value, -f=value, -fgh=value   => (option, value), (f, value), (fgh, value)
// --option=, -f=, -fgh=                  => (option, ""), (f, ""), (fgh, "")
fn optionTokenToOptionTuple(token: *const Token) OptionTuple {
    var kv_iter = mem.tokenize(u8, token.value, "=");

    return switch (token.tag) {
        .short_option,
        .short_option_with_tail,
        .long_option,
        => .{ token.value, null },

        .short_option_with_value,
        .short_option_with_empty_value,
        .short_options_with_value,
        .short_options_with_empty_value,
        .long_option_with_value,
        .long_option_with_empty_value,
        => .{ kv_iter.next().?, kv_iter.rest() },

        else => unreachable,
    };
}

fn consumeArgValue(
    self: *Parser,
    arg: *const Arg,
    attached_value: ?[]const u8,
) InternalError!void {
    // Only set arg if caller didn't set it already
    if (self.err_builder.arg == null) self.err_builder.setArg(arg);

    if (attached_value) |val| {
        return self.processValue(arg, val, true);
    } else {
        const value = self.tokenizer.nextNonOptionArg() orelse return InternalError.ArgValueNotProvided;
        return self.processValue(arg, value, false);
    }
}

fn processValue(
    self: *Parser,
    arg: *const Arg,
    value: []const u8,
    is_attached_value: bool,
) InternalError!void {
    self.err_builder.setProvidedArg(value);

    if (arg.values_delimiter) |delimiter| {
        if (mem.containsAtLeast(u8, value, 1, delimiter)) {
            var values_iter = mem.split(u8, value, delimiter);
            var values = std.ArrayList([]const u8).init(self.allocator);
            errdefer values.deinit();

            while (values_iter.next()) |val| {
                try self.verifyAndAppendValue(arg, &values, val);
            }
            return self.args_ctx.putMatchedArg(arg, .{ .many = values });
        }
    }

    if (is_attached_value) {
        // When values delimiter is not set and multiple values are passed
        // by attaching it then take the entire values as single value
        //
        // For ex: -f=v1,v2
        // option = f
        // value = v1,v2
        if (arg.verifyValueInAllowedValues(value)) {
            return self.args_ctx.putMatchedArg(arg, .{ .single = value });
        } else {
            return InternalError.ProvidedValueIsNotValidOption;
        }
    } else {
        var values = std.ArrayList([]const u8).init(self.allocator);
        errdefer values.deinit();

        try self.verifyAndAppendValue(arg, &values, value);
        // Consume minimum number of required values first
        if (arg.min_values) |min| {
            try self.consumeNValues(arg, &values, min);
            // Not enough values
            if (values.items.len < min) return error.TooFewArgValue;
        }
        const has_max_num = (arg.max_values != null);
        const max_eqls_one = (has_max_num and (arg.max_values.? == 1));

        // If maximum number and takes_multiple_values is not set we are not looking for more values
        if ((!has_max_num or max_eqls_one) and !(arg.isSettingApplied(.takes_multiple_values))) {
            // If values contains only one value, we can be sure that the minimum number of values is set to 1
            // therefore return it as a single value instead
            if (values.items.len == 1) {
                values.deinit();
                return self.args_ctx.putMatchedArg(arg, .{ .single = value });
            } else {
                return self.args_ctx.putMatchedArg(arg, .{ .many = values });
            }
        }
        if (arg.isSettingApplied(.takes_multiple_values)) {
            if (!has_max_num) {
                try self.consumeValuesTillNextOption(arg, &values);
                return self.args_ctx.putMatchedArg(arg, .{ .many = values });
            }
        }
        if (has_max_num) {
            try self.consumeNValues(arg, &values, arg.max_values.?);
        }
        return self.args_ctx.putMatchedArg(arg, .{ .many = values });
    }
}

fn consumeNValues(
    self: *Parser,
    arg: *const Arg,
    list: *std.ArrayList([]const u8),
    num: usize,
) InternalError!void {
    var i: usize = 1;
    while (i < num) : (i += 1) {
        const value = self.tokenizer.nextNonOptionArg() orelse return;
        try self.verifyAndAppendValue(arg, list, value);
    }
}

fn consumeValuesTillNextOption(
    self: *Parser,
    arg: *const Arg,
    list: *std.ArrayList([]const u8),
) InternalError!void {
    while (self.tokenizer.nextNonOptionArg()) |value| {
        try self.verifyAndAppendValue(arg, list, value);
    }
}

fn verifyAndAppendValue(
    self: *Parser,
    arg: *const Arg,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) InternalError!void {
    self.err_builder.setProvidedArg(value);

    if ((value.len == 0) and !(arg.isSettingApplied(.allow_empty_value)))
        return InternalError.EmptyArgValueNotAllowed;
    if (!(arg.verifyValueInAllowedValues(value)))
        return InternalError.ProvidedValueIsNotValidOption;

    try list.append(value);
}

fn parseSubCommand(self: *Parser, provided_subcmd: []const u8) Error!MatchedSubCommand {
    const valid_subcmd = self.cmd.findSubcommand(provided_subcmd) orelse {
        self.err_builder.setErr(Error.UnknownCommand);
        return self.err_builder.err;
    };

    // zig fmt: off
    if (valid_subcmd.isSettingApplied(.takes_value)
        or valid_subcmd.countArgs() >= 1
        or valid_subcmd.countOptions() >= 1
        or valid_subcmd.countSubcommands() >= 1) {
        // zig fmt: on
        const subcmd_argv = self.tokenizer.restArg() orelse {
            if (!(valid_subcmd.isSettingApplied(.arg_required))) {
                return MatchedSubCommand.initWithArg(
                    valid_subcmd.name,
                    ArgsContext.init(self.allocator),
                );
            }
            self.err_builder.setCmd(valid_subcmd);
            self.err_builder.setErr(Error.CommandArgumentNotProvided);
            return self.err_builder.err;
        };
        var parser = Parser.init(self.allocator, Tokenizer.init(subcmd_argv), valid_subcmd);
        const subcmd_ctx = parser.parse() catch |err| {
            // Bubble up the error trace to the parent command that happened while parsing subcommand
            self.err_builder = parser.err_builder;
            return err;
        };

        return MatchedSubCommand.initWithArg(valid_subcmd.name, subcmd_ctx);
    }
    return MatchedSubCommand.initWithoutArg(valid_subcmd.name);
}
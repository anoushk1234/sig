const network = @import("zig-network");

/// Maximum over-the-wire size of a Transaction
///   1280 is IPv6 minimum MTU
///   40 bytes is the size of the IPv6 header
///   8 bytes is the size of the fragment header
pub const PACKET_DATA_SIZE: usize = 1232;

pub const Packet = struct {
    data: [PACKET_DATA_SIZE]u8,
    size: usize,
    addr: network.EndPoint,

    const Self = @This();

    pub fn init(addr: network.EndPoint, data: [PACKET_DATA_SIZE]u8, size: usize) Self {
        var self = Self{
            .addr = addr,
            .data = data,
            .size = size,
        };
        return self;
    }
};

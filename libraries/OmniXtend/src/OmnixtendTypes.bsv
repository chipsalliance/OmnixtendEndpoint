/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendTypes;

import Vector :: *;
import BUtils :: *;
import StatusRegHandler :: *;
import Arbiter :: *;

import OmnixtendTypesImplementation :: *;

export OmnixtendTypesImplementation :: *;
export OmnixtendTypes :: *;

////////////////////////////////////////
// User Configuration
////////////////////////////////////////

// Set to 1 for OmniXtend 1.1 mode
// Set to 0 to enable OmniXtend 1.0.3 mode
typedef `OX_11_MODE OX_11_MODE;

// Credit Handling
// Number of bits used for credit counters
typedef 24 OmnixtendCreditSize;

// Ethernet specific

// Ethernet type to use for OmniXtend
// Not determined in spec
typedef 'hAAAA OmnixtendEthType;

// Maximum packet size in bytes
// Set to 1500 if jumbo frames are not supported
// Jumbo frames usually requires support by Ethernet IP, e.g. through setting a configuration bit
typedef `MAXIMUM_PACKET_SIZE MAXIMUM_PACKET_SIZE;

// Connections
typedef `OMNIXTEND_CONNECTIONS OmnixtendConnections;

// Number of output channels to queue tilelink messages before processing by the sender logic
// If there are more connections than output channels, the connections are distributed evenly on the available output channels by round-robin
typedef 4 SenderOutputChannels;

// Number of flits than can be stored in the output channels before processing by the sender
typedef 128 SenderOutputFlitsFIFO;

////////////////////////////////////////
// Derived types and helper functions
////////////////////////////////////////

// Maximum number of configuration registers
// BSC will print a warning (not an error!) if this value is too low
typedef 140 OMNIXTEND_CONFIG_REGISTER_MAX;
typedef 64  OMNIXTEND_CONFIG_REGISTER_WIDTH;

typedef StatusInterface#(OMNIXTEND_CONFIG_REGISTER_MAX, OMNIXTEND_CONFIG_REGISTER_WIDTH) 
                                                                        StatusInterfaceOmnixtend;
typedef StatusRegHandler#(OMNIXTEND_CONFIG_REGISTER_WIDTH) StatusRegHandlerOmnixtend;

// Requires changes in OmnixtendReceiver if changed
// as the information locations change in the stream
typedef 64 ETH_STREAM_DATA_WIDTH;
typedef   0 ETH_STREAM_USER_WIDTH;

typedef 22 OMNIXTEND_ACK_SIZE;

typedef Bit#(48) Mac;
typedef `MAC_ADDR MyMac;

typedef UInt#(OmnixtendCreditSize) OmnixtendCreditCounter;
typedef Int#(TAdd#(1, OmnixtendCreditSize)) OmnixtendCreditCounterInt;

function OmnixtendCreditCounterInt counterToInt(OmnixtendCreditCounter c);
    return zeroExtend(unpack(pack(c)));
endfunction

function OmnixtendCreditCounter counterToUInt(OmnixtendCreditCounterInt c);
    return truncate(unpack(pack(c)));
endfunction

typedef Vector#(OmnixtendChannelsReceive, Array#(Reg#(OmnixtendCreditCounter))) OmnixtendCreditCounterVectorReceive;
typedef Vector#(OmnixtendChannelsSend, Array#(Reg#(OmnixtendCreditCounter))) OmnixtendCreditCounterVectorSend;

typedef union tagged {
    OmnixtendCreditCounterVectorReceive Receive;
    OmnixtendCreditCounterVectorSend Send;
} OmnixtendCreditCounterVector;

function Maybe#(Array#(Reg#(OmnixtendCreditCounter))) getChannelCredits(OmnixtendCreditCounterVector v, OmnixtendChannel c);
    if(v matches tagged Receive .ve) begin
        return tagged Valid ve[receiveChannelToVectorIndex(c)];
    end else if(v matches tagged Send .ve) begin
        return tagged Valid ve[sendChannelToVectorIndex(c)];
    end else begin
        return tagged Invalid;
    end
endfunction

function Action updateCredit(OmnixtendCreditCounterVector v, OmnixtendChannel chan, OmnixtendCredit c);
    action
        if(v matches tagged Receive .x) begin
            x[receiveChannelToVectorIndex(chan)][1] <= x[receiveChannelToVectorIndex(chan)][1] + (1 << c);
        end else if(v matches tagged Send .x) begin
            x[sendChannelToVectorIndex(chan)][1] <= x[sendChannelToVectorIndex(chan)][1] + (1 << c);
        end
    endaction
endfunction


typedef Bit#(64) OmnixtendFlit;

typedef union tagged {
    Tuple2#(OmnixtendFlit, FlitsPerPacketCounterType) Start;
    OmnixtendFlit Intermediate;
    OmnixtendFlit End;
} OmnixtendData deriving(Bits, Eq, FShow);

function OmnixtendFlit getFlit(OmnixtendData d);
    let flit_out = ?;
    if(d matches tagged Start {.flit, .len}) begin
        flit_out = flit;
    end else if(d matches tagged Intermediate .flit) begin
        flit_out = flit;
    end else if(d matches tagged End .flit) begin
        flit_out = flit;
    end
    return flit_out;
endfunction

function FlitsPerPacketCounterType getNumFlits(OmnixtendData d);
    let flit_out = ?;
    if(d matches tagged Start {.flit, .len}) begin
        flit_out = len + 1;
    end
    return flit_out;
endfunction

function Bool isLast(OmnixtendData d);
    let last = False;
    if(d matches tagged Start {.flit, .len} &&& len == 0) begin
        last = True;
    end else if(d matches tagged End .flit) begin
        last = True;
    end
    return last;
endfunction

typedef Bit#(5) OmnixtendCredit;

typedef UInt#(22) OmnixtendSequence;

typedef struct {
    OmnixtendSequence sequence_number;
    OmnixtendSequence sequence_number_ack;
    Bit#(3) vc;
    OmnixtendChannel chan;
    OmnixtendCredit credit;
    Bool ack;
} PacketData deriving(Bits, Eq, FShow);

typedef struct {
    OmnixtendSequence sequence_number_ack;
    Bool ack;
} AckOnly deriving(Bits, Eq, FShow);

typedef union tagged {
    PacketData Packet;
    AckOnly Ack;
    void NAK;
    OmnixtendSequence OutOfSequenceACK;
    OmnixtendData Flit;
} OmnixtendOp deriving (Bits, Eq, FShow);

typedef enum {
    Normal = 4'h0,
    ACK_only = 4'h1,
    Open_Connection = 4'h2,
    Close_Connection = 4'h3,
    Unused[12]
} OmnixtendMessageType deriving(Bits, Eq, FShow);

typedef struct {
    Bit#(3) vc;    
    OmnixtendMessageType message_type;
    Bit#(3) reserved2;
    Bit#(22) sequence_number;
    Bit#(22) sequence_number_ack;
    Bit#(1) ack;
    Bit#(1) reserved;
    Bit#(3) chan;
    Bit#(5) credit;
} OmnixtendHeader deriving(Bits, Eq, FShow);

typedef struct {
    Bit#(16) start_of_omnixtend_pkt;
    Bit#(16) eth_type;
    Bit#(48) mac_src;
    Bit#(48) mac_dst;
} EthernetHeader deriving(Bits, Eq, FShow);



typedef Tuple2#(Bool, OmnixtendFlit) ResendBufferType;
typedef Tuple3#(OmnixtendConnectionsCntrType, Bool, OmnixtendFlit) ResendBufferConnType;

typedef TExp#(`RESEND_SIZE) ResendBufferSize;
typedef TSub#(ResendBufferSize, TAdd#(1, MIN_FLITS_PER_PACKET)) ResendBufferSizeUseable; // Safety margin to avoid blocking resend buffer

typedef TSub#(TExp#(`RESEND_TIMEOUT_CYCLES_LOG2), 2) ResendTimeoutCounterCycles;
typedef TSub#(TExp#(`ACK_TIMEOUT_CYCLES_LOG2), 2) ACKTimeoutCounterCycles;

typedef 64 OMNIXTEND_FLIT_WIDTH;
typedef TDiv#(OMNIXTEND_FLIT_WIDTH, 8) OMNIXTEND_FLIT_BYTES;

typedef TAdd#(14, 8) OMNIXTEND_HEADER_SIZE_BYTES; // Ethernet header + Omnixtend header
typedef TAdd#(OMNIXTEND_HEADER_SIZE_BYTES, 8) OMNIXTEND_EMPTY_PACKET_SIZE_BYTES; // Adds Mask
typedef TDiv#(OMNIXTEND_EMPTY_PACKET_SIZE_BYTES, 8) OMNIXTEND_EMPTY_PACKET_FLITS;
typedef 64 MINIMUM_PACKET_SIZE;

typedef TExp#(15) MAXIMUM_OMNIXTEND_SIZE_BYTES;

typedef TDiv#(MINIMUM_PACKET_SIZE, OMNIXTEND_FLIT_BYTES) MIN_FLITS_PER_PACKET;
typedef TDiv#(MAXIMUM_PACKET_SIZE, OMNIXTEND_FLIT_BYTES) MAX_FLITS_PER_PACKET;
typedef TLog#(TAdd#(MAX_FLITS_PER_PACKET, 1)) FlitsPerPacketCounterBits;
typedef UInt#(FlitsPerPacketCounterBits) FlitsPerPacketCounterType;
typedef Int#(TAdd#(1, FlitsPerPacketCounterBits)) FlitsPerPacketCounterTypeInt;

typedef `MAXIMUM_TL_PER_FRAME MaxStartOfMessageFlit;
typedef UInt#(TLog#(TAdd#(MaxStartOfMessageFlit, 1))) MaxStartOfMessageFlitCntr;

typedef void OneOmnixtendCredit;
typedef FlitsPerPacketCounterType AddOmnixtendCredit;
typedef Tuple2#(OmnixtendConnectionsCntrType, AddOmnixtendCredit) OmnixtendCreditReturnChannel;

typedef TMul#(OX_11_MODE, 128) DefaultCredits;

typedef TAdd#(1024, DefaultCredits) TotalStartCredits;
typedef TSub#(TotalStartCredits, DefaultCredits) StartCredits;


typedef struct {
    Bit#(1) reserved;
    OmnixtendChannel chan;
    Bit#(3) opcode;
    Bit#(1) reserved2;
    Bit#(4) param;
    Bit#(4) size;
    Bit#(8) domain;
    Bool denied;
    Bool corrupt;
    Bit#(12) reserved3;
    Bit#(26) source;
} OmnixtendMessageABCD deriving(Bits, Eq, FShow);

typedef struct {
    Bit#(1) reserved2;
    OmnixtendChannel chan;
    Bit#(34) reserved;
    Bit#(26) sink;
} OmnixtendMessageE deriving(Bits, Eq, FShow);

typedef Bit#(64) OmnixtendMessageAddress;
typedef Bit#(64) OmnixtendMessageData;

typedef struct{
    Bit#(38) reserved;
    Bit#(26) sink;
} OmnixtendMessageSink deriving(Bits, Eq, FShow);

typedef union tagged {
    OmnixtendMessageABCD ChanABCD;
    OmnixtendMessageE ChanE;
    OmnixtendMessageAddress Address;
    OmnixtendMessageData Data;
    OmnixtendMessageSink Sink;
    void Padding;
} OmnixtendMessage deriving(Bits, Eq, FShow);

typedef enum {
    PutFullData = 3'b000,
    PutPartialData = 1,
    ArithmeticData = 2,
    LogicalData = 3,
    Get = 4,
    Intent = 5,
    AcquireBlock = 6,
    AcquirePerm = 7
} TilelinkOpcodeChanA deriving(Bits, Eq, FShow);

typedef enum {
    PutFullData = 3'b000,
    PutPartialData = 1,    
    ArithmeticData = 2,
    LogicalData = 3,
    Get = 4,
    Intent = 5,
    ProbeBlock = 6,
    ProbePerm = 7
} TilelinkOpcodeChanB deriving(Bits, Eq, FShow);

typedef enum {
    AccessAck = 3'b000,
    AccessAckData = 1,
    HintAck = 2,
    ProbeAck = 4,
    ProbeAckData = 5,
    Release = 6,
    ReleaseData = 7
} TilelinkOpcodeChanC deriving(Bits, Eq, FShow);

typedef enum {
    AccessAck = 3'b000, 
    AccessAckData = 1,
    HintAck = 2,
    Grant = 4,
    GrantData = 5,
    ReleaseAck = 6
} TilelinkOpcodeChanD deriving(Bits, Eq, FShow);

typedef enum {
    GrantAck = 3'b000
} TilelinkOpcodeChanE deriving(Bits, Eq, FShow);


function Bool messageContainsDataAndMask(OmnixtendMessage m);
    if(m matches tagged ChanABCD .x) begin
        if(x.chan == A || x.chan == B) begin
            TilelinkOpcodeChanA o = unpack(x.opcode);
            return o == PutPartialData;
        end else begin
            return False;
        end
    end else begin
        return False;
    end
endfunction

function Bool messageContainsData(OmnixtendMessage m);
    if(m matches tagged ChanABCD .x) begin
        if(x.chan == D) begin
            TilelinkOpcodeChanD o = unpack(x.opcode);
            return o == AccessAckData;
        end else begin
            return False;
        end
    end else begin
        return False;
    end
endfunction

function Bool messageContainsDataAnd8Bytes(OmnixtendMessage m);
    if(m matches tagged ChanABCD .x) begin
        if(x.chan == A || x.chan == B) begin
            TilelinkOpcodeChanA o = unpack(x.opcode);
            return o == PutFullData || o == ArithmeticData || o == LogicalData;
        end else if(x.chan == C) begin
            TilelinkOpcodeChanC o = unpack(x.opcode);
            return o == AccessAckData || o == ProbeAckData || o == ReleaseData;
        end else if(x.chan == D) begin
            TilelinkOpcodeChanD o = unpack(x.opcode);
            return o == GrantData;
        end else begin
            return False;
        end
    end else begin
        return False;
    end
endfunction

function Bool messageContains8Bytes(OmnixtendMessage m);
    if(m matches tagged ChanABCD .x) begin
        if(x.chan == A || x.chan == B) begin
            TilelinkOpcodeChanA o = unpack(x.opcode);
            TilelinkOpcodeChanB o_b = unpack(x.opcode);
            return o == Get || o == Intent || (x.chan == A && o == AcquireBlock) || (x.chan == A && o == AcquirePerm) || (x.chan == B && o_b == ProbePerm) || (x.chan == B && o_b == ProbeBlock);
        end else if(x.chan == C) begin
            TilelinkOpcodeChanC o = unpack(x.opcode);
            return o == AccessAck || o == HintAck || o == ProbeAck || o == Release;
        end else if(x.chan == D) begin
            TilelinkOpcodeChanD o = unpack(x.opcode);
            return o == Grant;
        end else begin
            return False;
        end
    end else begin
        return False;
    end
endfunction

// According to Omnixtend 1.0.3 spec page 13
function FlitsPerPacketCounterType calculateDataSize(Bit#(4) size);
    Int#(5) size_u = cExtend(size);
    size_u = size_u - 3;
    if(size_u < 0) begin
        return 1;
    end else begin
        return 1 << size_u;
    end
endfunction

function FlitsPerPacketCounterType calculateDataAndMaskSize(Bit#(4) size);
    Int#(5) size_u = cExtend(size);
    size_u = size_u - 3;
    if(size_u < 0) begin
        // Address + Data + Mask
        return 1 + 1 + 1;
    end else if(size < 6) begin
        // Address + Mask + Multiple Data
        return 1 + 1 + (1 << size_u);
    end else begin
        // Address + Multiple Mask + Multiple Data
        return 1 + (1 << size_u) + (1 << (size_u - 3));
    end
endfunction

function FlitsPerPacketCounterType getFlitsThisMessage(OmnixtendMessage m);
    if(m matches tagged ChanABCD .x) begin
        // There are multiple message types:
        // Data + Mask + 1 Flit
        // Data + 1 Flit
        // Data
        // + 1 Flit
        // Nothing extra
        if(messageContainsDataAndMask(m)) begin
            return calculateDataAndMaskSize(x.size);
        end else if(messageContainsData(m)) begin
            return calculateDataSize(x.size);
        end else if(messageContainsDataAnd8Bytes(m)) begin
            return 1 + calculateDataSize(x.size);
        end else if(messageContains8Bytes(m)) begin
            return 1;
        end else begin
            return 0;
        end
    end else begin // All other types don't have any data
        return 0;
    end
endfunction

typedef UInt#(TLog#(OmnixtendConnections)) OmnixtendConnectionsCntrType;

typedef enum {
    Activated,
    Disabled
} ConnectionStateChange deriving(Bits, Eq, FShow);

// Tilelink requires that all requests are aligned to the size
function Bool isAligned(Bit#(OMNIXTEND_FLIT_WIDTH) addr, Bit#(4) size);
    return (addr & ((1 << size) - 1)) == 0;
endfunction

typedef enum {
    MIN = 0,
    MAX = 1,
    MINU = 2,
    MAXU = 3,
    ADD = 4
} ArithmeticOperation deriving(Bits, Eq, FShow);

typedef enum {
    XOR = 0,
    OR = 1,
    AND = 2,
    SWAP = 3
} LogicOperation deriving(Bits, Eq, FShow);

typedef union tagged {
    ArithmeticOperation Arithmetic;
    LogicOperation Logic;
} OXCalcOp deriving(Bits, Eq, FShow);

typedef enum {
    ACTIVE,
    IDLE,
    CLOSED_BY_HOST,
    CLOSED_BY_HOST_WAITING_FOR_REQUESTS,
    CLOSED_BY_CLIENT
} ConnectionStatus deriving(Bits, Eq, FShow);

typedef struct {
    Mac mac;
    ConnectionStatus status;
} ConnectionState deriving(Bits, Eq, FShow);

typedef enum {
    ToT = 4'h0,
    ToB = 1,
    ToN = 2,
    Unused[13]
} OmnixtendPermissionChangeCap deriving(Bits, Eq, FShow);

typedef enum  {
    NtoB = 4'h0,
    NtoT = 1,
    BtoT = 2,
    Unused[13]
} OmnixtendPermissionChangeGrow deriving(Bits, Eq, FShow);

typedef enum  {
    TtoB = 4'h0,
    TtoN = 1,
    BtoN = 2,
    Unused[13]
} OmnixtendPermissionChangePrune deriving(Bits, Eq, FShow);

typedef enum  {
    TtoT = 4'h3,
    BtoB = 4,
    NtoN = 5,
    Unused[13]
} OmnixtendPermissionChangeReport deriving(Bits, Eq, FShow);

function UInt#(TLog#(MAXIMUM_PACKET_SIZE)) flits_from_size(Bit#(4) size);
        let flits = (1 << size) / fromInteger(valueOf(OMNIXTEND_FLIT_BYTES));
        if((1 << size) < fromInteger(valueOf(OMNIXTEND_FLIT_BYTES))) begin
            flits = 1;
        end
        return flits;
endfunction

function Bool compat_mode_enabled();
    return valueOf(OX_11_MODE) == 0;
endfunction

function Bool ack_only_enabled();
    return !compat_mode_enabled();
endfunction

function Bool connections_enabled();
    return !compat_mode_enabled();
endfunction

function Bool gotGrant(ArbiterClient_IFC c);
    return c.grant();
endfunction

endpackage
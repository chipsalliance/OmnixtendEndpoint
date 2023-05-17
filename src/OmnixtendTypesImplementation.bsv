/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

package OmnixtendTypesImplementation;

typedef enum {
    INVALID = 3'h0,
    A = 3'h1,
    B = 3'h2,
    C = 3'h3,
    D = 3'h4,
    E = 3'h5
} OmnixtendChannel deriving(Bits, Eq, FShow);

typedef 3 OmnixtendChannelsReceive;
typedef 2 OmnixtendChannelsSend;

function Bool isReceiveChannel(OmnixtendChannel c);
    return c == A || c == C || c == E;
endfunction

function Bool isSendChannel(OmnixtendChannel c);
    return c == B || c == D;
endfunction

function Integer receiveChannelToVectorIndex(OmnixtendChannel c);
    case(c)
        A: return 0;
        C: return 1;
        E: return 2;
    endcase
endfunction

function OmnixtendChannel receiveVectorIndexToChannel(Integer c);
    case(c)
        0: return A;
        1: return C;
        2: return E;
    endcase
endfunction

function OmnixtendChannel receiveVectorIndexToChannelUInt(UInt#(TLog#(OmnixtendChannelsReceive)) c);
    case(c)
        0: return A;
        1: return C;
        2: return E;
    endcase
endfunction

function Integer sendChannelToVectorIndex(OmnixtendChannel c);
    case(c)
        B: return 0;
        D: return 1;
    endcase
endfunction

function OmnixtendChannel sendVectorIndexToChannel(Integer c);
    case(c)
        0: return B;
        1: return D;
    endcase
endfunction

function OmnixtendChannel sendVectorIndexToChannelUInt(UInt#(TLog#(OmnixtendChannelsSend)) c);
    case(c)
        0: return B;
        1: return D;
    endcase
endfunction

endpackage
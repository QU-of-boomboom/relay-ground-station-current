`timescale 1ns / 1ps
// Four independent latest-value queues share one fully pipelined quality core.
// Cycle/cancellation contract: gs_shared_quality_spec.md. Not a statistics FIFO.
module gs_shared_quality(
    input i_clk, // Single PL clock, target 200 MHz.
    input i_rst, // Synchronous global reset cancels every source.
    input [3:0] i_cancel, // Cancel old work by source, including the return edge.
    input [3:0] i_request, // Capture a complete new value for each asserted source.
    input [3115:0] i_payload, // Four 779-bit raw frames; source zero is least significant.
    input [31:0] i_generation, // Four 8-bit source generations, sampled with the frames.
    output [3:0] o_pending, // One waiting position per source.
    output [3:0] o_replaced, // New request superseded an unserved old value this edge.
    output [3:0] o_valid, // At most one source receives a result per edge.
    output [7:0] o_generation, // Generation of the valid result, otherwise zero.
    output [441:0] o_payload // Complete original result, otherwise zero.
);
    reg [778:0] reg_pending_payload [0:3]; // Frozen source values, never live input muxes.
    reg [7:0] reg_pending_generation [0:3]; // Source generation travels with each queue value.
    reg [3:0] flag_pending; // Eligibility storage; wide payload storage needs no reset.
    reg [3:0] replaced_o; // Observable replacement pulse excludes simultaneous dequeue.
    reg [1:0] reg_cursor; // Next source to search first.
    wire [3:0] wire_eligible; // Old pending values surviving current source cancellation.
    reg [3:0] wire_rotated; // Eligibility rotated into cursor-relative order.
    reg [1:0] wire_offset; // First eligible position in the rotated order.
    wire [1:0] wire_selected; // Physical source index, explicitly modulo four.
    wire flag_grant; // An old queued value enters the shared input register.
    wire [3:0] wire_granted; // One-hot dequeue mask.
    reg [778:0] wire_selected_payload; // Four-way data selection before a registered boundary.
    reg [7:0] wire_selected_generation; // Identical selection for the generation.
    reg [778:0] reg_entry_payload; // Registered boundary before all numeric logic.
    reg [7:0] reg_entry_generation; // Generation aligned with the shared input.
    reg [1:0] reg_entry_slot; // Source aligned with the shared input.
    reg flag_entry; // Shared input register contains a computation.
    wire flag_launch; // Current cancellation may revoke the registered input.
    reg [18:0] flag_route_valid; // Nineteen positions cover E through E+18.
    reg [1:0] reg_route_slot [0:18]; // Source for cancellation at every pipeline position.
    reg [7:0] reg_route_generation [0:18]; // Exact generation for the returning result.
    wire flag_core_valid; // Arithmetic core completion at its original E+18 boundary.
    wire [441:0] wire_core_payload; // Original quality result before source qualification.
    wire flag_return; // Global and source reset cannot expose old results.
    genvar gen_lane,gen_stage;

    assign wire_eligible=flag_pending & ~i_cancel;
    assign flag_grant=(|wire_eligible) & (!i_rst);
    assign wire_selected=reg_cursor + wire_offset;
    assign wire_granted=flag_grant ? (4'b0001 << wire_selected) : 4'b0000;
    assign flag_launch=flag_entry & (!i_cancel[reg_entry_slot]);
    assign flag_return=flag_core_valid & flag_route_valid[18] & (!i_cancel[reg_route_slot[18]]) & (!i_rst);
    assign o_pending=flag_pending;
    assign o_replaced=replaced_o;
    assign o_valid=flag_return ? (4'b0001 << reg_route_slot[18]) : 4'b0000;
    assign o_generation=flag_return ? reg_route_generation[18] : 8'd0;
    assign o_payload=flag_return ? wire_core_payload : 442'd0;

    // Rotate four flags rather than a wide payload barrel shifter.
    always @(*) begin
        case(reg_cursor)
            2'd0:wire_rotated=wire_eligible;
            2'd1:wire_rotated={wire_eligible[0],wire_eligible[3:1]};
            2'd2:wire_rotated={wire_eligible[1:0],wire_eligible[3:2]};
            2'd3:wire_rotated={wire_eligible[2:0],wire_eligible[3]};
            default:wire_rotated=4'd0;
        endcase
    end
    always @(*) begin
        if(wire_rotated[0])wire_offset=2'd0;
        else if(wire_rotated[1])wire_offset=2'd1;
        else if(wire_rotated[2])wire_offset=2'd2;
        else wire_offset=2'd3;
    end
    // Explicit four-way mux keeps the memory layout independent of synthesis heuristics.
    always @(*) begin
        wire_selected_payload=779'd0;
        wire_selected_generation=8'd0;
        case(wire_selected)
            2'd0:begin wire_selected_payload=reg_pending_payload[0];wire_selected_generation=reg_pending_generation[0];end
            2'd1:begin wire_selected_payload=reg_pending_payload[1];wire_selected_generation=reg_pending_generation[1];end
            2'd2:begin wire_selected_payload=reg_pending_payload[2];wire_selected_generation=reg_pending_generation[2];end
            2'd3:begin wire_selected_payload=reg_pending_payload[3];wire_selected_generation=reg_pending_generation[3];end
            default:begin wire_selected_payload=779'd0;wire_selected_generation=8'd0;end
        endcase
    end
    always @(posedge i_clk)begin
        if(i_rst)reg_cursor<=2'd0;
        else if(flag_grant)reg_cursor<=wire_selected + 2'd1;
    end
    generate
        for(gen_lane=0;gen_lane<4;gen_lane=gen_lane+1)begin:gen_queue
            always @(posedge i_clk)begin
                if(i_rst)flag_pending[gen_lane]<=1'b0;
                else if(i_request[gen_lane])flag_pending[gen_lane]<=1'b1;
                else if(i_cancel[gen_lane] | wire_granted[gen_lane])flag_pending[gen_lane]<=1'b0;
            end
            always @(posedge i_clk)begin
                if(i_request[gen_lane])begin
                    reg_pending_payload[gen_lane]<=i_payload[gen_lane*779 +: 779];
                    reg_pending_generation[gen_lane]<=i_generation[gen_lane*8 +: 8];
                end
            end
            always @(posedge i_clk)begin
                if(i_rst)replaced_o[gen_lane]<=1'b0;
                else replaced_o[gen_lane]<=i_request[gen_lane] & flag_pending[gen_lane] &
                    (!i_cancel[gen_lane]) & (!wire_granted[gen_lane]);
            end
        end
    endgenerate
    always @(posedge i_clk)begin
        if(i_rst)flag_entry<=1'b0;
        else flag_entry<=flag_grant;
    end
    always @(posedge i_clk)begin
        if(flag_grant)begin
            reg_entry_payload<=wire_selected_payload;
            reg_entry_generation<=wire_selected_generation;
            reg_entry_slot<=wire_selected;
        end
    end
    always @(posedge i_clk)begin
        if(i_rst)flag_route_valid[0]<=1'b0;
        else flag_route_valid[0]<=flag_launch;
        reg_route_slot[0]<=reg_entry_slot;
        reg_route_generation[0]<=reg_entry_generation;
    end
    generate
        for(gen_stage=1;gen_stage<19;gen_stage=gen_stage+1)begin:gen_route
            always @(posedge i_clk)begin
                if(i_rst)flag_route_valid[gen_stage]<=1'b0;
                else flag_route_valid[gen_stage]<=flag_route_valid[gen_stage-1] &
                    (!i_cancel[reg_route_slot[gen_stage-1]]);
                reg_route_slot[gen_stage]<=reg_route_slot[gen_stage-1];
                reg_route_generation[gen_stage]<=reg_route_generation[gen_stage-1];
            end
        end
    endgenerate
    gs_full_quality_compact Core_Inst(
        .i_clk(i_clk),.i_rst(i_rst),.i_clear(1'b0),.i_valid(flag_launch),
        .i_count(reg_entry_payload[778:770]),.i_delivered(reg_entry_payload[769:761]),
        .i_window(reg_entry_payload[760:752]),.i_minimum(reg_entry_payload[751:743]),
        .i_low(reg_entry_payload[742:733]),.i_high(reg_entry_payload[732:723]),
        .i_active(reg_entry_payload[722:499]),.i_context(reg_entry_payload[498:145]),
        .i_tag(reg_entry_payload[144:129]),.i_evidence_present(reg_entry_payload[128]),
        .i_now_ms(reg_entry_payload[127:64]),.i_max_age_ms(reg_entry_payload[63:0]),
        .o_valid(flag_core_valid),.o_reason(wire_core_payload[441:438]),
        .o_condition(wire_core_payload[437:435]),.o_usable(wire_core_payload[434]),
        .o_tag(wire_core_payload[433:418]),.o_context(wire_core_payload[417:64]),
        .o_evaluated_ms(wire_core_payload[63:0]));
endmodule

`timescale 1ns / 1ps
// Four local dwell machines consume the shared quality result once per tag.
// A pre-armed PL deadline cannot be extended by delayed reads or host silence.
module gs_unified_alarm_bank #(
    parameter integer C_CLOCKS_PER_MS=200000
)(
    input wire i_clk,input wire i_rst,
    input wire [3:0] i_lane_clear,input wire [3:0] i_lane_configured,
    input wire [7:0] i_lane_pdr,
    input wire [3:0] i_lane_publication,input wire [31:0] i_lane_generation,
    input wire i_quality_valid,input wire [1:0] i_quality_slot,
    input wire [31:0] i_quality_tag,input wire [2:0] i_quality_required,
    input wire [1:0] i_quality_pdr,input wire [1:0] i_quality_condition,
    input wire [2:0] i_quality_missing,
    input wire [7:0] i_quality_generation,
    input wire [5:0] i_wr_addr,input wire [31:0] i_wr_data,
    input wire i_wr_valid,output wire o_wr_ready,
    input wire [5:0] i_rd_addr,input wire i_rd_valid,output wire o_rd_ready,
    output wire [31:0] o_rd_data,output wire o_rd_valid,input wire i_rd_ready,
    output wire [19:0] o_alarm_state
);
    localparam integer C_DIV_BITS=(C_CLOCKS_PER_MS<2)?1:$clog2(C_CLOCKS_PER_MS);
    reg [C_DIV_BITS-1:0] reg_divider;
    wire flag_tick=(reg_divider==C_CLOCKS_PER_MS-1);
    reg [1:0] reg_selected;
    reg [15:0] reg_ttl;
    reg [31:0] reg_holds;
    reg [2:0] reg_required;
    reg [31:0] reg_error;
    reg [31:0] reg_read_data;
    reg flag_read_valid;
    wire flag_write=i_wr_valid & o_wr_ready;
    wire flag_arm=flag_write & (i_wr_addr==6'h18);
    wire flag_cancel=flag_write & (i_wr_addr==6'h1c);
    wire flag_settings_valid=(reg_ttl!=0) & (reg_holds[15:0]!=0) &
        (reg_holds[31:16]!=0) & reg_required[0];
    wire flag_bad_write=flag_write & !(
        ((i_wr_addr==6'h08) & (i_wr_data<4)) |
        ((i_wr_addr==6'h0c) & (i_wr_data>0) & (i_wr_data<=65535)) |
        ((i_wr_addr==6'h10) & (i_wr_data[15:0]!=0) & (i_wr_data[31:16]!=0)) |
        ((i_wr_addr==6'h14) & (i_wr_data<=7) & i_wr_data[0]) |
        (i_wr_addr==6'h18) | ((i_wr_addr==6'h1c) & (i_wr_data==1)));
    wire [127:0] wire_status,wire_tags;
    wire [3:0] flag_bad_arm;
    reg [31:0] wire_read;
    assign o_wr_ready=!i_rst;
    assign o_rd_ready=(!i_rst) & (!flag_read_valid) & (!i_wr_valid);
    assign o_rd_valid=(!i_rst) & flag_read_valid;
    assign o_rd_data=reg_read_data;
    always @(*) begin
        wire_read=32'd0;
        case(i_rd_addr)
            6'h00:wire_read=32'h47554133;
            6'h04:wire_read=32'd1;
            6'h08:wire_read={30'd0,reg_selected};
            6'h0c:wire_read={16'd0,reg_ttl};
            6'h10:wire_read=reg_holds;
            6'h14:wire_read={29'd0,reg_required};
            6'h18:wire_read=wire_tags[reg_selected*32 +: 32];
            6'h1c:wire_read=reg_error;
            6'h20:wire_read=wire_status[31:0];
            6'h24:wire_read=wire_status[63:32];
            6'h28:wire_read=wire_status[95:64];
            6'h2c:wire_read=wire_status[127:96];
            default:wire_read=32'd0;
        endcase
    end
    always @(posedge i_clk) begin
        if(i_rst)begin
            reg_divider<=0;reg_selected<=0;reg_ttl<=0;reg_holds<=0;
            reg_required<=0;reg_error<=0;reg_read_data<=0;flag_read_valid<=0;
        end else begin
            if(flag_tick)reg_divider<=0;else reg_divider<=reg_divider+1'b1;
            if(i_rd_ready)flag_read_valid<=0;
            if(i_rd_valid & o_rd_ready)begin reg_read_data<=wire_read;flag_read_valid<=1;end
            if(flag_write & !flag_bad_write)begin
                case(i_wr_addr)
                    6'h08:reg_selected<=i_wr_data[1:0];
                    6'h0c:reg_ttl<=i_wr_data[15:0];
                    6'h10:reg_holds<=i_wr_data;
                    6'h14:reg_required<=i_wr_data[2:0];
                    default:reg_selected<=reg_selected;
                endcase
            end
            if(flag_bad_write)reg_error<=1;
            else if(|flag_bad_arm)reg_error<=2;
        end
    end
    genvar node;
    generate for(node=0;node<4;node=node+1)begin:Nodes
        reg [31:0] reg_tag,reg_lane_holds;
        reg [2:0] reg_lane_required,reg_missing;
        reg [15:0] reg_pending_ttl,reg_sample_ttl;
        reg [1:0] reg_condition,reg_pdr;
        reg [7:0] reg_generation;
        wire flag_selected=(reg_selected==node);
        wire flag_lane_arm=flag_arm & flag_selected;
        wire flag_arm_valid=flag_settings_valid & (i_wr_data!=0) &
            (i_wr_data>reg_tag) & i_lane_configured[node] & (!i_lane_clear[node]);
        wire flag_policy_change=(reg_lane_holds!=reg_holds) | (reg_lane_required!=reg_required);
        wire flag_drop=i_lane_clear[node] | (!i_lane_configured[node]) |
            (flag_selected & (flag_cancel | flag_bad_write)) |
            (flag_lane_arm & ((!flag_arm_valid) | flag_policy_change));
        wire flag_live=(reg_sample_ttl!=0) & (reg_condition!=0) &
            (i_lane_generation[node*8 +: 8]==reg_generation) &
            ((!i_lane_publication[node]) | (i_lane_pdr[node*2 +: 2]==reg_pdr)) &
            (reg_pdr!=0) & (!flag_drop);
        wire flag_result=i_quality_valid & (i_quality_slot==node) &
            (i_quality_tag==reg_tag) & (reg_pending_ttl!=0) &
            (i_quality_required==reg_lane_required) & (!flag_lane_arm);
        wire [15:0] wire_pending_next=flag_tick ? reg_pending_ttl-16'd1 : reg_pending_ttl;
        wire [2:0] wire_state;
        wire flag_valid,flag_alarm;
        wire [4:0] wire_alarm=flag_live ? {flag_valid,flag_alarm,wire_state} : 5'd0;
        assign flag_bad_arm[node]=flag_lane_arm & (!flag_arm_valid);
        assign o_alarm_state[node*5 +: 5]=(!i_rst) ? wire_alarm : 5'd0;
        assign wire_tags[node*32 +: 32]=reg_tag;
        assign wire_status[node*32 +: 32]={reg_sample_ttl,reg_lane_required,
            (reg_pending_ttl!=0),1'b0,flag_live,reg_missing,reg_condition,wire_alarm};
        gs_pdr_alarm Alarm_Inst(.i_clk(i_clk),.i_rstn(!i_rst),.i_clear(!flag_live),
            .i_tick_ms(flag_tick),.i_condition(reg_condition),
            .i_bad_hold(reg_lane_holds[15:0]),.i_good_hold(reg_lane_holds[31:16]),
            .o_state(wire_state),.o_valid(flag_valid),.o_alarm(flag_alarm));
        always @(posedge i_clk)begin
            if(i_rst)begin
                reg_tag<=0;reg_lane_holds<=0;reg_lane_required<=0;reg_missing<=0;
                reg_pending_ttl<=0;reg_sample_ttl<=0;reg_condition<=0;reg_pdr<=0;reg_generation<=0;
            end else begin
                if(flag_tick)begin
                    if(reg_pending_ttl!=0)reg_pending_ttl<=reg_pending_ttl-16'd1;
                    if(reg_sample_ttl!=0)reg_sample_ttl<=reg_sample_ttl-16'd1;
                end
                if(!flag_live)begin reg_sample_ttl<=0;reg_condition<=0;end
                if(flag_result)begin
                    reg_pending_ttl<=0;
                    reg_missing<=i_quality_missing;
                    reg_pdr<=i_quality_pdr;
                    reg_generation<=i_quality_generation;
                    if((wire_pending_next!=0) & (i_quality_pdr!=0) &
                        (i_quality_generation==i_lane_generation[node*8 +: 8]) &
                        ((!i_lane_publication[node]) | (i_quality_pdr==i_lane_pdr[node*2 +: 2])))begin
                        reg_sample_ttl<=wire_pending_next;reg_condition<=i_quality_condition;
                    end else begin reg_sample_ttl<=0;reg_condition<=0;end
                end
                if(flag_lane_arm & flag_arm_valid)begin
                    reg_tag<=i_wr_data;reg_pending_ttl<=reg_ttl;
                    reg_lane_holds<=reg_holds;reg_lane_required<=reg_required;
                end
                if(flag_drop)begin
                    reg_sample_ttl<=0;reg_condition<=0;reg_missing<=0;
                    // A legal policy replacement starts a new pending lease only.
                    if(!(flag_lane_arm & flag_arm_valid))reg_pending_ttl<=0;
                end
            end
        end
    end endgenerate
    // synthesis translate_off
    initial if(C_CLOCKS_PER_MS<2)$fatal(1,"unified alarm needs at least two clocks per ms");
    // synthesis translate_on
endmodule

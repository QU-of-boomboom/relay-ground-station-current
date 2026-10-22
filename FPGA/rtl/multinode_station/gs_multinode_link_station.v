`timescale 1ns / 1ps
// 四节点PDR并行，RTT/AoI共享服务位于0xf40..0xfbf；读目标锁存至消费。
module gs_multinode_link_station #(
    parameter [31:0] C_CLOCKS_PER_MS=32'd200000,
    parameter [8:0] C_WINDOW=9'd64
)(
    input i_clk,input i_rst,input [3:0] i_backend_reset,
    input [31:0] i_wr_addr,input [31:0] i_wr_data,input i_wr_valid,output o_wr_ready,
    input [31:0] i_rd_addr,input i_rd_valid,output o_rd_ready,
    output [31:0] o_rd_data,output o_rd_valid,input i_rd_ready,
    output [19:0] o_alarm_state
);
    wire flag_service_write,flag_service_read;
    wire flag_service_wr,flag_service_rr,flag_service_valid;
    wire flag_station_wr,flag_station_rr,flag_station_valid;
    wire [31:0] reg_service_data,reg_station_data;
    reg flag_read_pending;
    reg [1:0] reg_read_target;
    wire flag_unified_write=(i_wr_addr[31:6]==26'h3b);
    wire flag_unified_read=(i_rd_addr[31:6]==26'h3b);
    wire flag_unified_wr,flag_unified_rr,flag_unified_valid;
    wire [31:0] wire_unified_data;
    wire flag_quality_valid;
    wire [1:0] wire_quality_slot,wire_quality_pdr,wire_quality_condition;
    wire [31:0] wire_quality_tag;
    wire [2:0] wire_quality_required,wire_quality_missing;
    wire [7:0] wire_quality_generation;
    wire [3:0] flag_lane_publication;
    wire [19:0] wire_pdr_alarm;
    wire [895:0] reg_lane_active;
    wire [3:0] flag_lane_configured,flag_lane_clear;
    wire [7:0] reg_lane_pdr;
    wire [255:0] reg_lane_time;
    wire [31:0] reg_lane_generation;
    gs_unified_alarm_bank #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS)) Unified_Inst(
        .i_clk(i_clk),.i_rst(i_rst),.i_lane_clear(flag_lane_clear),
        .i_lane_configured(flag_lane_configured),.i_lane_pdr(reg_lane_pdr),
        .i_lane_publication(flag_lane_publication),.i_lane_generation(reg_lane_generation),
        .i_quality_valid(flag_quality_valid),.i_quality_slot(wire_quality_slot),
        .i_quality_tag(wire_quality_tag),.i_quality_required(wire_quality_required),
        .i_quality_pdr(wire_quality_pdr),.i_quality_condition(wire_quality_condition),
        .i_quality_missing(wire_quality_missing),
        .i_quality_generation(wire_quality_generation),
        .i_wr_addr(i_wr_addr[5:0]),.i_wr_data(i_wr_data),
        .i_wr_valid(i_wr_valid & flag_unified_write),.o_wr_ready(flag_unified_wr),
        .i_rd_addr(i_rd_addr[5:0]),.i_rd_valid(i_rd_valid & !flag_read_pending & flag_unified_read),
        .o_rd_ready(flag_unified_rr),.o_rd_data(wire_unified_data),.o_rd_valid(flag_unified_valid),
        .i_rd_ready(i_rd_ready & flag_read_pending & (reg_read_target==2)),.o_alarm_state(o_alarm_state));
    assign flag_service_write=(i_wr_addr[31:8]==24'hf) &
        ((i_wr_addr[7:6]==2'd1) | (i_wr_addr[7:6]==2'd2));
    assign flag_service_read=(i_rd_addr[31:8]==24'hf) &
        ((i_rd_addr[7:6]==2'd1) | (i_rd_addr[7:6]==2'd2));
    assign o_wr_ready=flag_unified_write ? flag_unified_wr : (flag_service_write ? flag_service_wr : flag_station_wr);
    assign o_rd_ready=(!i_rst) & (!flag_read_pending) & (flag_unified_read ? flag_unified_rr : (flag_service_read ? flag_service_rr : flag_station_rr));
    assign o_rd_valid=(!i_rst) & flag_read_pending & ((reg_read_target==2) ? flag_unified_valid : ((reg_read_target==1) ? flag_service_valid : flag_station_valid));
    assign o_rd_data=(reg_read_target==2) ? wire_unified_data : ((reg_read_target==1) ? reg_service_data : reg_station_data);
    always @(posedge i_clk)begin
        if(i_rst)begin flag_read_pending<=1'b0;reg_read_target<=2'd0;end
        else if(i_rd_valid & o_rd_ready)begin
            flag_read_pending<=1'b1;reg_read_target<=flag_unified_read ? 2'd2 : {1'b0,flag_service_read};
        end else if(o_rd_valid & i_rd_ready)flag_read_pending<=1'b0;
    end
    gs_multinode_station #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS),.C_WINDOW(C_WINDOW)) Station_Inst(
        .i_clk(i_clk),.i_rst(i_rst),.i_backend_reset(i_backend_reset),
        .i_wr_addr(i_wr_addr),.i_wr_data(i_wr_data),.i_wr_valid(i_wr_valid & !flag_service_write & !flag_unified_write),.o_wr_ready(flag_station_wr),
        .i_rd_addr(i_rd_addr),.i_rd_valid(i_rd_valid & !flag_read_pending & !flag_service_read & !flag_unified_read),.o_rd_ready(flag_station_rr),
        .o_rd_data(reg_station_data),.o_rd_valid(flag_station_valid),.i_rd_ready(i_rd_ready & flag_read_pending & (reg_read_target==0)),
        .o_alarm_state(wire_pdr_alarm),.o_lane_active(reg_lane_active),.o_lane_configured(flag_lane_configured),
        .o_lane_pdr(reg_lane_pdr),.o_lane_time_ms(reg_lane_time),.o_lane_generation(reg_lane_generation),.o_lane_clear(flag_lane_clear),.o_lane_publication(flag_lane_publication));
`ifdef GS_SEQUENCED_SERVICE
    gs_link_service_sequenced Service_Inst(
`else
    gs_link_service Service_Inst(
`endif
        .i_clk(i_clk),.i_rst(i_rst),.i_lane_active(reg_lane_active),.i_lane_configured(flag_lane_configured),
        .i_lane_pdr(reg_lane_pdr),.i_lane_time_ms(reg_lane_time),.i_lane_generation(reg_lane_generation),.i_lane_clear(flag_lane_clear),
        .i_wr_addr({25'd0,~i_wr_addr[6],i_wr_addr[5:0]}),.i_wr_data(i_wr_data),
        .i_wr_valid(i_wr_valid & flag_service_write),.o_wr_ready(flag_service_wr),
        .i_rd_addr({25'd0,~i_rd_addr[6],i_rd_addr[5:0]}),
        .i_rd_valid(i_rd_valid & !flag_read_pending & flag_service_read),.o_rd_ready(flag_service_rr),
        .o_rd_data(reg_service_data),.o_rd_valid(flag_service_valid),.i_rd_ready(i_rd_ready & flag_read_pending & (reg_read_target==1)),
        .o_quality_valid(flag_quality_valid),.o_quality_slot(wire_quality_slot),.o_quality_tag(wire_quality_tag),
        .o_quality_required(wire_quality_required),.o_quality_pdr(wire_quality_pdr),
        .o_quality_condition(wire_quality_condition),.o_quality_missing(wire_quality_missing),.o_quality_generation(wire_quality_generation));
endmodule

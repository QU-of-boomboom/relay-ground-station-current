`timescale 1ns / 1ps
// 官方User_Reg型局部接口：PS守卫保留响应，双mailbox跨到独立PL域。
module gs_multinode_physical #(
    parameter [31:0] C_CLOCKS_PER_MS=32'd200000,
    parameter [8:0] C_WINDOW=9'd64,
    parameter [31:0] C_TIMEOUT=32'd1000000
)(
    input i_ps_clk, input i_ps_rstn,
    input i_pl_clk, input i_pl_rstn,
    input [31:0] i_wr_addr,input [31:0] i_wr_data,input i_wr_valid,output o_wr_ready,
    input [31:0] i_rd_addr,input i_rd_valid,output o_rd_ready,
    output [31:0] o_rd_data,output o_rd_valid,input i_rd_ready,
    output [19:0] o_alarm_state
);
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] reg_ps_release;
    wire flag_backend_rstn,flag_backend_up,flag_ps_run,flag_pl_run,flag_link_fault;
    wire [31:0] reg_guard_wa,reg_guard_ra;
    wire [31:0] reg_backend_wa,reg_backend_wd,reg_backend_ra,reg_backend_data;
    wire flag_backend_wv,flag_backend_wr,flag_backend_rv,flag_backend_rr,flag_backend_valid,flag_backend_ready;
    wire [31:0] reg_local_wa,reg_local_ra;
    wire [31:0] reg_pl_wa,reg_pl_wd,reg_pl_ra,reg_pl_data;
    wire flag_pl_wv,flag_pl_wr,flag_pl_rv,flag_pl_rr,flag_pl_valid,flag_pl_ready;
    wire flag_available;
    wire flag_lease_write,flag_lease_read,flag_lease_wr,flag_lease_rr,flag_lease_valid;
    wire flag_bridge_wr,flag_bridge_rr,flag_bridge_valid;
    wire [31:0] reg_lease_data,reg_bridge_data;
    // PS自身复位独立释放，PL复位不能清PS守卫和其已接收响应。
    always @(posedge i_ps_clk or negedge i_ps_rstn) begin
        if(!i_ps_rstn) begin reg_ps_release<=2'd0; end
        else begin reg_ps_release<={reg_ps_release[0],1'b1}; end
    end
    gs_backend_reset_bridge ResetNotice_Inst(
        .ps_clk(i_ps_clk),.ps_rst_n(i_ps_rstn),.pl_rst_n(i_pl_rstn),
        .backend_rst_n(flag_backend_rstn),.backend_up(flag_backend_up));
    gs_cdc_reset_pair Release_Inst(
        .i_src_clk(i_ps_clk),.i_src_rstn(i_ps_rstn),.i_dst_clk(i_pl_clk),.i_dst_rstn(flag_backend_rstn),
        .o_src_run(flag_ps_run),.o_dst_run(flag_pl_run));
    assign flag_available=flag_backend_up & flag_ps_run & !flag_link_fault;
    // 仅保留区映射到外层guard；正常槽内0x200不能被外层截获。
    assign reg_guard_wa=(i_wr_addr[31:6]==26'h3c) ? {26'h8,i_wr_addr[5:0]} :
                        (i_wr_addr[31:12]==20'd0) ? (32'h00010000 | i_wr_addr) : 32'hffffffff;
    assign reg_guard_ra=(i_rd_addr[31:6]==26'h3c) ? {26'h8,i_rd_addr[5:0]} :
                        (i_rd_addr[31:12]==20'd0) ? (32'h00010000 | i_rd_addr) : 32'hffffffff;
    assign reg_local_wa=(reg_backend_wa[31:12]==20'h10) ? {20'd0,reg_backend_wa[11:0]} : 32'hffffffff;
    assign reg_local_ra=(reg_backend_ra[31:12]==20'h10) ? {20'd0,reg_backend_ra[11:0]} : 32'hffffffff;
    assign flag_lease_write=(reg_backend_wa[31:6]==26'h43f);
    assign flag_lease_read=(reg_backend_ra[31:6]==26'h43f);
    assign flag_backend_wr=flag_lease_write ? flag_lease_wr : flag_bridge_wr;
    assign flag_backend_rr=flag_lease_read ? flag_lease_rr : flag_bridge_rr;
    assign flag_backend_valid=flag_lease_read ? flag_lease_valid : flag_bridge_valid;
    assign reg_backend_data=flag_lease_read ? reg_lease_data : reg_bridge_data;
    gs_session_lease Lease_Inst(
        .i_clk(i_ps_clk),.i_rst(!reg_ps_release[1]),
        .i_wr_addr({26'd0,reg_backend_wa[5:0]}),.i_wr_data(reg_backend_wd),.i_wr_valid(flag_backend_wv & flag_lease_write),.o_wr_ready(flag_lease_wr),
        .i_rd_addr({26'd0,reg_backend_ra[5:0]}),.i_rd_valid(flag_backend_rv & flag_lease_read),.o_rd_ready(flag_lease_rr),
        .o_rd_data(reg_lease_data),.o_rd_valid(flag_lease_valid),.i_rd_ready(flag_backend_ready & flag_lease_read));
    gs_transport_guard Guard_Inst(
        .clk(i_ps_clk),.rst(!reg_ps_release[1]),.backend_up(flag_available),
        .wr_addr(reg_guard_wa),.wr_data(i_wr_data),.wr_valid(i_wr_valid),.wr_ready(o_wr_ready),
        .rd_addr(reg_guard_ra),.rd_valid(i_rd_valid),.rd_ready(o_rd_ready),
        .rd_data(o_rd_data),.rd_data_valid(o_rd_valid),.rd_data_ready(i_rd_ready),
        .backend_wr_addr(reg_backend_wa),.backend_wr_data(reg_backend_wd),.backend_wr_valid(flag_backend_wv),.backend_wr_ready(flag_backend_wr),
        .backend_rd_addr(reg_backend_ra),.backend_rd_valid(flag_backend_rv),.backend_rd_ready(flag_backend_rr),
        .backend_rd_data(reg_backend_data),.backend_rd_data_valid(flag_backend_valid),.backend_rd_data_ready(flag_backend_ready));
    gs_cdc_register_bridge #(.C_TIMEOUT(C_TIMEOUT)) Bridge_Inst(
        .i_ps_clk(i_ps_clk),.i_ps_run(flag_ps_run),.i_pl_clk(i_pl_clk),.i_pl_run(flag_pl_run),
        .i_wr_addr(reg_local_wa),.i_wr_data(reg_backend_wd),.i_wr_valid(flag_backend_wv & !flag_lease_write),.o_wr_ready(flag_bridge_wr),
        .i_rd_addr(reg_local_ra),.i_rd_valid(flag_backend_rv & !flag_lease_read),.o_rd_ready(flag_bridge_rr),
        .o_rd_data(reg_bridge_data),.o_rd_valid(flag_bridge_valid),.i_rd_ready(flag_backend_ready & !flag_lease_read),.o_fault(flag_link_fault),
        .o_wr_addr(reg_pl_wa),.o_wr_data(reg_pl_wd),.o_wr_valid(flag_pl_wv),.i_wr_ready(flag_pl_wr),
        .o_rd_addr(reg_pl_ra),.o_rd_valid_request(flag_pl_rv),.i_rd_ready_request(flag_pl_rr),
        .i_response_data(reg_pl_data),.i_response_valid(flag_pl_valid),.o_response_ready(flag_pl_ready));
`ifdef GS_LINK_SERVICE
    gs_multinode_link_station #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS),.C_WINDOW(C_WINDOW)) Station_Inst(
`else
    gs_multinode_station #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS),.C_WINDOW(C_WINDOW)) Station_Inst(
`endif
        .i_clk(i_pl_clk),.i_rst(!flag_pl_run),.i_backend_reset(4'd0),
        .i_wr_addr(reg_pl_wa),.i_wr_data(reg_pl_wd),.i_wr_valid(flag_pl_wv),.o_wr_ready(flag_pl_wr),
        .i_rd_addr(reg_pl_ra),.i_rd_valid(flag_pl_rv),.o_rd_ready(flag_pl_rr),
        .o_rd_data(reg_pl_data),.o_rd_valid(flag_pl_valid),.i_rd_ready(flag_pl_ready),.o_alarm_state(o_alarm_state));
endmodule

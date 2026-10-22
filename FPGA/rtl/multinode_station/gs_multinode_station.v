`timescale 1ns / 1ps
// 四个节点统计和告警独立运行，共享有序CPU入口。
module gs_multinode_station #(
    parameter [31:0] C_CLOCKS_PER_MS=32'd200000,
    parameter [8:0] C_WINDOW=9'd64,
    parameter [15:0] C_BAD_HOLD=16'd2,
    parameter [15:0] C_GOOD_HOLD=16'd2
)(
    input i_clk, // 路由与四个节点共用时钟
    input i_rst, // 同步全系统复位
    input [3:0] i_backend_reset, // 各槽独立业务复位，不清guard
    input [31:0] i_wr_addr, // 四千字节局部地址空间
    input [31:0] i_wr_data, // CPU完整写字
    input i_wr_valid, // CPU写地址数据已有效
    output o_wr_ready, // CPU写入口准入
    input [31:0] i_rd_addr, // CPU读取的局部地址
    input i_rd_valid, // CPU读请求资格
    output o_rd_ready, // CPU读入口准入
    output [31:0] o_rd_data, // 有序返回的读取内容
    output o_rd_valid, // 已保留的CPU响应资格
    input i_rd_ready, // CPU响应消费许可
    output [19:0] o_alarm_state, // 四个真实告警状态，槽零位于低位
    output [895:0] o_lane_active, // 共享质量服务的真实活动身份
    output [3:0] o_lane_configured, // 各槽配置资格
    output [7:0] o_lane_pdr, // 已资格化的当前PL条件，零不可用
    output [255:0] o_lane_time_ms, // 各槽原PL时基，仅诊断
    output [31:0] o_lane_generation, // 各槽发布代号
    output [3:0] o_lane_clear, // 配置、复位或运行故障撤销
    output [3:0] o_lane_publication // 新的有效发布事件，区别于毫秒重算空档
);
    wire [31:0] reg_lane_addr, reg_lane_data; // 请求保留槽输出
    wire [3:0] flag_write_valid, flag_write_ready; // 各节点写握手
    wire [3:0] flag_read_valid, flag_read_ready; // 各节点读握手
    wire [3:0] flag_response_valid, flag_response_ready; // 各节点返回握手
    wire [127:0] reg_response_data; // 四个独立守卫返回字
    genvar gen_slot; // 固定四槽硬件复制索引
`ifdef GS_SHARED_QUALITY
    wire [3:0] flag_compute_request,flag_compute_cancel,flag_compute_valid;
    wire [3115:0] wire_compute_payload;
    wire [31:0] wire_compute_generation;
    wire [441:0] wire_compute_result;
    wire [7:0] wire_compute_result_generation;
    gs_shared_quality Shared_Inst(
        .i_clk(i_clk),.i_rst(i_rst),.i_cancel(flag_compute_cancel),.i_request(flag_compute_request),
        .i_payload(wire_compute_payload),.i_generation(wire_compute_generation),
        .o_pending(),.o_replaced(),.o_valid(flag_compute_valid),
        .o_generation(wire_compute_result_generation),.o_payload(wire_compute_result));
    // synthesis translate_off
    initial begin
        if(C_CLOCKS_PER_MS<32)$fatal(1,"shared quality requires at least 32 clocks per millisecond");
    end
    // synthesis translate_on
`endif
    gs_node_bus_router Router_Inst(
        .i_clk(i_clk),.i_rst(i_rst),
        .i_wr_addr(i_wr_addr),.i_wr_data(i_wr_data),.i_wr_valid(i_wr_valid),.o_wr_ready(o_wr_ready),
        .i_rd_addr(i_rd_addr),.i_rd_valid(i_rd_valid),.o_rd_ready(o_rd_ready),
        .o_rd_data(o_rd_data),.o_rd_valid(o_rd_valid),.i_rd_ready(i_rd_ready),
        .o_lane_addr(reg_lane_addr),.o_lane_data(reg_lane_data),
        .o_lane_wr_valid(flag_write_valid),.i_lane_wr_ready(flag_write_ready),
        .o_lane_rd_valid(flag_read_valid),.i_lane_rd_ready(flag_read_ready),
        .i_lane_rd_data(reg_response_data),.i_lane_rd_valid(flag_response_valid),.o_lane_rd_ready(flag_response_ready));
    generate
        for(gen_slot=0;gen_slot<4;gen_slot=gen_slot+1) begin:gen_nodes
            wire [329:0] wire_config;
            wire [65:0] wire_clock;
            wire [453:0] wire_publication;
            assign o_lane_active[gen_slot*224 +: 224]=wire_config[325:102];
            assign o_lane_configured[gen_slot]=wire_config[326] & (!i_backend_reset[gen_slot]) & (!i_rst);
            assign o_lane_time_ms[gen_slot*64 +: 64]=wire_clock[65:2];
            assign o_lane_generation[gen_slot*8 +: 8]=wire_publication[453:446];
            assign o_lane_publication[gen_slot]=wire_publication[443];
            assign o_lane_clear[gen_slot]=i_rst | i_backend_reset[gen_slot] | wire_config[328] |
                wire_clock[0] | wire_publication[444];
            assign o_lane_pdr[gen_slot*2 +: 2]=(wire_publication[442] & wire_publication[434] &
                wire_publication[437] & o_lane_configured[gen_slot] & (!o_lane_clear[gen_slot])) ?
                wire_publication[436:435] : 2'd0;
            // 每槽完整实例拥有自己的时基、窗口、配置、快照及复位代。
            gs_alarm_bus_station #(.C_CLOCKS_PER_MS(C_CLOCKS_PER_MS),.C_WINDOW(C_WINDOW),
                .C_BAD_HOLD(C_BAD_HOLD),.C_GOOD_HOLD(C_GOOD_HOLD)) Station_Inst(
`ifdef GS_SHARED_QUALITY
                .o_compute_request(flag_compute_request[gen_slot]),.o_compute_cancel(flag_compute_cancel[gen_slot]),
                .o_compute_payload(wire_compute_payload[gen_slot*779 +: 779]),.o_compute_generation(wire_compute_generation[gen_slot*8 +: 8]),
                .i_compute_valid(flag_compute_valid[gen_slot]),.i_compute_generation(wire_compute_result_generation),.i_compute_payload(wire_compute_result),
`endif
                .i_clk(i_clk),.i_rst(i_rst),.i_backend_reset(i_backend_reset[gen_slot]),
                .i_wr_addr(reg_lane_addr),.i_wr_data(reg_lane_data),.i_wr_valid(flag_write_valid[gen_slot]),.o_wr_ready(flag_write_ready[gen_slot]),
                .i_rd_addr(reg_lane_addr),.i_rd_valid(flag_read_valid[gen_slot]),.o_rd_ready(flag_read_ready[gen_slot]),
                .o_rd_data(reg_response_data[gen_slot*32 +: 32]),.o_rd_valid(flag_response_valid[gen_slot]),.i_rd_ready(flag_response_ready[gen_slot]),
                .o_config_state(wire_config),.o_clock_state(wire_clock),.o_cache_state(),.o_publication_state(wire_publication),.o_window_state(),
                .o_alarm_state(o_alarm_state[gen_slot*5 +: 5]),.o_snapshot_state());
        end
    endgenerate
endmodule

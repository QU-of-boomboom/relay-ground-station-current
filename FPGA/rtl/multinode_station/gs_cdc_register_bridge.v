`timescale 1ns / 1ps
// 单在途请求/完成mailbox；超时永久锁停至桥复位，绝不自动重发。
module gs_cdc_register_bridge #(
    parameter [31:0] C_TIMEOUT=32'd1000000 // PS等待完成的最大拍数
)(
    input i_ps_clk, input i_ps_run, // 已共同同步释放的PS域
    input i_pl_clk, input i_pl_run, // 已共同同步释放的PL域
    input [31:0] i_wr_addr, input [31:0] i_wr_data, input i_wr_valid,
    output o_wr_ready,
    input [31:0] i_rd_addr, input i_rd_valid, output o_rd_ready,
    output [31:0] o_rd_data, output o_rd_valid, input i_rd_ready,
    output o_fault, // PS域粘滞完成未知
    output [31:0] o_wr_addr, output [31:0] o_wr_data, output o_wr_valid,
    input i_wr_ready,
    output [31:0] o_rd_addr, output o_rd_valid_request, input i_rd_ready_request,
    input [31:0] i_response_data, input i_response_valid, output o_response_ready
);
    localparam [1:0] ST_PS_IDLE=2'd0, ST_PS_WAIT=2'd1, ST_PS_HOLD=2'd2;
    localparam [2:0] ST_PL_IDLE=3'd0, ST_PL_WRITE=3'd1, ST_PL_READ=3'd2, ST_PL_WAIT=3'd3, ST_PL_SEND=3'd4;
    reg [1:0] state_ps_current,state_ps_next;
    reg [2:0] state_pl_current,state_pl_next;
    reg flag_fault,flag_read_owned;
    reg [31:0] cnt_wait,reg_ps_response;
    reg [64:0] reg_pl_request;
    reg [32:0] reg_pl_response;
    wire flag_cmd_ready,flag_cmd_valid,flag_cmd_take,flag_submit;
    wire [64:0] reg_cmd_payload;
    wire [64:0] reg_received_command;
    wire flag_rsp_ready,flag_rsp_valid,flag_rsp_take,flag_rsp_submit;
    wire [32:0] reg_received_response;
    wire flag_write_take,flag_read_take,flag_expired,flag_response_match;
    wire flag_cmd_done,flag_rsp_done;
    assign o_wr_ready=i_ps_run & !flag_fault & (state_ps_current==ST_PS_IDLE) & flag_cmd_ready;
    assign o_rd_ready=o_wr_ready & !i_wr_valid;
    assign flag_write_take=i_wr_valid & o_wr_ready;
    assign flag_read_take=i_rd_valid & o_rd_ready;
    assign flag_submit=flag_write_take | flag_read_take;
    assign reg_cmd_payload=flag_write_take ? {1'b0,i_wr_addr,i_wr_data} : {1'b1,i_rd_addr,32'd0};
    assign o_rd_valid=i_ps_run & !flag_fault & (state_ps_current==ST_PS_HOLD);
    assign o_rd_data=reg_ps_response;
    assign o_fault=flag_fault;
    assign flag_expired=(cnt_wait>=C_TIMEOUT-32'd1);
    assign flag_response_match=(reg_received_response[32]==flag_read_owned);
    assign flag_rsp_take=i_ps_run & !flag_fault & (state_ps_current==ST_PS_WAIT);
    assign flag_cmd_take=i_pl_run & (state_pl_current==ST_PL_IDLE);
    assign o_wr_addr=reg_pl_request[63:32];
    assign o_wr_data=reg_pl_request[31:0];
    assign o_wr_valid=i_pl_run & (state_pl_current==ST_PL_WRITE);
    assign o_rd_addr=reg_pl_request[63:32];
    assign o_rd_valid_request=i_pl_run & (state_pl_current==ST_PL_READ);
    assign o_response_ready=i_pl_run & (state_pl_current==ST_PL_WAIT);
    assign flag_rsp_submit=i_pl_run & (state_pl_current==ST_PL_SEND);
    gs_cdc_mailbox #(.WIDTH(65),.RESET_PRE_SYNCED(1)) Command_Inst(
        .src_clk(i_ps_clk),.src_rst_n(i_ps_run),.src_submit(flag_submit),.src_data(reg_cmd_payload),.src_ready(flag_cmd_ready),.src_done(flag_cmd_done),
        .dst_clk(i_pl_clk),.dst_rst_n(i_pl_run),.dst_valid(flag_cmd_valid),.dst_data(reg_received_command),.dst_ready(flag_cmd_take));
    gs_cdc_mailbox #(.WIDTH(33),.RESET_PRE_SYNCED(1)) Response_Inst(
        .src_clk(i_pl_clk),.src_rst_n(i_pl_run),.src_submit(flag_rsp_submit),.src_data(reg_pl_response),.src_ready(flag_rsp_ready),.src_done(flag_rsp_done),
        .dst_clk(i_ps_clk),.dst_rst_n(i_ps_run),.dst_valid(flag_rsp_valid),.dst_data(reg_received_response),.dst_ready(flag_rsp_take));
    // 来源状态与任务处理分开，锁停后不再开放任何事务。
    always @(posedge i_ps_clk or negedge i_ps_run) begin
        if(!i_ps_run) begin state_ps_current<=ST_PS_IDLE; end
        else begin state_ps_current<=state_ps_next; end
    end
    always @(*) begin
        state_ps_next=state_ps_current;
        case(state_ps_current)
            ST_PS_IDLE:begin
                if(flag_submit) begin state_ps_next=ST_PS_WAIT; end
            end
            ST_PS_WAIT:begin
                if(flag_rsp_valid & flag_rsp_take & flag_response_match) begin
                    if(flag_read_owned) begin state_ps_next=ST_PS_HOLD; end
                    else begin state_ps_next=ST_PS_IDLE; end
                end
            end
            ST_PS_HOLD:begin
                if(i_rd_ready) begin state_ps_next=ST_PS_IDLE; end
            end
            default:begin state_ps_next=ST_PS_IDLE; end
        endcase
    end
    // 完成在截止沿到达时优先接纳；没有匹配完成才判超时。
    always @(posedge i_ps_clk or negedge i_ps_run) begin
        if(!i_ps_run) begin
            cnt_wait<=32'd0; flag_fault<=1'b0; flag_read_owned<=1'b0; reg_ps_response<=32'd0;
        end else begin
            if(flag_submit) begin flag_read_owned<=flag_read_take; cnt_wait<=32'd0; end
            else if((state_ps_current==ST_PS_WAIT) & !flag_fault) begin
                if(flag_rsp_valid) begin
                    if(!flag_response_match) begin flag_fault<=1'b1; end
                    else begin reg_ps_response<=reg_received_response[31:0]; end
                end else if(flag_expired) begin flag_fault<=1'b1; end
                else begin cnt_wait<=cnt_wait+32'd1; end
            end
        end
    end
    // 执行域将每个请求只提交一次，再返回同种类完成。
    always @(posedge i_pl_clk or negedge i_pl_run) begin
        if(!i_pl_run) begin state_pl_current<=ST_PL_IDLE; end
        else begin state_pl_current<=state_pl_next; end
    end
    always @(*) begin
        state_pl_next=state_pl_current;
        case(state_pl_current)
            ST_PL_IDLE:begin
                if(flag_cmd_valid) begin
                    if(reg_received_command[64]) begin state_pl_next=ST_PL_READ; end
                    else begin state_pl_next=ST_PL_WRITE; end
                end
            end
            ST_PL_WRITE:begin if(i_wr_ready) begin state_pl_next=ST_PL_SEND; end end
            ST_PL_READ:begin if(i_rd_ready_request) begin state_pl_next=ST_PL_WAIT; end end
            ST_PL_WAIT:begin if(i_response_valid) begin state_pl_next=ST_PL_SEND; end end
            ST_PL_SEND:begin if(flag_rsp_ready) begin state_pl_next=ST_PL_IDLE; end end
            default:begin state_pl_next=ST_PL_IDLE; end
        endcase
    end
    always @(posedge i_pl_clk or negedge i_pl_run) begin
        if(!i_pl_run) begin reg_pl_request<=65'd0; reg_pl_response<=33'd0; end
        else begin
            if(flag_cmd_take & flag_cmd_valid) begin reg_pl_request<=reg_received_command; end
            if(o_wr_valid & i_wr_ready) begin reg_pl_response<=33'd0; end
            else if(o_response_ready & i_response_valid) begin reg_pl_response<={1'b1,i_response_data}; end
        end
    end
    generate if(C_TIMEOUT<32'd2) begin:gen_invalid_timeout
        ERROR_TIMEOUT_MUST_BE_AT_LEAST_TWO Invalid_Inst();
    end endgenerate
endmodule

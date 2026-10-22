`timescale 1ns / 1ps
// 分阶段总线质量服务；S沿冻结、S+1判定、S+2执行，原默认模块保留。
module gs_link_service_sequenced #(
    parameter integer C_CAPTURE_LIMIT=32 // 等待当前PDR发布的最大采样沿数
)(
    input i_clk, // 唯一PL时钟，目标200MHz
    input i_rst, // 同步高复位取消请求与读响应
    input [895:0] i_lane_active, // 四个224位真实配置身份，槽零低位
    input [3:0] i_lane_configured, // 各槽已配置资格
    input [7:0] i_lane_pdr, // 各槽已资格化当前PDR，0表示不可用
    input [255:0] i_lane_time_ms, // 各槽PL计数，仅诊断
    input [31:0] i_lane_generation, // 各槽发布代号，仅诊断
    input [3:0] i_lane_clear, // 各槽配置提交/业务复位/故障撤销事件
    input [31:0] i_wr_addr, // 128字节局部地址，完整译码
    input [31:0] i_wr_data, // 全字写数据
    input i_wr_valid, // 写请求
    output o_wr_ready, // 请求接受，协议错误写仍被接受并记错
    input [31:0] i_rd_addr, // 完整局部读地址
    input i_rd_valid, // 读请求
    output o_rd_ready, // 无未消费响应时接受
    output [31:0] o_rd_data, // 已注册并保持的读响应
    output o_rd_valid, // 响应资格
    input i_rd_ready, // 响应消费
    output o_quality_valid, // 结果完成单拍，不依赖CPU是否读取
    output [1:0] o_quality_slot,output [31:0] o_quality_tag,
    output [2:0] o_quality_required,output [1:0] o_quality_pdr,
    output [1:0] o_quality_condition,output [2:0] o_quality_missing,
    output [7:0] o_quality_generation
);
    localparam [2:0] LP_IDLE=3'd0,LP_CAPTURE=3'd1,LP_COMPARE=3'd2,LP_LAUNCH=3'd3,LP_WAIT=3'd4;
    localparam [1:0] C_BUS_IDLE=2'd0,C_BUS_DECODE=2'd1,C_BUS_APPLY=2'd2;
    localparam [3:0] C_READ=4'd0,C_SHADOW=4'd1,C_INDEX=4'd2,C_SUBMIT=4'd3,
        C_RELEASE=4'd4,C_CLEAR=4'd5,C_BAD_ADDRESS=4'd6,C_BAD_DATA=4'd7;
    reg [1:0] reg_bus_state,wire_bus_next; // 请求槽与两阶段延迟
    reg [3:0] reg_request_kind,wire_request_kind; // 接受沿冻结完整地址/命令类别
    reg [6:0] reg_request_view; // bit0忙、1完成、2读背压、3已有错、4写齐、5坏标签、6坏flags
    reg [4:0] reg_request_word; // 已译码的shadow字索引
    reg [31:0] reg_request_data,reg_request_read; // 写字或S沿读快照
    reg [3:0] reg_request_read_error,reg_command_error,wire_command_error;
    reg [3:0] reg_pending_clear; // 从接受到实际提交的四槽撤销累计
    reg [2:0] reg_state; // 单请求执行阶段
    reg [799:0] reg_shadow; // 25字请求，提交至结果释放期间禁止修改
    reg [24:0] reg_written; // 本次完整写覆盖
    reg [31:0] reg_last_tag; // 接受过的最大tag，禁止复用或回绕
    reg [31:0] reg_error; // 粘滞协议错误
    reg flag_done; // 冻结结果存在
    reg [1:0] reg_slot; // 冻结服务对象
    reg [7:0] reg_capture_count; // 有界等待，不无限阻塞寄存器
    reg [223:0] reg_captured_active; // 真实PDR同沿的完整活动身份
    reg [13:0] flag_identity_equal; // 14段16位并行比较
    reg flag_binding_bad,flag_revoked; // 身份失败与在途撤销
    reg [1:0] reg_captured_pdr; // 同沿且受PS来源许可约束的PDR
    reg [63:0] reg_captured_time; // PL诊断时间，不参与PS时域推算
    reg [7:0] reg_captured_generation; // PDR来源代号
    reg [16:0] reg_result; // 完整结果状态
    reg [3:0] reg_result_index; // 12字冻结结果索引
    reg [31:0] reg_read_data; // 保持到消费，后续错误不改变它
    reg flag_read_valid; // 单槽读响应
    reg [31:0] wire_read_value,wire_read_error; // 完整默认赋值译码
    wire flag_write,flag_read,flag_busy,flag_shadow_address;
    wire [31:0] wire_result_word;
    reg [31:0] wire_selected_result;
    wire flag_core_valid,flag_core_invalid;
    wire [31:0] reg_core_tag;
    wire [1:0] reg_core_condition,reg_core_rtt,reg_core_rtt_reason,reg_core_aoi,reg_core_aoi_reason;
    wire [2:0] reg_core_missing;
    wire flag_current_revocation;
    genvar gen_identity;

    reg flag_quality_event;
    assign o_quality_valid=(!i_rst) & flag_quality_event;
    assign o_quality_slot=reg_slot;
    assign o_quality_tag=reg_shadow[31:0];
    assign o_quality_required=reg_shadow[36:34];
    assign o_quality_pdr=reg_result[15:14];
    assign o_quality_condition=reg_result[1:0];
    assign o_quality_missing=reg_result[4:2];
    assign o_quality_generation=reg_captured_generation;
    always @(posedge i_clk)begin
        if(i_rst)flag_quality_event<=1'b0;
        else flag_quality_event<=(reg_state==LP_WAIT) & flag_core_valid;
    end
    assign flag_busy=(reg_state!=LP_IDLE);
    assign o_wr_ready=(!i_rst) & (reg_bus_state==C_BUS_IDLE);
    assign o_rd_ready=(!i_rst) & (reg_bus_state==C_BUS_IDLE) & (!flag_read_valid) & (!i_wr_valid);
    assign o_rd_data=reg_read_data;
    assign o_rd_valid=(!i_rst) & flag_read_valid;
    assign flag_write=i_wr_valid & o_wr_ready;
    assign flag_read=i_rd_valid & o_rd_ready;
    assign flag_shadow_address=(i_wr_addr[31:7]==25'd0) & (i_wr_addr[1:0]==2'd0) &
        (i_wr_addr[6:2]>=5'd4) & (i_wr_addr[6:2]<=5'd28);
    assign flag_current_revocation=flag_revoked | i_lane_clear[reg_slot];
    assign wire_result_word=wire_selected_result;

    // 输入25字仅单写口；结果身份和tag直接引用被冻结的shadow，避免重复宽寄存器。
    always @(*) begin
        wire_selected_result=32'd0;
        case(reg_result_index)
            4'd0:wire_selected_result=reg_shadow[31:0];
            4'd1:wire_selected_result={15'd0,reg_result};
            4'd2:wire_selected_result=reg_shadow[95:64];
            4'd3:wire_selected_result=reg_shadow[127:96];
            4'd4:wire_selected_result=reg_shadow[159:128];
            4'd5:wire_selected_result=reg_shadow[191:160];
            4'd6:wire_selected_result=reg_shadow[223:192];
            4'd7:wire_selected_result=reg_shadow[255:224];
            4'd8:wire_selected_result=reg_shadow[287:256];
            4'd9:wire_selected_result=reg_captured_time[31:0];
            4'd10:wire_selected_result=reg_captured_time[63:32];
            4'd11:wire_selected_result={24'd0,reg_captured_generation};
            default:wire_selected_result=32'd0;
        endcase
    end
    always @(*) begin
        wire_read_value=32'd0;
        wire_read_error=32'd0;
        case(i_rd_addr)
            32'h00:wire_read_value=32'h47535134;
            32'h04:wire_read_value=32'h0001001a;
            32'h08:wire_read_value={27'd0,flag_revoked,(reg_error!=32'd0),(&reg_written),flag_done,flag_busy};
            32'h0c:wire_read_value=reg_error;
            32'h74:wire_read_value=reg_last_tag;
            32'h78:begin
                if(flag_done)wire_read_value=wire_result_word;
                else wire_read_error=32'd7;
            end
            32'h7c:wire_read_value={7'd0,reg_written};
            default:begin
                if((i_rd_addr[31:7]==25'd0) & (i_rd_addr[1:0]==2'd0) &
                    (i_rd_addr[6:2]>=5'd4) & (i_rd_addr[6:2]<=5'd28))
                    wire_read_value=reg_shadow[(i_rd_addr[6:2]-5'd4)*32 +: 32];
                else wire_read_error=32'd1;
            end
        endcase
    end
    // S沿的类别译码与资格冻结互不经过完整错误优先级。
    always @(*) begin
        wire_request_kind=C_BAD_ADDRESS;
        if(flag_shadow_address)wire_request_kind=C_SHADOW;
        else if(i_wr_addr==32'h74)begin
            if(i_wr_data>32'd11)wire_request_kind=C_BAD_DATA;
            else wire_request_kind=C_INDEX;
        end else if(i_wr_addr==32'h08)begin
            case(i_wr_data)
                32'd1:wire_request_kind=C_SUBMIT;
                32'd2:wire_request_kind=C_RELEASE;
                32'd4:wire_request_kind=C_CLEAR;
                default:wire_request_kind=C_BAD_DATA;
            endcase
        end
    end
    // 仅冻结的单比特事实进入优先级，不再从执行状态贯穿到执行使能。
    always @(*) begin
        wire_command_error=4'd0;
        case(reg_request_kind)
            C_READ:wire_command_error=reg_request_read_error;
            C_SHADOW:if(reg_request_view[0] | reg_request_view[1])wire_command_error=4'd3;
            C_INDEX:if(reg_request_view[0] | (!reg_request_view[1]) | reg_request_view[2])wire_command_error=4'd3;
            C_SUBMIT:begin
                if(reg_request_view[0] | reg_request_view[1] | reg_request_view[2])wire_command_error=4'd3;
                else if(reg_request_view[3])wire_command_error=4'd8;
                else if(!reg_request_view[4])wire_command_error=4'd4;
                else if(reg_request_view[5])wire_command_error=4'd5;
                else if(reg_request_view[6])wire_command_error=4'd6;
            end
            C_RELEASE:begin
                if(reg_request_view[0] | reg_request_view[2])wire_command_error=4'd3;
                else if(!reg_request_view[1])wire_command_error=4'd7;
            end
            C_CLEAR:if(reg_request_view[0] | reg_request_view[1] | reg_request_view[2])wire_command_error=4'd3;
            C_BAD_ADDRESS:wire_command_error=4'd1;
            C_BAD_DATA:wire_command_error=4'd2;
            default:wire_command_error=4'd1;
        endcase
    end
    always @(*) begin
        wire_bus_next=reg_bus_state;
        case(reg_bus_state)
            C_BUS_IDLE:if(flag_write | flag_read)wire_bus_next=C_BUS_DECODE;
            C_BUS_DECODE:wire_bus_next=C_BUS_APPLY;
            C_BUS_APPLY:wire_bus_next=C_BUS_IDLE;
            default:wire_bus_next=C_BUS_IDLE;
        endcase
    end
    always @(posedge i_clk)begin
        if(i_rst)reg_bus_state<=C_BUS_IDLE;
        else reg_bus_state<=wire_bus_next;
    end
    always @(posedge i_clk)begin
        if(i_rst)begin
            reg_request_kind<=C_READ;reg_request_view<=7'd0;reg_request_word<=5'd0;
            reg_request_data<=32'd0;reg_request_read<=32'd0;reg_request_read_error<=4'd0;
            reg_command_error<=4'd0;reg_pending_clear<=4'd0;
            reg_read_data<=32'd0;flag_read_valid<=1'b0;
        end else begin
            if(i_rd_ready)flag_read_valid<=1'b0;
            if(reg_bus_state!=C_BUS_IDLE)reg_pending_clear<=reg_pending_clear | i_lane_clear;
            case(reg_bus_state)
                C_BUS_IDLE:begin
                    if(flag_write | flag_read)begin
                        reg_request_kind<=flag_write ? wire_request_kind : C_READ;
                        reg_request_word<=i_wr_addr[6:2]-5'd4;
                        reg_request_data<=i_wr_data;
                        reg_request_read<=wire_read_value;
                        reg_request_read_error<=wire_read_error[3:0];
                        reg_request_view<= {(reg_shadow[63:40]!=24'd0) | (!reg_shadow[34]),
                            (reg_shadow[31:0]==32'd0) | (reg_shadow[31:0]<=reg_last_tag),
                            (&reg_written),(reg_error!=32'd0),flag_read_valid,flag_done,flag_busy};
                        reg_pending_clear<=i_lane_clear;
                    end
                end
                C_BUS_DECODE:reg_command_error<=wire_command_error;
                C_BUS_APPLY:begin
                    if(reg_request_kind==C_READ)begin
                        reg_read_data<=reg_request_read;flag_read_valid<=1'b1;
                    end
                end
                default:reg_command_error<=4'd1;
            endcase
        end
    end
    generate
        for(gen_identity=0;gen_identity<14;gen_identity=gen_identity+1)begin:gen_compare
            always @(posedge i_clk)begin
                if(i_rst)flag_identity_equal[gen_identity]<=1'b0;
                else if(reg_state==LP_COMPARE)
                    flag_identity_equal[gen_identity]<=
                        (reg_captured_active[gen_identity*16 +: 16]==reg_shadow[64+gen_identity*16 +: 16]);
            end
        end
    endgenerate
    gs_link_quality Core_Inst(
        .i_clk(i_clk),.i_rst(i_rst),.i_valid(reg_state==LP_LAUNCH),.i_tag(reg_shadow[31:0]),
        .i_pdr(((&flag_identity_equal) & (!flag_current_revocation)) ? reg_captured_pdr : 2'd0),
        .i_required(reg_shadow[36:34]),.i_rtt_available(reg_shadow[37]),
        .i_rtt_lower(reg_shadow[351:288]),.i_rtt_upper(reg_shadow[415:352]),
        .i_rtt_good(reg_shadow[479:416]),.i_rtt_bad(reg_shadow[543:480]),
        .i_aoi_available(reg_shadow[38]),.i_aoi_lower(reg_shadow[607:544]),
        .i_aoi_upper(reg_shadow[671:608]),.i_aoi_good(reg_shadow[735:672]),.i_aoi_bad(reg_shadow[799:736]),
        .o_valid(flag_core_valid),.o_tag(reg_core_tag),.o_condition(reg_core_condition),.o_missing(reg_core_missing),
        .o_invalid(flag_core_invalid),.o_rtt_condition(reg_core_rtt),.o_rtt_reason(reg_core_rtt_reason),
        .o_aoi_condition(reg_core_aoi),.o_aoi_reason(reg_core_aoi_reason));
    always @(posedge i_clk)begin
        if(i_rst)begin
            reg_state<=LP_IDLE;reg_shadow<=800'd0;reg_written<=25'd0;
            reg_last_tag<=32'd0;reg_error<=32'd0;flag_done<=1'b0;reg_slot<=2'd0;
            reg_capture_count<=8'd0;reg_captured_active<=224'd0;
            flag_binding_bad<=1'b0;flag_revoked<=1'b0;reg_captured_pdr<=2'd0;
            reg_captured_time<=64'd0;reg_captured_generation<=8'd0;
            reg_result<=17'd0;reg_result_index<=4'd0;
        end else begin
            if((flag_busy | flag_done) & i_lane_clear[reg_slot])flag_revoked<=1'b1;
            case(reg_state)
                LP_CAPTURE:begin
                    if((i_lane_configured[reg_slot] & (i_lane_pdr[reg_slot*2 +: 2]!=2'd0)) |
                        (reg_capture_count==C_CAPTURE_LIMIT-1) | flag_current_revocation)begin
                        reg_captured_active<=i_lane_active[reg_slot*224 +: 224];
                        reg_captured_pdr<=(i_lane_configured[reg_slot] & reg_shadow[39]) ?
                            i_lane_pdr[reg_slot*2 +: 2] : 2'd0;
                        reg_captured_time<=i_lane_time_ms[reg_slot*64 +: 64];
                        reg_captured_generation<=i_lane_generation[reg_slot*8 +: 8];
                        reg_state<=LP_COMPARE;
                    end else reg_capture_count<=reg_capture_count+8'd1;
                end
                LP_COMPARE:reg_state<=LP_LAUNCH;
                LP_LAUNCH:begin flag_binding_bad<=!(&flag_identity_equal);reg_state<=LP_WAIT;end
                LP_WAIT:begin
                    if(flag_core_valid)begin
                        reg_result<={flag_binding_bad | flag_current_revocation,reg_captured_pdr,
                            reg_core_aoi_reason,reg_core_aoi,reg_core_rtt_reason,reg_core_rtt,
                            flag_core_invalid,reg_core_missing,reg_core_condition};
                        // 最终撤销优先，避免clear恰好在流水结束沿时逃逸。
                        if(flag_binding_bad | flag_current_revocation)begin
                            reg_result[1:0]<=2'd0;
                            reg_result[4:2]<=reg_shadow[36:34];
                        end
                        flag_done<=1'b1;reg_state<=LP_IDLE;
                    end
                end
                default:reg_state<=LP_IDLE;
            endcase
            // S+2只使用已登记类别和错误码；总线槽期间禁止另一笔写改变shadow。
            if((reg_bus_state==C_BUS_APPLY) & (reg_command_error==4'd0))begin
                case(reg_request_kind)
                    C_SHADOW:begin
                        reg_shadow[reg_request_word*32 +: 32]<=reg_request_data;
                        reg_written[reg_request_word]<=1'b1;
                    end
                    C_INDEX:reg_result_index<=reg_request_data[3:0];
                    C_SUBMIT:begin
                        reg_slot<=reg_shadow[33:32];reg_last_tag<=reg_shadow[31:0];reg_written<=25'd0;
                        reg_state<=LP_CAPTURE;reg_capture_count<=8'd0;flag_binding_bad<=1'b0;
                        flag_revoked<=reg_pending_clear[reg_shadow[33:32]] | i_lane_clear[reg_shadow[33:32]];
                    end
                    C_RELEASE:begin flag_done<=1'b0;reg_result_index<=4'd0;end
                    C_CLEAR:begin reg_error<=32'd0;reg_written<=25'd0;end
                    default:reg_error<=reg_error;
                endcase
            end
            if((reg_bus_state==C_BUS_APPLY) & (reg_command_error!=4'd0))
                reg_error<={28'd0,reg_command_error};
        end
    end
    // synthesis translate_off
    initial begin
        if(C_CAPTURE_LIMIT<1 || C_CAPTURE_LIMIT>255)$fatal(1,"link service capture limit must be 1..255");
    end
    // synthesis translate_on
endmodule

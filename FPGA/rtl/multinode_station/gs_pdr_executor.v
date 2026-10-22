`timescale 1ns/1ps
// PDR transaction executor / PDR结算事务执行器。
// One request owns the window until its stable response is consumed.
module gs_pdr_executor #(
    parameter integer WINDOW = 64
)(
    input wire clk,
    input wire rst,
    input wire [255:0] cmd_data,
    input wire cmd_valid,
    output wire cmd_ready,
    output wire [255:0] rsp_data,
    output wire rsp_valid,
    input wire rsp_ready
);
    localparam [2:0] IDLE=3'd0, COMPARE=3'd1, DECIDE=3'd2,
                     BEGIN_BATCH=3'd3, APPLY=3'd4, CAPTURE=3'd5, RESPONSE=3'd6;
    reg [2:0] state, next_state;
    reg [255:0] request;
    reg [255:0] response;
    reg active;
    reg [63:0] epoch, session;
    reg [31:0] node, next_index, last_index;
    reg last_result, last_valid;
    reg [7:0] result_code;
    wire [7:0] opcode = request[7:0];
    // 宽字段比较先寄存，再进入决策，避免比较与多层选择串成一路。
    reg fields_ok, identity_equal, epoch_equal, epoch_less;
    reg previous_equal, index_less, index_greater, exhausted;
    reg [7:0] decision_code;
    wire [8:0] count, delivered;
    wire window_valid, window_full;
    wire clear_window = rst || (state == BEGIN_BATCH);
    wire sample_window = !rst && (state == APPLY);
    assign cmd_ready = !rst && (state == IDLE);
    assign rsp_valid = !rst && (state == RESPONSE);
    assign rsp_data = response;

    gs_pdr_window #(.WINDOW(WINDOW)) window_core (
        .clk(clk), .rst(clear_window), .in_valid(sample_window), .received(request[8]),
        .count(count), .delivered(delivered), .lost(),
        .result_valid(window_valid), .window_full(window_full)
    );

    // 检查顺序与软件契约一致，拒绝命令不修改窗口或活动身份。
    always @(*) begin
        decision_code = 8'd0;
        if (!fields_ok) begin
            decision_code = 8'd8;
        end
        else if (opcode == 8'd1) begin
            if (active && epoch_less) begin
                decision_code = 8'd9;
            end else if (active && epoch_equal) begin
                decision_code = identity_equal ? 8'd1 : 8'd6;
            end
        end else if (!active) begin
            decision_code = 8'd2;
        end else if (!identity_equal) begin
            decision_code = 8'd3;
        end
        else if (opcode == 8'd2) begin
            if (last_valid && previous_equal) begin
                decision_code = (request[8] == last_result) ? 8'd1 : 8'd6;
            end else if (index_less) begin
                decision_code = 8'd4;
            end else if (exhausted) begin
                decision_code = 8'd7;
            end else if (index_greater) begin
                decision_code = 8'd5;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (cmd_valid && cmd_ready) begin
                    next_state = COMPARE;
                end
            end
            COMPARE: next_state = DECIDE;
            DECIDE: begin
                if (decision_code != 0) begin
                    next_state = CAPTURE;
                end else if (opcode == 8'd1) begin
                    next_state = BEGIN_BATCH;
                end else if (opcode == 8'd2) begin
                    next_state = APPLY;
                end else begin
                    next_state = CAPTURE;
                end
            end
            BEGIN_BATCH: next_state = CAPTURE;
            APPLY: next_state = CAPTURE;
            CAPTURE: next_state = RESPONSE;
            RESPONSE: begin
                if (rsp_valid && rsp_ready) begin
                    next_state = IDLE;
                end
            end
            default: next_state = IDLE;
        endcase
    end

    // APPLY与CAPTURE隔开一个边沿，返回值包含刚写入的窗口结果。
    always @(posedge clk) begin
        if (rst) begin
            request <= 256'd0;
            response <= 256'd0;
            active <= 1'b0;
            epoch <= 64'd0;
            session <= 64'd0;
            node <= 32'd0;
            next_index <= 32'd0;
            last_index <= 32'd0;
            last_result <= 1'b0;
            last_valid <= 1'b0;
            result_code <= 8'd0;
            fields_ok <= 1'b0;
            identity_equal <= 1'b0;
            epoch_equal <= 1'b0;
            epoch_less <= 1'b0;
            previous_equal <= 1'b0;
            index_less <= 1'b0;
            index_greater <= 1'b0;
            exhausted <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (cmd_valid && cmd_ready) begin
                        request <= cmd_data;
                    end
                end
                COMPARE: begin
                    fields_ok <= (request[255:224] == 0) && (request[15:9] == 0) &&
                        (opcode >= 1 && opcode <= 3) && (request[95:32] != 0) &&
                        (request[127:96] != 0) && (request[191:128] != 0) &&
                        ((opcode == 2) || ((request[223:192] == 0) && !request[8]));
                    epoch_equal <= request[95:32] == epoch;
                    epoch_less <= request[95:32] < epoch;
                    identity_equal <= (request[95:32] == epoch) &&
                        (request[127:96] == node) && (request[191:128] == session);
                    previous_equal <= request[223:192] == last_index;
                    index_less <= request[223:192] < next_index;
                    index_greater <= request[223:192] > next_index;
                    exhausted <= next_index == 32'hffffffff;
                end
                DECIDE: result_code <= decision_code;
                BEGIN_BATCH: begin
                    active <= 1'b1;
                    epoch <= request[95:32];
                    node <= request[127:96];
                    session <= request[191:128];
                    next_index <= 32'd0;
                    last_index <= 32'd0;
                    last_result <= 1'b0;
                    last_valid <= 1'b0;
                end
                APPLY: begin
                    last_index <= next_index;
                    next_index <= next_index + 32'd1;
                    last_result <= request[8];
                    last_valid <= 1'b1;
                end
                CAPTURE: response <= {session, node, 14'd0, delivered, count,
                    next_index, epoch, 5'd0, window_full, window_valid, active,
                    result_code, request[31:16]};
                default: begin
                end
            endcase
        end
    end
endmodule

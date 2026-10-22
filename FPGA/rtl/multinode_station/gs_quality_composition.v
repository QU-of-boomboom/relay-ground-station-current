`timescale 1ns / 1ps

////////////////////////////////////English///////////////////////////////////////
// Company:         Relay project
// Engineer:        Relay project
//
// Create Date:     2026/10/03 14:36:36
// Design Name:     gs_quality_composition
// Module Name:     gs_quality_composition
// Description:     gs_quality_composition_spec.md
// Simulations:     sim/tb_gs_quality_composition.v
//
// Referrences:     None
//
// Dependencies:    None
//
// Version:         V1.0
// Revision Date:   2026/10/03 14:36:36
// History:
// Time             Version     Revised by        Contents
// 2026/10/03       V1.0        Relay project              Create file.
///////////////////////////////////Chinese////////////////////////////////////////
// 版权归属:        Relay project
// 开发人员:        Relay project
//
// 创建日期:        2026年10月03日
// 设计名称:        gs_quality_composition
// 模块名称:        gs_quality_composition
// 模块说明:        gs_quality_composition_spec.md
// 仿真工程:        sim/tb_gs_quality_composition.v
//
// 参考资料:        None
//
// 依赖文件:        None
//
// 当前版本:        V1.0
// 修订日期:        2026年10月03日
// 修订历史:
// 时间             版本        修订人            修订内容
// 2026年10月03日   V1.0        Relay project              创建文件

module gs_quality_composition
(
	//-----------------全局信号-----------------//
	input i_clk,                                // 合成流水时钟
	input i_rst,                                // 同步高有效复位
	input i_clear,                              // 丢弃全部在途与同沿输入

	//-----------------用户接口-----------------//
	input i_valid,                              // 独立于证据存在的事务有效
	input [2:0] i_quality,                      // 数值质量编码
	input [1:0] i_binding,                      // 身份与修订归属编码
	input [1:0] i_time_status,                  // 来源时间判定
	input i_update_ok,                          // 统计更新成功
	input i_global_invalid,                     // 当前控制原字段非法
	input i_evidence_present,                   // 是否持有统计证据
	input [15:0] i_tag,                         // 可重复核对标签
	input [353:0] i_context,                    // 原来源上下文
	input [63:0] i_evaluated_ms,                // 原评估时刻
	output o_valid,                             // 包含拒绝结果的事务有效
	output [3:0] o_reason,                      // 完整拒绝或质量原因
	output [2:0] o_condition,                   // 语义条件而非告警二位编码
	output o_usable,                            // 仅有效数值质量可使用
	output [15:0] o_tag,                        // 返回输入标签
	output [353:0] o_context,                   // 返回同笔来源快照
	output [63:0] o_evaluated_ms                // 返回采样时刻
);

	//----------------寄存器信号----------------//
	reg [8:0] reg_leaf_control;                 // 控制原字段拒绝
	reg [8:0] reg_leaf_absent;                  // 空证据评估
	reg [8:0] reg_leaf_quality_reserved_low;    // 数值保留五
	reg [8:0] reg_leaf_quality_reserved_high;   // 数值保留六
	reg [8:0] reg_leaf_binding_reserved;        // 归属保留三
	reg [8:0] reg_leaf_identity;                // 链路身份错配
	reg [8:0] reg_leaf_revision;                // 配置版本不符
	reg [8:0] reg_leaf_quality_reject;          // 来源统计非法
	reg [8:0] reg_leaf_time_reject;             // 时间来源越界
	reg [8:0] reg_leaf_update;                  // 结算更新失败
	reg [8:0] reg_leaf_empty;                   // 样本窗口为空
	reg [8:0] reg_leaf_unknown;                 // 来源时刻未知
	reg [8:0] reg_leaf_stale;                   // 来源证据过期
	reg [8:0] reg_leaf_warmup;                  // 数量尚未预热
	reg [8:0] reg_leaf_bad;                     // 接收率低区
	reg [8:0] reg_leaf_band;                    // 接收率滞回带
	reg [8:0] reg_pair_alpha;                   // 控制与空证据
	reg [8:0] reg_pair_beta;                    // 两个数值保留码
	reg [8:0] reg_pair_gamma;                   // 绑定保留及身份
	reg [8:0] reg_pair_delta;                   // 修订与计数合法性
	reg [8:0] reg_pair_epsilon;                 // 来源时间及更新
	reg [8:0] reg_pair_zeta;                    // 零样本与未知时间
	reg [8:0] reg_pair_eta;                     // 过期及预热
	reg [8:0] reg_pair_theta;                   // 低质量及滞回
	reg [8:0] reg_quarter_alpha;                // 全局及保留数值
	reg [8:0] reg_quarter_beta;                 // 归属与来源数值
	reg [8:0] reg_quarter_gamma;                // 时间及统计状态
	reg [8:0] reg_quarter_delta;                // 年龄及有效质量
	reg [8:0] reg_half_alpha;                   // 高优先错误集合
	reg [8:0] reg_half_beta;                    // 低优先状态集合
	reg [8:0] reg_root_alpha;                   // 全局最高命中
	reg [15:0] reg_tag_first;                   // 原始接受核对标签
	reg [353:0] reg_context_first;              // 原始接受完整证据
	reg [63:0] reg_evaluated_first;             // 原始接受采样时间
	reg [15:0] reg_tag_second;                  // 相邻配对核对标签
	reg [353:0] reg_context_second;             // 相邻配对完整证据
	reg [63:0] reg_evaluated_second;            // 相邻配对采样时间
	reg [15:0] reg_tag_third;                   // 四项裁决核对标签
	reg [353:0] reg_context_third;              // 四项裁决完整证据
	reg [63:0] reg_evaluated_third;             // 四项裁决采样时间
	reg [15:0] reg_tag_fourth;                  // 半区归并核对标签
	reg [353:0] reg_context_fourth;             // 半区归并完整证据
	reg [63:0] reg_evaluated_fourth;            // 半区归并采样时间
	reg [15:0] reg_tag_fifth;                   // 根部选择核对标签
	reg [353:0] reg_context_fifth;              // 根部选择完整证据
	reg [63:0] reg_evaluated_fifth;             // 根部选择采样时间

	//-----------------标志信号-----------------//
	reg flag_valid_first;                       // 原始接受请求标识
	reg flag_valid_second;                      // 相邻配对请求标识
	reg flag_valid_third;                       // 四项裁决请求标识
	reg flag_valid_fourth;                      // 半区归并请求标识
	reg flag_valid_fifth;                       // 根部选择请求标识

	//-----------------其他信号-----------------//
	// 清除控制
	wire wire_flush;                            // 单域全部寄存级同步撤销

	//-----------------输出信号-----------------//
	// 用户接口
	reg reg_valid_o;                            // 结果存在标识
	reg [3:0] reg_reason_o;                     // 最终原因字
	reg [2:0] reg_condition_o;                  // 下游条件字
	reg reg_usable_o;                           // 数值可消费位
	reg [15:0] reg_tag_o;                       // 返回事务标签
	reg [353:0] reg_context_o;                  // 返回来源元数据
	reg [63:0] reg_evaluated_o;                 // 返回评估时间戳

	//---------------其他信号连线---------------//
	assign wire_flush = i_rst | i_clear;        // 共用的复位或提交清除条件

	//---------------输出信号连线---------------//
	// 用户接口
	assign o_valid = reg_valid_o;               // 结果事务有效保持寄存边界
	assign o_reason = reg_reason_o;             // 命中原因或默认良好保持寄存边界
	assign o_condition = reg_condition_o;       // 随候选携带的条件保持寄存边界
	assign o_usable = reg_usable_o;             // 所选证据的数值可用位保持寄存边界
	assign o_tag = reg_tag_o;                   // 返回核对标签保持寄存边界
	assign o_context = reg_context_o;           // 返回完整来源快照保持寄存边界
	assign o_evaluated_ms = reg_evaluated_o;    // 返回原评估时刻保持寄存边界

	//-------------输出信号处理区域-------------//
	// 用户接口
	// 只有通过五个内部延迟边界的事务才在此沿有效。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_valid_o <= 1'd0;                // 结果存在标识清空
		end else begin
			reg_valid_o <= flag_valid_fifth;    // 公布第六级有效状态
		end
	end

	// 根候选没有命中时，本笔合法编码只能是良好质量。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_reason_o <= 4'd0;               // 最终原因字清空
		end else begin
			reg_reason_o <= reg_root_alpha[8] ? reg_root_alpha[7:4] : 4'd10; // 选中原因或采用GOOD编码
		end
	end

	// 原因与条件在叶节点同时定义，末端无需再译码。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_condition_o <= 3'd0;            // 下游条件字清空
		end else begin
			reg_condition_o <= reg_root_alpha[8] ? reg_root_alpha[3:1] : 3'd7; // 输出预先编码的三位条件
		end
	end

	// 仅低质量、滞回和良好结果允许消费统计数值。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_usable_o <= 1'd0;               // 数值可消费位清空
		end else begin
			reg_usable_o <= reg_root_alpha[8] ? reg_root_alpha[0] : 1'b1; // 送出候选自带的可用性
		end
	end

	// 输出标签来自根部等待沿，不取正在输入的新标签。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_tag_o <= 16'd0;                 // 返回事务标签清空
		end else begin
			reg_tag_o <= reg_tag_fifth;         // 对齐结果与原输入核对号
		end
	end

	// 拒绝结果也返回其来源快照，但不因此授予缓存更新资格。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_context_o <= 354'd0;            // 返回来源元数据清空
		end else begin
			reg_context_o <= reg_context_fifth; // 保持原证据字段与判定成对
		end
	end

	// 延迟只搬运既有评估时刻，不能以当前时间刷新证据。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_evaluated_o <= 64'd0;           // 返回评估时间戳清空
		end else begin
			reg_evaluated_o <= reg_evaluated_fifth; // 保持本笔判断的时间基准
		end
	end

	//-------------主要任务处理区域-------------//
	// 当前配置无效时立即阻断所有来源判断。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_control <= 9'd0;           // 控制原字段拒绝清空
		end else begin
			reg_leaf_control <= {(i_global_invalid), 8'h02}; // 建立最高优先的非法响应
		end
	end

	// 未持有证据时忽略质量和时间输入。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_absent <= 9'd0;            // 空证据评估清空
		end else begin
			reg_leaf_absent <= {(!i_evidence_present), 8'h10}; // 把缺证据转换为无数据结果
		end
	end

	// 质量码五没有业务定义，必须按非法输入处理。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_quality_reserved_low <= 9'd0; // 数值保留五清空
		end else begin
			reg_leaf_quality_reserved_low <= {(i_quality == 3'd5), 8'h02}; // 拒绝第一种保留数值编码
		end
	end

	// 编码六不能被解释为有效接收率。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_quality_reserved_high <= 9'd0; // 数值保留六清空
		end else begin
			reg_leaf_quality_reserved_high <= {(i_quality == 3'd6), 8'h02}; // 拦截另一种未定义质量状态
		end
	end

	// 预留归属值不允许进入身份匹配通道。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_binding_reserved <= 9'd0;  // 归属保留三清空
		end else begin
			reg_leaf_binding_reserved <= {(i_binding == 2'd3), 8'h02}; // 对未定义绑定码采取失效保护
		end
	end

	// 节点、会话或运行代差异先于修订检查。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_identity <= 9'd0;          // 链路身份错配清空
		end else begin
			reg_leaf_identity <= {(i_binding == 2'b01), 8'h22}; // 记录身份拒绝原因
		end
	end

	// 身份通过之后仍须拒绝不同配置产生的证据。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_revision <= 9'd0;          // 配置版本不符清空
		end else begin
			reg_leaf_revision <= {(i_binding == 2'd2), 8'h32}; // 保留修订失配标记
		end
	end

	// 异常计数不能覆盖更高优先的归属拒绝。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_quality_reject <= 9'd0;    // 来源统计非法清空
		end else begin
			reg_leaf_quality_reject <= {(i_quality == 3'd7), 8'h02}; // 形成数值来源非法候选
		end
	end

	// 未来或越界时刻先于统计更新失败处理。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_time_reject <= 9'd0;       // 时间来源越界清空
		end else begin
			reg_leaf_time_reject <= {(i_time_status == 2'd3), 8'h02}; // 保留时间不可计算结果
		end
	end

	// 本次统计未成功时不能使用看似良好的接收率。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_update <= 9'd0;            // 结算更新失败清空
		end else begin
			reg_leaf_update <= {(!i_update_ok), 8'h42}; // 生成更新失败条件
		end
	end

	// 已有证据的零样本优先于未知及过期。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_empty <= 9'd0;             // 样本窗口为空清空
		end else begin
			reg_leaf_empty <= {(i_quality == 3'b000), 8'h10}; // 将空计数映射为无数据
		end
	end

	// 缺少可信时间的非空统计不可宣称新鲜。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_unknown <= 9'd0;           // 来源时刻未知清空
		end else begin
			reg_leaf_unknown <= {(i_time_status == 2'd2), 8'h54}; // 建立时间未知候选
		end
	end

	// 超过年龄界限的统计优先于预热与数值。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_stale <= 9'd0;             // 来源证据过期清空
		end else begin
			reg_leaf_stale <= {(i_time_status == 2'b01), 8'h66}; // 生成过期条件
		end
	end

	// 样本不足时尚不进入高低阈值质量判断。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_warmup <= 9'd0;            // 数量尚未预热清空
		end else begin
			reg_leaf_warmup <= {(i_quality == 3'b001), 8'h78}; // 记录预热结果
		end
	end

	// 低阈值命中提供可用的劣化质量结果。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_bad <= 9'd0;               // 接收率低区清空
		end else begin
			reg_leaf_bad <= {(i_quality == 3'b010), 8'h8b}; // 携带低质量及可用位
		end
	end

	// 既未恶化也未恢复的统计仍可参与滞回。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_leaf_band <= 9'd0;              // 接收率滞回带清空
		end else begin
			reg_leaf_band <= {(i_quality == 3'b011), 8'h9d}; // 返回中间质量及可用位
		end
	end

	// 控制非法优先于没有统计对象。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_pair_alpha <= 9'd0;             // 控制与空证据清空
		end else begin
			reg_pair_alpha <= reg_leaf_control[8] ? reg_leaf_control : reg_leaf_absent; // 全局错误覆盖缺证据
		end
	end

	// 按编码五、编码六的顺序汇总防护结果。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_pair_beta <= 9'd0;              // 两个数值保留码清空
		end else begin
			reg_pair_beta <= reg_leaf_quality_reserved_low[8] ? reg_leaf_quality_reserved_low : reg_leaf_quality_reserved_high; // 收集未定义质量拒绝
		end
	end

	// 未知归属编码优先于正常的身份错配说明。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_pair_gamma <= 9'd0;             // 绑定保留及身份清空
		end else begin
			reg_pair_gamma <= reg_leaf_binding_reserved[8] ? reg_leaf_binding_reserved : reg_leaf_identity; // 非法绑定优先身份错误
		end
	end

	// 配置不匹配先于来源计数错误解释。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_pair_delta <= 9'd0;             // 修订与计数合法性清空
		end else begin
			reg_pair_delta <= reg_leaf_revision[8] ? reg_leaf_revision : reg_leaf_quality_reject; // 不同修订覆盖来源非法
		end
	end

	// 不合法时刻先于更新失败进入输出。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_pair_epsilon <= 9'd0;           // 来源时间及更新清空
		end else begin
			reg_pair_epsilon <= reg_leaf_time_reject[8] ? reg_leaf_time_reject : reg_leaf_update; // 时刻拒绝压过统计失败
		end
	end

	// 没有样本时不报告来源时间未知。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_pair_zeta <= 9'd0;              // 零样本与未知时间清空
		end else begin
			reg_pair_zeta <= reg_leaf_empty[8] ? reg_leaf_empty : reg_leaf_unknown; // 空窗口压过未知时标
		end
	end

	// 旧证据不会因为尚在预热而跳过年龄限制。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_pair_eta <= 9'd0;               // 过期及预热清空
		end else begin
			reg_pair_eta <= reg_leaf_stale[8] ? reg_leaf_stale : reg_leaf_warmup; // 年龄失效覆盖数量不足
		end
	end

	// 选择数值低区或滞回区，均携带可用属性。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_pair_theta <= 9'd0;             // 低质量及滞回清空
		end else begin
			reg_pair_theta <= reg_leaf_bad[8] ? reg_leaf_bad : reg_leaf_band; // 择取劣化或中间质量
		end
	end

	// 全局控制和缺证据优先于预留质量码。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_quarter_alpha <= 9'd0;          // 全局及保留数值清空
		end else begin
			reg_quarter_alpha <= reg_pair_alpha[8] ? reg_pair_alpha : reg_pair_beta; // 筛选最先四条控制规则
		end
	end

	// 保留绑定、身份、修订按序压过计数非法。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_quarter_beta <= 9'd0;           // 归属与来源数值清空
		end else begin
			reg_quarter_beta <= reg_pair_gamma[8] ? reg_pair_gamma : reg_pair_delta; // 汇总归属拒绝与数值错误
		end
	end

	// 来源非法和更新失败优先于零计数、未知。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_quarter_gamma <= 9'd0;          // 时间及统计状态清空
		end else begin
			reg_quarter_gamma <= reg_pair_epsilon[8] ? reg_pair_epsilon : reg_pair_zeta; // 保持来源错误的先后顺序
		end
	end

	// 过期和预热在低质量、滞回之前裁决。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_quarter_delta <= 9'd0;          // 年龄及有效质量清空
		end else begin
			reg_quarter_delta <= reg_pair_eta[8] ? reg_pair_eta : reg_pair_theta; // 合并最后四条质量规则
		end
	end

	// 控制层拒绝必须覆盖归属及计数层拒绝。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_half_alpha <= 9'd0;             // 高优先错误集合清空
		end else begin
			reg_half_alpha <= reg_quarter_alpha[8] ? reg_quarter_alpha : reg_quarter_beta; // 完成高半区候选选择
		end
	end

	// 来源及更新状态先于时效和质量落区。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_half_beta <= 9'd0;              // 低优先状态集合清空
		end else begin
			reg_half_beta <= reg_quarter_gamma[8] ? reg_quarter_gamma : reg_quarter_delta; // 确定低半区首项结果
		end
	end

	// 在上下半区之间选出本笔事务首条适用规则。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_root_alpha <= 9'd0;             // 全局最高命中清空
		end else begin
			reg_root_alpha <= reg_half_alpha[8] ? reg_half_alpha : reg_half_beta; // 完成全部十六条件的仲裁
		end
	end

	// 原始接受阶段同步保存事务有效；空拍也必须占用流水位置。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			flag_valid_first <= 1'd0;           // 撤销刚采样的评估请求
		end else begin
			flag_valid_first <= i_valid;        // 记住这一沿是否发起评估
		end
	end

	// 原始接受阶段同步保存标签副本；短标签可以重复且不代表身份。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_tag_first <= 16'd0;             // 清除最前端核对编号
		end else begin
			reg_tag_first <= i_tag;             // 捕获输入标签供后续核对
		end
	end

	// 原始接受阶段同步保存上下文快照；来源三百五十四位不被选择树改写。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_context_first <= 354'd0;        // 擦除输入证据暂存内容
		end else begin
			reg_context_first <= i_context;     // 接受完整身份与证据字段
		end
	end

	// 原始接受阶段同步保存评估时刻；输出判定仍属于最初采样时刻。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_evaluated_first <= 64'd0;       // 放弃本次接受时刻
		end else begin
			reg_evaluated_first <= i_evaluated_ms; // 固定判断使用的当前时间值
		end
	end

	// 相邻配对阶段同步保存事务有效；空拍也必须占用流水位置。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			flag_valid_second <= 1'd0;          // 阻断进入两项选择后的事务
		end else begin
			flag_valid_second <= flag_valid_first; // 让有效位跟随首轮二选一
		end
	end

	// 相邻配对阶段同步保存标签副本；短标签可以重复且不代表身份。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_tag_second <= 16'd0;            // 配对沿不再保留旧标签
		end else begin
			reg_tag_second <= reg_tag_first;    // 沿用接受级短标签
		end
	end

	// 相邻配对阶段同步保存上下文快照；来源三百五十四位不被选择树改写。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_context_second <= 354'd0;       // 取消等待四路选择的原来源
		end else begin
			reg_context_second <= reg_context_first; // 将来源快照搬到配对边界
		end
	end

	// 相邻配对阶段同步保存评估时刻；输出判定仍属于最初采样时刻。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_evaluated_second <= 64'd0;      // 抹去相邻仲裁附带的时间
		end else begin
			reg_evaluated_second <= reg_evaluated_first; // 时间基准跨过相邻选择层
		end
	end

	// 四项裁决阶段同步保存事务有效；空拍也必须占用流水位置。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			flag_valid_third <= 1'd0;           // 清掉四项筛选的有效标记
		end else begin
			flag_valid_third <= flag_valid_second; // 把配对有效标记送入四路边界
		end
	end

	// 四项裁决阶段同步保存标签副本；短标签可以重复且不代表身份。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_tag_third <= 16'd0;             // 四路选择期间的编号作废
		end else begin
			reg_tag_third <= reg_tag_second;    // 推进已通过配对沿的标签
		end
	end

	// 四项裁决阶段同步保存上下文快照；来源三百五十四位不被选择树改写。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_context_third <= 354'd0;        // 清空四分区携带的身份字段
		end else begin
			reg_context_third <= reg_context_second; // 四项仲裁保留同笔三百五十四位内容
		end
	end

	// 四项裁决阶段同步保存评估时刻；输出判定仍属于最初采样时刻。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_evaluated_third <= 64'd0;       // 舍弃四选阶段的评估快照
		end else begin
			reg_evaluated_third <= reg_evaluated_second; // 在四分区结果旁保存评估毫秒值
		end
	end

	// 半区归并阶段同步保存事务有效；空拍也必须占用流水位置。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			flag_valid_fourth <= 1'd0;          // 半区结果在冲刷沿失去效力
		end else begin
			flag_valid_fourth <= flag_valid_third; // 传递与两个半区结果对应的有效性
		end
	end

	// 半区归并阶段同步保存标签副本；短标签可以重复且不代表身份。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_tag_fourth <= 16'd0;            // 撤销半区配套的短核对号
		end else begin
			reg_tag_fourth <= reg_tag_third;    // 将四分区编号对齐到上下半区
		end
	end

	// 半区归并阶段同步保存上下文快照；来源三百五十四位不被选择树改写。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_context_fourth <= 354'd0;       // 丢弃半区合并所附原始信息
		end else begin
			reg_context_fourth <= reg_context_third; // 保存与半区候选同时到达的证据
		end
	end

	// 半区归并阶段同步保存评估时刻；输出判定仍属于最初采样时刻。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_evaluated_fourth <= 64'd0;      // 半区选出的时标不再保留
		end else begin
			reg_evaluated_fourth <= reg_evaluated_third; // 为八项筛选结果保留采样时标
		end
	end

	// 根部选择阶段同步保存事务有效；空拍也必须占用流水位置。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			flag_valid_fifth <= 1'd0;           // 阻止根结果在下一沿被发布
		end else begin
			flag_valid_fifth <= flag_valid_fourth; // 在根选择结束时记录待输出事务
		end
	end

	// 根部选择阶段同步保存标签副本；短标签可以重复且不代表身份。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_tag_fifth <= 16'd0;             // 删除根部等待发布的编号
		end else begin
			reg_tag_fifth <= reg_tag_fourth;    // 短标签到达最终内部等待级
		end
	end

	// 根部选择阶段同步保存上下文快照；来源三百五十四位不被选择树改写。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_context_fifth <= 354'd0;        // 根部来源快照随本次提交撤销
		end else begin
			reg_context_fifth <= reg_context_fourth; // 完整元数据与根候选同步到达
		end
	end

	// 根部选择阶段同步保存评估时刻；输出判定仍属于最初采样时刻。
	always @(posedge i_clk) begin
		if (wire_flush) begin
			reg_evaluated_fifth <= 64'd0;       // 禁止旧评估时刻继续向外传播
		end else begin
			reg_evaluated_fifth <= reg_evaluated_fourth; // 传递半区阶段保存的时间用于最终返回
		end
	end

endmodule

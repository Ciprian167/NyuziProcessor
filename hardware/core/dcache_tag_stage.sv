// 
// Copyright 2011-2015 Jeff Bush
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// 

`include "defines.sv"

//
// Instruction Pipeline L1 Data Cache Tag Stage.
// Contains tags and cache line states, which it queries when a memory access 
// occurs. There is one cycle of latency to fetch these, so the next stage 
// will handle the result. The L1 data cache is set associative. There is a 
// separate block of tag ram for each way, which this reads in parallel. The 
// next stage will check them to see if there is a cache hit on one of the 
// ways. This also contains the translation lookaside buffer, which will 
// convert the virtual memory address to a physical one. The cache is 
// virtually indexed and physically tagged: the tag memories contain physical
// addresses, translated by the TLB.
//

module dcache_tag_stage
	(input                                      clk,
	input                                       reset,
                                                
	// From operand_fetch_stage                 
	input vector_t                              of_operand1,
	input vector_lane_mask_t                    of_mask_value,
	input vector_t                              of_store_value,
	input                                       of_instruction_valid,
	input decoded_instruction_t                 of_instruction,
	input thread_idx_t                          of_thread_idx,
	input subcycle_t                            of_subcycle,
                                                
	// to dcache_data_stage                     
	output logic                                dt_instruction_valid,
	output decoded_instruction_t                dt_instruction,
	output vector_lane_mask_t                   dt_mask_value,
	output thread_idx_t                         dt_thread_idx,
	output l1d_addr_t                           dt_request_vaddr,
	output l1d_addr_t                           dt_request_paddr,
	output                                      dt_tlb_hit,
	output vector_t                             dt_store_value,
	output subcycle_t                           dt_subcycle,
	output logic                                dt_valid[`L1D_WAYS],
	output l1d_tag_t                            dt_tag[`L1D_WAYS],
	
	// from dcache_data_stage
	input                                       dd_update_lru_en,
	input l1d_way_idx_t                         dd_update_lru_way,

	// To ifetch_tag_stage
	output                                      dt_invalidate_tlb_en,
	output                                      dt_invalidate_tlb_all,
	output page_index_t                         dt_itlb_vpage_idx,
	output                                      dt_update_itlb_en,
	output page_index_t                         dt_update_itlb_ppage_idx,
	
	
	// From l2_cache_interface
	input                                       l2i_dcache_lru_fill_en,
	input l1d_set_idx_t                         l2i_dcache_lru_fill_set,
	input [`L1D_WAYS - 1:0]                     l2i_dtag_update_en_oh,
	input l1d_set_idx_t                         l2i_dtag_update_set,
	input l1d_tag_t                             l2i_dtag_update_tag,
	input                                       l2i_dtag_update_valid,
	input                                       l2i_snoop_en,
	input l1d_set_idx_t                         l2i_snoop_set,

	// From control_registers
	input                                       cr_mmu_en[`THREADS_PER_CORE],

	// To l2_cache_interface
	output logic                                dt_snoop_valid[`L1D_WAYS],
	output l1d_tag_t                            dt_snoop_tag[`L1D_WAYS],
	output l1d_way_idx_t                        dt_fill_lru,

	// From writeback_stage                     
	input logic                                 wb_rollback_en,
	input thread_idx_t                          wb_rollback_thread_idx);

	l1d_addr_t request_addr_nxt;
	logic is_cache_access;
	logic cache_load_en;
	logic instruction_valid;
	logic[$clog2(`VECTOR_LANES) - 1:0] scgath_lane;
	logic cache_fetch_en;
	page_index_t tlb_ppage_idx;
	logic tlb_hit;
	page_index_t ppage_idx;
	scalar_t fetched_addr;
	logic tlb_lookup_en;
	logic is_valid_cache_control;
	logic update_dtlb_en;

	assign instruction_valid = of_instruction_valid 
		&& (!wb_rollback_en || wb_rollback_thread_idx != of_thread_idx) 
		&& of_instruction.pipeline_sel == PIPE_MEM;
	assign is_valid_cache_control = instruction_valid
		&& of_instruction.is_cache_control;
	assign cache_load_en = instruction_valid 
		&& of_instruction.memory_access_type != MEM_CONTROL_REG
		&& of_instruction.is_memory_access      // Not cache control
		&& of_instruction.is_load;
	assign tlb_lookup_en = instruction_valid 
		&& of_instruction.memory_access_type != MEM_CONTROL_REG;
	assign scgath_lane = ~of_subcycle;
	assign request_addr_nxt = of_operand1[scgath_lane] + of_instruction.immediate_value;
	assign dt_invalidate_tlb_en = is_valid_cache_control
		&& (of_instruction.cache_control_op == CACHE_TLB_INVAL
		|| of_instruction.cache_control_op == CACHE_TLB_INVAL_ALL);
	assign dt_invalidate_tlb_all = of_instruction.cache_control_op 
		== CACHE_TLB_INVAL_ALL;
	assign update_dtlb_en = is_valid_cache_control
		&& of_instruction.cache_control_op == CACHE_DTLB_INSERT;
	assign dt_update_itlb_en = is_valid_cache_control
		&& of_instruction.cache_control_op == CACHE_ITLB_INSERT;
	assign dt_itlb_vpage_idx = of_operand1[0][31-:`PAGE_NUM_BITS];
	assign dt_update_itlb_ppage_idx = of_store_value[0][31-:`PAGE_NUM_BITS];

	//
	// Way metadata
	//
	genvar way_idx;
	generate
		for (way_idx = 0; way_idx < `L1D_WAYS; way_idx++)
		begin : way_tag_gen
			// Valid flags are flops instead of SRAM because they need
			// to all be cleared on reset.
			logic line_valid[`L1D_SETS];

			sram_2r1w #(
				.DATA_WIDTH($bits(l1d_tag_t)), 
				.SIZE(`L1D_SETS),
				.READ_DURING_WRITE("NEW_DATA")
			) sram_tags(
				.read1_en(cache_load_en),
				.read1_addr(request_addr_nxt.set_idx),
				.read1_data(dt_tag[way_idx]),
				.read2_en(l2i_snoop_en),
				.read2_addr(l2i_snoop_set),
				.read2_data(dt_snoop_tag[way_idx]),
				.write_en(l2i_dtag_update_en_oh[way_idx]),
				.write_addr(l2i_dtag_update_set),
				.write_data(l2i_dtag_update_tag),
				.*);

			always_ff @(posedge clk, posedge reset)
			begin
				if (reset)
				begin
					for (int set_idx = 0; set_idx < `L1D_SETS; set_idx++)
						line_valid[set_idx] <= 0;
				end
				else 
				begin
					if (l2i_dtag_update_en_oh[way_idx])
						line_valid[l2i_dtag_update_set] <= l2i_dtag_update_valid;

					// Fetch cache line state for pipeline
					if (cache_load_en)
					begin
						if (l2i_dtag_update_en_oh[way_idx] && l2i_dtag_update_set == request_addr_nxt.set_idx)
							dt_valid[way_idx] <= l2i_dtag_update_valid;	// Bypass
						else
							dt_valid[way_idx] <= line_valid[request_addr_nxt.set_idx];
					end

					// Fetch cache line state for snoop
					if (l2i_snoop_en)
					begin
						if (l2i_dtag_update_en_oh[way_idx] && l2i_dtag_update_set == l2i_snoop_set)
							dt_snoop_valid[way_idx] <= l2i_dtag_update_valid;	// Bypass
						else
							dt_snoop_valid[way_idx] <= line_valid[l2i_snoop_set];
					end
				end
			end
		end
	endgenerate
	
`ifdef HAS_MMU
	tlb #(.NUM_ENTRIES(`DTLB_ENTRIES)) dtlb(
		.lookup_en(tlb_lookup_en),
		.lookup_vpage_idx(of_operand1[0][31-:`PAGE_NUM_BITS]),
		.lookup_ppage_idx(tlb_ppage_idx),
		.lookup_hit(tlb_hit),
		.update_en(update_dtlb_en),
		.update_ppage_idx(of_store_value[0][31-:`PAGE_NUM_BITS]),
		.update_vpage_idx(of_operand1[0][31-:`PAGE_NUM_BITS]),
		.invalidate_en(dt_invalidate_tlb_en),
		.invalidate_all(dt_invalidate_tlb_all),
		.invalidate_vpage_idx(of_operand1[0][31-:`PAGE_NUM_BITS]),
		.*);
		
	// This combinational logic is after the flip flops,
	// so these signals are delayed one cycle from other signals
	// in this module.
	always_comb
	begin
		if (cr_mmu_en[dt_thread_idx])
		begin
			dt_tlb_hit = tlb_hit;
			ppage_idx = tlb_ppage_idx;
		end
		else
		begin
			dt_tlb_hit = 1;
			ppage_idx = fetched_addr[31-:`PAGE_NUM_BITS];
		end
	end
`else
	// If MMU is disabled, just identity map addresses
	assign dt_tlb_hit = 1;
	assign ppage_idx = fetched_addr[31-:`PAGE_NUM_BITS];
`endif

	cache_lru #(.NUM_WAYS(`L1D_WAYS), .NUM_SETS(`L1D_SETS)) lru(
		.fill_en(l2i_dcache_lru_fill_en),
		.fill_set(l2i_dcache_lru_fill_set),
		.fill_way(dt_fill_lru),
		.access_en(instruction_valid),
		.access_set(request_addr_nxt.set_idx),
		.access_update_en(dd_update_lru_en),
		.access_update_way(dd_update_lru_way),
		.*);

	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			/*AUTORESET*/
			// Beginning of autoreset for uninitialized flops
			dt_instruction <= '0;
			dt_instruction_valid <= '0;
			dt_mask_value <= '0;
			dt_store_value <= '0;
			dt_subcycle <= '0;
			dt_thread_idx <= '0;
			fetched_addr <= '0;
			// End of automatics
		end
		else
		begin
			assert($onehot0(l2i_dtag_update_en_oh));
			dt_instruction_valid <= instruction_valid;
			dt_instruction <= of_instruction;
			dt_mask_value <= of_mask_value;
			dt_thread_idx <= of_thread_idx;
			dt_store_value <= of_store_value;
			dt_subcycle <= of_subcycle;
			fetched_addr <= request_addr_nxt;
		end
	end
	
	assign dt_request_paddr = { ppage_idx, fetched_addr[31 - `PAGE_NUM_BITS:0] };
	assign dt_request_vaddr = fetched_addr;
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// verilog-auto-reset-widths:unbased
// End:

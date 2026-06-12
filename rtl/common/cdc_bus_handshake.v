`default_nettype none
// cdc_bus_handshake.v - multi-bit CDC bridge with toggle-handshake.
//
// Use this when the multi-bit `src_data` bus updates atomically and the
// destination must see a coherent snapshot — i.e., never observe partial
// updates from skew between bits in a bit-wise 2-FF scheme.
//
// Operation:
//   1. Source asserts a 1-cycle `src_update` pulse while `src_data` is valid.
//   2. Source latches `src_data -> src_data_r` and toggles a 1-bit `src_toggle`
//      register on that same cycle.
//   3. `src_toggle` is synchronized into the destination clock domain through
//      a 2-FF synchronizer (`sync_2ff`).
//   4. Destination detects an edge on the synchronized toggle and samples
//      `src_data_r` directly. Because `src_update` pulses much less frequently
//      than `dst_clk`, `src_data_r` is quasi-static (held many src_clk cycles)
//      by the time the destination samples it — no metastability hazard on
//      the data bits themselves.
//   5. Destination registers the sampled data into `dst_data` and pulses
//      `dst_update` for one `dst_clk` cycle.
//
// Constraints:
//   - The source must hold its update rate below
//        f_update_max < f_dst_clk / (2 + sync_stages)
//     so the toggle is not missed. For this project (decision_update at sys_clk
//     ~100 MHz max but actually fires only per inference cycle, ~kHz; vitals
//     update at I2C speed, ~kHz) the constraint is trivially satisfied vs
//     pixel_clk (~74 MHz).
//   - `src_data_r` is exported as a `(* syn_keep *)` register so the
//     synthesizer doesn't collapse it.
//   - In a Gowin SDC, the AI-side `src_data_r[*]` to OSD-side `dst_data[*]`
//     path should be declared as either `set_clock_groups -asynchronous`
//     between sys_clk and pixel_clk or as `set_max_delay` matching the slower
//     period. See `asic/asic_constraints.sdc` / TMDS_60HZ.sdc for the actual
//     declaration.
module cdc_bus_handshake #(
    parameter WIDTH = 8
)(
    input  wire             src_clk,
    input  wire             src_rst_n,
    input  wire [WIDTH-1:0] src_data,
    input  wire             src_update,    // 1-cycle pulse: new data ready

    input  wire             dst_clk,
    input  wire             dst_rst_n,
    output reg  [WIDTH-1:0] dst_data,
    output reg              dst_update     // 1-cycle pulse: new data latched
);

// ---- Source domain: latch data + toggle ----
(* syn_keep = 1, syn_preserve = 1 *)
reg [WIDTH-1:0] src_data_r;
(* syn_keep = 1, syn_preserve = 1 *)
reg             src_toggle;

always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
        src_data_r <= {WIDTH{1'b0}};
        src_toggle <= 1'b0;
    end else if (src_update) begin
        src_data_r <= src_data;
        src_toggle <= ~src_toggle;
    end
end

// ---- Cross-clock 2-FF synchronizer on the toggle bit ----
wire toggle_sync;
sync_2ff #(.STAGES(2), .INIT_VALUE(1'b0)) u_toggle_sync (
    .dst_clk   (dst_clk),
    .dst_rst_n (dst_rst_n),
    .async_in  (src_toggle),
    .sync_out  (toggle_sync)
);

// ---- Destination domain: detect toggle change, latch quasi-static data ----
reg toggle_sync_d;
wire toggle_edge = toggle_sync ^ toggle_sync_d;

always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
        toggle_sync_d <= 1'b0;
        dst_data      <= {WIDTH{1'b0}};
        dst_update    <= 1'b0;
    end else begin
        toggle_sync_d <= toggle_sync;
        dst_update    <= toggle_edge;
        if (toggle_edge)
            dst_data <= src_data_r;
    end
end

endmodule

`default_nettype wire

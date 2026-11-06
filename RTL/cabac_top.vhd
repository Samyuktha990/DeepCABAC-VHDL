library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.cabac_types_pkg.all;

entity CABAC_TOP is
    generic (
        FIFO_DEPTH         : positive := 32;
        RESERVOIR_WIDTH    : positive := 256;
        MAX_BINS_PER_CYCLE : positive := 16
    );

    port (
        clk : in std_logic;
        rst : in std_logic;

        ------------------------------------------------------------
        -- Encoded byte input stream
        ------------------------------------------------------------
        data_in    : in  std_logic_vector(7 downto 0);
        data_valid : in  std_logic;
        data_ready : out std_logic;

        ------------------------------------------------------------
        -- Decode control
        ------------------------------------------------------------
        start_decode  : in std_logic;
        end_of_stream : in std_logic;

        ------------------------------------------------------------
        -- Decoded output
        ------------------------------------------------------------
        symbol_out   : out integer;
        symbol_valid : out std_logic;
        busy         : out std_logic;
        give_output    : in  std_logic;

        init_done    : out std_logic;

        ------------------------------------------------------------
        -- Debug / status
        ------------------------------------------------------------
        decoded_bits : out std_logic_vector(MAX_BINS_PER_CYCLE-1 downto 0);
        valid_count  : out natural range 0 to MAX_BINS_PER_CYCLE;

        fifo_level : out integer range 0 to FIFO_DEPTH;

        reservoir_valid_bits :
            out natural range 0 to RESERVOIR_WIDTH;

        bits_consumed :
            out natural range 0 to RESERVOIR_WIDTH;

        symbol_commit : out std_logic;

        need_bits : out std_logic
    );
end entity;

architecture rtl of CABAC_TOP is

    ----------------------------------------------------------------
    -- CABAC configuration
    -- These are the same values that were previously passed from
    -- CABAC_TOP into CABAC_Core_8.
    ----------------------------------------------------------------
    constant NUM_CTX_C   : positive := 4;
    constant MAX_TOTAL_C : positive := 64;
    constant N_C         : positive := 1;

    constant FULL_C : unsigned(32 downto 0) :=
        shift_left(to_unsigned(1, 33), 32);
        

    constant NEW_SYMBOL_STATE : debin_work_state_t := (
        state       => DB_SIG,
        sign_neg    => '0',
        absgr       => 1,
        unary       => (others => '0'),
        bypass_left => (others => '0'),
        remainder   => (others => '0')
    );

    subtype ctx_mem_t is
        ctx_array_t(0 to NUM_CTX_C-1);

    type arithmetic_chain_t is
        array (0 to MAX_BINS_PER_CYCLE) of arithmetic_state_t;

    type context_chain_t is
        array (0 to MAX_BINS_PER_CYCLE) of ctx_mem_t;

    type debin_chain_t is
        array (0 to MAX_BINS_PER_CYCLE) of debin_work_state_t;

    type sl_array_t is
        array (natural range <>) of std_logic;

    type ctxid_array_t is
        array (natural range <>) of integer range 0 to 3;

    type count_array_t is
        array (natural range <>) of count_t;

    type integer_array_t is
        array (natural range <>) of integer;

    ----------------------------------------------------------------
    -- FIFO signals
    ----------------------------------------------------------------
    signal fifo_wr_en    : std_logic;
    signal fifo_rd_en    : std_logic;
    signal fifo_data_out : std_logic_vector(7 downto 0);
    signal fifo_rd_valid : std_logic;
    signal fifo_full     : std_logic;
    signal fifo_empty    : std_logic;
    signal fifo_level_s  : integer range 0 to FIFO_DEPTH;
    signal symbol_commit_r : std_logic := '0';

    ----------------------------------------------------------------
    -- Intermediate storage / reservoir signals
    ----------------------------------------------------------------
    signal reservoir_bits :
        std_logic_vector(RESERVOIR_WIDTH-1 downto 0);

    signal reservoir_valid_s :
        natural range 0 to RESERVOIR_WIDTH;

    signal reservoir_bit       : std_logic;
    signal reservoir_bit_valid : std_logic;

    ----------------------------------------------------------------
    -- CABAC arithmetic/context registers
    ----------------------------------------------------------------
    signal arithmetic_reg : arithmetic_state_t := (
        low_value  => (others => '0'),
        high_value => FULL_C,
        code_value => (others => '0'),
        bit_ptr    => 0
    );

    signal c0_reg : ctx_mem_t :=
        (others => to_unsigned(1, 7));

    signal c1_reg : ctx_mem_t :=
        (others => to_unsigned(1, 7));

    ----------------------------------------------------------------
    -- Stage-chain signals
    ----------------------------------------------------------------
    signal arithmetic_chain : arithmetic_chain_t;
    signal c0_chain         : context_chain_t;
    signal c1_chain         : context_chain_t;
    signal debin_chain      : debin_chain_t;

    signal stage_enable :
        sl_array_t(0 to MAX_BINS_PER_CYCLE);

    signal stage_success :
        sl_array_t(0 to MAX_BINS_PER_CYCLE-1);

    signal stage_need_bits :
        sl_array_t(0 to MAX_BINS_PER_CYCLE-1);

    signal stage_bin :
        sl_array_t(0 to MAX_BINS_PER_CYCLE-1);

    signal stage_symbol_done :
        sl_array_t(0 to MAX_BINS_PER_CYCLE-1);

    signal stage_ctx_id :
        ctxid_array_t(0 to MAX_BINS_PER_CYCLE-1);

    signal stage_bypass :
        sl_array_t(0 to MAX_BINS_PER_CYCLE-1);

    signal stage_c0 :
        count_array_t(0 to MAX_BINS_PER_CYCLE-1);

    signal stage_c1 :
        count_array_t(0 to MAX_BINS_PER_CYCLE-1);

    signal stage_symbol :
        integer_array_t(0 to MAX_BINS_PER_CYCLE-1);

    ----------------------------------------------------------------
    -- Collected combinational result of the stage chain
    ----------------------------------------------------------------
    signal decoded_bits_comb :
        std_logic_vector(MAX_BINS_PER_CYCLE-1 downto 0);

    signal valid_count_comb :
        natural range 0 to MAX_BINS_PER_CYCLE;

    signal symbol_done_comb  : std_logic;
    signal symbol_value_comb : integer;
    signal need_bits_comb    : std_logic;

    ----------------------------------------------------------------
    -- Initialization / control
    ----------------------------------------------------------------
    type init_state_t is (
        INIT_REQ,
        INIT_WAIT,
        READY
    );

    signal init_state : init_state_t := INIT_REQ;

    signal init_count :
        integer range 0 to 31 := 0;

    signal run_r : std_logic := '0';

    signal bit_consume_r : std_logic := '0';
    signal init_done_r   : std_logic := '0';

    signal symbol_out_r   : integer := 0;
    signal symbol_valid_r : std_logic := '0';
    signal busy_r         : std_logic := '1';

    signal decoded_bits_r :
        std_logic_vector(MAX_BINS_PER_CYCLE-1 downto 0) :=
        (others => '0');

    signal valid_count_r :
        natural range 0 to MAX_BINS_PER_CYCLE := 0;

    signal need_bits_r : std_logic := '0';

    ----------------------------------------------------------------
    -- Number of compressed bits consumed by the CURRENT symbol.
    -- This is fed back to the moving reservoir.
    ----------------------------------------------------------------
    signal consume_count_s :
        natural range 0 to RESERVOIR_WIDTH := 0;

    signal data_ready_int : std_logic;

begin

    assert NUM_CTX_C >= 4
        report "CABAC_TOP requires at least four CABAC contexts"
        severity failure;

    ----------------------------------------------------------------
    -- External outputs
    ----------------------------------------------------------------
    symbol_out   <= symbol_out_r;
    symbol_valid <= symbol_valid_r;
    busy         <= busy_r;
    init_done    <= init_done_r;

    decoded_bits <= decoded_bits_r;
    valid_count  <= valid_count_r;

    need_bits <= need_bits_r;

    fifo_level <= fifo_level_s;
    reservoir_valid_bits <= reservoir_valid_s;
    bits_consumed <= consume_count_s;
    symbol_commit <= symbol_commit_r;
    

    ----------------------------------------------------------------
    -- Input-stream ready/valid handshake
    ----------------------------------------------------------------
    data_ready_int <= (not fifo_full) or fifo_rd_en;
    data_ready <= data_ready_int;
    fifo_wr_en <= data_valid and data_ready_int;

    ----------------------------------------------------------------
    -- FIFO
    ----------------------------------------------------------------
    U_FIFO : entity work.FIFO
        generic map (
            DATA_WIDTH => 8,
            DEPTH      => FIFO_DEPTH
        )
        port map (
            clk      => clk,
            rst      => rst,
            wr_en    => fifo_wr_en,
            rd_en    => fifo_rd_en,
            data_in  => data_in,
            data_out => fifo_data_out,
            rd_valid => fifo_rd_valid,
            full     => fifo_full,
            empty    => fifo_empty,
            level    => fifo_level_s
        );

    ----------------------------------------------------------------
    -- Intermediate storage / bit reservoir
    ----------------------------------------------------------------
    U_STORAGE : entity work.intermediate_storage
        generic map (
            RESERVOIR_WIDTH => RESERVOIR_WIDTH
        )
        port map (
            clk => clk,
            rst => rst,

            fifo_data_out => fifo_data_out,
            fifo_rd_valid => fifo_rd_valid,
            fifo_rd_en    => fifo_rd_en,

            bit_consume => bit_consume_r,
            bit_out     => reservoir_bit,
            bit_valid   => reservoir_bit_valid,

            consume_count => consume_count_s,
            bits_out      => reservoir_bits,
            valid_bits    => reservoir_valid_s
        );

    ----------------------------------------------------------------
    -- Beginning of every combinational CABAC chain
    --
    -- low/high/code and contexts continue from the previous symbol.
    -- The Debinarizer starts each new symbol in DB_SIG.
    ----------------------------------------------------------------
    arithmetic_chain(0) <= arithmetic_reg;
    c0_chain(0) <= c0_reg;
    c1_chain(0) <= c1_reg;
    debin_chain(0) <= NEW_SYMBOL_STATE;

    ----------------------------------------------------------------
    -- Stage 0 starts whenever continuous decoding is active.
    ----------------------------------------------------------------
    stage_enable(0) <=
        '1'
        when
            (init_done_r = '1') and
            (end_of_stream = '0') and
            ((run_r = '1') or (start_decode = '1'))
        else
            '0';

    ----------------------------------------------------------------
    -- Direct instantiation of the verified modules.
    -- No CABAC_Core_8 instance exists anymore.
    ----------------------------------------------------------------
    GEN_STAGES : for i in 0 to MAX_BINS_PER_CYCLE-1 generate

        U_DEBIN_STEP : entity work.Debin_step
            generic map (
                N => N_C
            )
            port map (
                state_in => debin_chain(i),

                ctx_id      => stage_ctx_id(i),
                bypass_mode => stage_bypass(i),

                decoded_bit => stage_bin(i),
                enable      => stage_success(i),

                state_out => debin_chain(i+1),

                symbol_out  => stage_symbol(i),
                symbol_done => stage_symbol_done(i)
            );

        U_CONTEXT_STEP : entity work.Context_step
            generic map (
                NUM_CTX   => NUM_CTX_C,
                MAX_TOTAL => MAX_TOTAL_C
            )
            port map (
                c0_mem_in => c0_chain(i),
                c1_mem_in => c1_chain(i),

                ctx_id      => stage_ctx_id(i),
                bypass_mode => stage_bypass(i),

                c0_selected => stage_c0(i),
                c1_selected => stage_c1(i),

                decoded_bit   => stage_bin(i),
                update_enable => stage_success(i),

                c0_mem_out => c0_chain(i+1),
                c1_mem_out => c1_chain(i+1)
            );

        U_DECODER_STEP : entity work.Decoder_step_splitbranch_ratio33_offsetcmp
            generic map (
                STREAM_WIDTH => RESERVOIR_WIDTH
            )
            port map (
                enable => stage_enable(i),

                state_in => arithmetic_chain(i),

                c0_in       => stage_c0(i),
                c1_in       => stage_c1(i),
                bypass_mode => stage_bypass(i),

                bits_in       => reservoir_bits,
                valid_bits_in => reservoir_valid_s,

                decoded_bit => stage_bin(i),
                success     => stage_success(i),
                need_bits   => stage_need_bits(i),

                state_out => arithmetic_chain(i+1)
            );

        stage_enable(i+1) <=
            stage_success(i) and
            (not stage_symbol_done(i));

    end generate;

    ----------------------------------------------------------------
    -- Collect the successful bins and final symbol from this cycle.
    ----------------------------------------------------------------
    process(all)
        variable bits_v :
            std_logic_vector(MAX_BINS_PER_CYCLE-1 downto 0);

        variable count_v :
            natural range 0 to MAX_BINS_PER_CYCLE;

        variable done_v   : std_logic;
        variable symbol_v : integer;
        variable need_v   : std_logic;
    begin
        bits_v   := (others => '0');
        count_v  := 0;
        done_v   := '0';
        symbol_v := 0;
        need_v   := '0';
        

        for i in 0 to MAX_BINS_PER_CYCLE-1 loop
            if stage_success(i) = '1' then
                bits_v(i) := stage_bin(i);
                count_v := count_v + 1;
            end if;

            if stage_need_bits(i) = '1' then
                need_v := '1';
            end if;

            if (stage_symbol_done(i) = '1') and
               (done_v = '0')
            then
                done_v := '1';
                symbol_v := stage_symbol(i);
            end if;
        end loop;

        decoded_bits_comb <= bits_v;
        valid_count_comb  <= count_v;

        symbol_done_comb  <= done_v;
        symbol_value_comb <= symbol_v;
        need_bits_comb    <= need_v;
    end process;

    ----------------------------------------------------------------
    -- Convert Decoder_step's local bit pointer into the number of
    -- compressed bits to remove from the reservoir this clock.
    ----------------------------------------------------------------
    consume_count_s <=
        arithmetic_chain(MAX_BINS_PER_CYCLE).bit_ptr
        when
            (stage_enable(0) = '1') and
            (symbol_done_comb = '1') and
            (need_bits_comb = '0') and
             (give_output = '1')
        else
            0;

    ----------------------------------------------------------------
    -- Sequential state / initialization / continuous decoding
    ----------------------------------------------------------------
    process(clk)
        variable next_value_v : unsigned(32 downto 0);
    begin
        if rising_edge(clk) then

            --------------------------------------------------------
            -- One-clock/debug defaults
            --------------------------------------------------------
            bit_consume_r <= '0';
            decoded_bits_r <= (others => '0');
            valid_count_r <= 0;
            need_bits_r <= '0';
            symbol_commit_r <= '0';

        

            if rst = '1' then

                arithmetic_reg <= (
                    low_value  => (others => '0'),
                    high_value => FULL_C,
                    code_value => (others => '0'),
                    bit_ptr    => 0
                );

                c0_reg <=
                    (others => to_unsigned(1, 7));

                c1_reg <=
                    (others => to_unsigned(1, 7));

                init_state <= INIT_REQ;
                init_count <= 0;
                init_done_r <= '0';

                symbol_out_r <= 0;
                symbol_valid_r <= '0';
                busy_r <= '1';

                run_r <= '0';
                symbol_commit_r <= '0';

            elsif init_state = INIT_REQ then

                ----------------------------------------------------
                -- Request one initialization bit from reservoir.
                ----------------------------------------------------
                bit_consume_r <= '1';
                busy_r <= '1';
                init_state <= INIT_WAIT;

            elsif init_state = INIT_WAIT then

                ----------------------------------------------------
                -- Capture one of the first 32 arithmetic-code bits.
                ----------------------------------------------------
                if reservoir_bit_valid = '1' then
                    next_value_v :=
                        shift_left(arithmetic_reg.code_value, 1);

                    next_value_v(0) := reservoir_bit;

                    arithmetic_reg.code_value <= next_value_v;

                    if init_count = 31 then
                        init_done_r <= '1';
                        init_state <= READY;
                        busy_r <= '0';
                    else
                        init_count <= init_count + 1;
                        init_state <= INIT_REQ;
                    end if;

                else
                    -- No initialization bit yet. Retry.
                    init_state <= INIT_REQ;
                end if;

            else

                ----------------------------------------------------
                -- READY / continuous decoding
                ----------------------------------------------------
                if end_of_stream = '1' then
                    run_r <= '0';
                    busy_r <= '0';
                    symbol_valid_r <= '0';

                else
                    if start_decode = '1' then
                        run_r <= '1';
                    end if;

                    if (run_r = '1') or
                       (start_decode = '1')
                    then
                        busy_r <= '1';

                        decoded_bits_r <= decoded_bits_comb;
                        valid_count_r <= valid_count_comb;

                       if need_bits_comb = '1' then

    need_bits_r <= '1';

    assert false
    report "CABAC BIT SHORTAGE: " &
           "time=" & time'image(now) &
           " reservoir_valid_bits=" &
           integer'image(reservoir_valid_s) &
           " fifo_level=" &
           integer'image(fifo_level_s) &
           " valid_bins=" &
           integer'image(valid_count_comb)
    severity warning;

elsif symbol_done_comb /= '1' then

    assert false
        report "ERROR: Symbol needs more than MAX_BINS_PER_CYCLE bins"
        severity failure;

end if;

                        if (symbol_done_comb = '1') and
                           (need_bits_comb = '0') and
                           (give_output = '1') then
                        
                            ------------------------------------------------
                            -- Keep arithmetic low/high/code and updated
                            -- contexts, but restart local reservoir indexing
                            -- from bit 0 for the next symbol.
                            ------------------------------------------------
                            arithmetic_reg <= (
                                low_value  => arithmetic_chain(MAX_BINS_PER_CYCLE).low_value,
                                high_value => arithmetic_chain(MAX_BINS_PER_CYCLE).high_value,
                                code_value => arithmetic_chain(MAX_BINS_PER_CYCLE).code_value,
                                bit_ptr    => 0
                            );

                            c0_reg <= c0_chain(MAX_BINS_PER_CYCLE);
                            c1_reg <= c1_chain(MAX_BINS_PER_CYCLE);

                            symbol_out_r <= symbol_value_comb;
                            symbol_valid_r <= '1';
                            symbol_commit_r <= '1';
                        end if;

                    else
                        busy_r <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture;
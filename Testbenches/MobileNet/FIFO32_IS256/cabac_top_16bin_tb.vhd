library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;

library std;
use std.textio.all;
use std.env.all;

entity CABAC_TOP_tb is
    generic (
        TB_FIFO_DEPTH : positive := 32;

        -- 0 = continuous source
        -- 1 = periodic source interruption
        TB_BURST_MODE : natural := 0;
        TB_ON_CYCLES  : positive := 20;
        TB_OFF_CYCLES : natural := 15;

        TB_INPUT_FILE : string :=
    "../../../data/mobilenet/encoded_bits_mobilenet.txt";

TB_GOLDEN_FILE : string :=
    "../../../data/mobilenet/original_weights_mobilenet.txt";

        -- Strict mode terminates at the first detected
        -- decoder bit shortage or output gap.
        TB_STRICT_MODE : boolean := true;

        -- Maximum consecutive missing commits after
        -- continuous output has been established.
        TB_MAX_GAP_CYCLES : positive := 1;

        -- Maximum simulation cycles after reset.
        TB_TIMEOUT_CYCLES : positive := 10000000
    );
end entity CABAC_TOP_tb;


architecture tb of CABAC_TOP_tb is

    ------------------------------------------------------------
    -- Configuration
    ------------------------------------------------------------

    constant CLK_PERIOD : time := 10 ns;

    constant RESERVOIR_WIDTH : positive := 256;

    constant MAX_BINS_PER_CYCLE : positive := 16;

    -- UPDATED:
    -- Previously 64 bits.
    -- Now wait for the entire 256-bit reservoir to fill.
    constant PREFILL_BITS : natural := 256;

    constant TAIL_ZERO_BYTES : natural := 4;

    
       constant BITSTREAM_PATH : string := TB_INPUT_FILE;
    constant ORIGINAL_WEIGHTS_PATH : string := TB_GOLDEN_FILE;



    ------------------------------------------------------------
    -- Clock and reset
    ------------------------------------------------------------

    signal clk : std_logic := '0';

    signal rst : std_logic := '1';


    ------------------------------------------------------------
    -- Encoded input interface
    ------------------------------------------------------------

    signal data_in : std_logic_vector(7 downto 0) :=
        (others => '0');

    signal data_valid : std_logic := '0';

    signal data_ready : std_logic;


    ------------------------------------------------------------
    -- Decoder control
    ------------------------------------------------------------

    signal start_decode : std_logic := '0';

    signal end_of_stream : std_logic := '0';

    signal give_output : std_logic := '0';


    ------------------------------------------------------------
    -- Decoder outputs
    ------------------------------------------------------------

    signal symbol_out : integer;

    signal symbol_valid : std_logic;

    signal symbol_commit : std_logic;

    signal busy : std_logic;

    signal init_done : std_logic;


    ------------------------------------------------------------
    -- Debug signals
    ------------------------------------------------------------

    signal decoded_bits :
        std_logic_vector(MAX_BINS_PER_CYCLE-1 downto 0);

    signal valid_count :
        natural range 0 to MAX_BINS_PER_CYCLE;

    signal fifo_level :
        integer range 0 to TB_FIFO_DEPTH;

    signal reservoir_valid_bits :
        natural range 0 to RESERVOIR_WIDTH;

    signal bits_consumed :
        natural range 0 to RESERVOIR_WIDTH;

    signal need_bits : std_logic;


    ------------------------------------------------------------
    -- Testbench status
    ------------------------------------------------------------

    signal file_done : std_logic := '0';

    signal decoder_stall_cycles : natural := 0;

    signal input_stall_cycles : natural := 0;

    signal symbol_commit_cycles : natural := 0;

    signal simulation_cycles : natural := 0;

    signal source_pause : std_logic := '0';


begin

    ------------------------------------------------------------
    -- Clock generation
    ------------------------------------------------------------

    clk <= not clk after CLK_PERIOD / 2;


    ------------------------------------------------------------
    -- DUT instantiation
    ------------------------------------------------------------

    DUT : entity work.CABAC_TOP

        generic map (
            FIFO_DEPTH => TB_FIFO_DEPTH,

            RESERVOIR_WIDTH => RESERVOIR_WIDTH,

            MAX_BINS_PER_CYCLE => MAX_BINS_PER_CYCLE
        )

        port map (
            clk => clk,

            rst => rst,

            data_in => data_in,

            data_valid => data_valid,

            data_ready => data_ready,

            start_decode => start_decode,

            end_of_stream => end_of_stream,

            symbol_out => symbol_out,

            symbol_valid => symbol_valid,

            symbol_commit => symbol_commit,

            busy => busy,

            give_output => give_output,

            init_done => init_done,

            decoded_bits => decoded_bits,

            valid_count => valid_count,

            fifo_level => fifo_level,

            reservoir_valid_bits => reservoir_valid_bits,

            bits_consumed => bits_consumed,

            need_bits => need_bits
        );


    ------------------------------------------------------------
    -- Reset process
    ------------------------------------------------------------

    RESET_PROC : process
    begin

        rst <= '1';

        wait for 30 ns;

        wait until falling_edge(clk);

        rst <= '0';

        report "RESET RELEASED";

        wait;

    end process;


    ------------------------------------------------------------
    -- Encoded data source
    ------------------------------------------------------------

    FILE_SOURCE : process

        file bitstream_file : text;

        variable status : file_open_status;

        variable L : line;

        variable byte_v :
            std_logic_vector(7 downto 0);

        variable bytes_sent : natural := 0;

        variable cycle_in_pattern : natural := 0;


        --------------------------------------------------------
        -- Send one byte using ready/valid handshake
        --------------------------------------------------------

        procedure send_byte(
            constant b : in std_logic_vector(7 downto 0)
        ) is

        begin

            loop

                wait until falling_edge(clk);

                if TB_BURST_MODE /= 0
                   and TB_OFF_CYCLES > 0
                   and
                   (cycle_in_pattern mod
                   (TB_ON_CYCLES + TB_OFF_CYCLES))
                   >= TB_ON_CYCLES then

                    data_valid <= '0';

                    source_pause <= '1';

                else

                    data_in <= b;

                    data_valid <= '1';

                    source_pause <= '0';

                end if;

                cycle_in_pattern :=
                    cycle_in_pattern + 1;

                wait until rising_edge(clk);

                exit when
                    data_valid = '1'
                    and data_ready = '1';

            end loop;

            data_valid <= '0';

        end procedure;


    begin

        data_valid <= '0';

        file_done <= '0';

        wait until rst = '0';

        report "STARTING ENCODED INPUT";

        file_open(
            status,
            bitstream_file,
            BITSTREAM_PATH,
            read_mode
        );

        assert status = open_ok
            report "Cannot open " & BITSTREAM_PATH
            severity failure;


        --------------------------------------------------------
        -- Read encoded bytes
        --------------------------------------------------------

        while not endfile(bitstream_file) loop

            readline(bitstream_file, L);

            if L'length > 0 then

                read(L, byte_v);

                send_byte(byte_v);

                bytes_sent := bytes_sent + 1;

            end if;

        end loop;


        --------------------------------------------------------
        -- Append zero bytes for decoder termination
        --------------------------------------------------------

        for i in 1 to TAIL_ZERO_BYTES loop

            send_byte((others => '0'));

        end loop;


        --------------------------------------------------------
        -- Finish input
        --------------------------------------------------------

        wait until falling_edge(clk);

        data_valid <= '0';

        source_pause <= '0';

        file_done <= '1';

        file_close(bitstream_file);

        report
            "INPUT COMPLETE: bytes="
            & integer'image(bytes_sent)
            & ", zero tail bytes="
            & integer'image(TAIL_ZERO_BYTES);

        wait;

    end process;


    ------------------------------------------------------------
    -- UPDATED START PROCESS
    --
    -- Wait for:
    --   1. CABAC initialization
    --   2. Full 256-bit intermediate storage
    --
    -- Only then start continuous symbol decoding.
    ------------------------------------------------------------

    START_PROC : process

    begin

        start_decode <= '0';

        give_output <= '0';


        --------------------------------------------------------
        -- Step 1: Wait for initialization
        --------------------------------------------------------

        wait until init_done = '1';

        report "CABAC INITIALIZATION COMPLETE";


        --------------------------------------------------------
        -- Step 2: Wait for full reservoir
        --------------------------------------------------------

        if reservoir_valid_bits < PREFILL_BITS then

            report
                "WAITING FOR RESERVOIR PREFILL: current="
                & integer'image(reservoir_valid_bits)
                & " target="
                & integer'image(PREFILL_BITS);

            wait until
                reservoir_valid_bits >= PREFILL_BITS;

        end if;


        --------------------------------------------------------
        -- Step 3: Reservoir is completely filled
        --------------------------------------------------------

        report
            "RESERVOIR PREFILL COMPLETE: valid bits="
            & integer'image(reservoir_valid_bits);


        --------------------------------------------------------
        -- Step 4: Start continuous decoding
        --------------------------------------------------------

        wait until falling_edge(clk);

        start_decode <= '1';

        give_output <= '1';

        report "CONTINUOUS DECODING STARTED";


        --------------------------------------------------------
        -- Step 5: Deassert start pulse
        --------------------------------------------------------

        wait until falling_edge(clk);

        start_decode <= '0';

        wait;

    end process;


    ------------------------------------------------------------
    -- Stall and cycle monitor
    ------------------------------------------------------------

    STALL_MONITOR : process(clk)

    begin

        if rising_edge(clk) then

            if rst = '1' then

                decoder_stall_cycles <= 0;

                input_stall_cycles <= 0;

                symbol_commit_cycles <= 0;

                simulation_cycles <= 0;

            else

                simulation_cycles <=
                    simulation_cycles + 1;


                ------------------------------------------------
                -- Decoder stalls due to insufficient bits
                ------------------------------------------------

                if need_bits = '1' and give_output = '1' then

                        decoder_stall_cycles <=
                            decoder_stall_cycles + 1;

                        assert false
                            report "FAIL: CABAC decoder stalled due to insufficient bits at "
                                & time'image(now)
                            severity failure;

                    end if;


                ------------------------------------------------
                -- Input stalls due to FIFO backpressure
                ------------------------------------------------

                ------------------------------------------------------------
-- FIFO INPUT BACKPRESSURE DEBUG
------------------------------------------------------------

if data_valid = '1' and data_ready = '0' then
 input_stall_cycles <= input_stall_cycles + 1;

 -----   report
  --      "FIFO INPUT BACKPRESSURE: "
  --      & "time=" & time'image(now)
  ---      & " cycle=" & integer'image(simulation_cycles)
 --       & " fifo_level=" & integer'image(fifo_level)
 --       & " reservoir_bits="
 --       & integer'image(reservoir_valid_bits)
 --       & " init_done=" & std_logic'image(init_done)
  --      & " give_output=" & std_logic'image(give_output)
 --       & " need_bits=" & std_logic'image(need_bits)

 --   severity warning;

end if;


                ------------------------------------------------
                -- Count committed symbols
                ------------------------------------------------

                if symbol_commit = '1' then

                    symbol_commit_cycles <=
                        symbol_commit_cycles + 1;

                end if;


                ------------------------------------------------
                -- Timeout protection
                ------------------------------------------------

              --  assert
                 --   simulation_cycles < TB_TIMEOUT_CYCLES

                 --   report
                  --      "TIMEOUT: decoder did not finish. "
                 --       & "Check reservoir prefill, "
                  --      & "starvation, EOS and renormalization."

                 --   severity failure;

            end if;

        end if;

    end process;


    ------------------------------------------------------------
    -- Compare decoded symbols against Python reference
    ------------------------------------------------------------

    RESULT_PROC : process

        file weights_file : text;

        variable status : file_open_status;

        variable L : line;

        variable expected_v : integer;

        variable symbol_number : natural := 0;

        variable mismatch_count : natural := 0;

    begin

        file_open(
            status,
            weights_file,
            ORIGINAL_WEIGHTS_PATH,
            read_mode
        );

        assert status = open_ok

            report
                "Cannot open "
                & ORIGINAL_WEIGHTS_PATH

            severity failure;


        --------------------------------------------------------
        -- Monitor committed symbols
        --------------------------------------------------------

        loop

            wait until rising_edge(clk);

            wait for 1 ps;


            if rst = '0'
               and symbol_commit = '1' then


                ------------------------------------------------
                -- Ensure reference data remains
                ------------------------------------------------

                assert not endfile(weights_file)

                    report
                        "Decoder produced more symbols "
                        & "than reference"

                    severity failure;


                ------------------------------------------------
                -- Read expected symbol
                ------------------------------------------------

                readline(weights_file, L);

                read(L, expected_v);


                ------------------------------------------------
                -- Compare
                ------------------------------------------------

                if symbol_out /= expected_v then

                    mismatch_count :=
                        mismatch_count + 1;

                    report
                        "MISMATCH ["
                        & integer'image(symbol_number)
                        & "] expected="
                        & integer'image(expected_v)
                        & " actual="
                        & integer'image(symbol_out)

                    severity failure;

                end if;


                ------------------------------------------------
                -- Update symbol count
                ------------------------------------------------

                symbol_number :=
                    symbol_number + 1;


                ------------------------------------------------
                -- Progress report
                ------------------------------------------------

                if symbol_number mod 10000 = 0 then

                    report
                        "Checked "
                        & integer'image(symbol_number)
                        & " symbols";

                end if;


                ------------------------------------------------
                -- All symbols verified
                ------------------------------------------------

                if endfile(weights_file) then

                    end_of_stream <= '1';

                    report
                        "PASS: all "
                        & integer'image(symbol_number)
                        & " symbols matched";

                    report
                        "FIFO depth="
                        & integer'image(TB_FIFO_DEPTH)
                        & " decoder stall cycles="
                        & integer'image(decoder_stall_cycles)
                        & " input stall cycles="
                        & integer'image(input_stall_cycles);

                    file_close(weights_file);

                    wait until falling_edge(clk);

                    std.env.stop;

                    wait;

                end if;

            end if;

        end loop;

    end process;

    ------------------------------------------------------------
-- SYMBOL_VALID CONTINUITY CHECK
--
-- Once SYMBOL_VALID becomes '1', it must remain '1'
-- throughout normal operation.
------------------------------------------------------------
SYMBOL_VALID_MONITOR : process(clk)

    variable valid_seen : boolean := false;
   -- variable cycle_count : natural := 0;

begin

    if rising_edge(clk) then

        if rst = '1' then

            valid_seen := false;
           -- cycle_count := 0;

           -- report "SYMBOL_VALID_MONITOR: Reset active at "
            --    & time'image(now)
             --   severity note;

        else

         --   cycle_count := cycle_count + 1;    
          --  if cycle_count mod 10 = 0 then

             --   report "MONITOR ACTIVE: cycle="
              --      & integer'image(cycle_count)
              ---      & " time=" & time'image(now)
              --      & " symbol_valid="
             --       & std_logic'image(symbol_valid)
              --      & " valid_seen="
            --        & boolean'image(valid_seen)
             --       severity note;

         --   end if;

            -- Detect the FIRST assertion of SYMBOL_VALID
            if symbol_valid = '1' then

                valid_seen := true;

                --report "FIRST SYMBOL_VALID HIGH at "
                 --   & time'image(now)
                  --  severity note;

            end if;

            -- Detect unexpected drop after first HIGH
            if valid_seen
               and symbol_valid /= '1'
               and end_of_stream = '0' then

                assert false
                    report "ERROR: SYMBOL_VALID DROPPED! "
                        & "Simulation time = "
                        & time'image(now)
                    severity failure;

            end if;

        end if;

    end if;

end process SYMBOL_VALID_MONITOR;


end architecture tb;